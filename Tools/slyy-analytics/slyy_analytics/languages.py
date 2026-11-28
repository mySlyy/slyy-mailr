"""File types the analytics know: language name, line-comment and block-comment markers."""
from __future__ import annotations

LANGUAGES = {
    ".swift": ("Swift", "//", ("/*", "*/")),
    ".kt": ("Kotlin", "//", ("/*", "*/")),
    ".rs": ("Rust", "//", ("/*", "*/")),
    ".ts": ("TypeScript", "//", ("/*", "*/")),
    ".tsx": ("TypeScript", "//", ("/*", "*/")),
    ".js": ("JavaScript", "//", ("/*", "*/")),
    ".mjs": ("JavaScript", "//", ("/*", "*/")),
    ".py": ("Python", "#", None),
    ".sh": ("Shell", "#", None),
    ".yml": ("YAML", "#", None),
    ".yaml": ("YAML", "#", None),
    ".html": ("HTML", None, ("<!--", "-->")),
    ".css": ("CSS", None, ("/*", "*/")),
    ".md": ("Markdown", None, None),
    ".json": ("JSON", None, None),
    ".strings": ("Strings", "//", ("/*", "*/")),
    ".conf": ("Config", "#", None),
}

# Languages whose functions are found and measured (brace-based or indentation-based).
FUNCTION_PATTERNS = {
    "Swift": r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|open|static|class|final|override|mutating|nonisolated|async|throws|@MainActor)\s+)*func\s+([A-Za-z_][A-Za-z0-9_]*)",
    "Kotlin": r"^\s*(?:(?:public|private|internal|protected|override|suspend|inline|open)\s+)*fun\s+(?:<[^>]+>\s+)?([A-Za-z_][A-Za-z0-9_]*)",
    "Rust": r"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)",
    "TypeScript": r"^\s*(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)",
    "JavaScript": r"^\s*(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)",
    "Python": r"^(\s*)(?:async\s+)?def\s+([A-Za-z_][A-Za-z0-9_]*)",
}

def language_of(path: str):
    for ext, spec in LANGUAGES.items():
        if path.endswith(ext):
            return spec
    return None
