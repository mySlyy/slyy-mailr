"""History: size per release tag and commit activity per week (from git)."""
from __future__ import annotations
import subprocess
from collections import defaultdict
from datetime import datetime, timezone
from .languages import language_of
from .size import count_lines


def git(root: str, *args: str) -> str:
    return subprocess.run(["git", "-C", root, *args], capture_output=True, text=True, check=True).stdout


def size_at(config, ref: str) -> dict:
    """Code lines per module kind (code/test) at a commit or tag, without checking it out."""
    paths = [p for p in git(config.root, "ls-tree", "-r", "--name-only", ref).splitlines()
             if not config.excluded(p) and language_of(p)]
    proc = subprocess.Popen(["git", "-C", config.root, "cat-file", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    totals = defaultdict(int)
    for p in paths:
        proc.stdin.write(f"{ref}:{p}\n".encode())
        proc.stdin.flush()
        header = proc.stdout.readline().split()
        if len(header) < 3 or header[1] != b"blob":
            continue
        data = proc.stdout.read(int(header[2]))
        proc.stdout.read(1)
        _, lc, block = language_of(p)
        code, _, _ = count_lines(data.decode("utf-8", "replace"), lc, block)
        module = config.module_of(p)
        totals[module.get("kind", "code") if module else "other"] += code
    proc.stdin.close()
    proc.wait()
    return dict(totals)


def analyse(config) -> dict:
    pattern = config.history.get("tags", "v*")
    try:
        tags = [t for t in git(config.root, "tag", "--list", pattern, "--sort=creatordate").splitlines() if t]
    except Exception:
        return {"releases": [], "weeks": [], "commits": 0}
    releases = []
    for t in tags:
        date = git(config.root, "log", "-1", "--format=%cI", t).strip()
        s = size_at(config, t)
        releases.append({"tag": t, "date": date, "code": s.get("code", 0), "test": s.get("test", 0)})
    weeks = defaultdict(lambda: {"commits": 0, "added": 0, "removed": 0})
    log = git(config.root, "log", "--numstat", "--format=@%cI", "--no-merges")
    current = None
    commits = 0
    for line in log.splitlines():
        if line.startswith("@"):
            d = datetime.fromisoformat(line[1:]).astimezone(timezone.utc)
            current = f"{d.isocalendar()[0]}-W{d.isocalendar()[1]:02d}"
            weeks[current]["commits"] += 1
            commits += 1
        elif line and current:
            parts = line.split("\t")
            if len(parts) == 3 and parts[0].isdigit() and not config.excluded(parts[2]) and language_of(parts[2]):
                weeks[current]["added"] += int(parts[0])
                weeks[current]["removed"] += int(parts[1])
    return {"releases": releases, "weeks": [{"week": k, **v} for k, v in sorted(weeks.items())], "commits": commits}
