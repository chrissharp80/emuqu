#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib/preflight.sh"
source "$(dirname "$0")/lib/xcodebuild.sh"

SCHEME="${SCHEME:-Emuqu}"
PROJECT="${PROJECT:-Emuqu.xcodeproj}"
RESULT_BUNDLE="${RESULT_BUNDLE:-build/TestResults.xcresult}"
MIN_COVERAGE="${MIN_COVERAGE:-}"

# TEST_SCOPE=unit runs only `EmuquTests`; all three floors (overall, logic,
# views) are enforced at either scope.
#
# Cost. The two targets are wildly asymmetric: the unit target runs
# in ~25 SECONDS, the UI target in ~37 MINUTES, and macOS Actions minutes bill at
# 10x. So the full suite costs roughly 400 billable minutes and the unit suite
# costs about 8 — on a 3,000-minute monthly allowance, the difference between
# ~7 CI runs a month and ~300.
#
# Splitting on that seam is also what `check_coverage.sh` already argues for in
# its own header: "Raising LOGIC is the meaningful goal. Raising OVERALL
# materially requires snapshot tests for the view layer." The LOGIC floor is the
# number that reflects test discipline, and the unit target is what moves it.
# The UI target runs at scope `full`: every night on main (ci.yml's schedule),
# on demand, and before every release through testflight.yml, where it covers
# the flows a unit test cannot reach. All three floors apply at either scope.
TEST_SCOPE="${TEST_SCOPE:-full}"
case "$TEST_SCOPE" in
    unit)
        ONLY_TESTING_ARGS="-only-testing:EmuquTests"
        # The floors hold here too. The unit target alone already clears
        # them (about 58% logic and 52% overall against floors of 45 and 44),
        # so a pull request that drops coverage fails on the pull request.
        ;;
    full)
        ONLY_TESTING_ARGS=""
        ;;
    *)
        echo "TEST_SCOPE must be 'unit' or 'full' (got '$TEST_SCOPE')" >&2
        exit 64
        ;;
esac

if [[ -z "${DESTINATION:-}" ]]; then
    DESTINATION="$("$(dirname "$0")/select_simulator_destination.sh" "$SCHEME" "$PROJECT")"
else
    DESTINATION="$DESTINATION"
fi

mkdir -p "$(dirname "$RESULT_BUNDLE")"
rm -rf "$RESULT_BUNDLE"

# Cap the parallel test runners.
#
# Both test targets are marked parallelizable, so xcodebuild clones the
# simulator once per worker and installs + launches the UI-test runner on all of
# them at the same time. Above three concurrent clones this machine loses one
# per run to
#
#   Simulator device failed to launch …xctrunner. The request was denied by
#   service delegate (SBMainWorkspace) for reason: Busy ("Application failed
#   preflight checks")
#
# which fails the whole invocation while every test that did run passed — the
# worst kind of red, because it looks like a product failure and is not.
# Three workers keeps the wall-clock win and stops the contention. Override with
# MAX_TEST_WORKERS if a bigger machine can take more.
MAX_TEST_WORKERS="${MAX_TEST_WORKERS:-3}"

# Simulator CLONES are capped separately from worker count, and at 1.
#
# `-maximum-concurrent-test-simulator-destinations 3` clones the base device
# three times, and the UI-test runner is intermittently missing from a clone:
#
#     Unknown application display identifier
#     com.chrissharp.flowrecovery.uitests.xctrunner
#
# It fires on the first attempt of nearly every run; the retry usually hides
# it, and when both attempts lose, a fully green run is reported as a build
# failure. Cloning is the only thing that
# introduces a device the runner was never installed into, so stop cloning. Unit
# tests still run `MAX_TEST_WORKERS`-wide inside the single destination; only the
# UI suites serialise, which they already effectively did.
MAX_SIM_CLONES="${MAX_SIM_CLONES:-1}"

# Parallel testing OFF — this is the flag that actually stops cloning.
#
# The wrong lever is tempting. `-maximum-concurrent-test-simulator-destinations`
# governs how many distinct DEVICE TYPES run at once; it has nothing to do with
# worker clones. Set it to 1 and nothing changes — the logs still read
# `Test suite 'EmuquUITests' started on 'Clone 2 of iPhone 17'`. Cloning comes
# from `-maximum-parallel-testing-workers`, and the only way to switch it off is
# `-parallel-testing-enabled NO`.
#
# The symptom this closes: the UI-test runner is intermittently missing from a
# clone, which surfaces as
#
#     Unknown application display identifier
#     com.chrissharp.flowrecovery.uitests.xctrunner
#
# It hits roughly half of all first attempts and can survive the retry,
# reporting a fully green suite as a build failure. Serial testing is slower; a
# run that has to be repeated is slower still.
PARALLEL_TESTING="${PARALLEL_TESTING:-NO}"

echo "Running tests on destination: $DESTINATION (max $MAX_TEST_WORKERS parallel workers)"

# NOT DONE HERE: resetting the simulator's privacy grants.
#
# HealthKit authorisation from an earlier run survives `-UITests-FreshInstall`
# (app-container wipes do not touch the device's TCC database), so when a
# couple of UI tests go red for that reason,
# `xcrun simctl privacy <udid> reset all <bundle>` looks like the obvious fix.
#
# It is not. `reset all` denies everything, and dozens of UI tests across every
# suite depend on the app getting past its permission gates — the whole suite
# goes red. A blanket reset trades two environment-sensitive tests for dozens
# of broken ones.
#
# The real cause of those failures is a human killing test runs mid-flight and
# leaving grants behind, not a defect in this pipeline. If a device gets
# contaminated, erase it deliberately:
#
#     xcrun simctl shutdown <udid> && xcrun simctl erase <udid>
#
# A SECOND kind of contamination, and the one more likely to bite, because it
# survives on disk and does not heal itself. The unit suite writes
# through `SessionArchive.shared`, which resolves to the App Group container:
#
#     ~/Library/Developer/CoreSimulator/Devices/<udid>/data/Containers/Shared/
#         AppGroup/<guid>/HRVArchive/
#
# Any run that dies partway — a killed job, a red run, anything — can leave
# index.json holding entries whose session files are gone. Nothing rebuilds the
# index from that state, so `SessionArchive` keeps failing `fileNotFound` on
# those IDs and the tests that open the shared archive go red on EVERY
# subsequent run, with no code change to explain it. If archive tests fail and
# nothing you changed touches the archive, delete that HRVArchive directory —
# it is test scratch, and the app recreates it.
#
# It reaches the UI suites too, and that is the confusing part: the dashboard
# reads the archive on launch, so a stale index fails
# testDashboardShowsRecoveryScoreSection,
# testFreshInstallDashboardShowsTheFirstReadingPrompt and
# testDashboardTabPassesAccessibilityAudit on ANY ordering. Nothing in those
# three tests has anything to do with the archive, which is exactly why this is
# worth writing down.
#
# The residue comes from tests that open the shared archive rather than a
# hermetic `SessionArchive(directory:)` instance — IntegrationTests,
# MorningProcessingServiceTests and ArchiveMigrationParityTests do — so it can
# appear after any of those dies partway, and the recovery step above stays.
#
# A per-service reset for only the suites that assert on denial would work, but
# it belongs next to those suites, not as a blanket step here.

# Retry ONLY the simulator-infrastructure failure, never a test failure.
#
# `xctrunner` intermittently fails to launch with
#
#   The request was denied by service delegate (SBMainWorkspace) for reason:
#   Busy ("Application failed preflight checks")
#
# when the host is loaded. Capping workers at three (above) makes it rarer but
# not impossible, and it tends to land after the unit suite has already gone
# fully green, so the run reports FAILED with zero failed tests. That is the
# worst shape of red: it looks like a product regression and is a busy
# simulator.
#
# The guard is deliberately narrow. The log is grepped for exact infrastructure
# strings, and a run with any test failure those strings do not explain is not
# retried at all: a retry is a second chance for the whole suite, and a test
# that fails intermittently for a real reason would take it and pass. Two
# attempts, then give up honestly.
# Type-checker time limits, applied to THIS build only.
#
# Without these, the frontend's hard limit is the only thing that catches a
# slow expression, and it catches them as an unfixable-looking wall of red on a
# runner — "the compiler is unable to type-check this expression in reasonable
# time", on a file that compiles fine locally — rather than as a diagnostic on
# the machine that wrote the code. Measuring instead of guessing is what
# surfaces a site like a 455-line `EmuquApp.body` modifier chain at 9,766 ms
# that every incremental build pays for.
#
# ## Why these particular numbers
#
# Set from observed RUNNER values, because the local number does not predict
# them. Two data points, both ordinary code:
#
#   * SessionRecoveryService.patchAction    — under  400 ms local, 2,082 ms runner
#   * gradeAdjustedSecondsPerMetre          — under  120 ms local, 2,171 ms runner
#
# That is a spread of roughly 5x to 18x, not a constant factor. Calibrating a
# tight limit from local measurements is therefore unsound, and each
# miscalibration costs a CI run.
#
# So the limits are placed above the highest legitimate runner cost seen
# (~2,200 ms) with real margin, rather than just above the local maximum:
#
#   * 4000 ms per expression
#   * 6000 ms per function body
#
# That still catches what this gate is actually for: the frontend's own hard
# limit — "unable to type-check this expression in reasonable time" — which is
# reached in tens of seconds, an order of magnitude above these. The gate
# exists to name that file and line before the compiler gives up, not to
# police every slow-ish function; sites like the two above get fixed on their
# merits, not because the number demands it.
#
# Deliberately passed on the command line rather than set in the project: a
# local `xcodebuild archive` for the App Store must never fail because a runner
# was busy. This is a CI signal, not a shipping constraint.
TYPE_CHECK_FLAGS="-Xfrontend -warn-long-expression-type-checking=4000 -Xfrontend -warn-long-function-bodies=6000"

# TEST_DERIVED_DATA gives the run its own build folder. Two builds sharing
# Xcode's default one lock and can corrupt its build database, so a CI run
# beside an open Xcode sets this. Unset, xcodebuild's default applies.
DERIVED_DATA_ARGS=""
if [[ -n "${TEST_DERIVED_DATA:-}" ]]; then
    DERIVED_DATA_ARGS="-derivedDataPath ${TEST_DERIVED_DATA}"
fi

run_tests() {
    # shellcheck disable=SC2086
    xcodebuild test \
        "$XCODEBUILD_PINNED" \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -resultBundlePath "$RESULT_BUNDLE" \
        -parallel-testing-enabled "$PARALLEL_TESTING" \
        -maximum-parallel-testing-workers "$MAX_TEST_WORKERS" \
        -maximum-concurrent-test-simulator-destinations "$MAX_SIM_CLONES" \
        $ONLY_TESTING_ARGS \
        $DERIVED_DATA_ARGS \
        OTHER_SWIFT_FLAGS="\$(inherited) $TYPE_CHECK_FLAGS" \
        -enableCodeCoverage YES 2>&1 | tee "$TEST_LOG"
    return "${PIPESTATUS[0]}"
}

# The simulator-infrastructure markers. Each is described where the retry
# decision is made, below.
INFRA_MARKERS='Application failed preflight checks|Failed to get matching snapshots|process main thread busy|Unknown application display identifier'

# Prints each failed test case in the log whose failure the infrastructure
# markers do not explain, one per line; prints nothing when every failure is
# explained.
#
# A failed test case is explained only when XCTest recorded at least one issue
# against it (`<file>:<line>: error: <test> : <message>`) and every such issue
# carries a marker. One assertion message without a marker makes it a real
# failure. So does a failed test with no recorded issue at all (a crash or a
# timeout), and so does a failure line in a format whose test name does not
# appear in the issue lines: anything this cannot attribute counts against the
# retry, never for it.
unexplained_failures() {
    local log="$1" test_case issues
    # `|| true`: no failed test case is a normal outcome (the runner never
    # launched), and under pipefail grep's status 1 would end the caller.
    { grep -oE "Test [Cc]ase '[^']+' failed" "$log" || true; } \
        | sed -E "s/^Test [Cc]ase '(.+)' failed$/\1/" \
        | sort -u \
        | while IFS= read -r test_case; do
            issues="$(grep -F -- "error: ${test_case} :" "$log" || true)"
            if [[ -z "$issues" ]] || grep -qvE "$INFRA_MARKERS" <<< "$issues"; then
                printf '%s\n' "$test_case"
            fi
        done
}

TEST_LOG="$(gate_mktemp xcodebuild-tests)" || exit $?
trap 'rm -f "$TEST_LOG"' EXIT

attempt=1
max_attempts=2
while :; do
    set +e
    run_tests
    test_status=$?
    set -e

    if (( test_status == 0 )); then
        break
    fi

    failed_tests="$(grep -cE "Test [Cc]ase '[^']+' failed" "$TEST_LOG" || true)"
    # Three distinct simulator-infrastructure failures, none of them product
    # faults — each reproduces with the whole suite green and the offending
    # test passing on its own immediately afterwards:
    #
    #   1. "Application failed preflight checks" — xctrunner refused to launch
    #      because the host was busy.
    #   2. "Unable to perform work on main run loop, process main thread busy" /
    #      "Failed to get matching snapshots" — an accessibility snapshot timed
    #      out while three simulator clones competed for the CPU.
    #   3. "Unknown application display identifier ...xctrunner" — the runner
    #      was not installed on the device. Seen right after a simulator erase:
    #      the build products are current but the device no longer has the app,
    #      and the reinstall loses the race with the launch. Also device state,
    #      also not a product fault.
    launch_flake="$(grep -cE "$INFRA_MARKERS" "$TEST_LOG" || true)"

    # When the runner cannot launch, or an accessibility snapshot times out
    # mid-test, XCTest *attributes* the failure to whichever test is in flight,
    # so a marker usually comes with one or more failed tests. A count of zero
    # failures cannot be the condition: it would skip the retry exactly when it
    # is needed.
    #
    # The condition is that every failed test failed BECAUSE of a marker
    # (`unexplained_failures` above). "A genuine failure fails again on the
    # retry" holds only for a deterministic one; a test that fails one run in
    # five for a real reason would pass the second attempt and turn the run
    # green. So when any failure is not the infrastructure's, the run is red
    # now, and the retry is left for the runs it exists for: a busy host and
    # nothing else.
    genuine="$(unexplained_failures "$TEST_LOG")"
    if (( attempt < max_attempts )) && (( launch_flake > 0 )) && [[ -n "$genuine" ]]; then
        echo ""
        echo "Simulator infrastructure failure detected, but not retrying: these"
        echo "test(s) failed for a reason the infrastructure markers do not explain:"
        while IFS= read -r test_case; do
            echo "  ${test_case}"
        done <<< "$genuine"
    elif (( attempt < max_attempts )) && (( launch_flake > 0 )); then
        echo ""
        echo "Simulator infrastructure failure detected (${failed_tests} test(s) blamed, each by a marker)."
        echo "That is contention, not a regression — retrying (attempt $((attempt + 1))/$max_attempts)."
        xcrun simctl shutdown all >/dev/null 2>&1 || true
        sleep 10
        rm -rf "$RESULT_BUNDLE"
        attempt=$((attempt + 1))
        continue
    fi

    exit "$test_status"
done

if [[ -n "$MIN_COVERAGE" ]]; then
    "$(dirname "$0")/check_coverage.sh" "$RESULT_BUNDLE" "$MIN_COVERAGE"
else
    "$(dirname "$0")/check_coverage.sh" "$RESULT_BUNDLE"
fi
