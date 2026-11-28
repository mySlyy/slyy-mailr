"""Writes the results as analytics.json (for dashboards and later comparison) and REPORT.md (for people)."""
from __future__ import annotations
import json, os
from datetime import datetime, timezone


def write(results: dict, out_dir: str) -> tuple[str, str]:
    os.makedirs(out_dir, exist_ok=True)
    jpath = os.path.join(out_dir, "analytics.json")
    with open(jpath, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2, ensure_ascii=False, default=str)
    mpath = os.path.join(out_dir, "REPORT.md")
    with open(mpath, "w", encoding="utf-8") as f:
        f.write(markdown(results))
    return jpath, mpath


def markdown(r: dict) -> str:
    s, t = r["size"], r["size"]["totals"]
    lines = [f"# Code analytics · {r['project']}", "", f"{r['generated']} · commit `{r.get('commit', '?')}` · slyy-analytics {r['tool_version']}", "",
             "## Size", "", "| Module | Kind | Files | Code | Comments |", "|---|---|---:|---:|---:|"]
    for m in s["modules"]:
        lines.append(f"| {m['name']} | {m.get('kind', '')} | {m['files']} | {m['code']:,} | {m['comment']:,} |")
    lines += ["", f"Production code {t['code']:,} lines, tests {t['test']:,} (ratio {t['test_ratio']}), {t['functions']} functions, median length {t['median_function_length']} lines.", ""]
    lines += ["## Longest functions", ""] + [f"- `{f['path']}:{f['line']}` {f['name']} · {f['length']} lines" for f in s["longest_functions"][:10]]
    c = r["coverage"]
    lines += ["", "## Coverage", ""]
    if c.get("available"):
        lines += [f"{c['percent']} % of {c['lines']:,} lines ({c.get('note', '')})", ""] + [f"- {m['name']}: {m['percent']} %" for m in c["modules"]]
    else:
        lines.append(f"Not available: {c.get('reason')}")
    d = r["dependencies"]
    lines += ["", "## Dependencies", ""] + [f"- {p['name']} {p.get('version') or ''} · {p['pinned']}" for p in d["packages"]]
    sec = r["security"]
    lines += ["", "## Security", ""] + [f"- [{e['severity']}] {e['entitlement']}: {e['allows']}" for e in sec["entitlements"]]
    lines += [f"- [{h['severity']}] {h['kind']} in `{h['path']}:{h['line']}`" for h in sec["committed_secrets"]]
    return "\n".join(lines) + "\n"


def stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
