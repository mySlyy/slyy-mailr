"""Reads a repository's analytics.json."""
from __future__ import annotations
import fnmatch, json, os

DEFAULT_EXCLUDE = [".git/*", "*/.build/*", "build/*", "*/build/*", "node_modules/*", "*/node_modules/*", "*.xcodeproj/*", "DerivedData/*"]

class Config:
    def __init__(self, data: dict, root: str):
        self.root = os.path.abspath(root)
        self.project = data.get("project", os.path.basename(self.root))
        # modules: [{"name", "paths": [...], "kind": "code" | "test" | "tooling" | "docs"}]
        self.modules = data.get("modules", [])
        self.exclude = DEFAULT_EXCLUDE + data.get("exclude", [])
        self.coverage = data.get("coverage", {})
        self.security = data.get("security", {})
        self.dependencies = data.get("dependencies", {})
        self.thresholds = {"long_function": 60, "large_file": 500, **data.get("thresholds", {})}
        self.history = data.get("history", {"tags": "v*"})

    @classmethod
    def load(cls, path: str, root: str | None = None) -> "Config":
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return cls(data, root or os.path.dirname(os.path.abspath(path)))

    def excluded(self, rel: str) -> bool:
        return any(fnmatch.fnmatch(rel, pat) for pat in self.exclude)

    def module_of(self, rel: str):
        """The first module whose path prefix matches (longest prefix wins)."""
        best, best_len = None, -1
        for m in self.modules:
            for p in m.get("paths", []):
                p = p.rstrip("/")
                if (rel == p or rel.startswith(p + "/")) and len(p) > best_len:
                    best, best_len = m, len(p)
        return best
