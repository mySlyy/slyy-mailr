"""CLI: python3 -m slyy_analytics [--config analytics.json] [--out build/analytics]"""
from __future__ import annotations
import argparse, subprocess, sys
from . import __version__, config as cfg, size, history, coverage, deps, security, report


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="slyy-analytics", description="Code analytics for a Slyy repository.")
    p.add_argument("--config", default="analytics.json")
    p.add_argument("--root", default=None, help="repository root (default: the config's folder)")
    p.add_argument("--out", default="build/analytics")
    p.add_argument("--skip", default="", help="comma-separated: history,coverage,deps,security")
    a = p.parse_args(argv)
    c = cfg.Config.load(a.config, a.root)
    skip = set(filter(None, a.skip.split(",")))
    files = size.tracked_files(c.root)
    try:
        commit = subprocess.run(["git", "-C", c.root, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
    except Exception:
        commit = ""
    results = {
        "project": c.project, "generated": report.stamp(), "commit": commit, "tool_version": __version__,
        "size": size.analyse(c),
        "history": {} if "history" in skip else history.analyse(c),
        "coverage": {"available": False, "reason": "skipped"} if "coverage" in skip else coverage.analyse(c),
        "dependencies": {"packages": []} if "deps" in skip else deps.analyse(c, files),
        "security": {"entitlements": [], "committed_secrets": []} if "security" in skip else security.analyse(c, files),
    }
    j, m = report.write(results, a.out if a.out.startswith("/") else f"{c.root}/{a.out}")
    t = results["size"]["totals"]
    print(f"{c.project}: {t['code']:,} lines of code, {t['test']:,} of tests · coverage {results['coverage'].get('percent', 'n/a')} % · {j}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
