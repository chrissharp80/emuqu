#!/usr/bin/env bash
set -euo pipefail

# Debt budgets may fall. They may not rise. Coverage floors are the mirror
# image: they may rise, and they may not fall.
#
# Every gate in `enforce_tech_debt_budgets.sh` and `enforce_swiftlint_budget.sh`
# compares `count > budget`, and every budget currently sits exactly at its
# measured value. That is the ratchet working — but a ratchet whose stop can be
# unscrewed is a suggestion. The cheapest way to make CI green after adding a
# `try?` is to edit `.ci/try_optional_budget.txt`, and nothing else tells the
# difference between paying the debt and moving the goalpost.
#
# So: compare every `.ci/*.txt` value against the merge base. A decrease is the
# point of the exercise. An increase fails unless the commit range explicitly
# says why, via a trailer in any commit message:
#
#     budget-raise-ok: .ci/shared_usage_budget.txt <reason>
#
# The escape hatch is deliberate and deliberately noisy — some raises are
# legitimate (a vendored subsystem lands, a threshold is retuned) and those
# should be a sentence in the history rather than an invisible edit.
#
# DIRECTION MATTERS. Not every `.ci/*.txt` is a ceiling: three are floors —
# `min_coverage.txt`, `min_coverage_logic.txt`, `min_localization_coverage.txt`.
# Compare those as though smaller were always better and gutting the
# logic-coverage floor from 37 % to 5 % prints "ratcheted: 37 -> 5" and passes —
# the one edit the script exists to catch, waved through with congratulations.
# Files named `min_*` ratchet upward, and a decrease is what needs justifying.

BASE_REF="${1:-}"
CI_DIR="${CI_DIR:-.ci}"

if [[ ! -d "$CI_DIR" ]]; then
    echo "check_budget_monotonicity: no $CI_DIR directory; nothing to check."
    exit 0
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "check_budget_monotonicity: not a git repository; skipping."
    exit 0
fi

# Resolve the baseline. In CI, GITHUB_BASE_REF names the PR target — a real
# branch someone is proposing to merge into, which is the only place this check
# means anything.
#
# The local fallback is deliberately NOT `HEAD~1`. On a solo repo whose history
# is squashed before it goes public, HEAD~1 is a commit that is about to stop
# existing; asserting things about a diff against it manufactures work with
# nobody on the other end of it. Worse, it fires on your own uncommitted work
# in progress, so the only way to a green local run is a justification
# addressed to no one. No explicit baseline and no PR target means no
# comparison. Pass a ref explicitly (`check_budget_monotonicity.sh main`) when
# you actually want one.
#
# PUSH-TO-MAIN IS THE HOLE `BUDGET_BASE_REF` closes. `GITHUB_BASE_REF` is set
# only for pull_request events. This repo is developed by committing straight
# to `main`, so with only `GITHUB_BASE_REF` every run that actually matters
# prints "no PR baseline … Skipping" and compares nothing — every ratchet in
# `.ci/`, all sitting exactly at their measured value, unprotected by the one
# gate whose entire job is to stop a budget being edited instead of paid.
# `ci.yml` passes `github.event.before` on a push, which is the commit `main`
# pointed at before the push landed. Local runs with no baseline still skip,
# deliberately, for the reasons above.

# No usable baseline.
#
# Skipping is right locally and wrong in CI. A release gate that cannot compare
# must say so rather than pass; otherwise "enforced" and "did not run" print
# the same green tick.
no_baseline() {
    local reason="$1"
    if [[ -n "${BUDGET_REQUIRE_BASELINE:-}" ]]; then
        echo "check_budget_monotonicity: $reason." >&2
        echo "A baseline is REQUIRED here — refusing to report enforcement that did not happen." >&2
        exit 1
    fi
    echo "check_budget_monotonicity: $reason; skipping (set BUDGET_REQUIRE_BASELINE=1 to make this fatal)."
    exit 0
}

if [[ -z "$BASE_REF" ]]; then
    if [[ -n "${GITHUB_BASE_REF:-}" ]]; then
        BASE_REF="origin/${GITHUB_BASE_REF}"
    elif [[ -n "${BUDGET_BASE_REF:-}" ]]; then
        BASE_REF="${BUDGET_BASE_REF}"
    else
        # With no baseline this function exits before any file is read — there
        # is no working-tree-vs-HEAD comparison "for free". To check your own
        # uncommitted budget edits, ask for it by name:
        #
        #     ./scripts/check_budget_monotonicity.sh HEAD
        no_baseline "no baseline supplied"
    fi
fi

# A force-push or an initial push sends the all-zero SHA as `before`. That is
# not a baseline, it is the absence of one.
if [[ "$BASE_REF" =~ ^0{40}$ ]]; then
    no_baseline "baseline is the null SHA (new or force-pushed branch)"
fi

if ! git rev-parse --verify --quiet "$BASE_REF^{commit}" >/dev/null; then
    no_baseline "baseline '$BASE_REF' is not resolvable"
fi

# Collect the acknowledged raises from every commit message in the range.
allowed_changes="$(git log --format=%B "${BASE_REF}..HEAD" 2>/dev/null \
    | grep -Eio '^budget-raise-ok:[[:space:]]*[^[:space:]]+' \
    | sed -E 's/^[Bb][^:]*:[[:space:]]*//' || true)"

is_allowed() {
    local file="$1"
    [[ -n "$allowed_changes" ]] || return 1
    grep -Fxq "$file" <<< "$allowed_changes"
}

# `min_*` budgets are floors: the value is a minimum to clear, so raising it
# tightens the gate and lowering it loosens one.
is_floor() {
    [[ "$(basename "$1")" == min_* ]]
}

read_int() {
    # Budget files hold a single integer. Anything else is treated as absent
    # rather than guessed at.
    local raw="$1"
    raw="$(tr -d '[:space:]' <<< "$raw")"
    [[ "$raw" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$raw"
}

violations=()
compared=0

while IFS= read -r file; do
    current_raw="$(cat "$file")"
    current="$(read_int "$current_raw")" || continue

    # A file that did not exist at the baseline is a new budget, not a raise.
    previous_raw="$(git show "${BASE_REF}:${file}" 2>/dev/null || true)"
    [[ -n "$previous_raw" ]] || continue
    previous="$(read_int "$previous_raw")" || continue

    compared=$((compared + 1))

    (( current == previous )) && continue

    if is_floor "$file"; then
        loosened=$(( current < previous ))
    else
        loosened=$(( current > previous ))
    fi

    if (( loosened )); then
        if is_allowed "$file"; then
            echo "  ALLOWED: $file ${previous} -> ${current} (acknowledged)"
        else
            violations+=("$file ${previous} -> ${current}")
        fi
    else
        echo "  ratcheted: $file ${previous} -> ${current}"
    fi
done < <(find "$CI_DIR" -maxdepth 1 -name '*.txt' | sort)

if (( ${#violations[@]} > 0 )); then
    echo >&2
    echo "ERROR: gate loosened without justification (base: ${BASE_REF}):" >&2
    for violation in "${violations[@]}"; do
        echo "  - $violation" >&2
    done
    echo >&2
    echo "Debt ceilings ratchet down; coverage floors (min_*) ratchet up. Pay the" >&2
    echo "debt, or record the reason — either as a commit message trailer:" >&2
    echo >&2
    echo "    budget-raise-ok: <path> <why this gate legitimately loosened>" >&2
    exit 1
fi

echo "check_budget_monotonicity: clean. ${compared} budgets compared against ${BASE_REF}."
