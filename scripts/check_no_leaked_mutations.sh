#!/usr/bin/env bash
# No mutation from `verify_tests_fail.sh` may be left applied in the tree.
#
# Why this exists. The mutation verifier edits PRODUCTION source,
# runs a suite, and restores from backup in an EXIT trap. A trap does not run
# when the process is killed — a harness timeout, a Ctrl-C at the wrong moment —
# and the mutated file simply stays mutated.
#
# `pnn50_threshold` swaps pNN50's 50 ms threshold for 75 ms; a killed run
# leaves it applied, and it can be committed like that. pNN50 is a standard HRV
# metric with a defined threshold, so every reading taken against that build
# reports a wrong value for it. Nothing else catches it, because the one test
# that would is itself reported as "already red" — which is what a leaked
# mutation looks like from the inside.
#
# This gate reads each mutation case, extracts the ORIGINAL string it replaces,
# and requires that string to still be present in its target file. A leak means
# the original is gone.
set -euo pipefail

python3 - <<'PY'
import pathlib, re, sys

script = pathlib.Path('scripts/verify_tests_fail.sh')
if not script.exists():
    print(f"check_no_leaked_mutations: {script} not found", file=sys.stderr)
    raise SystemExit(2)

text = script.read_text()
# Two shapes are in use: `o='ORIGINAL';assert s.count(o)==1` and an inlined
# `assert s.count('ORIGINAL')==1`. Both always contain `s.count('...')`, so that
# is what is parsed — an `o=`-only parser silently skips the inlined cases, and
# a leak in one of those goes unnoticed by its own guard.
# Split the file on `mutate "name"` and take each case's whole body. A stricter
# regex parses a fraction of the cases and reports "clean" — a gate measuring a
# fraction of what it claims is the failure mode this whole repo exists to
# prevent.
# `'a' + chr(36) + 'b'` -> `a$b`. Only integer literals are resolved; anything
# else falls through to the unparsed list, which is fatal below.
CHR_CONCAT = re.compile(r"'\s*\+\s*chr\((\d+)\)\s*\+\s*'")

parts = re.split(r'\nmutate "', text)[1:]
cases = []
for part in parts:
    name = part.split('"', 1)[0]
    pm = re.search(r'"(Emuqu/[^"]+\.swift)"', part)
    # Two shapes: `o='ORIGINAL';assert s.count(o)` and inlined
    # `assert s.count('ORIGINAL')`. Handling only one of them lets a leak in
    # the other shape slip past.
    om = re.search(r"o='(.*?)';assert", part, re.S) or \
         re.search(r"s\.count\('(.*?)'\)\s*[=><]", part, re.S)
    if pm and om:
        cases.append((name, pm.group(1), om.group(1)))
    else:
        cases.append((name, pm.group(1) if pm else '?', None))

leaked, unparsed = [], []
for name, path, orig in cases:
    if orig is None:
        unparsed.append(name)
        continue
    orig = (orig.replace("\\'", "'").replace('\\"', '"')
                 .replace('\\n', '\n').replace('\\$', '$'))
    # Some cases build their string as `'text' + chr(36) + 'more'` so the shell
    # never sees a bare `$`. Resolving that concatenation is four lines;
    # reporting them as "not literal-comparable" instead leaves
    # `normalized_power_not_fourth_power` — a mutation of the normalized power
    # formula itself — permanently unchecked by the guard whose whole job is
    # noticing an unrestored mutation.
    orig = CHR_CONCAT.sub(lambda m: chr(int(m.group(1))), orig)
    if "chr(" in orig or "' + " in orig:
        unparsed.append(name)
        continue
    p = pathlib.Path(path)
    if not p.exists():
        leaked.append((name, path, "target file missing"))
    elif orig not in p.read_text():
        leaked.append((name, path, "the ORIGINAL code is gone — a mutation is still applied"))

if leaked:
    print(f"check_no_leaked_mutations: {len(leaked)} leaked mutation(s).\n")
    for name, path, why in leaked:
        print(f"  {name}")
        print(f"      {path}")
        print(f"      {why}")
    print("\n  A killed verifier run leaves production source mutated. Restore the")
    print("  original — `git diff` against the last good commit shows it — and")
    print("  re-run ./scripts/verify_tests_fail.sh to confirm the suite is green.")
    raise SystemExit(1)

# A case this parser cannot read is a case it is not checking. Reporting that
# in a note next to the word "clean" is how a gate ends up guarding 27 of 28
# mutations while reading as if it guarded all of them — so it is fatal.
if unparsed:
    print(f"check_no_leaked_mutations: {len(unparsed)} mutation(s) this gate cannot read.\n")
    for name in unparsed:
        print(f"  {name}")
    print("\n  An unreadable case is an unchecked case. Either write the mutation's")
    print("  ORIGINAL as a plain literal, or teach this parser the shape it uses.")
    raise SystemExit(1)

print(f"check_no_leaked_mutations: clean. {len(cases)} mutation(s) verified absent from the tree.")
PY
