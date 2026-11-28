"""Test coverage from llvm-cov (`llvm-cov export` JSON, as written by `swift test --enable-code-coverage`) or lcov."""
from __future__ import annotations
import json, os
from collections import defaultdict


def _rel(config, path: str) -> str:
    p = os.path.abspath(path)
    return os.path.relpath(p, config.root) if p.startswith(config.root) else path


def read_llvm_json(path: str) -> dict:
    """{file: (covered_lines, total_lines)} from an llvm-cov export."""
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    out = {}
    for d in data.get("data", []):
        for fi in d.get("files", []):
            lines = fi.get("summary", {}).get("lines", {})
            out[fi["filename"]] = (lines.get("covered", 0), lines.get("count", 0))
    return out


def read_lcov(path: str) -> dict:
    out, current, hit, total = {}, None, 0, 0
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line.startswith("SF:"):
                current, hit, total = line[3:], 0, 0
            elif line.startswith("DA:"):
                total += 1
                if int(line.split(",")[1]) > 0:
                    hit += 1
            elif line == "end_of_record" and current:
                out[current] = (hit, total)
    return out


def analyse(config) -> dict:
    src = config.coverage.get("file")
    if not src:
        return {"available": False, "reason": "no coverage file configured"}
    path = os.path.join(config.root, src)
    if not os.path.exists(path):
        return {"available": False, "reason": f"{src} not found (run the tests with coverage first)"}
    files = read_lcov(path) if src.endswith(".info") else read_llvm_json(path)
    per_module = defaultdict(lambda: [0, 0])
    rows = []
    for name, (hit, total) in files.items():
        rel = _rel(config, name)
        if config.excluded(rel) or total == 0:
            continue
        module = config.module_of(rel)
        if not module or module.get("kind") != "code":
            continue  # only production code counts
        per_module[module["name"]][0] += hit
        per_module[module["name"]][1] += total
        rows.append({"path": rel, "module": module["name"], "covered": hit, "lines": total, "percent": round(100 * hit / total, 1)})
    hit = sum(v[0] for v in per_module.values())
    total = sum(v[1] for v in per_module.values())
    return {
        "available": True,
        "source": src,
        "note": config.coverage.get("note", ""),
        "percent": round(100 * hit / total, 1) if total else None,
        "covered": hit, "lines": total,
        "modules": [{"name": k, "covered": v[0], "lines": v[1], "percent": round(100 * v[0] / v[1], 1)} for k, v in sorted(per_module.items())],
        "least_covered": sorted([r for r in rows if r["lines"] >= 20], key=lambda r: r["percent"])[:12],
    }
