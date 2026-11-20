#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/preflight.sh"

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
# executed rather than as annotated. First run (2026-08-18): 1,444 tests, **zero
# race reports**.
#
# Unit suite only. The UI suite runs the app in a separate process where TSan
# would need to be injected into the runner too, and its wall-clock cost under
# instrumentation is prohibitive for a per-PR gate.
#
# This is slow — a full instrumented build plus an instrumented test run. It is
# its own CI job and is deliberately not in `make ci`.

SCHEME="${SCHEME:-Emuqu}"
PROJECT="${PROJECT:-Emuqu.xcodeproj}"
DERIVED="${TSAN_DERIVED_DATA:-build/DD-tsan}"

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

set +e
xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED" \
    -enableThreadSanitizer YES \
    -only-testing:EmuquTests > "$log" 2>&1
status=$?
set -e
stop_heartbeat
echo "Sanitized build and test run took $(( ($(date +%s) - started) / 60 )) min."

# An empty log would read as zero races and zero failures.
gate_require_nonempty "$log" "the xcodebuild log"

races="$(grep -c 'WARNING: ThreadSanitizer' "$log" || true)"
passed="$(grep -c "' passed" "$log" || true)"
failed="$(grep -c "' failed" "$log" || true)"

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

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "## Thread Sanitizer"
        echo
        echo '```text'
        echo "${races} race reports across ${passed} passing tests"
        echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
fi
