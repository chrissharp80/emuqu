#!/usr/bin/env bash
set -euo pipefail

# The roots and budget files are relative; from another directory the roots
# would hold no files and both counts would read 0.
cd "$(dirname "$0")/.."

# Fixed-point fonts in the view layer.
#
# `.font(.system(size: N))`, `Font.system(size: N)` held in a variable or
# passed through a helper, and the same call split across lines all do not respond to the user's text-size setting.
# At AX5 the surrounding text grows and those numbers stay put, which breaks
# layout and leaves the largest figures on screen rendered at their smallest
# size for exactly the users who enlarged their text.
#
# `View.scaledFont(size:)` is the migration target (see ScaledFont.swift). Most
# of the app is already on it. This counts what is left and ratchets it down.
#
# Why a budget rather than zero: a few sites are legitimately fixed and must
# stay that way —
#   • `RecapCard` renders a 1080 × 1920 shareable PNG where the point size IS
#     the design and there is no user text-size setting to honour.
#   • `ScoreRing`'s score digits are centred inside a fixed-diameter ring; a
#     scaled 84 pt figure renders past the stroke it sits in.
# Those are documented at their call sites. The budget exists so the *rest*
# cannot quietly grow back.
#
# This also stands in for XCTest's `.dynamicType` accessibility audit, which is
# excluded in AccessibilityAuditUITests because it cannot see through
# `@ScaledMetric` and flags correctly-scaling `scaledFont` sites. See the
# reasoning in that file.

BUDGET_FILE="${FIXED_FONT_BUDGET_FILE:-.ci/fixed_font_budget.txt}"
# Scans the whole app target, not just `Emuqu/Sources`. `EmuquApp.swift` sits at
# `Emuqu/`; with the narrower root, extracting a view out of it into
# `Sources/Views/` moves a fixed-size font across the boundary and the count
# rises by one with no code changed. A budget that shifts when a file moves is
# measuring the wrong thing.
SOURCE_ROOT="${1:-Emuqu}"

# The watch target is a separate population: an app-target budget on its own
# reads as the whole picture while the watch's fixed-point fonts go uncounted.
#
# It gets its OWN budget rather than being folded into the app's, for two
# reasons. `View.scaledFont(size:)` lives in `Emuqu/Sources` and is unreachable
# from a separate watchOS target, so the migration target the app is ratcheting
# toward does not exist there; and folding its count into the app's would be a
# budget RAISE, which is the move `check_budget_monotonicity.sh` exists to stop.
# A population entering a gate for the first time gets a new budget at its
# measured value.
WATCH_ROOT="${2:-EmuquWatch Watch App}"
WATCH_BUDGET_FILE="${FIXED_FONT_WATCH_BUDGET_FILE:-.ci/fixed_font_watch_budget.txt}"

if [[ ! -f "$BUDGET_FILE" ]]; then
    echo "Fixed-font budget file not found: $BUDGET_FILE" >&2
    exit 66
fi

budget="$(tr -d '[:space:]' < "$BUDGET_FILE")"
if [[ ! "$budget" =~ ^[0-9]+$ ]]; then
    echo "Fixed-font budget file is not an integer: $BUDGET_FILE" >&2
    exit 65
fi

measure() {
python3 - "$1" <<'PY'
import os
import sys

import re

root = sys.argv[1]

# A missing root walks nothing and would read as a clean count of 0.
if not os.path.isdir(root):
    sys.stderr.write("check_fixed_font_budget: source root not found: " + root + "\n")
    sys.exit(66)

# COUNT ONLY A NUMERIC LITERAL ARGUMENT.
#
# Counting the substring `.font(.system(size:` regardless of the argument
# over-reports by roughly nine times: most sites pass a declared
# `@ScaledMetric` variable and therefore ALREADY scale correctly — they are the
# migration target, counted as the debt — and a few more pass a proportional
# expression inside a fixed-diameter ring. With that count the message about
# ratcheting toward the documented exceptions is unreachable by construction:
# the count can never fall below the number of correctly scaling sites. A
# literal argument is the one with the property the gate header describes: it
# does not respond to the user text-size setting.
# (No apostrophes in this block: an apostrophe inside the enclosing $( )
# command substitution starts a quoted string for the bash parser, even in a
# quoted heredoc. Same trap enforce_tech_debt_budgets.sh documents.)
#
# The needle is the `Font.system(size:)` call itself, with or without the
# `Font` prefix, wherever it appears: inside `.font(...)`, as a stored `Font`,
# or as an argument on a continuation line.
NEEDLE = re.compile(r"(?<![\w])(?:Font)?\.system\(size:\s*([^,)]+)")
LITERAL_ARG = re.compile(r"^[\d.]+$")
count = 0
files = 0
for dirpath, _dirnames, filenames in os.walk(root):
    for name in filenames:
        if not name.endswith(".swift"):
            continue
        files += 1
        with open(os.path.join(dirpath, name), encoding="utf-8", errors="replace") as handle:
            for line in handle:
                stripped = line.strip()
                if stripped.startswith("//"):
                    continue
                for argument in NEEDLE.findall(line):
                    if LITERAL_ARG.match(argument.strip()):
                        count += 1
if files == 0:
    sys.stderr.write("check_fixed_font_budget: no Swift files under " + root + "\n")
    sys.exit(66)
print(count)
PY
}

# `|| exit $?`: measure runs in a subshell, so its exit cannot stop this script.
count="$(measure "$SOURCE_ROOT")" || exit $?
watch_count="$(measure "$WATCH_ROOT")" || exit $?

if [[ ! -f "$WATCH_BUDGET_FILE" ]]; then
    echo "Fixed-font watch budget file not found: $WATCH_BUDGET_FILE" >&2
    exit 66
fi
watch_budget="$(tr -d '[:space:]' < "$WATCH_BUDGET_FILE")"
if [[ ! "$watch_budget" =~ ^[0-9]+$ ]]; then
    echo "Fixed-font watch budget file is not an integer: $WATCH_BUDGET_FILE" >&2
    exit 65
fi

echo "Fixed-point fonts (.system(size: <literal>)): ${count} (budget: ${budget}; ratchet toward the documented exceptions)"
echo "  ...in ${WATCH_ROOT}: ${watch_count} (budget: ${watch_budget})"

failed=0
if (( count > budget )); then
    echo >&2
    echo "ERROR: fixed-point font count exceeded budget (${count} > ${budget})." >&2
    echo "Use .scaledFont(size:) so the text honours Dynamic Type, or document" >&2
    echo "why this site must stay fixed and raise the budget deliberately." >&2
    failed=1
fi

if (( watch_count > watch_budget )); then
    echo >&2
    echo "ERROR: watch fixed-point font count exceeded budget (${watch_count} > ${watch_budget})." >&2
    echo "scaledFont is not reachable from the watch target; use @ScaledMetric." >&2
    failed=1
fi

if (( count < budget )); then
    echo "  below budget — lower ${BUDGET_FILE} to ${count} to lock the gain in"
fi
if (( watch_count < watch_budget )); then
    echo "  below budget — lower ${WATCH_BUDGET_FILE} to ${watch_count} to lock the gain in"
fi

(( failed )) && exit 1

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "## Fixed-point font budget"
        echo
        echo '```text'
        echo "Fixed-point fonts: ${count} (budget: ${budget})"
        echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
fi
