#!/usr/bin/env bash
# Runs verify_tests_fail.sh's own run_suite against a stand-in xcodebuild and
# checks how each outcome is classified: an interrupted run (tests started,
# non-zero exit, no assertion failed) must not read as a catch, and a recorded
# assertion failure must. Exit 0 when both hold, 1 otherwise.
set -uo pipefail
cd "$(dirname "$0")/../.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
eval "$(sed -n '/^run_suite() {/,/^}/p' scripts/verify_tests_fail.sh)"
BACKUP_DIR="$work"
XCODEBUILD_PINNED="-onlyUsePackageVersionsFromResolvedFile" PROJECT="p" SCHEME="s" DEST="d" DERIVED="$work/dd"

# classify <stand-in output>: run_suite's result for a run that prints it and exits 65.
classify() {
    printf '#!/bin/sh\ncat <<"OUT"\n%s\nOUT\nexit 65\n' "$1" > "$work/bin/xcodebuild"
    chmod +x "$work/bin/xcodebuild"
    PATH="$work/bin:$PATH" run_suite "EmuquTests/Probe"
}

interrupted="Test Suite 'Probe' started
Test Case '-[EmuquTests.Probe testA]' started.
Test Case '-[EmuquTests.Probe testA]' passed (0.001 seconds).
Test Case '-[EmuquTests.Probe testB]' started.
Testing failed: lost connection to the test runner"
caught="Test Suite 'Probe' started
Test Case '-[EmuquTests.Probe testA]' started.
/w/EmuquTests/Probe.swift:9: error: -[EmuquTests.Probe testA] : XCTAssertEqual failed: (\"1\") is not equal to (\"2\")
Test Case '-[EmuquTests.Probe testA]' failed (0.001 seconds)."

classify "$interrupted"; got_interrupted=$?
classify "$caught"; got_caught=$?
status=0
if (( got_interrupted == 1 )); then
    echo "mutation_result_probe: an interrupted run with no failed assertion was counted as a catch" >&2
    status=1
fi
if (( got_caught != 1 )); then
    echo "mutation_result_probe: a recorded assertion failure was not counted as a catch (got $got_caught)" >&2
    status=1
fi
exit $status
