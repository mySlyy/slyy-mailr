"""Security posture: app entitlements, transport exceptions, CI permissions and secrets, committed credentials."""
from __future__ import annotations
import os, plistlib, re

# Entitlements worth a second look, with what they allow.
ENTITLEMENT_NOTES = {
    "com.apple.security.app-sandbox": ("info", "App Sandbox on"),
    "com.apple.security.network.client": ("info", "outgoing network connections"),
    "com.apple.security.network.server": ("medium", "may listen for incoming connections"),
    "com.apple.security.device.camera": ("info", "camera (video calls)"),
    "com.apple.security.device.audio-input": ("info", "microphone (video calls)"),
    "com.apple.security.files.user-selected.read-write": ("info", "files the user picks"),
    "com.apple.security.files.downloads.read-write": ("low", "the Downloads folder"),
    "com.apple.security.application-groups": ("info", "a shared app-group container"),
    "com.apple.security.temporary-exception.mach-lookup.global-name": ("medium", "temporary exception: talk to named system services"),
    "com.apple.security.temporary-exception.files.absolute-path.read-write": ("medium", "temporary exception: write outside the sandbox"),
    "com.apple.security.temporary-exception.files.home-relative-path.read-write": ("medium", "temporary exception: write in the home folder"),
    "com.apple.security.temporary-exception.files.absolute-path.read-only": ("low", "temporary exception: read outside the sandbox"),
    "com.apple.security.cs.disable-library-validation": ("high", "loads unsigned libraries"),
    "com.apple.security.cs.allow-jit": ("medium", "JIT code"),
    "com.apple.security.get-task-allow": ("high", "debuggable by other processes"),
}

SECRET_PATTERNS = [
    ("private key", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |)PRIVATE KEY-----")),
    ("AWS access key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("GitHub token", re.compile(r"gh[pousr]_[A-Za-z0-9]{36,}")),
    ("Slack token", re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}")),
    ("Anthropic/OpenAI key", re.compile(r"sk-(?:ant-)?[A-Za-z0-9_-]{32,}")),
    ("password in code", re.compile(r"(?i)\b(?:password|passwd|secret)\s*[:=]\s*\"([^\"\s]{8,})\"")),
]


def _entitlements(config, files):
    found = []
    for rel in files:
        if rel.endswith(".entitlements"):
            try:
                data = plistlib.load(open(os.path.join(config.root, rel), "rb"))
                found += [(k, rel) for k, v in data.items() if v]
            except Exception:
                pass
    for rel in config.security.get("entitlements_in", ["project.yml"]):
        path = os.path.join(config.root, rel)
        if os.path.exists(path):
            for m in re.finditer(r"^\s*(com\.apple\.security\.[\w.-]+):\s*(\S*)", open(path, encoding="utf-8").read(), re.M):
                if m.group(2).lower() != "false":
                    found.append((m.group(1), rel))
    out, seen = [], set()
    for key, where in found:
        if key in seen:
            continue
        seen.add(key)
        sev, what = ENTITLEMENT_NOTES.get(key, ("low", "other entitlement"))
        out.append({"entitlement": key, "severity": sev, "allows": what, "declared_in": where})
    return sorted(out, key=lambda e: ["high", "medium", "low", "info"].index(e["severity"]))


def _transport(config):
    out = []
    for rel in config.security.get("plists_in", ["project.yml"]):
        path = os.path.join(config.root, rel)
        if os.path.exists(path):
            text = open(path, encoding="utf-8").read()
            for key, sev in [("NSAllowsArbitraryLoads", "high"), ("NSAllowsLocalNetworking", "low"), ("NSExceptionDomains", "medium")]:
                if re.search(rf"{key}:\s*true", text) or (key == "NSExceptionDomains" and key in text):
                    out.append({"setting": key, "severity": sev, "declared_in": rel})
    return out


def _workflows(config):
    wf_dir = os.path.join(config.root, ".github", "workflows")
    out = []
    if not os.path.isdir(wf_dir):
        return out
    for f in sorted(os.listdir(wf_dir)):
        text = open(os.path.join(wf_dir, f), encoding="utf-8").read()
        perms = re.findall(r"^permissions:\s*\n((?:\s+\w[\w-]*:\s*\w+\n)+)", text, re.M)
        out.append({
            "workflow": f,
            "triggers": re.findall(r"^\s{2}(push|pull_request_target|pull_request|workflow_dispatch|schedule|release):", text, re.M),
            "permissions": " ".join(p.strip().replace("\n", ",") for p in perms) or "default (read/write for the repo)",
            "secrets": sorted(set(re.findall(r"secrets\.([A-Z0-9_]+)", text))),
            "pull_request_target": "pull_request_target" in text,
            "unpinned_actions": sorted(set(m.group(0).split("uses:")[1].strip() for m in re.finditer(r"uses:\s*[\w./-]+@(?![0-9a-f]{40})[\w.-]+", text))),
        })
    return out


def _secrets(config, files):
    hits = []
    allowed = config.security.get("allow_secret_patterns_in", [])
    for rel in files:
        if config.excluded(rel) or any(rel.startswith(a) for a in allowed):
            continue
        path = os.path.join(config.root, rel)
        try:
            if os.path.getsize(path) > 2_000_000:
                continue
            text = open(path, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        for label, rx in SECRET_PATTERNS:
            for m in rx.finditer(text):
                line = text.count("\n", 0, m.start()) + 1
                in_test = "/Tests/" in rel or "test" in rel.lower()
                hits.append({"kind": label, "path": rel, "line": line, "in_tests": in_test,
                             "severity": "low" if in_test else "high"})
    return hits


def analyse(config, files: list[str]) -> dict:
    return {
        "entitlements": _entitlements(config, files),
        "transport": _transport(config),
        "workflows": _workflows(config),
        "committed_secrets": _secrets(config, files),
    }
