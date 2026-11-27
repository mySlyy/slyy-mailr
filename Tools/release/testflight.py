#!/usr/bin/env python3
"""TestFlight distribution through the App Store Connect API (used by CI).

  testflight.py preflight                      bundle ID registered? app record present? (prints the app id)
  testflight.py distribute --build N --version V [--group NAME] [--limit 100] [--notes FILE]
                                               waits until build N is processed, then: "What to Test" text,
                                               public tester group (link limited to --limit testers),
                                               build added to the group, submitted for beta review,
                                               public link written to stdout and $GITHUB_STEP_SUMMARY.

Auth from the environment: ASC_KEY_ID, ASC_ISSUER_ID (team keys), ASC_KEY_P8 (PEM text or base64 of it).
Optional, only used when App Store Connect has no beta test information yet:
  BETA_FEEDBACK_EMAIL, BETA_CONTACT_FIRST_NAME, BETA_CONTACT_LAST_NAME, BETA_CONTACT_PHONE, BETA_CONTACT_EMAIL,
  BETA_DEMO_USER, BETA_DEMO_PASSWORD (a test mailbox for Apple's reviewers).
"""
import argparse, base64, json, os, sys, time, urllib.error, urllib.request

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "ai.slyy.mailr"
APP_NAME = "Slyy Mailr"
DESCRIPTION = (
    "Slyy Mailr is mail, calendar and video calls for your own mail server (IMAP, SMTP, CalDAV) "
    "with Jitsi video meetings. Please test: reading and writing mail, swipe actions, selecting several "
    "messages, attachments and photos, the calendar list, meeting invitations, and new-mail notifications."
)


def b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def token():
    key_id = os.environ["ASC_KEY_ID"]
    issuer = os.environ.get("ASC_ISSUER_ID", "")
    raw = os.environ["ASC_KEY_P8"]
    pem = raw.encode() if "BEGIN PRIVATE KEY" in raw else base64.b64decode(raw)
    key = serialization.load_pem_private_key(pem, password=None)
    now = int(time.time())
    payload = {"iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"}
    if issuer:
        payload["iss"] = issuer
    else:
        payload["sub"] = "user"  # individual key
    head = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    body = b64url(json.dumps(payload).encode())
    der = key.sign(f"{head}.{body}".encode(), ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    return f"{head}.{body}.{b64url(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


class APIError(Exception):
    def __init__(self, status, body):
        self.status, self.body = status, body
        try:
            errs = json.loads(body).get("errors", [])
            msg = "; ".join(f"{e.get('title')}: {e.get('detail')}" for e in errs)
        except Exception:
            msg = body[:500]
        super().__init__(f"HTTP {status}: {msg}")


def call(method, path, body=None, ok=(200, 201, 204)):
    req = urllib.request.Request(API + path, method=method)
    req.add_header("Authorization", "Bearer " + token())
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, data, timeout=60) as r:
            text = r.read().decode()
            return json.loads(text) if text else {}
    except urllib.error.HTTPError as e:
        text = e.read().decode()
        if e.code in ok:
            return json.loads(text) if text else {}
        raise APIError(e.code, text)


def q(s):
    return urllib.request.quote(s, safe="")


def find_app():
    apps = call("GET", f"/v1/apps?filter[bundleId]={q(BUNDLE_ID)}")["data"]
    return apps[0] if apps else None


def ensure_bundle_id():
    found = call("GET", f"/v1/bundleIds?filter[identifier]={q(BUNDLE_ID)}")["data"]
    exact = [b for b in found if b["attributes"]["identifier"] == BUNDLE_ID]
    if exact:
        platform = exact[0]["attributes"]["platform"]
        print(f"Bundle ID {BUNDLE_ID} registered ({platform}).")
        return
    call("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
        "identifier": BUNDLE_ID, "name": APP_NAME, "platform": "UNIVERSAL"}}})
    print(f"Registered bundle ID {BUNDLE_ID} (iOS + macOS).")


def preflight(_):
    try:
        ensure_bundle_id()
    except APIError as e:
        print(f"::warning::Could not check or register the bundle ID ({e}). "
              "If the archive step fails on signing, the API key needs the Admin role.")
    app = find_app()
    if not app:
        print("::error::No App Store Connect app for ai.slyy.mailr yet. One-time step in App Store Connect: "
              "Apps → + → New App → platform iOS, name 'Slyy Mailr', language English, bundle ID ai.slyy.mailr, "
              "SKU slyy-mailr, full access. Then run the build again.")
        sys.exit(2)
    print(f"App Store Connect app: {app['attributes']['name']} (id {app['id']})")
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as f:
            f.write(f"app_id={app['id']}\n")


def wait_for_build(app_id, version, number, timeout=40 * 60):
    path = (f"/v1/builds?filter[app]={app_id}&filter[version]={q(number)}"
            f"&filter[preReleaseVersion.version]={q(version)}&filter[preReleaseVersion.platform]=IOS")
    start = time.time()
    while time.time() - start < timeout:
        data = call("GET", path)["data"]
        if data:
            state = data[0]["attributes"]["processingState"]
            print(f"Build {version} ({number}): {state}")
            if state == "VALID":
                return data[0]
            if state in ("FAILED", "INVALID"):
                sys.exit(f"::error::Apple rejected build {number} while processing ({state}).")
        else:
            print(f"Build {version} ({number}) not visible yet…")
        time.sleep(30)
    sys.exit("::error::Build did not finish processing within 40 minutes; it may still finish: run the workflow again with testflight on.")


def ensure_test_info(app_id):
    """Beta App Review needs a description, a feedback address, contact details and a demo login.
    Fills only what is missing and only from BETA_* variables; never overwrites what is in App Store Connect."""
    env = os.environ.get
    locs = call("GET", f"/v1/apps/{app_id}/betaAppLocalizations")["data"]
    if not locs and env("BETA_FEEDBACK_EMAIL"):
        call("POST", "/v1/betaAppLocalizations", {"data": {"type": "betaAppLocalizations",
            "attributes": {"locale": "en-US", "description": DESCRIPTION, "feedbackEmail": env("BETA_FEEDBACK_EMAIL")},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
        print("Added beta test description.")
    detail = call("GET", f"/v1/apps/{app_id}/betaAppReviewDetail")["data"]
    a = detail["attributes"]
    patch = {}
    for field, var in [("contactFirstName", "BETA_CONTACT_FIRST_NAME"), ("contactLastName", "BETA_CONTACT_LAST_NAME"),
                       ("contactPhone", "BETA_CONTACT_PHONE"), ("contactEmail", "BETA_CONTACT_EMAIL"),
                       ("demoAccountName", "BETA_DEMO_USER"), ("demoAccountPassword", "BETA_DEMO_PASSWORD")]:
        if not a.get(field) and env(var):
            patch[field] = env(var)
    if patch.get("demoAccountName"):
        patch["demoAccountRequired"] = True
        patch.setdefault("notes", "Sign in with the demo mailbox above; the servers are found automatically.")
    if patch:
        call("PATCH", f"/v1/betaAppReviewDetails/{detail['id']}", {"data": {"type": "betaAppReviewDetails", "id": detail["id"], "attributes": patch}})
        print("Filled beta review details: " + ", ".join(k for k in patch if "Password" not in k))
    missing = [f for f in ("contactFirstName", "contactLastName", "contactPhone", "contactEmail")
               if not (a.get(f) or patch.get(f))]
    if not (locs or env("BETA_FEEDBACK_EMAIL")):
        missing.append("beta description + feedback email")
    if not (a.get("demoAccountName") or patch.get("demoAccountName")):
        missing.append("demo account (sign-in required)")
    return missing


def what_to_test(build_id, notes):
    locs = call("GET", f"/v1/builds/{build_id}/betaBuildLocalizations")["data"]
    text = notes[:3900]
    if locs:
        call("PATCH", f"/v1/betaBuildLocalizations/{locs[0]['id']}", {"data": {"type": "betaBuildLocalizations", "id": locs[0]["id"], "attributes": {"whatsNew": text}}})
    else:
        call("POST", "/v1/betaBuildLocalizations", {"data": {"type": "betaBuildLocalizations",
            "attributes": {"locale": "en-US", "whatsNew": text},
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})


def ensure_group(app_id, name, limit):
    groups = call("GET", f"/v1/apps/{app_id}/betaGroups?limit=200")["data"]
    g = next((x for x in groups if x["attributes"]["name"] == name), None)
    attrs = {"publicLinkEnabled": True, "publicLinkLimitEnabled": True, "publicLinkLimit": limit, "feedbackEnabled": True}
    if g is None:
        g = call("POST", "/v1/betaGroups", {"data": {"type": "betaGroups", "attributes": {"name": name, **attrs},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})["data"]
        print(f"Created tester group '{name}'.")
    else:
        g = call("PATCH", f"/v1/betaGroups/{g['id']}", {"data": {"type": "betaGroups", "id": g["id"], "attributes": attrs}})["data"]
    return g


def distribute(args):
    app = find_app()
    if not app:
        preflight(args)
    app_id = app["id"]
    build = wait_for_build(app_id, args.version, args.build)
    notes = open(args.notes).read() if args.notes and os.path.exists(args.notes) else f"Slyy Mailr {args.version}"
    what_to_test(build["id"], notes)
    missing = ensure_test_info(app_id)
    group = ensure_group(app_id, args.group, args.limit)
    call("POST", f"/v1/betaGroups/{group['id']}/relationships/builds", {"data": [{"type": "builds", "id": build["id"]}]}, ok=(204, 409))
    print(f"Build {args.build} added to '{args.group}'.")
    submitted = False
    try:
        call("POST", "/v1/betaAppReviewSubmissions", {"data": {"type": "betaAppReviewSubmissions",
            "relationships": {"build": {"data": {"type": "builds", "id": build["id"]}}}}})
        submitted = True
        print("Submitted for Beta App Review.")
    except APIError as e:
        if e.status == 409 and "already" in e.body.lower():
            submitted = True
            print("Already submitted for Beta App Review.")
        else:
            print(f"::warning::Beta App Review submission failed: {e}")
    link = group["attributes"].get("publicLink") or ""
    lines = [f"### TestFlight: Slyy Mailr {args.version} ({args.build})",
             f"- Public link ({args.limit} testers max): {link or '(appears once the group is approved)'}",
             f"- Beta App Review: {'submitted' if submitted else 'NOT submitted'}"]
    if missing:
        lines.append("- Missing in App Store Connect → TestFlight → Test Information: " + ", ".join(missing))
    report = "\n".join(lines)
    print(report)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(report + "\n")
    if not submitted:
        print("::warning::Fill in the missing test information in App Store Connect, then run the workflow again "
              "(Actions → Build → Run workflow, with 'testflight' on).")


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("preflight").set_defaults(fn=preflight)
    d = sub.add_parser("distribute")
    d.add_argument("--build", required=True)
    d.add_argument("--version", required=True)
    d.add_argument("--group", default="Slyy Testers")
    d.add_argument("--limit", type=int, default=100)
    d.add_argument("--notes")
    d.set_defaults(fn=distribute)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
