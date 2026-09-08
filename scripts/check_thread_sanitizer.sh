#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/preflight.sh"

# Data-race detection over the unit suite.
#
# The app carries 45 `@unchecked Sendable` / `nonisolated(unsafe)` escapes and
# 84 `DispatchQueue` sites, in Swift 5 language mode where the compiler treats
# `Sendable` diagnostics as advisory. `check_unchecked_sendable.sh` proves the
# *count* of those escapes has not grown; it can prove nothing about whether any
# single one is correct.
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
trap 'rm -f "$log"' EXIT

echo "Running the unit suite under Thread Sanitizer (this takes several minutes)…"

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
    echo "ERROR: the sanitized test run failed (no races, so this is a test failure):" >&2
    grep "' failed" "$log" | head -20 >&2
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
