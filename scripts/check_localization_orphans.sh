#!/usr/bin/env bash
#
# CI guard: the catalogue -> code direction. A key nothing requests is a
# translation paid for in sixteen locales and shown to nobody.
#
# Why this exists. Three gates measure localization, and all three can report
# perfect scores at once:
#
#   * check_localization_coverage.sh   catalogue -> locale   100.00% x 16
#   * check_localization_bundle.sh     lookup -> bundle      all qualified
#   * check_localization_resolution.sh code -> catalogue     every literal resolves
#
# None of them measures catalogue -> code. That is the direction an orphan runs
# in: edit a localized literal and the OLD key stays behind, fully translated,
# requested by nothing. `check_localization_resolution.sh`'s own header
# describes exactly this — "translate the new key and delete the orphan it
# replaced" — and nothing else checks whether anyone deletes it.
#
# This is the inverse of that script and shares its extractor and its
# normalisation, including the permissive specifier match: both import
# `scripts/lib/localization_extract.py`. A hand-rolled
# extractor that only normalises `%@` reports hundreds of orphans, most of them
# `%lld` / `%d` forms that DO resolve. Getting this wrong in the loud direction
# is how a gate stops being believed, so it reuses the machinery that is
# already trusted.
#
# Keys marked `"shouldTranslate": false` are format/punctuation shells and are
# excluded, same as the coverage gate.
#
# Budget in `.ci/localization_orphan_budget.txt`, ratcheting DOWN.
#
# The extractor must look past a literal sitting immediately after the call
# paren. One that stops there cannot see `Text(cond ? a : b)` or a Swift Charts
# `.value(label, x)`, so dozens of live, shipping strings count as orphans —
# both halves of the sleep-editor delta badge, the sleep-target picker option,
# every chart axis label (AT1, RR_n+1, alpha1, Upper, Mean). A gate whose
# failures are one third false positives is a gate people learn to wave
# through. See `first_argument_literals` and `skip_literal_at` in the shared
# extractor.
#
# Exit 0 clean, 1 over budget, 2 on config error.

set -uo pipefail
cd "$(dirname "$0")/.."

SCAN_DIR="${1:-Emuqu/Sources}"
CATALOGUE="${2:-Emuqu/Localizable.xcstrings}"
BUDGET_FILE="${LOCALIZATION_ORPHAN_BUDGET_FILE:-.ci/localization_orphan_budget.txt}"

for required in "$CATALOGUE" "$BUDGET_FILE"; do
    if [[ ! -f "$required" ]]; then
        echo "check_localization_orphans: missing $required" >&2
        exit 2
    fi
done
budget="$(tr -d '[:space:]' < "$BUDGET_FILE")"
if [[ ! "$budget" =~ ^[0-9]+$ ]]; then
    echo "check_localization_orphans: budget file is not an integer: $BUDGET_FILE" >&2
    exit 2
fi

# `|| exit 2`: a crash in the measurement (an unparsable catalogue, say) leaves
# `count` empty, and `(( count > budget ))` reads empty as 0 and reports clean.
count="$(python3 - "$SCAN_DIR" "$CATALOGUE" <<'PY'
import json
import pathlib
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, "scripts/lib")
from localization_extract import candidate_keys, key_pattern, localized_literals

scan_dir, catalogue_path = sys.argv[1], sys.argv[2]
catalogue = json.loads(pathlib.Path(catalogue_path).read_text(encoding="utf-8"))
strings = catalogue.get("strings", {})

requested = set()
patterns = []
roots = [pathlib.Path(scan_dir), pathlib.Path("EmuquWatch Watch App"), pathlib.Path("Emuqu/EmuquApp.swift")]
for root in roots:
    if not root.exists():
        sys.stderr.write(f"check_localization_orphans: scan root missing: {root}\n")
        sys.exit(2)
    files = [root] if root.is_file() else sorted(root.rglob("*.swift"))
    for path in files:
        text = path.read_text(encoding="utf-8", errors="ignore")
        for _line, body in localized_literals(text):
            for candidate in candidate_keys(body):
                requested.add(candidate)
                if "%@" in candidate:
                    patterns.append(key_pattern(candidate))

orphans = []
for key, entry in strings.items():
    if entry.get("shouldTranslate") is False:
        continue
    if key in requested:
        continue
    if any(rx.match(key) for rx in patterns):
        continue
    orphans.append(key)

for key in sorted(orphans)[:15]:
    sys.stderr.write(f"    {key[:110]!r}\n")
print(len(orphans))
PY
)" || { echo "check_localization_orphans: the measurement failed; nothing was counted." >&2; exit 2; }
if [[ ! "$count" =~ ^[0-9]+$ ]]; then
    echo "check_localization_orphans: the measurement printed no count: '${count}'" >&2
    exit 2
fi

echo "Catalogue keys no code literal requests: ${count} (budget: ${budget}; ratchet toward 0)"

if (( count > budget )); then
    echo >&2
    echo "ERROR: orphaned catalogue keys exceeded budget (${count} > ${budget})." >&2
    echo "Each one is a phrase translated into 16 locales that no screen can show." >&2
    echo "Delete the key, or point a literal at it." >&2
    exit 1
fi

if (( count < budget )); then
    echo "check_localization_orphans: below budget — lower ${BUDGET_FILE} to ${count} to lock the gain in."
fi
echo "check_localization_orphans: clean."
