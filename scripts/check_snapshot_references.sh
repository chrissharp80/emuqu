#!/usr/bin/env bash
# Every `assertSnapshot(named:)` call must have a committed reference, and
# every committed reference must have a caller.
#
# Why this exists. The snapshot harness writes a reference when
# one is missing, so a deleted or never-committed reference does not fail — the
# next run silently records whatever the view does now and passes against it
# forever. That is the worst shape a gate can take: a check that reports
# success while measuring nothing.
#
# The harness fails the recording run itself, but only the run that records.
# On a fresh clone, or after someone deletes a reference to "fix" a failure,
# CI would record and go green. This closes that.
#
# SCOPE: this gate checks that assertions and reference files PAIR UP. It does
# NOT validate reference contents — a corrupted or hand-edited reference passes
# here and is caught by the snapshot test itself, which compares pixels. Both
# are needed: the test cannot notice a reference that was never committed,
# and this cannot notice one whose bytes are wrong.
set -euo pipefail

TESTS="EmuquTests"
SNAPS="EmuquTests/__Snapshots__"

if [ ! -d "$TESTS" ]; then
    echo "check_snapshot_references: $TESTS not found — run from the repo root." >&2
    exit 2
fi

python3 - "$TESTS" "$SNAPS" <<'PY'
import pathlib, re, sys

tests_dir, snaps_dir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

def call_spans(text):
    """Yield the argument text of each assertSnapshot( ... ) call.

    Paren-matched rather than regex-scanned: arguments routinely contain their
    own calls — `of: makeStats().hrChartCard(samples: makeSamples())` — and a
    naive `[^)]*` stops at the first inner `)` and misses the name entirely.
    """
    needle = "assertSnapshot("
    i = text.find(needle)
    while i != -1:
        j = i + len(needle)
        depth, start = 1, j
        while j < len(text) and depth:
            if text[j] == "(":
                depth += 1
            elif text[j] == ")":
                depth -= 1
            j += 1
        yield text[start:j - 1]
        i = text.find(needle, j)

called = {}
for f in tests_dir.rglob("*.swift"):
    for args in call_spans(f.read_text()):
        m = re.search(r'named:\s*"([^"]+)"', args)
        if m:
            called[m.group(1)] = f.name

stored = {p.stem for p in snaps_dir.glob("*.raw")} if snaps_dir.is_dir() else set()

missing = sorted(set(called) - stored)
orphan = sorted(stored - set(called))

if missing or orphan:
    print(f"check_snapshot_references: {len(missing) + len(orphan)} problem(s).\n")
    for name in missing:
        print(f"  no committed reference: '{name}' (asserted in {called[name]})")
        print("      The harness would record one on the next run and pass against")
        print("      itself. Record it with SNAPSHOT_RECORD=1 and commit it.")
    for name in orphan:
        print(f"  reference with no caller: '{name}.raw' — delete it")
    sys.exit(1)

if not called:
    print("check_snapshot_references: no snapshot assertions found.")
    print("  This gate exists to protect them; if the suite was removed, remove")
    print("  the gate too rather than leaving one that guards nothing.")
    sys.exit(1)

print(f"check_snapshot_references: clean. {len(called)} assertion(s), "
      f"{len(stored)} reference(s), all matched.")
PY
