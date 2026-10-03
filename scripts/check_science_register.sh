#!/usr/bin/env bash
#
# CI guard: every operative heuristic is classified by validation status.
#
# Why this exists. The copy linter is a
# LEXICAL gate: it matches phrasings. One review demonstrated the limit of that
# directly — the perimeter banned "strong predictor" and "early-warning
# system", and production shipped "strongly suggests", "strong indicator" and
# "likely getting sick". The vocabulary was blocked; the CLAIM walked around it.
#
# The audit asked instead for "a structured claim inventory linking each
# user-facing interpretation to its evidence level, allowed language, affected
# outputs, and tests". That is Tools/science_register/register.json. This
# script is what stops it becoming decoration:
#
#   * every entry carries a status from the documented set, and non-empty
#     evidence, affects and allowed_language fields
#   * the entry count is a floor that only ratchets up, so a classified
#     heuristic cannot quietly drop out of the register; a new score-adjusting
#     function is caught by the discovery scan below, not by the count
#   * every `tests` path exists, so an entry cannot cite coverage that is gone
#   * the register's scoring_version matches ScoringVersion.current, so a score
#     algorithm change forces a re-read of what is in it
#
# Second pass, after review pushed back on the word "every":
#
#   "'Ten are awaiting validation' is machine-checked. 'Every operative
#    heuristic is classified' is only true if the gate can independently
#    discover heuristics."
#
# Correct. A purely declarative registry proves the declarations are well
# formed, not that the list is complete. So this gate now also DISCOVERS: it
# scans the analysis layer for score-adjusting functions — names ending
# Adjustment / Penalty / Bonus / Modifier / Damper / Fraction — and requires
# each to be claimed by a register entry`s `symbols` list or waived by name
# with a reason. Adding a new scoring adjustment therefore fails the build
# until somebody classifies it.
#
# That is discovery over a known SHAPE, not over the concept. A heuristic
# expressed some other way stays invisible, and no gate can judge whether a
# status is honest. This is governance over a failure class, not proof that
# nothing was omitted.
#
# Exit 0 clean, 1 on a violation, 2 on config error.

set -uo pipefail
cd "$(dirname "$0")/.."

REGISTER="Tools/science_register/register.json"
BUDGET_FILE=".ci/min_science_register_entries.txt"
VERSION_SRC="Emuqu/Sources/Analysis/ScoringVersion.swift"

for required in "$REGISTER" "$BUDGET_FILE" "$VERSION_SRC"; do
    if [[ ! -f "$required" ]]; then
        echo "check_science_register: missing $required" >&2
        exit 2
    fi
done

python3 - "$REGISTER" "$BUDGET_FILE" "$VERSION_SRC" <<'PY'
import json
import pathlib
import re
import sys

register_path, budget_path, version_path = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    register = json.loads(pathlib.Path(register_path).read_text(encoding="utf-8"))
except Exception as exc:
    sys.stderr.write(f"check_science_register: cannot parse {register_path}: {exc}\n")
    sys.exit(2)

VALID = set(register.get("_status_meanings", {}))
if not VALID:
    sys.stderr.write("check_science_register: _status_meanings is empty\n")
    sys.exit(2)

entries = register.get("entries", [])
problems = []
seen = set()

for entry in entries:
    ident = entry.get("id", "<missing id>")
    if ident in seen:
        problems.append(f"{ident}: duplicate id")
    seen.add(ident)

    status = entry.get("status")
    if status not in VALID:
        problems.append(f"{ident}: status {status!r} is not one of {sorted(VALID)}")

    for field in ("affects", "evidence", "allowed_language"):
        value = entry.get(field)
        if not value:
            problems.append(f"{ident}: {field} is empty")

    for test_path in entry.get("tests", []):
        if not pathlib.Path(test_path).exists():
            problems.append(f"{ident}: cited test does not exist: {test_path}")

# The register must describe the version this build actually computes.
source = pathlib.Path(version_path).read_text(encoding="utf-8")
match = re.search(r'static let current\s*=\s*"([^"]+)"', source)
if not match:
    sys.stderr.write("check_science_register: cannot read ScoringVersion.current\n")
    sys.exit(2)
if register.get("scoring_version") != match.group(1):
    problems.append(
        f"register scoring_version {register.get('scoring_version')!r} "
        f"!= ScoringVersion.current {match.group(1)!r}"
    )

# --- Retracted claims must not reappear. ------------------------------------
# A wrong figure that was corrected in one place tends to survive in another
# (it did: the analyzer header dropped an ICC range that the register kept).
retracted = register.get("_retracted_claims", {}).get("claims", [])
if retracted:
    def scan(label, text):
        for claim in retracted:
            if claim in text:
                problems.append(f"{label}: states retracted claim {claim!r}")
    for entry in entries:
        for field in ("evidence", "affects", "allowed_language", "notes"):
            value = entry.get(field)
            if isinstance(value, str):
                scan(f"{entry.get('id', '<missing id>')}.{field}", value)
            elif isinstance(value, list):
                scan(f"{entry.get('id', '<missing id>')}.{field}", " ".join(map(str, value)))
    roots = [pathlib.Path("Emuqu/Sources"), pathlib.Path("docs")]
    for root in roots:
        for path in sorted(root.rglob("*")):
            if path.suffix not in (".swift", ".md") or not path.is_file():
                continue
            scan(str(path), path.read_text(encoding="utf-8", errors="ignore"))

# --- Discovery: score-adjusting functions must be claimed or waived. --------
SYMBOL_RE = re.compile(
    r"func\s+([a-zA-Z]+(?:Adjustment|Penalty|Bonus|Modifier|Damper|Fraction))\b"
)
SKIP = ("CauseDetection/",)  # ordering keys, not score inputs
discovered = set()
for path in sorted(pathlib.Path("Emuqu/Sources/Analysis").rglob("*.swift")):
    rel = str(path)
    if any(part in rel for part in SKIP):
        continue
    text = path.read_text(encoding="utf-8", errors="ignore")
    for name in SYMBOL_RE.findall(text):
        if name.endswith(("Descriptions", "Message")):
            continue
        discovered.add(name)

claimed = {sym for entry in entries for sym in entry.get("symbols", [])}
waived = {k for k in register.get("_waived_symbols", {}) if not k.startswith("_")}
unclassified = sorted(discovered - claimed - waived)
for name in unclassified:
    problems.append(
        f"{name}: a score-adjusting function no register entry claims. "
        "Add it to an entry's `symbols`, or waive it in `_waived_symbols` with a reason."
    )

stale = sorted((claimed | waived) - discovered)
for name in stale:
    problems.append(f"{name}: claimed or waived but no longer exists in the analysis layer")

budget = int(pathlib.Path(budget_path).read_text(encoding="utf-8").strip())
count = len(entries)

for problem in problems:
    print(f"  {problem}", file=sys.stderr)

from collections import Counter
tally = Counter(e.get("status") for e in entries)
print(f"check_science_register: {count} classified heuristics "
      + ", ".join(f"{k} {v}" for k, v in sorted(tally.items()))
      + f"; {len(discovered)} score-adjusting functions discovered, "
      + f"{len(claimed & discovered)} claimed, {len(waived & discovered)} waived")

if problems:
    print(f"check_science_register: {len(problems)} problem(s).", file=sys.stderr)
    sys.exit(1)

if count < budget:
    print(f"\ncheck_science_register: {count} entries is below the floor of {budget}.", file=sys.stderr)
    print("A classified heuristic was removed. If the heuristic is gone from the code,", file=sys.stderr)
    print("lower the floor with a budget-raise-ok trailer; if it is still in the code,", file=sys.stderr)
    print("it must stay classified.", file=sys.stderr)
    sys.exit(1)

if count > budget:
    print(f"check_science_register: above the floor — raise {budget_path} to {count} to lock it in.")

print("check_science_register: clean.")
PY
