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
# TSan prints its reports on the test host's stderr, and by default a race does
# not fail the test that hit it. Two settings carry the gate:
#
#   * `-parallel-testing-enabled NO`. `Emuqu.xctestplan` marks EmuquTests
#     parallelizable, and with parallel testing on, xcodebuild runs the host in
#     simulator clones whose stderr goes to per-clone logs in the result bundle,
#     not to the output this script reads. A race there leaves no line here.
#   * `TSAN_OPTIONS=halt_on_error=1`, passed to the test host as
#     `TEST_RUNNER_TSAN_OPTIONS` (xcodebuild hands `TEST_RUNNER_`-prefixed
#     variables to the host without the prefix). A race then ends the host, so
#     the run fails even if its report were lost.
#
# Neither is taken on trust. Before the suite, the script runs
# `ThreadSanitizerCanaryTests`, a test that races on purpose when
# `EMUQU_TSAN_CANARY=1`, and requires both a race report in the log and a failed
# run. If either is missing, this setup cannot see races, and the gate fails
# instead of reporting a clean suite. `verify_gates_fail.sh` plants each of
# those two regressions against a stand-in xcodebuild.

SCHEME="${SCHEME:-Emuqu}"
PROJECT="${PROJECT:-Emuqu.xcodeproj}"
DERIVED="${TSAN_DERIVED_DATA:-build/DD-tsan}"

if [[ -z "${DESTINATION:-}" ]]; then
    DESTINATION="$("$(dirname "$0")/select_simulator_destination.sh" "$SCHEME" "$PROJECT")"
fi

log="$(gate_mktemp tsan)" || exit $?
canary_log=""
heartbeat=""
stop_heartbeat() {
    [[ -n "$heartbeat" ]] || return 0
    # The loop's own `sleep` is a child of it; end that too, or it outlives the script.
    pkill -P "$heartbeat" 2>/dev/null || true
    kill "$heartbeat" 2>/dev/null || true
    wait "$heartbeat" 2>/dev/null || true
    heartbeat=""
}
trap 'stop_heartbeat; rm -f "$log" ${canary_log:+"$canary_log"}' EXIT
canary_log="$(gate_mktemp tsan-canary)" || exit $?

# run_sanitized <log> <test selector> [NAME=value ...]
#
# One instrumented `xcodebuild test` run of <test selector> into <log>: serial,
# with a race ending the test host. Each NAME=value is added to xcodebuild's
# environment. Returns xcodebuild's status.
run_sanitized() {
    local out="$1" selector="$2"
    shift 2
    env TEST_RUNNER_TSAN_OPTIONS=halt_on_error=1 "$@" \
        xcodebuild test \
        "$XCODEBUILD_PINNED" \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED" \
        -enableThreadSanitizer YES \
        -parallel-testing-enabled NO \
        "-only-testing:$selector" > "$out" 2>&1
}

echo "Running the unit suite under Thread Sanitizer (20 to 40 minutes on a CI runner)…"

# The canary: a planted race that must be reported in the log and fail the run.
# This run also does the instrumented build that the suite run below reuses.
set +e
run_sanitized "$canary_log" EmuquTests/ThreadSanitizerCanaryTests TEST_RUNNER_EMUQU_TSAN_CANARY=1
canary_status=$?
set -e
gate_require_nonempty "$canary_log" "the canary xcodebuild log"
canary_races="$(grep -c 'WARNING: ThreadSanitizer' "$canary_log" || true)"
if (( canary_races == 0 || canary_status == 0 )); then
    echo >&2
    echo "ERROR: the planted race in ThreadSanitizerCanaryTests was not caught" >&2
    echo "(race reports in the log: ${canary_races}; exit status of the run: ${canary_status})." >&2
    echo "A race has to print 'WARNING: ThreadSanitizer' to this log and fail the run;" >&2
    echo "while it does not, a clean suite run would be evidence of nothing." >&2
    echo "--- last 40 lines of the canary xcodebuild log ---" >&2
    tail -40 "$canary_log" >&2
    exit 1
fi
echo "Canary: the planted race was reported and failed the run."

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

# Without EMUQU_TSAN_CANARY the canary test returns at once, so the suite run
# includes it harmlessly.
set +e
run_sanitized "$log" EmuquTests
status=$?
set -e
stop_heartbeat
echo "Sanitized suite run took $(( ($(date +%s) - started) / 60 )) min."

# An empty log would read as zero races and zero failures.
gate_require_nonempty "$log" "the xcodebuild log"

# Test CASES, not suites: a `Test Suite '…' passed` line is not a test that ran.
# Serial runs write `Test Case '-[EmuquTests.Foo testBar]' passed (…)`; the
# `Test case 'Foo.testBar()' passed on …` form is counted too.
races="$(grep -c 'WARNING: ThreadSanitizer' "$log" || true)"
passed="$(grep -cE "Test [Cc]ase '[^']+' passed" "$log" || true)"
failed="$(grep -cE "Test [Cc]ase '[^']+' failed" "$log" || true)"

echo "Thread Sanitizer: ${races} race reports across ${passed} passing tests (${failed} failed)."

if (( races > 0 )); then
    echo >&2
    echo "ERROR: Thread Sanitizer reported ${races} data race(s):" >&2
    grep -A 20 'WARNING: ThreadSanitizer' "$log" >&2
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
