"""Size and structure: lines of code per module and language, largest files, longest functions."""
from __future__ import annotations
import re, subprocess
from collections import defaultdict
from .languages import language_of, FUNCTION_PATTERNS


def tracked_files(root: str) -> list[str]:
    """Files under version control (falls back to a walk outside git)."""
    try:
        out = subprocess.run(["git", "-C", root, "ls-files"], capture_output=True, text=True, check=True).stdout
        return [l for l in out.splitlines() if l]
    except Exception:
        import os
        found = []
        for d, _, files in os.walk(root):
            for f in files:
                found.append(os.path.relpath(os.path.join(d, f), root))
        return found


def count_lines(text: str, line_comment, block) -> tuple[int, int, int]:
    """(code, comment, blank) lines. A line with code and a trailing comment counts as code."""
    code = comment = blank = 0
    in_block = False
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            blank += 1
            continue
        if in_block:
            comment += 1
            if block and block[1] in line:
                in_block = False
            continue
        if block and line.startswith(block[0]):
            comment += 1
            if block[1] not in line[len(block[0]):]:
                in_block = True
            continue
        if line_comment and line.startswith(line_comment):
            comment += 1
            continue
        code += 1
    return code, comment, blank


def functions(text: str, language: str) -> list[dict]:
    """Functions with their first line and length (brace matching; indentation for Python)."""
    pattern = FUNCTION_PATTERNS.get(language)
    if not pattern:
        return []
    rx = re.compile(pattern)
    lines = text.splitlines()
    found = []
    if language == "Python":
        for i, l in enumerate(lines):
            m = rx.match(l)
            if not m:
                continue
            indent = len(m.group(1))
            end = i + 1
            while end < len(lines) and (not lines[end].strip() or len(lines[end]) - len(lines[end].lstrip()) > indent):
                end += 1
            found.append({"name": m.group(2), "line": i + 1, "length": end - i})
        return found
    for i, l in enumerate(lines):
        m = rx.match(l)
        if not m:
            continue
        depth, started, end = 0, False, None
        for j in range(i, min(len(lines), i + 2000)):
            s = re.sub(r'"(?:\\.|[^"\\])*"', '""', lines[j])  # ignore braces in strings
            s = s.split("//")[0]
            for ch in s:
                if ch == "{":
                    depth += 1
                    started = True
                elif ch == "}":
                    depth -= 1
            if started and depth <= 0:
                end = j
                break
            if not started and j > i + 5:
                break  # a declaration without a body (protocol requirement)
        if end is not None:
            found.append({"name": m.group(1), "line": i + 1, "length": end - i + 1})
    return found


def analyse(config) -> dict:
    per_module = defaultdict(lambda: {"files": 0, "code": 0, "comment": 0, "blank": 0, "languages": defaultdict(int)})
    files, funcs = [], []
    for rel in tracked_files(config.root):
        if config.excluded(rel):
            continue
        spec = language_of(rel)
        if not spec:
            continue
        name, lc, block = spec
        try:
            with open(f"{config.root}/{rel}", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        code, comment, blank = count_lines(text, lc, block)
        module = config.module_of(rel)
        mname = module["name"] if module else "Other"
        kind = module.get("kind", "code") if module else "other"
        m = per_module[mname]
        m["kind"] = kind
        m["files"] += 1
        m["code"] += code
        m["comment"] += comment
        m["blank"] += blank
        m["languages"][name] += code
        files.append({"path": rel, "module": mname, "kind": kind, "language": name, "code": code, "comment": comment, "blank": blank})
        if kind in ("code", "test"):
            for f in functions(text, name):
                funcs.append({**f, "path": rel, "module": mname, "kind": kind})

    modules = [{"name": k, **{kk: (dict(vv) if kk == "languages" else vv) for kk, vv in v.items()}} for k, v in per_module.items()]
    modules.sort(key=lambda m: -m["code"])
    code_lines = sum(m["code"] for m in modules if m.get("kind") == "code")
    test_lines = sum(m["code"] for m in modules if m.get("kind") == "test")
    by_language = defaultdict(int)
    for f in files:
        if f["kind"] in ("code", "test"):
            by_language[f["language"]] += f["code"]
    t = config.thresholds
    prod_funcs = [f for f in funcs if f["kind"] == "code"]
    lengths = sorted(f["length"] for f in prod_funcs)
    return {
        "modules": modules,
        "totals": {
            "code": code_lines, "test": test_lines,
            "test_ratio": round(test_lines / code_lines, 2) if code_lines else None,
            "files": sum(1 for f in files if f["kind"] in ("code", "test")),
            "comment_ratio": round(sum(f["comment"] for f in files if f["kind"] == "code") / code_lines, 3) if code_lines else None,
            "functions": len(prod_funcs),
            "median_function_length": lengths[len(lengths) // 2] if lengths else None,
        },
        "by_language": dict(sorted(by_language.items(), key=lambda kv: -kv[1])),
        "largest_files": sorted([f for f in files if f["kind"] in ("code", "test")], key=lambda f: -f["code"])[:15],
        "longest_functions": sorted(prod_funcs, key=lambda f: -f["length"])[:20],
        "flags": {
            "large_files": [f["path"] for f in files if f["kind"] == "code" and f["code"] > t["large_file"]],
            "long_functions": [f"{f['path']}:{f['line']} {f['name']} ({f['length']} lines)" for f in prod_funcs if f["length"] > t["long_function"]],
        },
    }
