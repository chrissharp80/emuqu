#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${1:-.swiftlint.yml}"
BUDGET_FILE="${2:-.ci/swiftlint_warning_budget.txt}"
REPORT_PATH="${3:-build/swiftlint-report.json}"

if [[ ! -f "$BUDGET_FILE" ]]; then
    echo "SwiftLint budget file not found: $BUDGET_FILE" >&2
    exit 66
fi

budget="$(tr -d '[:space:]' < "$BUDGET_FILE")"
if [[ ! "$budget" =~ ^[0-9]+$ ]]; then
    echo "SwiftLint budget file is not a whole number: $BUDGET_FILE" >&2
    exit 65
fi

mkdir -p "$(dirname "$REPORT_PATH")"
stderr_path="${REPORT_PATH%.json}.stderr"
swiftlint lint --config "$CONFIG_FILE" --reporter json > "$REPORT_PATH" 2> "$stderr_path"
# SwiftLint answers a malformed rule by warning and running the default, so a
# custom rule with a typo in its configuration would check nothing.
if grep -i 'invalid configuration' "$stderr_path" >&2; then
    echo "SwiftLint configuration is invalid; the rules above are not running." >&2
    exit 65
fi

summary="$(python3 - "$REPORT_PATH" "$budget" <<'PY'
import collections
import json
import sys

report_path = sys.argv[1]
budget = int(sys.argv[2])

with open(report_path, "r", encoding="utf-8") as fh:
    violations = json.load(fh)

count = len(violations)
print(f"SwiftLint violations: {count} (budget: {budget})")

counter = collections.Counter(v.get("rule_id", "unknown") for v in violations)
if counter:
    print("Top rules:")
    for rule, rule_count in counter.most_common(10):
        print(f"- {rule}: {rule_count}")
else:
    print("Top rules:\n- none")

if count > budget:
    sys.exit(1)
PY
)"

echo "$summary"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "## SwiftLint Budget"
        echo
        echo '```text'
        echo "$summary"
        echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
fi
