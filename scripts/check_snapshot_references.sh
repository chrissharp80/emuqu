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
# `assertRenders` calls compare against no reference and write none, so they
# are not counted here: only `assertSnapshot` needs a committed reference.
#
# It also fails when two or more references are byte-identical. Different
# views, states or fixtures render differently; identical bytes mean the
# renderer drew something other than the view (a flat colour, or the yellow
# placeholder with a red prohibition sign that `ImageRenderer` draws for
# UIKit-backed content), and every test holding that reference passes against
# it whatever its view does. A pair that is identical on purpose goes in
# IDENTICAL_ALLOWED below with the reason.
#
# SCOPE: beyond pairing and identical bytes, this gate does NOT validate
# reference contents: a corrupted or hand-edited reference passes here and is
# caught by the snapshot test itself, which compares pixels and refuses a
# reference that is the placeholder. Both are needed: the test cannot notice a
# reference that was never committed, and this cannot judge pixels.
set -euo pipefail

TESTS="EmuquTests"
SNAPS="EmuquTests/__Snapshots__"

if [ ! -d "$TESTS" ]; then
    echo "check_snapshot_references: $TESTS not found — run from the repo root." >&2
    exit 2
fi

python3 - "$TESTS" "$SNAPS" <<'PY'
import hashlib, pathlib, re, sys

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

def code_only(text):
    """Comments removed: a commented-out call is not a caller."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(re.sub(r'^((?:[^"/\n]|"(?:[^"\\\n]|\\.)*"|/(?!/))*)//.*$', r"\1", line)
                     for line in text.split("\n"))

called, unnamed = {}, []
for f in tests_dir.rglob("*.swift"):
    # The harness's own `func assertSnapshot(` is a declaration, not a call.
    code = re.sub(r"\bfunc\s+assertSnapshot\s*\(", "func declaredSnapshot(", code_only(f.read_text()))
    for args in call_spans(code):
        m = re.search(r'named:\s*"([^"\\]+)"\s*(?:[,)]|$)', args)
        if m:
            called[m.group(1)] = f.name
        else:
            # A name this gate cannot read (a variable, an interpolation) is a
            # reference it cannot pair: missing or not, it would pass.
            unnamed.append(f"{f.name}: assertSnapshot({args.strip()[:60]}...)")
if unnamed:
    print("check_snapshot_references: assertSnapshot calls without a literal name:\n")
    for call in unnamed:
        print(f"  {call}")
    print("\n  Pass `named:` a string literal so the reference can be paired.")
    sys.exit(1)

stored = {p.stem for p in snaps_dir.glob("*.raw")} if snaps_dir.is_dir() else set()

# References allowed to share their bytes with another reference, by name,
# with the reason.
IDENTICAL_ALLOWED = {
    "screen-morning-results-no-history": (
        "MorningResultsView hands the prior nights to the report export and "
        "draws nothing from them, so a first morning draws the same screen as "
        "screen-morning-results; the test pins that it renders at all"
    ),
}

by_bytes = {}
if snaps_dir.is_dir():
    for p in sorted(snaps_dir.glob("*.raw")):
        by_bytes.setdefault(hashlib.sha256(p.read_bytes()).hexdigest(), []).append(p.stem)
identical = [names for names in by_bytes.values()
             if len([n for n in names if n not in IDENTICAL_ALLOWED]) > 1]

missing = sorted(set(called) - stored)
orphan = sorted(stored - set(called))

if missing or orphan or identical:
    print(f"check_snapshot_references: {len(missing) + len(orphan) + len(identical)} problem(s).\n")
    for name in missing:
        print(f"  no committed reference: '{name}' (asserted in {called[name]})")
        print("      The harness would record one on the next run and pass against")
        print("      itself. Record it with SNAPSHOT_RECORD=1 and commit it.")
    for name in orphan:
        print(f"  reference with no caller: '{name}.raw' — delete it")
    for names in identical:
        print(f"  {len(names)} byte-identical references: {', '.join(names[:6])}"
              + (f" and {len(names) - 6} more" if len(names) > 6 else ""))
        print("      Different views do not render the same bytes: the renderer drew")
        print("      something other than the view. Re-record them and look at each one,")
        print("      or list a deliberate pair in IDENTICAL_ALLOWED with the reason.")
    sys.exit(1)

if not called:
    print("check_snapshot_references: no snapshot assertions found.")
    print("  This gate exists to protect them; if the suite was removed, remove")
    print("  the gate too rather than leaving one that guards nothing.")
    sys.exit(1)

print(f"check_snapshot_references: clean. {len(called)} assertion(s), "
      f"{len(stored)} reference(s), all matched and all distinct.")
PY
