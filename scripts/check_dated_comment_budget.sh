#!/usr/bin/env bash
#
# Dated changelog comments — a ratchet.
#
# Why this exists. Comment lines of the form "2026-05-13 — this used to …"
# are each accurate when written; together they read as a changelog pasted
# into the code, and they make files longer than the code in them justifies.
# The history belongs in git and in docs/adr; a comment should say WHY the
# code is the way it is, not WHEN it changed.
#
# This counts comment lines that carry an ISO date and fails when the count
# rises above `.ci/dated_comment_budget.txt`. The budget only ratchets down.
set -uo pipefail
cd "$(dirname "$0")/.."

source "$(dirname "$0")/lib/preflight.sh"

BUDGET_FILE=".ci/dated_comment_budget.txt"
if [[ ! -f "$BUDGET_FILE" ]]; then
    echo "check_dated_comment_budget: missing $BUDGET_FILE" >&2
    exit 2
fi
budget="$(tr -d '[:space:]' < "$BUDGET_FILE")"
count="$(grep -rhE '(^\s*(///?|/\*|\*)\s.*|//.*)\b20[0-9]{2}-[0-9]{2}-[0-9]{2}\b' Emuqu "EmuquWatch Watch App" EmuquTests EmuquUITests --include='*.swift' 2>/dev/null | wc -l | tr -d ' ')"
echo "Dated comment lines: ${count} (budget: ${budget}; ratchet toward 0)"
if (( count > budget )); then
    echo "check_dated_comment_budget: FAIL — ${count} dated comment lines exceed the budget of ${budget}." >&2
    echo "Say why the code is the way it is; leave the date to git." >&2
    exit 1
fi
if (( count < budget )); then
    echo "SLACK: lower ${BUDGET_FILE} to ${count} to lock the gain in"
fi
echo "check_dated_comment_budget: clean."
