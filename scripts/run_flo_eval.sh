#!/usr/bin/env bash
#
# Runs the Flo answer eval (EmuquTests/FloAnswerEvalRunner) on a simulator
# against a real provider, and nothing else.
#
#   EMUQU_EVAL_DIR=/path/to/emuqu-flo-eval-seed \
#   EMUQU_EVAL_GROK_KEY=xai-... \
#   scripts/run_flo_eval.sh
#
# Environment, passed to the test process (xcodebuild hands TEST_RUNNER_<NAME>
# to it as <NAME>):
#   EMUQU_EVAL_DIR            the seed folder: dataset.json, questions.json (required)
#   EMUQU_EVAL_GROK_KEY       an xAI key; or EMUQU_EVAL_ANTHROPIC_KEY / EMUQU_EVAL_OPENAI_KEY
#   EMUQU_EVAL_PROVIDER       grok, anthropic or openai when several keys are set
#   EMUQU_EVAL_MODEL          a model API id (default: the provider's default model)
#   EMUQU_EVAL_OUT            results folder (default: $EMUQU_EVAL_DIR/results-<timestamp>)
#   EMUQU_EVAL_DRY_RUN=1      a stub provider answers instead: no key, no network
#   EMUQU_EVAL_DESTINATION    xcodebuild destination (default: the first iPhone simulator)
#   EMUQU_EVAL_DERIVED_DATA   xcodebuild -derivedDataPath, to reuse an earlier build
#
# The xcodebuild log goes to $EMUQU_EVAL_OUT/xcodebuild.log, beside the
# results: it can carry the app's debug lines, so it is not for a tuner's eyes
# any more than the held-out results are. Exits with xcodebuild's status.

set -uo pipefail

source "$(dirname "$0")/lib/xcodebuild.sh"
cd "$(dirname "$0")/.."

if [[ -z "${EMUQU_EVAL_DIR:-}" ]]; then
    echo "run_flo_eval: set EMUQU_EVAL_DIR to the eval seed folder" >&2
    exit 64
fi
if [[ "${EMUQU_EVAL_DRY_RUN:-}" != "1" && -z "${EMUQU_EVAL_GROK_KEY:-}${EMUQU_EVAL_ANTHROPIC_KEY:-}${EMUQU_EVAL_OPENAI_KEY:-}" ]]; then
    echo "run_flo_eval: set EMUQU_EVAL_GROK_KEY, EMUQU_EVAL_ANTHROPIC_KEY or EMUQU_EVAL_OPENAI_KEY (or EMUQU_EVAL_DRY_RUN=1)" >&2
    exit 64
fi

OUT="${EMUQU_EVAL_OUT:-${EMUQU_EVAL_DIR%/}/results-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
LOG="$OUT/xcodebuild.log"

DESTINATION="${EMUQU_EVAL_DESTINATION:-}"
if [[ -z "$DESTINATION" ]]; then
    DESTINATION="platform=iOS Simulator,id=$(scripts/select_simulator_destination.sh Emuqu Emuqu.xcodeproj)" || {
        echo "run_flo_eval: no iOS simulator found; set EMUQU_EVAL_DESTINATION" >&2
        exit 69
    }
fi

# Each variable is exported with the TEST_RUNNER_ prefix only when set, so an
# unset one stays unset in the test process.
for name in EMUQU_EVAL_DIR EMUQU_EVAL_GROK_KEY EMUQU_EVAL_ANTHROPIC_KEY EMUQU_EVAL_OPENAI_KEY \
            EMUQU_EVAL_PROVIDER EMUQU_EVAL_MODEL EMUQU_EVAL_DRY_RUN; do
    if [[ -n "${!name:-}" ]]; then
        export "TEST_RUNNER_${name}=${!name}"
    fi
done
export TEST_RUNNER_EMUQU_EVAL_OUT="$OUT"
# The dataset's local times are Denver's, and the app files nights by the
# device's time zone.
export TEST_RUNNER_TZ="America/Denver"

DERIVED=()
if [[ -n "${EMUQU_EVAL_DERIVED_DATA:-}" ]]; then
    DERIVED=(-derivedDataPath "$EMUQU_EVAL_DERIVED_DATA")
fi

echo "run_flo_eval: results in $OUT"
xcodebuild test "$XCODEBUILD_PINNED" \
    -project Emuqu.xcodeproj -scheme Emuqu ${DERIVED[@]+"${DERIVED[@]}"} \
    -destination "$DESTINATION" \
    -only-testing:EmuquTests/FloAnswerEvalRunner \
    -parallel-testing-enabled NO \
    > "$LOG" 2>&1
status=$?

if (( status != 0 )); then
    echo "run_flo_eval: xcodebuild failed (exit $status); see $LOG" >&2
    tail -n 30 "$LOG" | grep -E "error|failed|Executed" >&2 || true
    exit "$status"
fi
if grep -q "FloAnswerEvalRunner.*skipped" "$LOG"; then
    echo "run_flo_eval: the eval was skipped; the environment did not reach the test process" >&2
    exit 1
fi
if [[ ! -f "$OUT/results.json" ]]; then
    echo "run_flo_eval: no results.json was written; see $LOG" >&2
    exit 1
fi
echo "run_flo_eval: done"
cat "$OUT/summary.md"
