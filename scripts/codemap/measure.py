"""How much of what real commits had to change together `impact` would have named beforehand.

Usage: measure.py [MAX_UNITS]   (commits changing 2..MAX_UNITS mapped units are used; default 25)

For every non-merge commit in the history, the units whose code it changed (each changed file
parsed before and after) are the ground truth. For each changed unit, the other changed units are
looked up in `impact` of the commit's other changed code units, from other files:

  * code: the unit is a certain caller (any distance), shares a store, or has alike code;
  * tests: a test method of the same suite (class) reaches a changed unit through certain callers.

Commits that bundle unrelated fixes count against the score, so it is a floor, not an exact miss
rate. Per-commit changes are cached in build/codemap-history.json by commit id.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / "build/codemap-history.json"
sys.path.insert(0, str(Path(__file__).resolve().parent))
import inventory as invmod  # noqa: E402


def _git(*a: str) -> bytes:
    return subprocess.run(["git", "-C", str(ROOT), *a], capture_output=True).stdout


def _units(path: str, raw: bytes, parser) -> dict[str, str]:
    lines = raw.decode(errors="replace").split("\n")
    us = invmod._swift_units(path, raw, parser) if path.endswith(".swift") else invmod._ns_units(path, lines)
    return {u["key"]: u["hash"] for u in invmod._finish(path, lines, us)["units"]}


def history() -> list[tuple[str, list[str]]]:
    """(commit, changed unit nodes) for every non-merge commit, newest first."""
    import tree_sitter as ts
    import tree_sitter_swift as tss
    parser = ts.Parser(ts.Language(tss.language()))
    cache = json.loads(CACHE.read_text()) if CACHE.exists() else {}
    out = []
    for c in _git("rev-list", "--no-merges", "HEAD").decode().split():
        if c not in cache:
            changed = set()
            names = _git("diff-tree", "--no-commit-id", "-r", "--name-only", "--root", c).decode().split("\n")
            for f in names:
                if not f or not (f.endswith(".swift") or invmod.NS_CODE.search(f)):
                    continue
                old, new = _git("show", f"{c}^:{f}"), _git("show", f"{c}:{f}")
                try:
                    a = _units(f, old, parser) if old else {}
                    b = _units(f, new, parser) if new else {}
                except Exception:  # a version tree-sitter cannot parse is left out
                    continue
                changed |= {f"{f}::{k}" for k, h in b.items() if a.get(k) != h}
            cache[c] = sorted(changed)
        out.append((c, cache[c]))
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    CACHE.write_text(json.dumps(cache))
    return out


def main(argv: list[str]) -> int:
    import codemap as cm
    import graph as graphmod
    import similar
    most = int(argv[0]) if argv else 25
    data = history()
    recs = cm.all_records()
    inv = invmod.inventory(ROOT)
    g = graphmod.build(inv, recs, ROOT)
    callers = graphmod.callers(g)
    units = g["units"]
    index = similar.Index(similar.unit_texts(inv, ROOT))
    users = cm.store_users_of(recs)
    is_test = lambda n: n.startswith(cm.TEST_ROOTS)
    suite = lambda n: (n.split("::")[0], (units.get(n) or {}).get("type", "").split(".")[0])

    reach = {}

    def impact(n):
        if n not in reach:
            dist, _, tests, _ = cm.walk_callers(callers, recs, n)
            code = set(dist) - {n}
            for _, _, others in cm.state_partners(users, cm.record_of(recs, n), n):
                code |= others
            code |= {o for o, _ in index.similar(n)}
            reach[n] = (code, {suite(t) for t in tests})
        return reach[n]

    found = {"code": [0, 0], "tests": [0, 0]}
    used = 0
    for _, changed in data:
        ch = [n for n in changed if n in units]
        if not 2 <= len(ch) <= most:
            continue
        used += 1
        seeds = [n for n in ch if not is_test(n)]
        for t in ch:
            others = [s for s in seeds if s.split("::")[0] != t.split("::")[0]]
            if not others:
                continue
            kind = "tests" if is_test(t) else "code"
            hit = any((suite(t) in impact(s)[1]) if kind == "tests" else (t in impact(s)[0]) for s in others)
            found[kind][0] += hit
            found[kind][1] += 1
    print(f"{used} commits changing 2-{most} mapped units")
    for kind, (h, n) in found.items():
        print(f"  {kind}: {h} of {n} co-changed units named ({h / max(n, 1):.0%})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
