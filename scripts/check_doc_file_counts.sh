#!/usr/bin/env bash
# The file counts in `docs/MAINTAINERS.md` must match the tree.
#
# Why this exists (2026-09-01). Every count in that document had drifted, most
# by 50% or more: `EmuquTests` documented as 90 files against 162 actual,
# `Assistant/` as 74 against 107, `Views/` as 145 against 193. Nobody noticed
# because nothing checked. An orientation document whose numbers are wrong is
# worse than one with no numbers — a new maintainer uses them to decide where
# the weight of the codebase sits, and these said the wrong thing.
#
# A 15% tolerance, because these are deliberately written as "~N" approximations
# and a gate that fails on every added file would be turned off within a week.
set -euo pipefail

python3 - <<'PY'
import pathlib, re, sys

DOC = pathlib.Path('docs/MAINTAINERS.md')
TOLERANCE = 0.15

# doc label -> directory to count (recursively, *.swift)
DIRS = {
    'Analysis':       'Emuqu/Sources/Analysis',
    'Collection':     'Emuqu/Sources/Collection',
    'Assistant':      'Emuqu/Sources/Assistant',
    'Services':       'Emuqu/Sources/Services',
    'Storage':        'Emuqu/Sources/Storage',
    'Models':         'Emuqu/Sources/Models',
    'Utilities':      'Emuqu/Sources/Utilities',
    'Views':          'Emuqu/Sources/Views',
    'CauseDetection': 'Emuqu/Sources/Analysis/CauseDetection',
}
FLAT = {  # counted non-recursively
    'EmuquTests':   'EmuquTests',
    'EmuquUITests': 'EmuquUITests',
    'ViewModels':   'Emuqu/Sources/ViewModels',
}

def actual(name):
    if name in FLAT:
        p = pathlib.Path(FLAT[name])
        return len(list(p.glob('*.swift'))) if p.is_dir() else 0
    p = pathlib.Path(DIRS[name])
    return len(list(p.rglob('*.swift'))) if p.is_dir() else 0

if not DOC.exists():
    print(f"check_doc_file_counts: {DOC} not found", file=sys.stderr)
    raise SystemExit(2)

text = DOC.read_text()
problems, checked = [], 0
for name in list(DIRS) + list(FLAT):
    # "`Analysis/` — ... (~74 files)" or "EmuquTests | Unit tests (162 files)"
    # `(?<![A-Za-z])` so "Models" does not match inside "ViewModels".
    for m in re.finditer(rf'(?<![A-Za-z]){re.escape(name)}(?![A-Za-z])[^\n(]*\((~?)(\d+) files?\)', text):
        claimed, real = int(m.group(2)), actual(name)
        checked += 1
        if real == 0:
            problems.append(f"{name}: documented as {claimed} but the directory is missing or empty")
        elif abs(claimed - real) > max(1, real * TOLERANCE):
            drift = (claimed - real) / real * 100
            problems.append(f"{name}: documented {claimed}, actual {real} ({drift:+.0f}%)")

if not checked:
    print("check_doc_file_counts: no counts found in MAINTAINERS.md.")
    print("  This gate exists to keep them honest; if they were removed on")
    print("  purpose, remove the gate too rather than leave one guarding nothing.")
    raise SystemExit(1)

if problems:
    print(f"check_doc_file_counts: {len(problems)} stale count(s) in {DOC}.\n")
    for p in problems:
        print(f"  {p}")
    print(f"\n  Tolerance is {TOLERANCE:.0%}. Update the numbers — a new maintainer")
    print("  reads them to decide where the weight of the codebase sits.")
    raise SystemExit(1)

print(f"check_doc_file_counts: clean. {checked} documented count(s) within {TOLERANCE:.0%} of the tree.")
PY
