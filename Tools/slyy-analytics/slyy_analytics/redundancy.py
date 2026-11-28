"""Redundant code: repeated blocks (copy-paste) and declarations nothing refers to.

Repeated blocks: each code line is normalised (whitespace collapsed, string and number literals replaced),
lines that carry no logic (braces, `}`, `else {`, imports, comments) are skipped, and every window of
`min_lines` consecutive significant lines is hashed. Windows seen in more than one place are merged into the
longest runs. Unused declarations: names declared with func/var/let/class/struct/enum/case/typealias whose
name appears nowhere else in the project's code and tests (word match). Both are candidates to read, not
verdicts: reflection, protocol requirements and framework callbacks can use a name without spelling it."""
from __future__ import annotations
import hashlib, re
from collections import defaultdict
from .languages import language_of
from .size import tracked_files

TRIVIAL = re.compile(r"^(\}|\{|\)|\]|\}\)|\})?\s*(else\s*\{|\}\s*else\s*\{|default:|break|return|\)\s*\{|\}\)?)?$")
STRING = re.compile(r'"(?:\\.|[^"\\])*"')
NUMBER = re.compile(r"\b\d+(\.\d+)?\b")

DECL = {
    "Swift": re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:private|fileprivate|internal|public|open|static|class|final|override|mutating|nonisolated|lazy|weak|unowned|convenience|required|indirect|@MainActor)\s+)*(func|var|let|class|struct|enum|actor|protocol|typealias|case)\s+`?([A-Za-z_]\w*)"),
    "Python": re.compile(r"^\s*(def|class)\s+([A-Za-z_]\w*)"),
    "Kotlin": re.compile(r"^\s*(?:\w+\s+)*(fun|val|var|class|object|interface)\s+([A-Za-z_]\w*)"),
    "Rust": re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?(fn|struct|enum|trait|const|static|type)\s+([A-Za-z_]\w*)"),
    "TypeScript": re.compile(r"^\s*(?:export\s+)?(?:async\s+)?(function|class|const|let|interface|type)\s+([A-Za-z_]\w*)"),
    "JavaScript": re.compile(r"^\s*(?:export\s+)?(?:async\s+)?(function|class|const|let)\s+([A-Za-z_]\w*)"),
}
# Names frameworks call without the project spelling them out.
FRAMEWORK_NAMES = {
    "body", "main", "init", "deinit", "description", "debugDescription", "hash", "id", "rawValue", "allCases",
    "makeNSView", "updateNSView", "makeUIView", "updateUIView", "makeCoordinator", "dismantleNSView", "dismantleUIView",
    "encode", "decode", "CodingKeys", "previews", "setUp", "tearDown", "setUpWithError", "tearDownWithError",
    "applicationDidFinishLaunching", "applicationWillTerminate", "applicationShouldTerminate", "scene", "sceneDidBecomeActive",
    "webView", "userContentController", "userNotificationCenter", "updater", "feedURLString", "standardUserDriver",
    "errorDescription", "failureReason", "recoverySuggestion", "localizedDescription", "makeIterator", "next",
    "startIndex", "endIndex", "index", "subscript", "callAsFunction", "reduce", "defaultValue", "_", "self",
}


def _sources(config, kinds=("code",)):
    for rel in tracked_files(config.root):
        if config.excluded(rel):
            continue
        spec = language_of(rel)
        if not spec:
            continue
        m = config.module_of(rel)
        kind = m.get("kind", "code") if m else "other"
        if kind not in kinds:
            continue
        try:
            text = open(f"{config.root}/{rel}", encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        yield rel, spec, text


def _significant(text, lc):
    out = []
    for i, raw in enumerate(text.splitlines(), 1):
        s = raw.strip()
        if not s or (lc and s.startswith(lc)) or s.startswith(("import ", "*", "/*", "#")) or TRIVIAL.match(s):
            continue
        s = NUMBER.sub("0", STRING.sub('""', s))
        out.append((i, re.sub(r"\s+", " ", s)))
    return out


def duplicates(config, min_lines=6):
    files = {}
    index = defaultdict(list)
    for rel, (lang, lc, _), text in _sources(config):
        sig = _significant(text, lc)
        files[rel] = sig
        for k in range(len(sig) - min_lines + 1):
            h = hashlib.sha1("\n".join(s for _, s in sig[k:k + min_lines]).encode()).hexdigest()
            index[h].append((rel, k))
    # mark windows that repeat, then grow runs per pair of places
    repeated = {h: locs for h, locs in index.items() if len(locs) > 1}
    by_first = defaultdict(set)
    for h, locs in repeated.items():
        by_first[locs[0]].add(h)
    seen, groups = set(), []
    for h, locs in sorted(repeated.items(), key=lambda kv: kv[1][0]):
        if (locs[0][0], locs[0][1]) in seen:
            continue
        # extend while the next window repeats in the same set of places with the same offsets
        length = min_lines
        while True:
            nxt = [(r, k + length - min_lines + 1) for r, k in locs]
            if any(k + min_lines > len(files[r]) for r, k in nxt):
                break
            keys = {hashlib.sha1("\n".join(s for _, s in files[r][k:k + min_lines]).encode()).hexdigest() for r, k in nxt}
            if len(keys) != 1:
                break
            for r, k in nxt:
                seen.add((r, k))
            length += 1
        places = []
        for r, k in locs:
            sig = files[r]
            places.append({"path": r, "start": sig[k][0], "end": sig[k + length - 1][0]})
        # drop overlaps of a place with itself (repetitive lines inside one block)
        uniq = []
        for p in places:
            if not any(q["path"] == p["path"] and not (p["end"] < q["start"] or p["start"] > q["end"]) for q in uniq):
                uniq.append(p)
        if len(uniq) > 1:
            groups.append({"lines": length, "places": uniq, "sample": files[locs[0][0]][locs[0][1]][1]})
    groups.sort(key=lambda g: -g["lines"] * (len(g["places"]) - 1))
    dup_lines = sum(g["lines"] * (len(g["places"]) - 1) for g in groups)
    return {"min_lines": min_lines, "groups": groups, "duplicated_lines": dup_lines}


def unused(config):
    decls, corpus = [], []
    for rel, (lang, lc, _), text in _sources(config, kinds=("code", "test")):
        corpus.append(text)
        if config.module_of(rel) and config.module_of(rel).get("kind") == "test":
            continue
        rx = DECL.get(lang)
        if not rx:
            continue
        for i, line in enumerate(text.splitlines(), 1):
            m = rx.match(line)
            if not m:
                continue
            kind, name = m.group(1), m.group(2)
            if name in FRAMEWORK_NAMES or "override" in line or "@objc" in line or "@IBAction" in line or name.startswith("test"):
                continue
            decls.append({"name": name, "kind": kind, "path": rel, "line": i})
    counts = defaultdict(int)
    for text in corpus:
        for w in re.findall(r"[A-Za-z_]\w*", text):
            counts[w] += 1
    # `case` names are also used as `.name`; the word match covers that.
    found = [d for d in decls if counts[d["name"]] <= 1]
    return {"candidates": sorted(found, key=lambda d: (d["path"], d["line"]))}


def analyse(config):
    return {"duplicates": duplicates(config, config.redundancy.get("min_lines", 6)), "unused": unused(config)}
