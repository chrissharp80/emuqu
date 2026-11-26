#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/preflight.sh"
source "$(dirname "$0")/lib/xcodebuild.sh"

# Data-race detection over the unit suite.
#
# The app builds in Swift 6 language mode with complete strict concurrency
# (`check_strict_concurrency_enabled.sh`), but it still carries
# `@unchecked Sendable` / `nonisolated(unsafe)` escapes, counted against
# `.ci/unchecked_sendable_budget.txt`, and `DispatchQueue` sites that the
# compiler takes on trust. `check_unchecked_sendable.sh` proves the *count* of
# those escapes has not grown; it can prove nothing about whether any single one
# is correct.
#
# Thread Sanitizer is the only thing that can. It instruments every memory
# access and reports actual races at runtime, so it tests the escapes as
# executed rather than as annotated.
#
# Unit suite only. The UI suite runs the app in a separate process where TSan
# would need to be injected into the runner too, and its wall-clock cost under
# instrumentation is prohibitive for a per-PR gate.
#
# This is slow — a full instrumented build plus an instrumented test run. It is
# its own CI job, and `make ci` runs it after the static gates.
#
# ## Why a clean result here means something
#
# TSan prints its reports on the test host's stderr. Two things carry the gate:
#
#   * `-parallel-testing-enabled NO`. `Emuqu.xctestplan` marks EmuquTests
#     parallelizable, and with parallel testing on, xcodebuild runs the host in
#     simulator clones whose stderr goes to per-clone logs in the result bundle,
#     not to the output this script reads. A race there leaves no line here.
#   * A planted race in the same process. On CI runners a sanitized test host
#     is sometimes blind for its whole life: the same build on the same machine
#     reports a race in one process and nothing in the next. A canary in a
#     separate run proves only that that other process could see races. So the
#     suite runs with `EMUQU_TSAN_CANARY=1`, `ThreadSanitizerCanaryTests` races
#     inside it, and the run counts only if the canary's report is in its log.
#     A run without it was blind and proves nothing; it is retried on a fresh
#     process, up to TSAN_ATTEMPTS runs, and the gate fails if every one was.
#
# A race must not end the host: on the simulator the sanitizer halts on its
# first report unless told `halt_on_error=0`, and a halt on the canary would
# leave the rest of the suite to a relaunched process the canary never
# vouched for. So the host gets `TSAN_OPTIONS=halt_on_error=0`, the canary's
# report and any other land in the same log, and every report other than the
# `verify_gates_fail.sh` plants a race, a blind host, parallel testing, a
# canary that is not asked to race and the halt left on, against a stand-in
# xcodebuild.

SCHEME="${SCHEME:-Emuqu}"
PROJECT="${PROJECT:-Emuqu.xcodeproj}"
DERIVED="${TSAN_DERIVED_DATA:-build/DD-tsan}"
ATTEMPTS="${TSAN_ATTEMPTS:-2}"
# The canary's test name, which every report on its race carries: a report is
# symbolicated to a file and line on some runs and only to the binary and the
# function on others.
CANARY_MARK="testUnsynchronizedWritesRaceWhenTheCanaryIsRequested"

if [[ -z "${DESTINATION:-}" ]]; then
    DESTINATION="$("$(dirname "$0")/select_simulator_destination.sh" "$SCHEME" "$PROJECT")"
fi

log="$(gate_mktemp tsan)" || exit $?
heartbeat=""
stop_heartbeat() {
    [[ -n "$heartbeat" ]] || return 0
    # The loop's own `sleep` is a child of it; end that too, or it outlives the script.
    pkill -P "$heartbeat" 2>/dev/null || true
    kill "$heartbeat" 2>/dev/null || true
    wait "$heartbeat" 2>/dev/null || true
    heartbeat=""
}
trap 'stop_heartbeat; rm -f "$log"' EXIT

# One instrumented `xcodebuild test` run of the unit suite into "$log",
# serial, with the canary asked to race. Returns xcodebuild's status.
run_sanitized() {
    env TEST_RUNNER_EMUQU_TSAN_CANARY=1 TEST_RUNNER_TSAN_OPTIONS=halt_on_error=0 \
        xcodebuild test \
        "$XCODEBUILD_PINNED" \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED" \
        -enableThreadSanitizer YES \
        -parallel-testing-enabled NO \
        "-only-testing:EmuquTests" > "$log" 2>&1
}

echo "Running the unit suite under Thread Sanitizer (20 to 40 minutes on a CI runner)…"

# xcodebuild writes only to the log, so without this the step prints nothing
# for half an hour and a slow run looks the same as a hung one. Once a minute,
# say how long it has run and how many tests have passed so far.
started="$(date +%s)"
(
    while sleep 60; do
        done_so_far="$(grep -c "' passed" "$log" 2>/dev/null || true)"
        echo "  $(( ($(date +%s) - started) / 60 )) min: ${done_so_far:-0} tests passed so far"
    done
) 2>/dev/null &
heartbeat=$!

attempt=0
while :; do
    attempt=$(( attempt + 1 ))
    set +e
    run_sanitized
    status=$?
    set -e
    gate_require_nonempty "$log" "the xcodebuild log"
    canary_races="$(grep 'SUMMARY: ThreadSanitizer' "$log" | grep -c "$CANARY_MARK" || true)"
    echo "Run ${attempt}: $(( ($(date +%s) - started) / 60 )) min so far; canary race reports: ${canary_races}."
    (( canary_races > 0 || attempt >= ATTEMPTS )) && break
    echo "Run ${attempt} was blind: the canary's planted race left no report, so this process could not see races. Running again."
done
stop_heartbeat

if (( canary_races == 0 )); then
    echo >&2
    echo "ERROR: in ${attempt} run(s), the planted race in ThreadSanitizerCanaryTests was never reported." >&2
    echo "A run whose own canary goes unseen could not see races, so its clean result is evidence of nothing." >&2
    echo "--- every sanitizer line in the last run ---" >&2
    grep -iE 'sanitizer|tsan' "$log" | grep -v 'xcodebuild\|-sanitize' >&2 || echo "(none)" >&2
    exit 1
fi

# Test CASES, not suites: a `Test Suite '…' passed` line is not a test that ran.
# Serial runs write `Test Case '-[EmuquTests.Foo testBar]' passed (…)`; the
# `Test case 'Foo.testBar()' passed on …` form is counted too.
all_races="$(grep -c 'SUMMARY: ThreadSanitizer' "$log" || true)"
races=$(( all_races - canary_races ))
passed="$(grep -cE "Test [Cc]ase '[^']+' passed" "$log" || true)"
failed="$(grep -cE "Test [Cc]ase '[^']+' failed" "$log" || true)"

echo "Thread Sanitizer: the canary's race was reported; ${races} other race reports across ${passed} passing tests (${failed} failed)."

if (( races > 0 )); then
    echo >&2
    echo "ERROR: Thread Sanitizer reported ${races} data race(s) besides the canary's:" >&2
    grep 'SUMMARY: ThreadSanitizer' "$log" | grep -v "$CANARY_MARK" >&2 || true
    grep -B 2 -A 30 'WARNING: ThreadSanitizer' "$log" >&2
    exit 1
fi

if (( status != 0 )); then
    echo >&2
    if (( failed > 0 )); then
        echo "ERROR: the sanitized test run failed (no races, so this is a test failure):" >&2
        # `|| true`: under pipefail, head closing the pipe early would end the
        # script here with grep's SIGPIPE status instead of xcodebuild's.
        grep "' failed" "$log" | head -20 >&2 || true
    else
        # No test failed, so the run never got that far: the build failed or
        # the test host crashed. Print why, or the CI log says nothing.
        echo "ERROR: the sanitized run failed before any test failed (build error or test host crash):" >&2
        # `|| true`: no marker line is a normal outcome here, and under
        # `set -e -o pipefail` grep's status 1 would end the script before the
        # log tail and with the wrong exit status.
        grep -E "error:|Testing failed|crashed|Restarting after unexpected exit|The following build commands failed" "$log" \
            | head -40 >&2 || true
        echo "--- last 40 lines of the xcodebuild log ---" >&2
        tail -40 "$log" >&2
    fi
    exit "$status"
fi

# Zero races means nothing when nothing ran. A run that selects no tests (a
# renamed target, a filter that matches nothing, a test bundle that never
# loaded) exits 0 with no warnings, which is a pass that measured nothing.
if (( passed == 0 )); then
    echo >&2
    echo "ERROR: xcodebuild exited 0 but no test case ran under Thread Sanitizer," >&2
    echo "so zero race reports is not evidence of anything." >&2
    echo "--- last 40 lines of the xcodebuild log ---" >&2
    tail -40 "$log" >&2
    exit 1
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "## Thread Sanitizer"
        echo
        echo '```text'
        echo "${races} race reports across ${passed} passing tests"
        echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
fi
