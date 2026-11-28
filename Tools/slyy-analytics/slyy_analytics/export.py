"""Turns analytics.json (and an optional review.json) into one data file per table, {rows, meta},
for a dashboard or any other reader. Each file says which tool, commit and command made it."""
from __future__ import annotations
import json, os


def _file(out: str, name: str, rows: list, meta: list) -> str:
    path = os.path.join(out, f"{name}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"rows": rows, "meta": meta}, f, ensure_ascii=False, indent=1)
    return path


def export(results: dict, out: str, review: dict | None = None, cleanup: dict | None = None) -> list[str]:
    os.makedirs(out, exist_ok=True)
    base = [{"label": "Tool", "value": f"slyy-analytics {results['tool_version']} (Tools/slyy-analytics)"},
            {"label": "Project", "value": results["project"]},
            {"label": "Commit", "value": results.get("commit", "")},
            {"label": "Generated", "value": results["generated"]},
            {"label": "Command", "value": "python3 -m slyy_analytics --config analytics.json && python3 -m slyy_analytics.export"}]
    s, c, d, sec = results["size"], results["coverage"], results["dependencies"], results["security"]
    t = s["totals"]
    paths = []
    findings = (review or {}).get("findings", [])
    paths.append(_file(out, "totals", [{
        "code_lines": t["code"], "test_lines": t["test"], "test_ratio": t["test_ratio"], "functions": t["functions"],
        "median_function_lines": t["median_function_length"], "comment_ratio": t["comment_ratio"],
        "coverage_percent": c.get("percent"), "releases": len(results["history"].get("releases", [])),
        "commits": results["history"].get("commits"),
        "review_important": sum(1 for f in findings if f["severity"] == "important"),
        "review_minor": sum(1 for f in findings if f["severity"] != "important"),
        "long_functions": len(s["flags"]["long_functions"]), "large_files": len(s["flags"]["large_files"]),
        "duplicated_lines": results.get("redundancy", {}).get("duplicates", {}).get("duplicated_lines"),
        "unused_candidates": len(results.get("redundancy", {}).get("unused", {}).get("candidates", [])),
        "cleanup_items": len((cleanup or {}).get("items", [])),
        "cleanup_lines": sum(i.get("lines", 0) for i in (cleanup or {}).get("items", [])),
    }], base + [{"label": "Definitions", "value": "code/test lines exclude comments and blank lines; test ratio = test lines per line of production code; coverage = share of the library's executable lines run by its tests"}]))
    paths.append(_file(out, "modules", [{"module": m["name"], "kind": m.get("kind", ""), "files": m["files"], "code": m["code"], "comment": m["comment"]} for m in s["modules"]], base))
    paths.append(_file(out, "releases", [{"tag": r["tag"], "date": r["date"][:10], "code": r["code"], "test": r["test"]} for r in results["history"].get("releases", [])], base + [{"label": "Method", "value": "lines counted at each release tag from git, without checking it out"}]))
    if c.get("available"):
        paths.append(_file(out, "coverage", [{"module": m["name"], "covered": m["covered"], "lines": m["lines"], "percent": m["percent"]} for m in c["modules"]], base + [{"label": "Measured", "value": c.get("note", "")}]))
        paths.append(_file(out, "coverage_files", [{"file": r["path"].split("/")[-1], "path": r["path"], "lines": r["lines"], "percent": r["percent"]} for r in c["least_covered"]], base))
    paths.append(_file(out, "functions", [{"function": f["name"], "file": f["path"].split("/")[-1], "path": f["path"], "line": f["line"], "lines": f["length"]} for f in s["longest_functions"][:12]], base))
    sec_rows = []
    for e in sec.get("entitlements", []):
        sec_rows.append({"id": e["entitlement"], "area": "App permission", "severity": e["severity"], "item": e["entitlement"].replace("com.apple.security.", ""), "detail": e["allows"]})
    for x in sec.get("transport", []):
        sec_rows.append({"id": x["setting"], "area": "Network", "severity": x["severity"], "item": x["setting"], "detail": "plain connections allowed to local network addresses"})
    for w in sec.get("workflows", []):
        sec_rows.append({"id": "wf-" + w["workflow"], "area": "CI", "severity": "low" if "write" in w["permissions"] else "info", "item": w["workflow"],
                         "detail": f"permissions {w['permissions']}; {len(w['secrets'])} secrets; actions not pinned to a commit: {', '.join(w['unpinned_actions']) or 'none'}"})
    for p in d.get("packages", []):
        sev = "medium" if "minimum" in p["pinned"] and not d.get("lockfile") else "info"
        sec_rows.append({"id": "dep-" + p["name"], "area": "Dependency", "severity": sev, "item": f"{p['name']} {p.get('version') or ''}".strip(),
                         "detail": f"{p['pinned']}{'; no lockfile committed, so each build may pick a newer release' if not d.get('lockfile') else ''}"})
    for h in sec.get("committed_secrets", []):
        sec_rows.append({"id": f"secret-{h['path']}:{h['line']}", "area": "Secrets", "severity": h["severity"], "item": f"{h['path'].split('/')[-1]}:{h['line']}",
                         "detail": f"{h['kind']} pattern" + (" in a test (placeholder value)" if h["in_tests"] else "")})
    order = ["high", "medium", "low", "info"]
    sec_rows.sort(key=lambda r: order.index(r["severity"]) if r["severity"] in order else 9)
    paths.append(_file(out, "security", sec_rows, base))
    if review:
        paths.append(_file(out, "review", [{"id": f["id"], "severity": f["severity"], "area": f["area"], "file": f["file"].split("/")[-1], "path": f["file"], "line": f["line"],
                                             "summary": f["summary"], "scenario": f["scenario"]} for f in findings],
                           base + [{"label": "Review", "value": f"{review.get('method', '')}; scope {review.get('scope', '')}; {review.get('reviewed', '')}"}]))
    red = results.get("redundancy", {})
    if red.get("duplicates"):
        rows = [{"id": f"D{i + 1}", "lines": g["lines"], "places": len(g["places"]),
                 "where": "; ".join(f"{p['path'].split('/')[-1]}:{p['start']}-{p['end']}" for p in g["places"])}
                for i, g in enumerate(red["duplicates"]["groups"])]
        paths.append(_file(out, "duplicates", rows, base + [{"label": "Method", "value": f"blocks of at least {red['duplicates']['min_lines']} significant lines (literals and whitespace normalised) found in more than one place"}]))
    if cleanup:
        paths.append(_file(out, "cleanup", cleanup["items"], base + [{"label": "Checked", "value": f"by hand, {cleanup.get('checked', '')}; marked in code as // CLEANUP(Cn), list in docs/CLEANUP.md"}]))
    return paths


if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser(prog="slyy-analytics export")
    p.add_argument("--in", dest="inp", default="build/analytics/analytics.json")
    p.add_argument("--review", default="build/analytics/review.json")
    p.add_argument("--cleanup", default="build/analytics/cleanup.json")
    p.add_argument("--out", default="build/analytics/dash")
    a = p.parse_args()
    r = json.load(open(a.inp, encoding="utf-8"))
    rv = json.load(open(a.review, encoding="utf-8")) if os.path.exists(a.review) else None
    cl = json.load(open(a.cleanup, encoding="utf-8")) if os.path.exists(a.cleanup) else None
    for path in export(r, a.out, rv, cl):
        print(path)
