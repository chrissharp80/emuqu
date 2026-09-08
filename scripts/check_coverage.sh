#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/preflight.sh"

# Coverage gate.
#
# A floor set at an aspiration — 90% line coverage of the whole `Emuqu.app`
# target, say — can never pass. The real figure is ~16%: 109,595 of the
# target's 218,660 executable lines — just over half — are SwiftUI view bodies
# in `Emuqu/Sources/Views`, which unit tests cannot meaningfully execute, and
# a 90% floor over that denominator is not reachable.
#
# A gate set to an aspiration is worse than no gate: it is documented in CI and
# the README as though it holds, and the first person to run it works around it.
# So the floors below are DERIVED FROM MEASUREMENT, in exactly the same style as
# `.ci/swiftlint_warning_budget.txt` and the tech-debt budgets — they block
# regression and get ratcheted up deliberately.
#
# Two numbers are enforced, because one alone is misleading:
#
#   • OVERALL  — whole app target. Guards against total coverage sliding.
#   • LOGIC    — everything except `Sources/Views`. This is the number that
#                actually reflects test discipline, because it covers the code
#                unit tests can reach: Analysis, Storage, Services, Models,
#                Collection, Assistant, Import, Export, Utilities.
#
# Raising LOGIC is the meaningful goal. Raising OVERALL materially requires
# snapshot tests for the view layer — tracked as its own piece of work.
#
# Usage: check_coverage.sh <xcresult_path> [minimum_overall_percent]

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <xcresult_path> [minimum_percent]" >&2
    exit 64
fi

RESULT_BUNDLE="$1"
MIN_COVERAGE="${2:-${MIN_COVERAGE:-}}"
COVERAGE_FILE="${MIN_COVERAGE_FILE:-.ci/min_coverage.txt}"
LOGIC_COVERAGE_FILE="${MIN_LOGIC_COVERAGE_FILE:-.ci/min_coverage_logic.txt}"
# Views floor. Snapshot tests are what move it.
VIEWS_COVERAGE_FILE="${MIN_VIEWS_COVERAGE_FILE:-.ci/min_coverage_views.txt}"

if [[ -z "$MIN_COVERAGE" && -f "$COVERAGE_FILE" ]]; then
    MIN_COVERAGE="$(tr -d '[:space:]' < "$COVERAGE_FILE")"
fi
MIN_COVERAGE="${MIN_COVERAGE:-16}"

MIN_LOGIC_COVERAGE="${MIN_LOGIC_COVERAGE:-}"
if [[ -z "$MIN_LOGIC_COVERAGE" && -f "$LOGIC_COVERAGE_FILE" ]]; then
    MIN_LOGIC_COVERAGE="$(tr -d '[:space:]' < "$LOGIC_COVERAGE_FILE")"
fi
MIN_LOGIC_COVERAGE="${MIN_LOGIC_COVERAGE:-30}"

MIN_VIEWS_COVERAGE="${MIN_VIEWS_COVERAGE:-}"
if [[ -z "$MIN_VIEWS_COVERAGE" && -f "$VIEWS_COVERAGE_FILE" ]]; then
    MIN_VIEWS_COVERAGE="$(tr -d '[:space:]' < "$VIEWS_COVERAGE_FILE")"
fi
MIN_VIEWS_COVERAGE="${MIN_VIEWS_COVERAGE:-0}"

if [[ ! -d "$RESULT_BUNDLE" ]]; then
    echo "Result bundle not found: $RESULT_BUNDLE" >&2
    exit 66
fi

# Per-file report. `--files-for-target` is what lets us split view code out of
# the denominator; the plain `--report` only gives the target total.
PER_FILE_REPORT="$(gate_mktemp emuqu_coverage)" || exit $?
trap 'rm -f "$PER_FILE_REPORT"' EXIT
xcrun xccov view --report --files-for-target Emuqu.app "$RESULT_BUNDLE" > "$PER_FILE_REPORT" 2>/dev/null || true

if [[ ! -s "$PER_FILE_REPORT" ]]; then
    echo "Unable to read per-file coverage from xccov." >&2
    exit 65
fi

# The report is passed as a FILE PATH, not on stdin — stdin is already carrying
# the Python program itself via the heredoc, and it cannot carry both.
SUMMARY="$(python3 - "$MIN_COVERAGE" "$MIN_LOGIC_COVERAGE" "$PER_FILE_REPORT" "${SKIP_OVERALL_COVERAGE:-0}" "${SKIP_LOGIC_COVERAGE:-0}" "$MIN_VIEWS_COVERAGE" <<'PY'
import re
import sys

min_overall = float(sys.argv[1])
min_logic = float(sys.argv[2])
report_path = sys.argv[3]
# A unit-only run cannot execute SwiftUI view bodies, so the OVERALL floor is
# unreachable there by construction. The LOGIC floor is still enforced — that is
# the number the header above calls the meaningful goal, and it is exactly
# the one the unit target moves.
skip_overall = len(sys.argv) > 4 and sys.argv[4] == "1"
skip_logic = len(sys.argv) > 5 and sys.argv[5] == "1"
min_views = float(sys.argv[6]) if len(sys.argv) > 6 else 0.0

rows = []
with open(report_path, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        m = re.search(r"(/\S+\.swift)\s+\d+\s+([\d.]+)%\s+\((\d+)/(\d+)\)", line)
        if m:
            rows.append((m.group(1), int(m.group(3)), int(m.group(4))))

if not rows:
    print("Unable to parse any per-file coverage rows from xccov.")
    raise SystemExit(65)

total_cov = sum(c for _, c, _ in rows)
total_all = sum(t for _, _, t in rows)
logic_cov = sum(c for p, c, _ in rows if "/Sources/Views/" not in p)
logic_all = sum(t for p, _, t in rows if "/Sources/Views/" not in p)
view_cov = total_cov - logic_cov
view_all = total_all - logic_all

overall_pct = 100.0 * total_cov / total_all if total_all else 0.0
logic_pct = 100.0 * logic_cov / logic_all if logic_all else 0.0
view_pct = 100.0 * view_cov / view_all if view_all else 0.0

print(f"Line coverage (overall app): {overall_pct:.2f}% ({total_cov}/{total_all})  minimum {min_overall:.0f}%")
print(f"Line coverage (logic, ex-Views): {logic_pct:.2f}% ({logic_cov}/{logic_all})  minimum {min_logic:.0f}%")
print(f"Line coverage (Views only): {view_pct:.2f}% ({view_cov}/{view_all})  minimum {min_views:.1f}%")

failed = False
if overall_pct + 1e-9 < min_overall:
    if skip_overall:
        print("SKIP: overall floor not enforced — unit-only run cannot execute view bodies")
    else:
        print(f"FAIL: overall coverage {overall_pct:.2f}% < {min_overall:.0f}%")
        failed = True
if logic_pct + 1e-9 < min_logic:
    if skip_logic:
        print("SKIP: logic floor not enforced — the floors are calibrated for a full-suite run")
    else:
        print(f"FAIL: logic coverage {logic_pct:.2f}% < {min_logic:.0f}%")
        failed = True
# The views floor is enforced on a unit-only run too: snapshot tests live in
# EmuquTests and execute view bodies, so this number is meaningful without the
# UI suite. It is a ratchet — raise it as screens gain snapshots.
if view_pct + 1e-9 < min_views:
    print(f"FAIL: views coverage {view_pct:.2f}% < {min_views:.1f}%")
    print("  Snapshot tests are what move this. See EmuquTests/ViewSnapshotTests.swift.")
    failed = True

raise SystemExit(1 if failed else 0)
PY
)" && STATUS=0 || STATUS=$?

echo "$SUMMARY"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "## Coverage"
        echo
        echo '```text'
        echo "$SUMMARY"
        echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
fi

if [[ "$STATUS" -ne 0 ]]; then
    echo "Coverage gate failed." >&2
    exit 1
fi
