#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/preflight.sh"

# Coverage gate.
#
# A floor set at an aspiration — 90% line coverage of the whole `Emuqu.app`
# target, say — can never pass. When this gate was written the real figure was
# ~16%: 109,595 of the target's 218,660 executable lines — just over half — were
# SwiftUI view bodies in `Emuqu/Sources/Views`, which unit tests cannot
# meaningfully execute, and a 90% floor over that denominator was not
# reachable. The floors have been ratcheted up from measurement since; the
# committed values in `.ci/min_coverage*.txt` are the current ones.
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
#   • LOGIC    — every path not under `/Sources/Views/`. This is the number
#                that actually reflects test discipline, because it covers the
#                code unit tests can reach: Analysis, Storage, Services, Models,
#                Collection, Assistant, Import, Export, Utilities. The
#                Assistant's own SwiftUI files (`Sources/Assistant/Views/`)
#                fall in this bucket too; the floors were measured that way.
#   • VIEWS    — paths under `/Sources/Views/`. Snapshot tests move it.
#   • AREAS    — one floor per path prefix in `.ci/min_coverage_areas.txt`:
#                each source folder, and within them the persistence core,
#                the assistant's confirmation step and the log scrubber. An
#                aggregate can rise while one of these falls; this cannot.
#
# Raising LOGIC is the meaningful goal. Raising OVERALL materially requires
# snapshot tests for the view layer — tracked as its own piece of work.
#
# The floors come from the committed files and nowhere else can lower them. A
# missing or unreadable floor file is an error, not a reason to fall back to a
# built-in number far below the committed one. `MIN_COVERAGE` (or the second
# argument), `MIN_LOGIC_COVERAGE` and `MIN_VIEWS_COVERAGE` may RAISE a floor
# for a run; a value below the committed floor is ignored, and the floor in
# force is printed either way.
#
# Usage: check_coverage.sh <xcresult_path> [minimum_overall_percent]

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <xcresult_path> [minimum_percent]" >&2
    exit 64
fi

RESULT_BUNDLE="$1"

is_number() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }

# floor <committed file> <override, may be empty>: prints the floor in force.
# Exits 66 when the committed file is missing or not a number, 64 when the
# override is not a number.
floor() {
    local file="$1" override="$2" committed
    if [[ ! -f "$file" ]]; then
        echo "Coverage floor file missing: $file. The committed floor is the gate." >&2
        exit 66
    fi
    committed="$(tr -d '[:space:]' < "$file")"
    if ! is_number "$committed"; then
        echo "Coverage floor file does not hold a number: $file ('$committed')." >&2
        exit 66
    fi
    if [[ -z "$override" ]]; then printf '%s' "$committed"; return; fi
    if ! is_number "$override"; then
        echo "Coverage floor override is not a number: '$override'." >&2
        exit 64
    fi
    awk -v a="$override" -v b="$committed" 'BEGIN { print (a > b) ? a : b }'
}

MIN_COVERAGE="$(floor .ci/min_coverage.txt "${2:-${MIN_COVERAGE:-}}")" || exit $?
MIN_LOGIC_COVERAGE="$(floor .ci/min_coverage_logic.txt "${MIN_LOGIC_COVERAGE:-}")" || exit $?
MIN_VIEWS_COVERAGE="$(floor .ci/min_coverage_views.txt "${MIN_VIEWS_COVERAGE:-}")" || exit $?
AREA_FLOORS=.ci/min_coverage_areas.txt
if [[ ! -f "$AREA_FLOORS" ]]; then
    echo "Coverage floor file missing: $AREA_FLOORS. The committed floor is the gate." >&2
    exit 66
fi

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
SUMMARY="$(python3 - "$MIN_COVERAGE" "$MIN_LOGIC_COVERAGE" "$PER_FILE_REPORT" "${SKIP_OVERALL_COVERAGE:-0}" "${SKIP_LOGIC_COVERAGE:-0}" "$MIN_VIEWS_COVERAGE" "$AREA_FLOORS" <<'PY'
import re
import sys

min_overall = float(sys.argv[1])
min_logic = float(sys.argv[2])
report_path = sys.argv[3]
# SKIP_OVERALL_COVERAGE / SKIP_LOGIC_COVERAGE=1 report a floor without
# enforcing it, for a local run of part of the suite. CI sets neither: every
# floor is enforced at every scope.
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
        print("SKIP: overall floor not enforced (SKIP_OVERALL_COVERAGE=1)")
    else:
        print(f"FAIL: overall coverage {overall_pct:.2f}% < {min_overall:.0f}%")
        failed = True
if logic_pct + 1e-9 < min_logic:
    if skip_logic:
        print("SKIP: logic floor not enforced (SKIP_LOGIC_COVERAGE=1)")
    else:
        print(f"FAIL: logic coverage {logic_pct:.2f}% < {min_logic:.0f}%")
        failed = True
# Snapshot tests live in EmuquTests and execute view bodies, so the views
# number is meaningful without the UI suite. It is a ratchet — raise it as
# screens gain snapshots.
if view_pct + 1e-9 < min_views:
    print(f"FAIL: views coverage {view_pct:.2f}% < {min_views:.1f}%")
    print("  Snapshot tests are what move this. See EmuquTests/ViewSnapshotTests.swift.")
    failed = True

# Per-area floors. An area the report has no lines for fails too: a renamed
# folder would otherwise drop its floor without anyone choosing to.
areas_path = sys.argv[7]
with open(areas_path, encoding="utf-8") as fh:
    area_lines = [line.split() for line in fh if line.strip() and not line.lstrip().startswith("#")]
seen_areas = set()
for fields in area_lines:
    if fields and fields[0] in seen_areas:
        print(f"FAIL: area {fields[0]} is listed twice in {areas_path}")
        failed = True
        continue
    seen_areas.add(fields[0] if fields else "")
    if len(fields) != 2 or not re.fullmatch(r"\d+(\.\d+)?", fields[1]):
        print(f"FAIL: unreadable line in {areas_path}: {' '.join(fields)}")
        failed = True
        continue
    prefix, area_min = fields[0], float(fields[1])
    inside = [(c, t) for p, c, t in rows if p.split("/Sources/", 1)[-1].startswith(prefix)]
    covered, lines = sum(c for c, _ in inside), sum(t for _, t in inside)
    if not lines:
        print(f"FAIL: no coverage rows for area {prefix}; fix its line in {areas_path}")
        failed = True
        continue
    area_pct = 100.0 * covered / lines
    print(f"Line coverage ({prefix}): {area_pct:.2f}% ({covered}/{lines})  minimum {area_min:.0f}%")
    if area_pct + 1e-9 < area_min and not skip_logic:
        print(f"FAIL: {prefix} coverage {area_pct:.2f}% < {area_min:.0f}%")
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
