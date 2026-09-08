#!/usr/bin/env bash
set -euo pipefail

# A skipped test is a test that passes without asserting anything.
#
# `XCTSkipUnless` is the right tool when a precondition genuinely cannot hold on
# the runner — no encryption hardware, an archive that is empty by design. It is
# also the failure mode this repo has already hit: a stale selector made
# `DataDeletionUITests`' navigation helper return nothing, the guard skipped
# every test in the class, and the suite reported green while asserting nothing.
# That was caught by reading the file, not by CI.
#
# So the count is budgeted like every other debt here. It ratchets down.

SKIP_BUDGET_FILE="${SKIP_BUDGET_FILE:-.ci/test_skip_budget.txt}"
TEST_DIRS=("${@:-EmuquTests EmuquUITests}")

read_budget() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "Budget file not found: $file" >&2
        exit 66
    fi
    local value
    value="$(tr -d '[:space:]' < "$file")"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo "Budget file is not an integer: $file" >&2
        exit 65
    fi
    printf '%s' "$value"
}

budget="$(read_budget "$SKIP_BUDGET_FILE")"

# Count call sites, not mentions: a line that only talks about XCTSkip in a doc
# comment is documentation, and several of the justifications in this repo are
# exactly that.
skip_count=0
while IFS= read -r file; do
    count="$(grep -cE '(^|[^/[:alnum:]_])(try +)?(throw +)?XCTSkip(Unless|If)?\(' "$file" || true)"
    skip_count=$((skip_count + count))
done < <(find EmuquTests EmuquUITests -name '*.swift' 2>/dev/null | sort)

echo "Test skip sites: ${skip_count} (budget: ${budget}; ratchet toward 0)"

if (( skip_count > budget )); then
    echo >&2
    echo "ERROR: skipped-test count exceeded budget (${skip_count} > ${budget})." >&2
    echo "A skip is a test that passes without asserting. If the precondition is" >&2
    echo "real, make the test set it up; if it is not, delete the guard." >&2
    echo >&2
    grep -rnE '(^|[^/[:alnum:]_])(try +)?(throw +)?XCTSkip(Unless|If)?\(' EmuquTests EmuquUITests --include='*.swift' >&2 || true
    exit 1
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "## Test skip budget"
        echo
        echo '```text'
        echo "Test skip sites: ${skip_count} (budget: ${budget})"
        echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
fi
