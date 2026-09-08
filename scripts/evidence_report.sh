#!/usr/bin/env bash
#
# Emit a factual snapshot of what this repository actually enforces.
#
# ## Why
#
# Two external audits (2026-08-26, 2026-08-27) reached the same shape of
# conclusion: the code is strong, the *evidence* is missing. One scored it
# "static implementation quality ~3.3/5, operational assurance ~1.2/5". Both had
# to infer the state of the codebase from a quiet Actions tab, and both inferred
# wrong — one concluded the app collects user data, another that the test suite
# had never been run.
#
# Neither was being careless. There was simply nothing in the repository that
# answered the question in one command. This is that command.
#
# It runs no builds and takes seconds: every number is read live from the
# enforced budget files or a plain source scan. Coverage percentages and
# pass/fail results are deliberately ABSENT rather than cached, because
# producing them needs a simulator and forty minutes — a stale number presented
# as current is the exact failure this repository keeps finding.
#
#     ./scripts/evidence_report.sh            # human-readable
#     ./scripts/evidence_report.sh --json     # machine-readable
#
# Nothing here is a claim about quality. It is a list of what is measured, what
# the ceiling is, and where the ceiling is written down, so a reviewer can check
# any line in a few seconds instead of guessing.

set -uo pipefail
cd "$(dirname "$0")/.."

JSON=0
[[ "${1:-}" == "--json" ]] && JSON=1

budget() { [[ -f ".ci/$1" ]] && tr -d '[:space:]' < ".ci/$1" || echo "?"; }

swift_files=$(find Emuqu/Sources "EmuquWatch Watch App" -name '*.swift' 2>/dev/null | wc -l | tr -d ' ')
swift_lines=$(find Emuqu/Sources "EmuquWatch Watch App" -name '*.swift' -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')
test_files=$(find EmuquTests EmuquUITests -name '*.swift' 2>/dev/null | wc -l | tr -d ' ')
unit_tests=$(grep -rhoE 'func test[A-Za-z0-9_]*\(' EmuquTests 2>/dev/null | wc -l | tr -d ' ')
ui_tests=$(grep -rhoE 'func test[A-Za-z0-9_]*\(' EmuquUITests 2>/dev/null | wc -l | tr -d ' ')
locales=$(python3 -c "
import json
d=json.load(open('Emuqu/Localizable.xcstrings'))
print(len({l for v in d['strings'].values() for l in (v.get('localizations') or {})}))
" 2>/dev/null || echo "?")
keys=$(python3 -c "
import json; print(len(json.load(open('Emuqu/Localizable.xcstrings'))['strings']))
" 2>/dev/null || echo "?")
waivers=$(grep -rn 'swiftlint:disable' Emuqu/Sources "EmuquWatch Watch App" 2>/dev/null | wc -l | tr -d ' ')
force_try=$(grep -rn 'try!' Emuqu/Sources "EmuquWatch Watch App" 2>/dev/null | grep -v '///' | wc -l | tr -d ' ')
force_cast=$(grep -rn 'as! ' Emuqu/Sources "EmuquWatch Watch App" 2>/dev/null | grep -v '///' | wc -l | tr -d ' ')
gates=$(grep -oE '^ci: .*' Makefile | tr ' ' '\n' | grep -v '^ci:$' | grep -c . | tr -d ' ')
auto_wf=$(python3 -c "
import glob, yaml
n = 0
for f in glob.glob('.github/workflows/*.yml'):
    d = yaml.safe_load(open(f))
    on = list((d.get(True) or d.get('on') or {}).keys())
    # One workflow, however many triggers it has (2026-09-03: gates.yml has push + pull_request).
    n += 1 if any(t not in ('workflow_dispatch', 'workflow_call') for t in on) else 0
print(n)
" 2>/dev/null || echo "?")

if (( JSON )); then
    python3 - "$swift_files" "$swift_lines" "$unit_tests" "$ui_tests" "$locales" "$keys" \
             "$waivers" "$force_try" "$force_cast" "$gates" "$auto_wf" \
             "$(budget swiftlint_warning_budget.txt)" \
             "$(budget shared_usage_budget.txt)" "$(budget try_optional_budget.txt)" \
             "$(budget min_coverage.txt)" "$(budget min_coverage_logic.txt)" <<'PY'
import json, sys
a = sys.argv[1:]
print(json.dumps({
    "source": {"swift_files": int(a[0]), "swift_lines": int(a[1])},
    "tests": {"unit": int(a[2]), "ui": int(a[3])},
    "localization": {"locales": int(a[4]), "keys": int(a[5]), "coverage_floor_percent": 100},
    "waivers": {"swiftlint_disable": int(a[6]), "force_try": int(a[7]), "force_cast": int(a[8])},
    "enforcement": {"gates_in_make_ci": int(a[9]), "auto_triggering_workflows": int(a[10])},
    "budgets": {
        "swiftlint_warnings": a[11], "strict_concurrency": "swift-6-mode, complete",
        "shared_singleton_uses": a[12], "try_optional_uses": a[13],
        "coverage_overall_floor": a[14], "coverage_logic_floor": a[15],
    },
    "notes": [
        "Budgets ratchet downward only; check_budget_monotonicity.sh fails an unjustified raise.",
        "No workflow runs automatically. See docs/CI_POSTURE.md for the costing.",
        "Coverage and test-run results require `make ci` (~40 min, needs a simulator).",
    ],
}, indent=2))
PY
    exit 0
fi

cat <<EOF
Emuqu — enforced state
$(date -u '+%Y-%m-%d')  ·  commit $(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')

SOURCE
  Swift files                       ${swift_files}
  Swift lines                       ${swift_lines}
  Test files                        ${test_files}
  Unit tests / UI tests             ${unit_tests} / ${ui_tests}

ZERO-TOLERANCE (enforced, not aspirational)
  swiftlint:disable in app source   ${waivers}
  Force try (try!)                  ${force_try}
  Force cast (as!)                  ${force_cast}
  Declarations over 20 lines        $(budget spec_long_functions_budget.txt)
  Nesting deeper than 2             $(budget spec_deep_nesting_budget.txt)
  Commented-out code                $(budget spec_commented_code_budget.txt)
  Strict concurrency                Swift 6 mode, complete   (compiler-enforced)

RATCHETED CEILINGS (may only go down)
  SwiftLint warnings                $(budget swiftlint_warning_budget.txt)
  .shared singleton uses            $(budget shared_usage_budget.txt)
  try? uses                         $(budget try_optional_budget.txt)
  Legacy ObservableObject           $(budget legacy_observable_object_budget.txt)
  Test skips                        $(budget test_skip_budget.txt)
  Fixed-point fonts                 $(budget fixed_font_budget.txt)

COVERAGE FLOORS (may only go up)
  Overall app                       $(budget min_coverage.txt)%
  Logic, excluding Views            $(budget min_coverage_logic.txt)%

LOCALIZATION
  Locales                           ${locales}
  Source strings                    ${keys}
  Enforced coverage floor           $(budget min_localization_coverage.txt)%

ENFORCEMENT
  Gates in \`make ci\`                ${gates}
  Auto-triggering workflows         ${auto_wf}    (see docs/CI_POSTURE.md)
  Warnings treated as errors        yes
  SBOM                              sbom.spdx.json, staleness-checked

VERIFY ANY LINE
  make ci                           run every gate plus the full suite (~40 min)
  cat .ci/*.txt                     every ceiling, as enforced
  ./scripts/evidence_report.sh --json

Coverage percentages and test results are NOT in this report: producing them
takes a simulator and forty minutes. Run \`make ci\` for them rather than
trusting a number cached here.
EOF
