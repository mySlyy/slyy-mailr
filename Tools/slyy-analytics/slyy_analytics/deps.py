"""Dependencies: what third-party code a repository pulls in, and how firmly it is pinned."""
from __future__ import annotations
import json, os, re


def _swift_resolved(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    pins = data.get("pins") or data.get("object", {}).get("pins", [])
    return [{"name": p.get("identity") or p.get("package"), "source": p.get("location") or p.get("repositoryURL"),
             "version": (p.get("state") or {}).get("version"), "pinned": "exact (lockfile)", "ecosystem": "SwiftPM"} for p in pins]


def _declared_swift(root: str, files: list[str]) -> list[dict]:
    """Packages declared in Package.swift or XcodeGen project.yml (`url:` + `from:`/`exactVersion:`)."""
    out = []
    for rel in files:
        path = os.path.join(root, rel)
        if not os.path.exists(path):
            continue
        text = open(path, encoding="utf-8").read()
        for m in re.finditer(r"url:\s*\"?(https?://[^\s\"]+)\"?(?:[\s,]+(from|exactVersion|branch|revision):\s*\"?([^\s\")]+)\"?)?", text):
            url, rule, version = m.group(1), m.group(2) or "unspecified", m.group(3)
            pinned = {"from": "minimum version (up to next major)", "exactVersion": "exact", "branch": "branch (moves)", "revision": "exact commit"}.get(rule, "unspecified")
            out.append({"name": url.rstrip("/").split("/")[-1].removesuffix(".git"), "source": url, "version": version, "pinned": pinned, "ecosystem": "SwiftPM", "declared_in": rel})
    return out


def _npm(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    pkgs = data.get("packages", {})
    return [{"name": k.split("node_modules/")[-1], "version": v.get("version"), "pinned": "exact (lockfile)", "ecosystem": "npm"}
            for k, v in pkgs.items() if k.startswith("node_modules/") and not v.get("dev")]


def _cargo(path: str) -> list[dict]:
    out, name = [], None
    for line in open(path, encoding="utf-8"):
        if line.startswith("name = "):
            name = line.split('"')[1]
        elif line.startswith("version = ") and name:
            out.append({"name": name, "version": line.split('"')[1], "pinned": "exact (lockfile)", "ecosystem": "Cargo"})
            name = None
    return out


def analyse(config, files: list[str]) -> dict:
    deps = []
    for rel in files:
        base = os.path.basename(rel)
        path = os.path.join(config.root, rel)
        try:
            if base == "Package.resolved":
                deps += _swift_resolved(path)
            elif base == "package-lock.json" and "node_modules" not in rel:
                deps += _npm(path)
            elif base == "Cargo.lock":
                deps += _cargo(path)
        except Exception:
            continue
    declared = _declared_swift(config.root, config.dependencies.get("declared_in", ["Package.swift", "project.yml"]) +
                               [f for f in files if f.endswith("Package.swift")])
    seen = {d["name"] for d in deps}
    deps += [d for d in declared if d["name"] not in seen]
    actions = []
    wf_dir = os.path.join(config.root, ".github", "workflows")
    if os.path.isdir(wf_dir):
        for f in sorted(os.listdir(wf_dir)):
            for m in re.finditer(r"uses:\s*([\w./-]+)@([\w.-]+)", open(os.path.join(wf_dir, f), encoding="utf-8").read()):
                actions.append({"action": m.group(1), "ref": m.group(2), "workflow": f, "pinned_to_commit": bool(re.fullmatch(r"[0-9a-f]{40}", m.group(2)))})
    return {"packages": deps, "lockfile": any(os.path.basename(f) in ("Package.resolved", "package-lock.json", "Cargo.lock") for f in files),
            "ci_actions": actions}
