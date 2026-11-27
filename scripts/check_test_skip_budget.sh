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
TEST_DIRS=("$@")
if (( ${#TEST_DIRS[@]} == 0 )); then
    TEST_DIRS=(EmuquTests EmuquUITests)
fi
# A missing directory would count no skips and read as clean.
for dir in "${TEST_DIRS[@]}"; do
    if [[ ! -d "$dir" ]]; then
        echo "Test directory not found: $dir" >&2
        exit 66
    fi
done

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
# exactly that. So comments (`//`, `///`, `/* */`) are removed before counting,
# and every call on a line counts, not the line. A skip spelled
# `XCTSkip.init(`, and Swift Testing's `.disabled(` and `withKnownIssue`, are
# skips too.
skip_sites="$(find "${TEST_DIRS[@]}" -name '*.swift' -print0 | sort -z | xargs -0 perl -0ne '
    my $file = $ARGV;
    s{/\*.*?\*/}{ my $c = $&; $c =~ s/[^\n]//g; $c }gse;
    s{//[^\n]*}{}g;
    my $n = 0;
    for my $line (split /\n/, $_, -1) {
        $n++;
        while ($line =~ /(?:^|[^[:alnum:]_])(XCTSkip(?:Unless|If)?\s*(?:\.\s*init\s*)?\(|withKnownIssue\s*[({])/g) {
            print "$file:$n: $1\n";
        }
    }
    # A trait list can span lines, so `.disabled(` is matched over the whole
    # file, within the attribute parentheses (one level of nesting).
    while (/@(?:Test|Suite)\s*\((?:[^()]|\([^()]*\))*?\.disabled\s*\(/gs) {
        my $at = 1 + (substr($_, 0, $-[0]) =~ tr/\n//);
        print "$file:$at: .disabled(\n";
    }
')" || { echo "check_test_skip_budget: counting failed" >&2; exit 70; }
skip_count="$(printf '%s' "$skip_sites" | grep -c . || true)"

# A test plan or scheme can skip whole classes without a line of Swift.
plan_skips="$(grep -nE '"skippedTests"|<SkippedTests>' Emuqu.xctestplan Emuqu.xcodeproj/xcshareddata/xcschemes/*.xcscheme 2>/dev/null || true)"
if [[ -n "$plan_skips" ]]; then
    echo "ERROR: tests are skipped in the test plan or scheme:" >&2
    echo "$plan_skips" >&2
    exit 1
fi

# The test plan skips without a line of Swift: a `skippedTests` entry drops a
# whole class, and `"enabled": false` drops a whole target. Each counts as a site.
plan_skips="$(python3 - <<'PY'
import json, pathlib
count = 0
for plan in pathlib.Path(".").glob("*.xctestplan"):
    data = json.loads(plan.read_text(encoding="utf-8"))
    for target in data.get("testTargets", []):
        count += len(target.get("skippedTests", []))
        count += 0 if target.get("enabled", True) else 1
        count += 1 if "selectedTests" in target else 0
print(count)
PY
)" || { echo "Could not read the test plan." >&2; exit 65; }
skip_count=$((skip_count + plan_skips))

echo "Test skip sites: ${skip_count} (budget: ${budget}; ratchet toward 0)"

if (( skip_count > budget )); then
    echo >&2
    echo "ERROR: skipped-test count exceeded budget (${skip_count} > ${budget})." >&2
    echo "A skip is a test that passes without asserting. If the precondition is" >&2
    echo "real, make the test set it up; if it is not, delete the guard." >&2
    echo >&2
    printf '%s\n' "$skip_sites" >&2
    exit 1
fi

# A ratchet holds only if the budget follows the count down: slack lets the
# next skip in unseen.
if (( skip_count < budget )); then
    echo "FAIL (slack): lower ${SKIP_BUDGET_FILE} to ${skip_count} in this change to lock the gain in." >&2
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
