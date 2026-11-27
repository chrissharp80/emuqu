#!/usr/bin/env bash
#
# Prove the test suite catches a real defect.
#
# ## Why this exists
#
# A passing suite does not demonstrate that the tests would fail if the code
# were wrong. Coverage does not demonstrate that either —
# coverage says a line executed, not that any assertion depended on its result.
# A suite can execute every line of a scoring function and still pass when the
# scores come out inverted.
#
# `verify_gates_fail.sh` already applies this discipline to the GATES: plant a
# violation, require the gate to go red. This is the same idea aimed at the
# TESTS: change the meaning of production code, require the suite to notice.
#
# Deliberately not a mutation-testing framework. A framework mutates everything
# and reports a percentage, which on a codebase this size is a number nobody
# acts on and a CI bill nobody wants. This mutates a small, chosen set of
# high-stakes behaviours — the arithmetic behind a recovery score, the
# threshold that labels it, the branch that decides whether health data is
# written encrypted — and requires each one to be caught. A survivor here is
# not a statistic; it names a specific behaviour nothing is asserting.
#
#     ./scripts/verify_tests_fail.sh            # every mutation
#     ./scripts/verify_tests_fail.sh pnn50      # one, by substring
#
# Needs a simulator and a build per mutation, so it is NOT part of `make ci`.
# Run it when the analysis or storage code changes.

#
# ## A note on the mutations themselves
#
# A survivor can be a bug in the script rather than a gap in the suite: a
# mutation that names a suite which does not cover the function it changed, or
# one that rewrites the first `.completeFileProtection` in the file — inside a
# doc comment, so it changes no behaviour and the tests are right to stay
# green.
#
# That is the same failure this repository keeps finding, here in the tool
# built to find it: a check that reports a result while measuring nothing. A
# survivor is only meaningful once the mutation is confirmed to alter behaviour
# and the named suite is confirmed to exercise it.

set -uo pipefail
cd "$(dirname "$0")/.."

source "$(dirname "$0")/lib/preflight.sh"
source "$(dirname "$0")/lib/xcodebuild.sh"

FILTER="${1:-}"
# MUTATION_SHARD="<index>/<count>" runs one share of the mutations, so CI can
# spread them over parallel jobs: a suite's mutations all fall in the share
# of the suite's first appearance, by order, modulo the count.
SHARD="${MUTATION_SHARD:-0/1}"
SHARD_INDEX="${SHARD%/*}"; SHARD_COUNT="${SHARD#*/}"
if ! [[ "$SHARD_INDEX" =~ ^[0-9]+$ && "$SHARD_COUNT" =~ ^[1-9][0-9]*$ ]] || (( SHARD_INDEX >= SHARD_COUNT )); then
    echo "verify_tests_fail: MUTATION_SHARD must be <index>/<count> with index < count, got '$SHARD'." >&2
    exit 64
fi
SUITE_ORDER=$'\n'
GREEN_SUITES=$'\n'
PROJECT="Emuqu.xcodeproj"
SCHEME="Emuqu"
DERIVED="${MUTATION_DERIVED_DATA:-build/MutationDerivedData}"
PASS=0; FAIL=0; SKIP=0; INVALID=0

DEST="$(./scripts/select_simulator_destination.sh "$SCHEME" "$PROJECT")"
if [[ -z "$DEST" ]]; then
    echo "verify_tests_fail: no simulator destination available." >&2
    exit 70
fi

BACKUP_DIR="$(gate_mktemp_dir verify-tests)" || exit $?
TOUCHED=()

backup() { local f="$1"; cp "$f" "$BACKUP_DIR/$(printf '%s' "$f" | tr '/' '_')"; TOUCHED+=("$f"); }
restore_all() {
    local f
    for f in "${TOUCHED[@]:-}"; do
        [[ -z "$f" ]] && continue
        cp "$BACKUP_DIR/$(printf '%s' "$f" | tr '/' '_')" "$f"
    done
    TOUCHED=()
}
gate_acquire_tree_lock "verify_tests_fail.sh"
trap 'restore_all; rm -rf "$BACKUP_DIR"; gate_release_tree_lock' EXIT INT TERM HUP

# Returns 0 = tests passed, 1 = a test failed an assertion, 2 = the BUILD
# failed, 4 = the run stopped without a test failing an assertion (a simulator
# that disconnected, a runner that crashed mid-suite).
#
# Collapsing all three into a single non-zero reports a transient build
# failure as "the suite was already red" and silently skips the mutation —
# several suites at once on a bad run, each of them passing individually. A
# build failure is an infrastructure problem, not evidence about the tests,
# and must not be mistaken for one.
run_suite() {
    local log="$BACKUP_DIR/run.log"
    if xcodebuild test "$XCODEBUILD_PINNED" -project "$PROJECT" -scheme "$SCHEME" -destination "$DEST" \
        -derivedDataPath "$DERIVED" -only-testing:"$1" \
        -parallel-testing-enabled NO >"$log" 2>&1; then
        return 0
    fi
    # No test ever executed => the build (or the runner) failed.
    if grep -qE "\*\* (BUILD|TEST BUILD) FAILED \*\*|error: (Building|Failed to)" "$log" \
       || ! grep -q "Test Suite\|Test Case" "$log"; then
        return 2
    fi
    # Only a recorded assertion failure is evidence about the code under test:
    # XCTest writes one `<file>:<line>: error: -[Suite test] : <message>` line
    # per failed assertion. A non-zero exit after tests started, with none of
    # those, is an interrupted run, and counting it would credit a mutation to
    # a suite that never asserted anything about it.
    if grep -qE ": error: -\[[^]]+\] : " "$log"; then
        return 1
    fi
    return 4
}

# The suite must be green before the mutation, or a red afterwards proves
# nothing about the mutation. Returns 0 when green; otherwise prints the SKIP
# line, counts it, and returns 1.
baseline_green() {
    local name="$1" suite="$2" baseline
    # The tree is restored after every mutation, so a suite seen green on the
    # unmutated source this run is green on it still.
    [[ "$GREEN_SUITES" == *$'\n'"$suite"$'\n'* ]] && return 0
    run_suite "$suite"; baseline=$?
    # One retry: these are usually transient, and a build failure or an
    # interrupted run must not be recorded as evidence about the tests either way.
    if (( baseline == 2 || baseline == 4 )); then run_suite "$suite"; baseline=$?; fi
    if (( baseline == 0 )); then GREEN_SUITES+="$suite"$'\n'; return 0; fi
    if (( baseline == 4 )); then
        printf "  \033[33mSKIP\033[0m  %-30s the run was interrupted twice (not a test result)\n" "$name"
    elif (( baseline == 2 )); then
        printf "  \033[33mSKIP\033[0m  %-30s BUILD failed (not a test result)\n" "$name"
    else
        printf "  \033[33mSKIP\033[0m  %-30s %s was already red\n" "$name" "$suite"
    fi
    SKIP=$((SKIP + 1)); return 1
}

# Did the last run's compile fail in the mutated file itself?
mutation_broke_build() {
    grep -E ':[0-9]+:[0-9]+: error:' "$BACKUP_DIR/run.log" | grep -qF "/$1:"
}

# Runs the suite against the applied mutation and prints how it was judged:
# 1 = a test failed an assertion, 0 = tests passed, 3 = the mutated file does
# not compile, 2 = the build failed for some other reason on two attempts,
# 4 = the run was interrupted on two attempts.
#
# Only 1 is a catch. A mutation that does not compile is reported red by
# xcodebuild without a single test asserting anything; counting that as
# "caught" is how a case reads PASS for a suite that was never exercised.
mutated_result() {
    local suite="$1" file="$2" code
    run_suite "$suite"; code=$?
    if (( code == 4 )) || { (( code == 2 )) && ! mutation_broke_build "$file"; }; then
        run_suite "$suite"; code=$?
    fi
    if (( code == 2 )) && mutation_broke_build "$file"; then code=3; fi
    echo "$code"
}

report_mutation() {
    local name="$1" suite="$2" code="$3"
    case "$code" in
        1) printf "  \033[32mPASS\033[0m  %-30s %s caught it\n" "$name" "$suite"
           PASS=$((PASS + 1)) ;;
        0) printf "  \033[31mFAIL\033[0m  %-30s SURVIVED — %s asserts nothing about this\n" "$name" "$suite"
           FAIL=$((FAIL + 1)) ;;
        3) printf "  \033[31mFAIL\033[0m  %-30s the mutation does not compile — fix the mutation\n" "$name"
           INVALID=$((INVALID + 1)) ;;
        4) printf "  \033[33mSKIP\033[0m  %-30s the run was interrupted twice (not a test result)\n" "$name"
           SKIP=$((SKIP + 1)) ;;
        *) printf "  \033[33mSKIP\033[0m  %-30s BUILD failed after the mutation (not a test result)\n" "$name"
           SKIP=$((SKIP + 1)) ;;
    esac
}

# The share of the mutations `suite` belongs to (see MUTATION_SHARD).
in_this_shard() {
    local suite="$1" position
    [[ "$SUITE_ORDER" == *$'\n'"$suite"$'\n'* ]] || SUITE_ORDER+="$suite"$'\n'
    position="$(printf '%s' "$SUITE_ORDER" | grep -nxF "$suite" | cut -d: -f1)"
    (( (position - 2) % SHARD_COUNT == SHARD_INDEX ))
}

# mutate <name> <suite> <file> <python mutation>
mutate() {
    local name="$1" suite="$2" file="$3" script="$4" code

    in_this_shard "$suite" || return
    if [[ -n "$FILTER" && "$name" != *"$FILTER"* ]]; then return; fi
    baseline_green "$name" "$suite" || return

    backup "$file"
    if ! python3 -c "$script" 2>/dev/null; then
        printf "  \033[33mSKIP\033[0m  %-30s could not apply the mutation\n" "$name"
        restore_all; SKIP=$((SKIP + 1)); return
    fi

    code="$(mutated_result "$suite" "$file")"
    restore_all
    report_mutation "$name" "$suite" "$code"
}

echo "Mutating production behaviour; each mutation must be caught."
echo

# pNN50 counts successive differences over 50 ms. Widening the threshold lowers
# every pNN50 the app reports.
mutate "pnn50_threshold" "EmuquTests/TimeDomainTests" \
    "Emuqu/Sources/Analysis/TimeDomainAnalysis.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/TimeDomainAnalysis.swift');s=p.read_text();assert s.count('abs(\$0) > 50')==1;p.write_text(s.replace('abs(\$0) > 50','abs(\$0) > 75'))"

# SDNN is the standard deviation of the clean RR series. Returning the mean
# instead is the kind of substitution a reader skims past.
mutate "sdnn_returns_mean" "EmuquTests/TimeDomainTests" \
    "Emuqu/Sources/Analysis/TimeDomainAnalysis.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/TimeDomainAnalysis.swift');s=p.read_text();assert s.count('sdnn: standardDeviation(cleanRR, mean: meanRR)')==1;p.write_text(s.replace('sdnn: standardDeviation(cleanRR, mean: meanRR)','sdnn: meanRR'))"

# RMSSD is the headline HRV number. Feeding it the raw series rather than the
# successive differences produces a plausible-looking but wrong value.
mutate "rmssd_wrong_input" "EmuquTests/TimeDomainTests" \
    "Emuqu/Sources/Analysis/TimeDomainAnalysis.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/TimeDomainAnalysis.swift');s=p.read_text();assert s.count('rmssd: rootMeanSquare(diffs)')==1;p.write_text(s.replace('rmssd: rootMeanSquare(diffs)','rmssd: rootMeanSquare(cleanRR)'))"

# The range that decides which verdict word a user sees next to the score.
# Shifting it relabels every score at the top of the dashboard.
mutate "recovery_label_inverted" "EmuquTests/RecoveryScoreCalculatorTests" \
    "Emuqu/Sources/Models/ScoreVerdict.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/ScoreVerdict.swift');s=p.read_text();o='        case 90...100: self = .excellent';assert s.count(o)==1;p.write_text(s.replace(o,'        case 91...100: self = .excellent'))"

# The import path converts HealthKit sleep boundaries into recording offsets.
# A bare `Int64(seconds * 1000)` here TRAPS on a non-finite or out-of-range
# date — and its inputs are dates parsed from a user-supplied file. Removing
# the guard does not merely fail the test, it kills the test runner process,
# which is what ships without it.
mutate "import_offset_unguarded" "EmuquTests/ImportSleepWindowTests" \
    "Emuqu/Sources/Import/ImportSleepWindow.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/ImportSleepWindow.swift');s=p.read_text();o='        guard seconds.isFinite else { return .failure(.notFinite) }';assert s.count(o)==1;p.write_text(s.replace(o,''))"

# Get Me Back is a safety screen. With `.greatestFiniteMagnitude` as the no-fix
# sentinel it crashes whenever the accuracy ribbon draws before GPS locks: the
# sentinel is finite, so an `isFinite` guard passes it, and the label then
# computes `Int(1.8e308)`, which traps.
mutate "gps_no_fix_sentinel_unguarded" "EmuquTests/GPSAccuracyLevelTests" \
    "Emuqu/Sources/Utilities/GPSAccuracyLevel.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/GPSAccuracyLevel.swift');s=p.read_text();o='        guard let meters, meters.isFinite,\n              meters >= Double(Int.min), meters < Double(Int.max) else { return nil }';assert s.count(o)==1;p.write_text(s.replace(o,'        guard let meters else { return nil }'))"

# CoreLocation reports a negative horizontalAccuracy to mean the fix is
# invalid. `case ..<10` matches -1 and reports \"GPS strong\".
mutate "gps_negative_accuracy_reads_good" "EmuquTests/GPSAccuracyLevelTests" \
    "Emuqu/Sources/Utilities/GPSAccuracyLevel.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/GPSAccuracyLevel.swift');s=p.read_text();o='guard let accuracy, accuracy.isFinite, accuracy >= 0 else { return .waiting }';assert s.count(o)==1;p.write_text(s.replace(o,'guard let accuracy, accuracy.isFinite else { return .waiting }'))"

# The live alpha-1 value drives the app's on-screen training-zone guidance.
# An ectopic beat left in the series drags alpha-1 down and makes an easy run
# read as hard. Widening the rejection threshold is the quiet way to break that.
mutate "dfa_ectopic_threshold_widened" "EmuquTests/LiveDFAAnalyzerTests" \
    "Emuqu/Sources/Analysis/LiveDFAAnalyzer.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/LiveDFAAnalyzer.swift');s=p.read_text();o='let ectopicRatio = HRVThresholds.ectopicThresholdPercent';assert s.count(o)==1;p.write_text(s.replace(o,'let ectopicRatio = 0.50'))"

# Scrubbing genuine beat-to-beat variation flattens alpha-1 the other way, so
# the lower bound matters as much as the upper one.
mutate "dfa_cleans_normal_variation" "EmuquTests/LiveDFAAnalyzerTests" \
    "Emuqu/Sources/Analysis/LiveDFAAnalyzer.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/LiveDFAAnalyzer.swift');s=p.read_text();o='let ectopicRatio = HRVThresholds.ectopicThresholdPercent';assert s.count(o)==1;p.write_text(s.replace(o,'let ectopicRatio = 0.05'))"

# The route-TRIMP "whole loop" test is a BAND. As a floor with no upper bound,
# `max` below it is unreachable and every user who runs past their saved route
# is under-credited.
mutate "route_trimp_whole_loop_unbounded" "EmuquTests/RouteTRIMPEstimatorTests" \
    "Emuqu/Sources/Analysis/RouteTRIMPEstimator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/RouteTRIMPEstimator.swift');s=p.read_text();o='        let isWholeLoop = recordedDistance >= savedDist * 0.9\n            && recordedDistance <= savedDist * 1.1';assert s.count(o)==1;p.write_text(s.replace(o,'        let isWholeLoop = recordedDistance >= savedDist * 0.9'))"

# A flat elevation step is not a direction change. DEM data is quantised, so
# treating one as a reversal chops sustained climbs into sub-threshold
# fragments and discards them: a quantised 20 m climb reports ZERO gain.
#
mutate "elevation_flat_step_splits_climb" "EmuquTests/TopoElevationServiceTests" \
    "Emuqu/Sources/Services/TopoElevationService.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/TopoElevationService.swift');s=p.read_text();o='            if sign == 0 { return }                      // flat: not a reversal';assert s.count(o)==1;p.write_text(s.replace(o,'            if sign == 0 { runSign = 0; return }'))"

# The threshold is what keeps DEM wobble out of the gain figure. Dropping it
# inflates elevation on every workout.
mutate "elevation_threshold_removed" "EmuquTests/TopoElevationServiceTests" \
    "Emuqu/Sources/Services/TopoElevationService.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/TopoElevationService.swift');s=p.read_text();o='            guard abs(runSum) >= threshold else { return }';assert s.count(o)==1;p.write_text(s.replace(o,'            guard abs(runSum) >= 0 else { return }'))"

# HRR contamination filtering is two-sided: too strict hides a real 2-minute
# recovery, too loose presents a yawn as physiology. Both directions of the
# 10 bpm tolerance are pinned.
mutate "hrr_tolerance_too_strict" "EmuquTests/HRRMonotonicDropTests" \
    "Emuqu/Sources/Analysis/HRRCaptureService.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/HRRCaptureService.swift');s=p.read_text();o='nonisolated private static let regressionTolerance = 10';assert s.count(o)==1;p.write_text(s.replace(o,'nonisolated private static let regressionTolerance = 0'))"

mutate "hrr_tolerance_too_loose" "EmuquTests/HRRMonotonicDropTests" \
    "Emuqu/Sources/Analysis/HRRCaptureService.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/HRRCaptureService.swift');s=p.read_text();o='nonisolated private static let regressionTolerance = 10';assert s.count(o)==1;p.write_text(s.replace(o,'nonisolated private static let regressionTolerance = 40'))"

# A malformed archive entry must be SKIPPED, not substituted. The tags array
# is decoded on every archive load; turning a bad element into a real tag would
# silently rewrite the user's morning history.
mutate "feeling_tag_garbage_substituted" "EmuquTests/MorningFeelingTagCodecTests" \
    "Emuqu/Sources/Models/MorningFeelingTag.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/MorningFeelingTag.swift');s=p.read_text();o='            if let raw = try? sub.singleValueContainer().decode(String.self),\n               let tag = MorningFeelingTag(rawValue: raw) {\n                result.append(tag)\n            }';assert s.count(o)==1;p.write_text(s.replace(o,'            if let raw = try? sub.singleValueContainer().decode(String.self),\n               let tag = MorningFeelingTag(rawValue: raw) {\n                result.append(tag)\n            } else if let fallback = MorningFeelingTag.allCases.first {\n                result.append(fallback)\n            }'))"

# A short recovered fragment filed as `.overnight` displaces the real
# overnight reading for that date — the user loses the night they recorded.
#
mutate "recovery_short_fragment_as_overnight" "EmuquTests/SessionRecoveryClassificationTests" \
    "Emuqu/Sources/Services/SessionRecoveryService+Backup.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SessionRecoveryService+Backup.swift');s=p.read_text();o='    private static let minBeatsForOvernight = 4_000';assert s.count(o)==1;p.write_text(s.replace(o,'    private static let minBeatsForOvernight = 1'))"

# The window-selection method is persisted in every archived session; a changed
# raw value silently re-labels historical readings.
mutate "window_method_raw_value_drift" "EmuquTests/WindowSelectionMethodTests" \
    "Emuqu/Sources/Models/WindowSelectionMethod.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/WindowSelectionMethod.swift');s=p.read_text();o='    case peakRMSSD';assert s.count(o)==1;p.write_text(s.replace(o,'    case peakRMSSD = \"peak_rmssd\"'))"

# An ambiguous recipient name must surface for disambiguation, never resolve
# to a guess — a PDF health report sent to a coin-flip address cannot be taken
# back.
mutate "email_ambiguous_name_guessed" "EmuquTests/EmailContactResolutionTests" \
    "Emuqu/Sources/Models/EmailContact.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/EmailContact.swift');s=p.read_text();o='        guard matches.count == 1 else { return .ambiguous }';assert s.count(o)==1;p.write_text(s.replace(o,''))"

# `effectiveMaxHR` anchors HR reserve in the Banister TRIMP exponential.
# Reverting Tanaka to `220 - age` under-estimates max HR for older adults,
# inflates HR reserve, and over-weights easy activity — a 4-mile walk read as
# a ~100-TRIMP session.
# The formula lives in `MaxHeartRate` so it can be tested as arithmetic rather
# than through an ambient Calendar.
mutate "max_hr_reverts_to_220_minus_age" "EmuquTests/MaxHeartRateTests" \
    "Emuqu/Sources/Analysis/MaxHeartRate.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/MaxHeartRate.swift');s=p.read_text();o='        let computed = Int((208.0 - 0.7 * Double(age)).rounded())';assert s.count(o)==1;p.write_text(s.replace(o,'        let computed = 220 - age'))"

# An implausible resting HR must not be accepted: it blows up HR reserve and
# every TRIMP figure derived from it.
mutate "resting_hr_accepts_implausible" "EmuquTests/EffectiveSettingsTests" \
    "Emuqu/Sources/Models/UserSettings+Model.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/UserSettings+Model.swift');s=p.read_text();o='        if let user = userRestingHR, user >= 30 { return user }';assert s.count(o)==1;p.write_text(s.replace(o,'        if let user = userRestingHR, user > 0 { return user }'))"

# Normalized power's FOURTH power is what makes it differ from average power.
# Dropping to squared (or to a plain mean) makes every ragged ride read as if
# it were ridden steadily.
mutate "normalized_power_not_fourth_power" "EmuquTests/NormalizedPowerTests" \
    "Emuqu/Sources/Collection/WorkoutSessionLifecycle+Metrics.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutSessionLifecycle+Metrics.swift');s=p.read_text();o='windowMeans.reduce(0) { ' + chr(36) + '0 + pow(' + chr(36) + '1, 4) }';assert s.count(o)==1;p.write_text(s.replace(o,'windowMeans.reduce(0) { ' + chr(36) + '0 + pow(' + chr(36) + '1, 2) }'))"

# The 30-second window is what separates a sustained surge from sample noise.
mutate "normalized_power_window_shrunk" "EmuquTests/NormalizedPowerTests" \
    "Emuqu/Sources/Collection/WorkoutSessionLifecycle+Metrics.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutSessionLifecycle+Metrics.swift');s=p.read_text();o='reduce(0, +) / 30.0 }';assert s.count(o)==1;p.write_text(s.replace(o,'reduce(0, +) / 10.0 }'))"

# The overnight merge offset re-anchors every beat of a child segment onto its
# parent's clock. Truncating instead of rounding loses a millisecond off each
# merge, and dropping the finiteness guard traps on a corrupt stored date.
#
mutate "merge_offset_truncates" "EmuquTests/OvernightMergeOffsetTests" \
    "Emuqu/Sources/Utilities/MillisecondOffset.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/MillisecondOffset.swift');s=p.read_text();o='        return Int64(ms.rounded())';assert s.count(o)==1;p.write_text(s.replace(o,'        return Int64(ms)'))"

# `percentile` must clamp both indices: clamping only the upper one lets p > 1
# read past the end of the array and p < 0 read negatively — both
# out-of-bounds crashes.
#
mutate "percentile_lower_index_unclamped" "EmuquTests/HRVSleepStageClassifierTests" \
    "Emuqu/Sources/Analysis/HRVSleepStageClassifier+Watch.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/HRVSleepStageClassifier+Watch.swift');s=p.read_text();o='        let clamped = p.isNaN ? 0 : min(max(p, 0), 1)';assert s.count(o)==1;p.write_text(s.replace(o,'        let clamped = p'))"

mutate "merge_offset_range_unguarded" "EmuquTests/OvernightMergeOffsetTests" \
    "Emuqu/Sources/Utilities/MillisecondOffset.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/MillisecondOffset.swift');s=p.read_text();o='        guard ms >= -representableLimitMs, ms <= representableLimitMs else { return nil }';assert s.count(o)==1;p.write_text(s.replace(o,''))"

# Zones are % of max HR with zone 2 starting at 60 %. Moving that floor to
# 50 % reads easy efforts as zone 2, which shifts every zone shown and every
# zone-drift cue.
mutate "hr_zone_wrong_band" "EmuquTests/WorkoutGeometryTests" \
    "Emuqu/Sources/Collection/WorkoutGeometry.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutGeometry.swift');s=p.read_text();o='        if pct < 0.60 { return 1 }';assert s.count(o)==1;p.write_text(s.replace(o,'        if pct < 0.50 { return 1 }'))"

# A bearing must wrap to [0, 360). A negative one sends a turn cue the wrong way.
mutate "bearing_not_normalised" "EmuquTests/WorkoutGeometryTests" \
    "Emuqu/Sources/Collection/WorkoutGeometry.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutGeometry.swift');s=p.read_text();o='        return (degrees + 360).truncatingRemainder(dividingBy: 360)';assert s.count(o)==1;p.write_text(s.replace(o,'        return degrees'))"

# Distance is written to Apple Health as PER-TICK DELTAS. Writing the
# cumulative reading instead multiplies the user's recorded distance — and it
# lands in their permanent Health record, not just the app.
mutate "healthkit_distance_written_cumulative" "EmuquTests/HealthKitWorkoutExportTests" \
    "Emuqu/Sources/Collection/HealthKitWorkoutExport.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/HealthKitWorkoutExport.swift');o='            let delta = dist - lastDistance';assert (s:=p.read_text()).count(o)==1;p.write_text(s.replace(o,'            let delta = dist'))"

# Active energy must scale with body mass; dropping it hands every user the
# same calorie burn.
mutate "healthkit_energy_ignores_body_mass" "EmuquTests/HealthKitWorkoutExportTests" \
    "Emuqu/Sources/Collection/HealthKitWorkoutExport.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/HealthKitWorkoutExport.swift');o='mlOxygenPerKgPerMET * bodyWeightKg * minutes';assert (s:=p.read_text()).count(o)==1;p.write_text(s.replace(o,'mlOxygenPerKgPerMET * 75.0 * minutes'))"

# The branch that decides whether a session is written encrypted. If nothing
# asserts on it, the encrypted write can silently regress to a plaintext fallback.
mutate "plaintext_write_undetected" "EmuquTests/PendingEncryptionLedgerTests" \
    "Emuqu/Sources/Storage/ArchivePendingEncryption.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/ArchivePendingEncryption.swift');s=p.read_text();o='return [.atomic, .completeFileProtectionUnlessOpen]';assert s.count(o)==1;p.write_text(s.replace(o,'return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]'))"

# ---------------------------------------------------------------------------
# Mutations for the logic lifted out of the god objects. The tests for that
# code were written for something that was never reachable before, and a test
# nobody has watched fail is worth exactly as much as a gate nobody has watched
# fail, which is the premise of this whole file.
# ---------------------------------------------------------------------------

# MET values become active energy in the user's permanent Health record. A band
# ceiling nudged upward silently under-credits every brisk walk.
mutate "met_walk_band_ceiling_shifted" "EmuquTests/METLookupTests" \
    "Emuqu/Sources/Collection/METLookup.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/METLookup.swift');s=p.read_text();o='        Band(upperKmh: 5.6, mets: 3.5),  // brisk';assert s.count(o)==1;p.write_text(s.replace(o,'        Band(upperKmh: 7.6, mets: 3.5),  // brisk'))"

# Below a walking crawl the pace figure is GPS jitter, not motion. Removing the
# floor turns noise into calories.
mutate "met_crawl_floor_removed" "EmuquTests/METLookupTests" \
    "Emuqu/Sources/Collection/METLookup.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/METLookup.swift');s=p.read_text();o='        guard speedKmh.isFinite, speedKmh >= 1.2 else { return nil }';assert s.count(o)==1;p.write_text(s.replace(o,'        guard speedKmh.isFinite else { return nil }'))"

# The onset-latency ceiling is needed in each of the three sibling detectors.
# Removing it reinstates a 69-minute bogus onset that shrinks a 337-minute
# night to 268 and skews the score.
mutate "hr_sleep_onset_clamp_removed" "EmuquTests/HRSleepEstimatorTests" \
    "Emuqu/Sources/Collection/HRSleepEstimator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/HRSleepEstimator.swift');s=p.read_text();o='        return windowStart\n';assert s.count(o)==1;p.write_text(s.replace(o,'        return sleepOnsetDetected\n'))"

# Taking the FIRST below-to-above crossing lets a bathroom trip at 1:30 AM be
# read as final wake and the rest of the night discarded.
mutate "hr_sleep_wake_takes_first_crossing" "EmuquTests/HRSleepEstimatorTests" \
    "Emuqu/Sources/Collection/HRSleepEstimator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/HRSleepEstimator.swift');s=p.read_text();o='        if let lastAsleepIndex = smoothed.lastIndex(where: { ' + chr(36) + '0.hr < threshold }) {';assert s.count(o)==1;p.write_text(s.replace(o,'        if let lastAsleepIndex = smoothed.firstIndex(where: { ' + chr(36) + '0.hr < threshold }) {'))"

# The 8 BPM floor is what stops a flat overnight trace being split at its own
# noise midpoint and reported as a night of sleep.
mutate "hr_sleep_range_floor_removed" "EmuquTests/HRSleepEstimatorTests" \
    "Emuqu/Sources/Collection/HRSleepEstimator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/HRSleepEstimator.swift');s=p.read_text();o='        guard maxHR - minHR >= 8 else {';assert s.count(o)==1;p.write_text(s.replace(o,'        guard maxHR - minHR >= 0 else {'))"

# Keying rescore on total minutes alone lets Apple's corrected onset (5 min vs
# an HR-guessed 117) land with the same total and leave the score computed
# from the stale window.
mutate "sleep_refresh_ignores_onset_move" "EmuquTests/SleepRefreshPolicyTests" \
    "Emuqu/Sources/Collection/SleepRefreshPolicy.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/SleepRefreshPolicy.swift');s=p.read_text();o='            needsRescore: firstSnapshot || delta >= 20 || onsetMovedMaterially || sourceUpgradedToWatch,';assert s.count(o)==1;p.write_text(s.replace(o,'            needsRescore: firstSnapshot || delta >= 20 || sourceUpgradedToWatch,'))"

# Updating only the display snapshot leaves WindowSelection scoring the stale
# HR-estimated window while the card shows corrected data.
mutate "sleep_refresh_updates_display_only" "EmuquTests/SleepRefreshPolicyTests" \
    "Emuqu/Sources/Collection/SleepRefreshPolicy.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/SleepRefreshPolicy.swift');s=p.read_text();o='            session.sleepStartMs = max(0, MillisecondOffset.between(freshStart, and: session.startDate, fallback: 0))';assert s.count(o)==1;p.write_text(s.replace(o,'            _ = freshStart'))"

# A user who hand-corrected their sleep timeline must not have it overwritten
# on the next foreground.
mutate "sleep_refresh_overwrites_user_edit" "EmuquTests/SleepRefreshPolicyTests" \
    "Emuqu/Sources/Collection/SleepRefreshPolicy.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/SleepRefreshPolicy.swift');s=p.read_text();o='        guard session.sleepUserAdjusted != true || session.sleepSnapshot == nil else {';assert s.count(o)==1;p.write_text(s.replace(o,'        guard true else {'))"

# Short transcripts overlap by chance; lowering their bar to the long-form one
# makes the assistant swallow every "yes" and "okay" as its own echo.
mutate "echo_short_transcript_bar_lowered" "EmuquTests/VoiceEchoHeuristicsTests" \
    "Emuqu/Sources/Assistant/VoiceEchoHeuristics.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/VoiceEchoHeuristics.swift');s=p.read_text();o='    static let shortTranscriptEchoThreshold = 0.85';assert s.count(o)==1;p.write_text(s.replace(o,'    static let shortTranscriptEchoThreshold = 0.6'))"

# Auto-pause and auto-resume have deliberately different thresholds; sharing
# one makes resume feel draggy.
mutate "autopause_resume_threshold_shared" "EmuquTests/AutoPauseDetectorTests" \
    "Emuqu/Sources/Collection/WorkoutTickState.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutTickState.swift');s=p.read_text();o='    static let movingSecondsBeforeAutoResume = 3';assert s.count(o)==1;p.write_text(s.replace(o,'    static let movingSecondsBeforeAutoResume = 15'))"

# A "has it grown" watermark skips every crash-recovery snapshot of a second
# workout until it out-grows the first.
mutate "backup_watermark_uses_greater_than" "EmuquTests/TrackBackupWatermarkTests" \
    "Emuqu/Sources/Collection/WorkoutTickState.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutTickState.swift');s=p.read_text();o='        guard trackCount != self.trackCount';assert s.count(o)==1;p.write_text(s.replace(o,'        guard trackCount > self.trackCount'))"

# The three cursors are OR-ed, so weakening ONE clause is invisible to a test
# that drops all three together — the mutation above can survive on that
# alone. One mutation per clause keeps each one honestly covered.
mutate "backup_watermark_baro_clause_weakened" "EmuquTests/TrackBackupWatermarkTests" \
    "Emuqu/Sources/Collection/WorkoutTickState.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutTickState.swift');s=p.read_text();o='            || baroCount != self.baroCount';assert s.count(o)==1;p.write_text(s.replace(o,'            || baroCount > self.baroCount'))"

mutate "backup_watermark_samples_clause_weakened" "EmuquTests/TrackBackupWatermarkTests" \
    "Emuqu/Sources/Collection/WorkoutTickState.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutTickState.swift');s=p.read_text();o='            || samplesCount != self.samplesCount';assert s.count(o)==1;p.write_text(s.replace(o,'            || samplesCount > self.samplesCount'))"

# Crash recovery decides what happens to data the user cannot re-record.

# The fallback picks the recording with MORE beats. Inverting it silently
# discards part of a workout in favour of the shorter pull.
mutate "recovery_merge_keeps_fewer_beats" "EmuquTests/SessionRecoveryMergeTests" \
    "Emuqu/Sources/Collection/SessionRecoveryMath.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/SessionRecoveryMath.swift');s=p.read_text();o='        strapRR.count > existing.count ? strapRR : existing';assert s.count(o)==1;p.write_text(s.replace(o,'        strapRR.count < existing.count ? strapRR : existing'))"

# The v5 corruption check. Comparing against the preceding value itself rather
# than half of it flags every ordinary strap dropout as corruption.
mutate "v5_discontinuity_flags_ordinary_gaps" "EmuquTests/SessionRecoveryMergeTests" \
    "Emuqu/Sources/Collection/SessionRecoveryMath.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/SessionRecoveryMath.swift');s=p.read_text();o='        return afterBoundary < beforeBoundary / 2';assert s.count(o)==1;p.write_text(s.replace(o,'        return afterBoundary > beforeBoundary / 2'))"

# `Int(Double)` on a non-finite or out-of-range value is a process kill, and
# this runs on a session that has already survived a crash and a merge.
mutate "recovered_avg_hr_unguarded_conversion" "EmuquTests/SessionRecoveryMergeTests" \
    "Emuqu/Sources/Collection/SessionRecoveryMath.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/SessionRecoveryMath.swift');s=p.read_text();o='        guard let meanHR, meanHR.isFinite, meanHR > 0 else { return 0 }';assert s.count(o)==1;p.write_text(s.replace(o,'        guard let meanHR else { return 0 }'))"

# CSV import of another app's export. Its three asymmetries are documented as
# load-bearing and "easy to tidy away by accident" — which is a claim about
# what the tests would catch, and therefore a claim worth mutating.

# A header-named RR column is trusted verbatim; range-checking it would
# silently drop rows the user can see in their own file.
mutate "csv_header_column_range_checked" "EmuquTests/RRDataImporterTests" \
    "Emuqu/Sources/Import/RRDataImporter+CSV.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+CSV.swift');s=p.read_text();o='            return convert(value)\n        }\n        if columns.count == 1 {';assert s.count(o)==1;p.write_text(s.replace(o,'            return validRRValue(convert(value))\n        }\n        if columns.count == 1 {'))"

# The two-column guess is only a heuristic about `timestamp,rr` exports, so it
# must stay range-checked or a wrong guess injects garbage into the series.
mutate "csv_two_column_guess_unchecked" "EmuquTests/RRDataImporterTests" \
    "Emuqu/Sources/Import/RRDataImporter+CSV.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+CSV.swift');s=p.read_text();o='        if let value = Double(columns[1]), value.isFinite {\n            return validRRValue(convert(value))';assert s.count(o)==1;p.write_text(s.replace(o,'        if let value = Double(columns[1]), value.isFinite {\n            return convert(value)'))"

# The first-column fallback fires only when column 1 failed to PARSE, not when
# it parsed and then failed the range check. That distinction is an `else if`
# on the parse, and collapsing it changes which rows survive an import.
mutate "csv_first_column_fallback_on_invalidity" "EmuquTests/RRDataImporterTests" \
    "Emuqu/Sources/Import/RRDataImporter+CSV.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+CSV.swift');s=p.read_text();o='        guard let value = Double(columns[0]), value.isFinite else { return nil }\n        return validRRValue(convert(value))';assert s.count(o)==1;p.write_text(s.replace(o,'        guard let value = Double(columns[0]), value.isFinite else { return nil }\n        return convert(value)'))"

# The delete predicates decide what is erased from the user's permanent
# Health record.
# A summary delete widened to a prefix erases the whole minute-level series.
mutate "health_export_summary_delete_swallows_series" "EmuquTests/HealthExportIdentityTests" \
    "Emuqu/Sources/Collection/HealthExportIdentity.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/HealthExportIdentity.swift');s=p.read_text();o='        externalUUID == summary(sessionId: sessionId, metric: metric)';assert s.count(o)==1;p.write_text(s.replace(o,'        externalUUID.hasPrefix(summary(sessionId: sessionId, metric: metric))'))"

# Without the trailing separator a series delete reaches every metric whose
# name merely starts with this one's.
mutate "health_export_series_delete_loses_separator" "EmuquTests/HealthExportIdentityTests" \
    "Emuqu/Sources/Collection/HealthExportIdentity.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/HealthExportIdentity.swift');s=p.read_text();o='        externalUUID.hasPrefix(seriesPrefix(sessionId: sessionId, metric: metric))';assert s.count(o)==1;p.write_text(s.replace(o,'        externalUUID.hasPrefix(summary(sessionId: sessionId, metric: metric))'))"

# Every identity is session-scoped. An unscoped match makes a re-export of
# today's reading delete every prior session's samples too.
mutate "health_export_identity_drops_session_scope" "EmuquTests/HealthExportIdentityTests" \
    "Emuqu/Sources/Collection/HealthExportIdentity.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/HealthExportIdentity.swift');s=p.read_text();o='        externalUUID == summary(sessionId: sessionId, metric: metric)';assert s.count(o)==1;p.write_text(s.replace(o,'        externalUUID.hasSuffix(metric.rawValue)'))"

# The training-load precedence a historical workout is scored by. Losing the
# METs tier is not hypothetical: without it, treadmill walks stop reaching
# ATL, and it has gone missing before.
mutate "training_load_drops_the_mets_tier" "EmuquTests/TrainingLoadPrecedenceTests" \
    "Emuqu/Sources/Collection/TrainingLoadPrecedence.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/TrainingLoadPrecedence.swift');s=p.read_text();o='        if let m = meta.computedMETLoad, m > 0 { return (m, .mets) }';assert s.count(o)==1;p.write_text(s.replace(o,''))"

# Route history is an ESTIMATE from prior runs of the same route. Ranking it
# above the measured Banister TRIMP credits a guess over a measurement.
mutate "training_load_prefers_route_history_over_banister" "EmuquTests/TrainingLoadPrecedenceTests" \
    "Emuqu/Sources/Collection/TrainingLoadPrecedence.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/TrainingLoadPrecedence.swift');s=p.read_text();o='        if let l = meta.luciaTRIMP, l > 0 { return (l, .banister) }';assert s.count(o)==1;p.write_text(s.replace(o,'        if let e = meta.extrapolatedTRIMP, e > 0 { return (e, .routeHistory) }'))"

# Zero is an ABSENT load, not a load of zero. Accepting it stops a real
# lower-tier value being used and credits the workout nothing.
mutate "training_load_accepts_zero_as_a_load" "EmuquTests/TrainingLoadPrecedenceTests" \
    "Emuqu/Sources/Models/WorkoutMetadata.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/WorkoutMetadata.swift');s=p.read_text();o='        guard let stored = powerTSS, stored > 0 else { return nil }';assert s.count(o)==1;p.write_text(s.replace(o,'        guard let stored = powerTSS else { return nil }'))"

# The AI's spoken zone call. Session-observed PEAK HR as the denominator
# produces "Zone 5 at 100 bpm" when the peak is only 105; the correct
# denominator is the user's physiological max.
mutate "zone_label_uses_session_peak_as_denominator" "EmuquTests/WorkoutMileMarkerEngineTests" \
    "Emuqu/Sources/Assistant/WorkoutMileMarkerEngine.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/WorkoutMileMarkerEngine.swift');s=p.read_text();o='        return HRZone.classify(hr: hr, userMaxHR: context.userMaxHR)?.localizedLabel';assert s.count(o)==1;p.write_text(s.replace(o,'        return HRZone.classify(hr: hr, userMaxHR: context.peakHR)?.localizedLabel'))"

# When every stored-HR point in the window was artifact-rejected the answer is
# nil, so the caller derives a real HR from the RR beats instead. Fabricating
# a 60 bpm sentinel biases the RHR z-score the recovery score is built on.
mutate "stored_hr_fabricates_a_sentinel" "EmuquTests/TimeDomainTests" \
    "Emuqu/Sources/Analysis/TimeDomainAnalysis.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/TimeDomainAnalysis.swift');s=p.read_text();o='        guard !hrValues.isEmpty, hrValues.count == cleanBeats else { return nil }';assert s.count(o)==1;p.write_text(s.replace(o,'        guard !hrValues.isEmpty, hrValues.count == cleanBeats else { return statistics(of: [60]) }'))"

# The classifier's SDNN is POPULATION variance (divisor N) on purpose, kept
# out of `Statistics` because that offers only the sample form (N-1). The two
# differ most on the short windows this classifier runs on.
mutate "sleep_stage_sdnn_uses_sample_variance" "EmuquTests/HRVSleepStageClassifierTests" \
    "Emuqu/Sources/Analysis/HRVSleepStageClassifier.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/HRVSleepStageClassifier.swift');s=p.read_text();o='avgRR, 2) }.reduce(0, +) / Double(validRRs.count)';assert s.count(o)==1;p.write_text(s.replace(o,'avgRR, 2) }.reduce(0, +) / Double(validRRs.count - 1)'))"

# The same-night merge's failure path. Falling through to the standalone write
# when the merge target cannot be read creates exactly the duplicate the merge
# exists to prevent — and the user's report for that is "my session is gone".
mutate "same_night_merge_falls_through_on_read_failure" "EmuquTests/ArchiveIntegrityTests" \
    "Emuqu/Sources/Storage/ArchiveStore+Internal.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/ArchiveStore+Internal.swift');s=p.read_text();o='this pass\", level: .warning)'+ chr(10) + '            throw error';assert s.count(o)==1;p.write_text(s.replace(o,'this pass\", level: .warning)'+chr(10)+'            return nil'))"

# iOS replays a repeating notification's content unchanged every morning, so a
# score baked into the fixed-time fallback is stale from the second day on.
mutate "repeating_push_bakes_in_a_score" "EmuquTests/MorningNotificationPayloadTests" \
    "Emuqu/Sources/Services/MorningNotificationScheduler.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/MorningNotificationScheduler.swift');s=p.read_text();o='        (\"Emuqu\", String(localized: \"Open Emuqu for this morning';assert s.count(o)==1;p.write_text(s.replace(o,'        (\"Emuqu\", String(localized: \"Open Emuqu is 72 for this morning'))"

# NOT MUTATED: `CoachVoiceGuard.endOfSegment`'s two scan loops.
#
# Its comment says folding them into one condition "would also swallow a
# terminator that FOLLOWS whitespace, merging `". ."` into a single segment",
# and that is true. Mutating it produces a survivor — correctly. Work the cases
# through and the fold moves only where stray punctuation lands: the
# scan stops at the first character that is neither a terminator nor
# whitespace, which is the start of the next sentence either way, so no word of
# the reply is ever gained or lost. An equivalent mutant, removed rather than
# forced green with an assertion about punctuation placement nobody depends on.
#
# `testATerminatorAfterWhitespaceDoesNotExtendThePreviousSentence` still covers
# the input shape, because the surrounding-sentence survival it asserts IS a
# property users depend on.

# DFA's detrend is the D in DFA. Without it the exponent still computes, still
# reproduces, and is still "physiological" — it is simply wrong, and it feeds
# the aerobic-threshold estimate.
mutate "dfa_skips_the_detrend" "EmuquTests/DFAReferenceValidationTests" \
    "Emuqu/Sources/Analysis/DFAAnalysis.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/DFAAnalysis.swift');s=p.read_text();o='            let residual = value - (line.intercept + line.slope * Double(index))';assert s.count(o)==1;p.write_text(s.replace(o,'            let residual = value - line.intercept'))"

# The integration step is what turns an interval series into the random walk
# whose growth the exponent measures. Dropping the accumulation leaves a
# number that looks like an exponent and measures nothing.
mutate "dfa_integration_not_cumulative" "EmuquTests/DFAReferenceValidationTests" \
    "Emuqu/Sources/Analysis/DFAAnalysis.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/DFAAnalysis.swift');s=p.read_text();o='            cumSum += rr[i] - mean';assert s.count(o)==1;p.write_text(s.replace(o,'            cumSum = rr[i] - mean'))"

# The launch-time interrupted-workout check narrows the backup set by index
# date before it opens a file. Dropping the date bound hands back every backup
# the app keeps — ninety days of whole beat files, decoded while the user
# waits for the first screen.
mutate "backup_window_ignores_date" "EmuquTests/RawRRBackupTests" \
    "Emuqu/Sources/Storage/RawRRBackup.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/RawRRBackup.swift');s=p.read_text();o='index.filter { ' + chr(36) + '0.captureDate >= cutoff }.map(';assert s.count(o)==1;p.write_text(s.replace(o,'index.map('))"

# A link is not a feed. Green before the first beat is the badge saying all is
# well while nothing is flowing.
mutate "badge_green_before_first_beat" "EmuquTests/StrapConnectionBadgeTests" \
    "Emuqu/Sources/Views/ConnectionPanelViews.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/ConnectionPanelViews.swift');s=p.read_text();o='            return (.orange, String(localized: \"Setting up\", bundle: LanguageManager.appBundle))';assert s.count(o)==1;p.write_text(s.replace(o,'            return (.green, String(localized: \"Connected\", bundle: LanguageManager.appBundle))'))"

# Live heart rate attaches to the peripheral the SDK reported with the link.
# Losing the identifier leaves the subscription nothing to attach to.
mutate "hr_subscription_loses_the_strap" "EmuquTests/StrapNightTests" \
    "Emuqu/Sources/Collection/StrapLinkCoordinator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapLinkCoordinator.swift');s=p.read_text();o='runtime.linkedPeripheralId = peripheralId';assert s.count(o)==1;p.write_text(s.replace(o,'runtime.linkedPeripheralId = nil'))"

# The strap connection lifecycle. A mid-night BLE drop while streaming must
# KEEP the device identity: the session's provenance and the reconnect both
# need it. Clearing it turns a five-second radio glitch into a lost night.
mutate "ble_drop_discards_device_identity" "EmuquTests/PolarConnectionLifecycleTests" \
    "Emuqu/Sources/Collection/StrapLinkCoordinator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapLinkCoordinator.swift');s=p.read_text();o='        clearLinkReadings(preserveDeviceIdentity: wasStreaming)';assert s.count(o)==1;p.write_text(s.replace(o,'        clearLinkReadings(preserveDeviceIdentity: false)'))"

# The H10 records to its own memory independently of BLE. A dropout that
# marks the recording finished loses the night the strap is still writing.
mutate "ble_drop_clears_device_recording_flag" "EmuquTests/PolarConnectionLifecycleTests" \
    "Emuqu/Sources/Collection/StrapLinkCoordinator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapLinkCoordinator.swift');s=p.read_text();o='        clearLinkReadings(preserveDeviceIdentity: wasStreaming)';assert s.count(o)==1;p.write_text(s.replace(o,'        clearLinkReadings(preserveDeviceIdentity: wasStreaming); recording.device.isRecordingOnDevice = false'))"

# `cancelConnection` is documented safe from any state. Without the guard it
# tears down a healthy connection.
mutate "cancel_connection_drops_a_live_connection" "EmuquTests/PolarConnectionLifecycleTests" \
    "Emuqu/Sources/Collection/StrapDiscoveryCoordinator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapDiscoveryCoordinator.swift');s=p.read_text();o='            guard state.connectionState == .connecting, let deviceId = state.pendingDeviceId else { return }';assert s.count(o)==1;p.write_text(s.replace(o,'            guard let deviceId = state.pendingDeviceId ?? state.connectedDeviceId else { return }'))"

# A late callback from a previous connection must not tear down the current
# one. Without the device match, any drop for any strap clears the live link.
mutate "stale_drop_tears_down_current_link" "EmuquTests/PolarConnectionLifecycleTests" \
    "Emuqu/Sources/Collection/StrapLinkCoordinator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapLinkCoordinator.swift');s=p.read_text();o='              deviceId == state.connectedDeviceId || deviceId == state.pendingDeviceId';assert s.count(o)==1;p.write_text(s.replace(o,'              !deviceId.isEmpty'))"

# A session whose strap drops is given the reconnect window. Without the
# deadline nothing ever ends the wait for a strap that is not coming back.
mutate "session_drop_not_given_a_window" "EmuquTests/PolarConnectionLifecycleTests" \
    "Emuqu/Sources/Collection/StrapLinkCoordinator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapLinkCoordinator.swift');s=p.read_text();o='            if wasStreaming { armReconnectDeadline() }';assert s.count(o)==1;p.write_text(s.replace(o,'            _ = wasStreaming'))"

# A lost pairing cannot be repaired by reconnecting. A session waiting on it
# must be told now, not twenty minutes later.
mutate "pairing_loss_leaves_the_session_waiting" "EmuquTests/PolarConnectionLifecycleTests" \
    "Emuqu/Sources/Collection/StrapLinkCoordinator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapLinkCoordinator.swift');s=p.read_text();o='PolarError.pairingLost\n        if wasStreaming { stream.reconnectExhausted = true }';assert s.count(o)==1;p.write_text(s.replace(o,'PolarError.pairingLost\n        _ = wasStreaming'))"

# SDK 8.x refuses a feature call locally until the strap is ready. Treating
# that refusal as a failure abandons a recording the strap would accept a
# second later.
mutate "not_ready_refusal_treated_as_failure" "EmuquTests/PolarConnectionLifecycleTests" \
    "Emuqu/Sources/Collection/StrapLinkControl.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapLinkControl.swift');s=p.read_text();o='            } catch where StrapErrorClassifier.isNotReadyYet(error) {';assert s.count(o)==1;p.write_text(s.replace(o,'            } catch where StrapErrorClassifier.isNotReadyYet(error) && refusals < 0 {'))"

# Every link reset makes the strap enumerate its services again. Resetting
# before a re-subscribe has had its chance keeps a slow strap permanently
# setting up.
mutate "feed_reset_before_resubscribe_had_its_chance" "EmuquTests/StrapFeedHealthTests" \
    "Emuqu/Sources/Collection/StrapFeedHealth.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapFeedHealth.swift');s=p.read_text();o='              inputs.now.timeIntervalSince(resubscribedAt) >= resubscribeGraceSec';assert s.count(o)==1;p.write_text(s.replace(o,'              inputs.now.timeIntervalSince(resubscribedAt) >= 0'))"

# Outside a session nothing is lost by a silent feed; resetting the link there
# only costs the strap another service setup.
mutate "feed_reset_outside_a_session" "EmuquTests/StrapFeedHealthTests" \
    "Emuqu/Sources/Collection/StrapFeedHealth.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapFeedHealth.swift');s=p.read_text();o='        guard inputs.sessionActive,';assert s.count(o)==1;p.write_text(s.replace(o,'        guard true,'))"

# Readiness from one link must not survive into the next.
mutate "readiness_survives_a_lost_link" "EmuquTests/StrapReadinessTests" \
    "Emuqu/Sources/Collection/StrapReadiness.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapReadiness.swift');s=p.read_text();o='        isLinked = false\n        isSettled = false\n        states = [:]';assert s.count(o)==1;p.write_text(s.replace(o,'        isLinked = false\n        isSettled = false'))"

# The SDK's summary means it stopped checking, not that unlisted features are
# absent. Reading it as absence is what left a slow H10 with no heart rate.
mutate "summary_treated_as_absence" "EmuquTests/StrapReadinessTests" \
    "Emuqu/Sources/Collection/StrapReadiness.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapReadiness.swift');s=p.read_text();o='        case .pending: return isSettled ? .unconfirmed : nil';assert s.count(o)==1;p.write_text(s.replace(o,'        case .pending: return isSettled ? .unavailable : nil'))"

# A strap can still hold last night's recording. Accepting a file from before
# the session scores the wrong night.
mutate "old_recording_accepted_for_tonight" "EmuquTests/StrapExerciseDecoderTests" \
    "Emuqu/Sources/Collection/StrapExerciseDecoder.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapExerciseDecoder.swift');s=p.read_text();o='        let earliest = notBefore.addingTimeInterval(-idStampToleranceSeconds)';assert s.count(o)==1;p.write_text(s.replace(o,'        let earliest = notBefore.addingTimeInterval(-1e12)'))"

# The Verity fallback listing returns one entry per sub-file; without grouping
# a night downloads N times over.
mutate "split_recording_listed_per_sub_file" "EmuquTests/StrapOfflineRecordingEntriesTests" \
    "Emuqu/Sources/Collection/StrapOfflineRecordingEntries.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapOfflineRecordingEntries.swift');s=p.read_text();o='        return entries.filter { seen.insert(recordingKey(forPath: path(\$0))).inserted }';assert s.count(o)==1;p.write_text(s.replace(o,'        return entries.filter { seen.insert(path(\$0)).inserted }'))"

# The optical quality gate. The blocker bit is the sensor saying it does not
# trust its own reading; ignoring it puts motion artefact into the night as
# heartbeats, and RMSSD is computed from the differences between them.
mutate "ppi_trusts_blocked_intervals" "EmuquTests/StrapPPIFilterTests" \
    "Emuqu/Sources/Collection/StrapPPIFilter.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapPPIFilter.swift');s=p.read_text();o='        guard sample.blockerBit == 0, sample.ppErrorEstimate <= maxErrorEstimateMs else { return nil }';assert s.count(o)==1;p.write_text(s.replace(o,'        guard sample.ppErrorEstimate <= maxErrorEstimateMs else { return nil }'))"

# 300-2000 ms is 200-30 bpm. Without the range check a 5-second gap becomes a
# beat.
mutate "ppi_accepts_implausible_intervals" "EmuquTests/StrapPPIFilterTests" \
    "Emuqu/Sources/Collection/StrapPPIFilter.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapPPIFilter.swift');s=p.read_text();o='        guard acceptedRange.contains(sample.ppInMs) else { return nil }';assert s.count(o)==1;p.write_text(s.replace(o,'        guard sample.ppInMs > 0 else { return nil }'))"

# The error estimate is in milliseconds and the signal being measured is a few
# tens of ms. Relaxing the cap admits noise as signal.
mutate "ppi_error_cap_relaxed" "EmuquTests/StrapPPIFilterTests" \
    "Emuqu/Sources/Collection/StrapPPIFilter.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapPPIFilter.swift');s=p.read_text();o='    static let maxErrorEstimateMs = 20';assert s.count(o)==1;p.write_text(s.replace(o,'    static let maxErrorEstimateMs = 500'))"

# Each beat is stamped at the elapsed time of the beats before it. A timeline
# that does not advance stacks the whole recording at t=0.
mutate "ppi_timeline_does_not_advance" "EmuquTests/StrapPPIFilterTests" \
    "Emuqu/Sources/Collection/StrapPPIFilter.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapPPIFilter.swift');s=p.read_text();o='            beatMs += Int64(interval)';assert s.count(o)==1;p.write_text(s.replace(o,'            beatMs += 0'))"

# The H10 keeps ONE exercise file. Starting a second recording abandons the
# first, and the night already on the strap is gone. `isRecordingOnDevice` is
# what the STRAP reports — true after a crash or a session started on the
# device itself, when the app believes it is idle.
mutate "strap_start_ignores_device_recording" "EmuquTests/StrapRecordingPolicyTests" \
    "Emuqu/Sources/Collection/StrapRecordingPolicy.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapRecordingPolicy.swift');s=p.read_text();o='        guard recordingState == .idle, !isRecordingOnDevice else { return .alreadyRecording }';assert s.count(o)==1;p.write_text(s.replace(o,'        guard recordingState == .idle else { return .alreadyRecording }'))"

# Starting a recording with no link reports success for a night that is not
# being recorded anywhere.
mutate "strap_start_ignores_connection" "EmuquTests/StrapRecordingPolicyTests" \
    "Emuqu/Sources/Collection/StrapRecordingPolicy.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapRecordingPolicy.swift');s=p.read_text();o='        guard hasAPI, hasDeviceId, connectionState == .connected else { return .notConnected }';assert s.count(o)==1;p.write_text(s.replace(o,'        guard hasAPI, hasDeviceId else { return .notConnected }'))"

# A 'not recording' reading is polled while the app may be mid-start or
# mid-stop. Acting on it drags the state machine backwards out of .starting.
mutate "strap_negative_status_resets_state" "EmuquTests/StrapRecordingPolicyTests" \
    "Emuqu/Sources/Collection/StrapRecordingPolicy.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapRecordingPolicy.swift');s=p.read_text();o='recordingState: current == .recording ? .idle : nil)';assert s.count(o)==1;p.write_text(s.replace(o,'recordingState: .idle)'))"

# A settled .recording the strap denies must return to idle. Left alone, an
# H10 stopped at a workout's end refused every arm for the rest of the night.
mutate "strap_negative_status_keeps_stale_recording" "EmuquTests/StrapRecordingPolicyTests" \
    "Emuqu/Sources/Collection/StrapRecordingPolicy.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapRecordingPolicy.swift');s=p.read_text();o='recordingState: current == .recording ? .idle : nil)';assert s.count(o)==1;p.write_text(s.replace(o,'recordingState: nil)'))"

# Skipping the session-end stop leaves the H10 recording flat into the next
# day, with the battery dead by evening.
mutate "strap_stop_skipped_when_recording" "EmuquTests/StrapRecordingPolicyTests" \
    "Emuqu/Sources/Collection/StrapRecordingPolicy.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapRecordingPolicy.swift');s=p.read_text();o='        return hasAPI && hasDeviceId && isRecordingOnDevice';assert s.count(o)==1;p.write_text(s.replace(o,'        return hasAPI && hasDeviceId && false'))"

# The most expensive failure in the app. The H10 keeps ONE exercise file, so
# starting a workout over a running overnight recording destroys the night.
# Checked before connection state on purpose: a busy strap is busy whether or
# not the link is up.
mutate "hr_source_preempts_overnight_recording" "EmuquTests/WorkoutHRSourceResolverTests" \
    "Emuqu/Sources/Collection/WorkoutHRSourceResolver.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutHRSourceResolver.swift');s=p.read_text();o='        guard !strapIsRecordingOnDevice else { return .strapBusy }';assert s.count(o)==1;p.write_text(s.replace(o,'        guard !strapIsRecordingOnDevice || !strapIsConnected else { return .strapBusy }'))"

# Claiming strap provenance for a workout that captured no RR makes the
# analyzer expect HRV-grade fields that were never recorded.
mutate "hr_source_claims_strap_with_none_available" "EmuquTests/WorkoutHRSourceResolverTests" \
    "Emuqu/Sources/Collection/WorkoutHRSourceResolver.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutHRSourceResolver.swift');s=p.read_text();o='        if hasKnownDevices { return .reconnectThenUseStrap }';assert s.count(o)==1;p.write_text(s.replace(o,'        if !hasKnownDevices { return .reconnectThenUseStrap }'))"

# A connected strap must win outright. Downgrading it throws away the only
# source that yields RMSSD, SDNN and DFA alpha-1.
mutate "hr_source_downgrades_a_connected_strap" "EmuquTests/WorkoutHRSourceResolverTests" \
    "Emuqu/Sources/Collection/WorkoutHRSourceResolver.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutHRSourceResolver.swift');s=p.read_text();o='        guard !strapIsConnected else { return .use(.strap) }';assert s.count(o)==1;p.write_text(s.replace(o,'        guard !strapIsConnected, !isWatchPaired else { return .use(.strap) }'))"

# Watch and none users must never be blocked on hardware they did not ask for.
mutate "hr_source_blocks_watch_users_on_the_strap" "EmuquTests/WorkoutHRSourceResolverTests" \
    "Emuqu/Sources/Collection/WorkoutHRSourceResolver.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutHRSourceResolver.swift');s=p.read_text();o='        guard requested == .strap else { return .use(requested) }';assert s.count(o)==1;p.write_text(s.replace(o,'        guard requested == .strap || requested == .watch else { return .use(requested) }'))"

# Restarting the recogniser while TTS is playing re-arms the mic loop against
# the synthesiser and can cut the assistant off mid-sentence.
mutate "voice_restarts_recognition_while_speaking" "EmuquTests/VoiceTurnPolicyTests" \
    "Emuqu/Sources/Assistant/VoiceTurnPolicy.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/VoiceTurnPolicy.swift');s=p.read_text();o='        return state == .listening';assert s.count(o)==1;p.write_text(s.replace(o,'        return true'))"

# The reported bug — 'alerts wipe out my message'. Speaking a proactive
# trigger clears partialTranscript, so firing one while the user is mid-
# sentence erases what they said.
mutate "voice_trigger_wipes_user_sentence" "EmuquTests/VoiceTurnPolicyTests" \
    "Emuqu/Sources/Assistant/VoiceTurnPolicy.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/VoiceTurnPolicy.swift');s=p.read_text();o='        if state == .listening, hasPartialTranscript { return true }';assert s.count(o)==1;p.write_text(s.replace(o,'        if state == .listening, !hasPartialTranscript { return true }'))"

# A trigger firing over a response being generated talks across the answer
# the user asked for.
mutate "voice_trigger_interrupts_in_flight_response" "EmuquTests/VoiceTurnPolicyTests" \
    "Emuqu/Sources/Assistant/VoiceTurnPolicy.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/VoiceTurnPolicy.swift');s=p.read_text();o='        if hasInFlightLLMTask || isStreamingResponse { return true }';assert s.count(o)==1;p.write_text(s.replace(o,'        if hasInFlightLLMTask, isStreamingResponse { return true }'))"

# Below 150 the zone bands stop being distinguishable and every zone the user
# sees collapses together.
mutate "maxhr_floor_removed" "EmuquTests/MaxHeartRateTests" \
    "Emuqu/Sources/Analysis/MaxHeartRate.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/MaxHeartRate.swift');s=p.read_text();o='        return max(floor, min(computed, ceiling))';assert s.count(o)==1;p.write_text(s.replace(o,'        return min(computed, ceiling)'))"

# A max HR the user measured in a lab must beat the population estimate.
mutate "maxhr_user_entry_ignored" "EmuquTests/MaxHeartRateTests" \
    "Emuqu/Sources/Analysis/MaxHeartRate.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/MaxHeartRate.swift');s=p.read_text();o='        if let userEntered, userEntered >= minimumUserEntered { return min(userEntered, maximumUserEntered) }';assert s.count(o)==1;p.write_text(s.replace(o,'        if let userEntered, userEntered >= minimumUserEntered, birthday == nil { return min(userEntered, maximumUserEntered) }'))"

# A workout that bounced between the phone and the Watch has interleaved
# timestamps. Out of order, successive differences become enormous — and
# RMSSD squares them.
mutate "rr_merge_leaves_series_unsorted" "EmuquTests/WorkoutRRMergeTests" \
    "Emuqu/Sources/Collection/WorkoutRRMerge.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutRRMerge.swift');s=p.read_text();o='        points.sort { '+chr(36)+'0.t_ms < '+chr(36)+'1.t_ms }';assert s.count(o)==1;p.write_text(s.replace(o,'        points.sort { '+chr(36)+'0.t_ms > '+chr(36)+'1.t_ms }'))"

# A watch or sourceless workout never started a strap stream. Adopting that
# buffer fabricates beats from an earlier session, at finalize and on every
# live tick (backup, beat count, heart rate).
mutate "rr_merge_adopts_stale_stream_for_watch_workouts" "EmuquTests/WorkoutRRMergeTests" \
    "Emuqu/Sources/Collection/WorkoutRRMerge.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutRRMerge.swift');s=p.read_text();o='        source == .strap ? streaming : []';assert s.count(o)==1;p.write_text(s.replace(o,'        streaming'))"

# The live tick reads the buffer without asking whose it is.
mutate "workout_tick_reads_stale_strap_buffer" "EmuquTests/WorkoutStrapOwnershipTests" \
    "Emuqu/Sources/Collection/WorkoutTicker+Tick.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutTicker+Tick.swift');s=p.read_text();o='WorkoutRRMerge.liveStrapBuffer(source: lifecycle.activeHRSource, streaming: core.strapStream.streamedRRPoints)';assert s.count(o)==1;p.write_text(s.replace(o,'core.strapStream.streamedRRPoints'))"

# Dismissing an old summary stops whichever stream is live, an overnight's
# included.
mutate "acknowledge_stops_another_sessions_stream" "EmuquTests/WorkoutStrapOwnershipTests" \
    "Emuqu/Sources/Collection/WorkoutRecorder+DeviceFetch.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutRecorder+DeviceFetch.swift');s=p.read_text();o='stream.streamingStartTime == ownStart else {';assert s.count(o)==1;p.write_text(s.replace(o,'stream.streamingStartTime == ownStart || stream.isStreaming else {'))"

# A night re-analysed elsewhere keeps its old reading in the baseline.
mutate "baseline_sync_ignores_a_changed_reading" "EmuquTests/BaselineArchiveSyncTests" \
    "Emuqu/Sources/Collection/BaselineArchiveSync.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/BaselineArchiveSync.swift');s=p.read_text();o='        return abs(archived - held) > rmssdTolerance';assert s.count(o)==1;p.write_text(s.replace(o,'        return abs(archived - held) > rmssdTolerance * 1_000_000'))"

# A full night folded into an insufficient fragment keeps the fragment's class.
mutate "merge_keeps_the_fragments_quality" "EmuquTests/SessionMergeClockTests" \
    "Emuqu/Sources/Storage/SessionMerger.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/SessionMerger.swift');s=p.read_text();o='        existing.hrvDataQuality = imported.hrvDataQuality';assert s.count(o)==1;p.write_text(s.replace(o,'        existing.hrvDataQuality = existing.hrvDataQuality ?? imported.hrvDataQuality'))"

# Acceptance after a fold reads the review card's own id, which the archive
# no longer holds.
mutate "review_acceptance_reads_the_folded_away_id" "EmuquTests/SessionDiscardTests" \
    "Emuqu/Sources/Collection/MorningSessionPipeline+Processing.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/MorningSessionPipeline+Processing.swift');s=p.read_text();o='        foldedId ?? session.id';assert s.count(o)==1;p.write_text(s.replace(o,'        session.id'))"

# The Watch fallback carries strap data the phone never saw. Dropping it
# shortens the series and shifts every window after the gap.
mutate "rr_merge_drops_watch_routed_points" "EmuquTests/WorkoutRRMergeTests" \
    "Emuqu/Sources/Collection/WorkoutRRMerge.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutRRMerge.swift');s=p.read_text();o='        points.append(contentsOf: watchRouted)';assert s.count(o)==1;p.write_text(s.replace(o,'        points.append(contentsOf: watchRouted.dropLast())'))"

# Clearing deletes a recording the user may never have downloaded — after a
# crash, or a session started on the device itself, that is a whole night.
# The rescue exists to save exactly that data, so running it second saves
# nothing.
mutate "strap_clears_before_rescuing" "EmuquTests/StrapStartSequenceTests" \
    "Emuqu/Sources/Collection/StrapStartSequence.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapStartSequence.swift');s=p.read_text();o='        [.rescueExisting, .clearExisting, .beginRecording]';assert s.count(o)==1;p.write_text(s.replace(o,'        [.clearExisting, .rescueExisting, .beginRecording]'))"

# The H10 refuses to start with a stored exercise present (error 106), and
# recording before the rescue overwrites the file being downloaded.
mutate "strap_records_before_clearing" "EmuquTests/StrapStartSequenceTests" \
    "Emuqu/Sources/Collection/StrapStartSequence.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapStartSequence.swift');s=p.read_text();o='        [.rescueExisting, .clearExisting, .beginRecording]';assert s.count(o)==1;p.write_text(s.replace(o,'        [.rescueExisting, .beginRecording, .clearExisting]'))"

# The guarantee is that the rescue comes BEFORE the clear. A check that only
# asks whether a rescue exists would call a clear-then-rescue sequence safe.
mutate "strap_rescue_check_ignores_order" "EmuquTests/StrapStartSequenceTests" \
    "Emuqu/Sources/Collection/StrapStartSequence.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapStartSequence.swift');s=p.read_text();o='        return rescueIndex < clearIndex';assert s.count(o)==1;p.write_text(s.replace(o,'        return true'))"

# The H10 stores a night as intervals with no timestamps; the timeline is the
# accumulation. A timeline that does not advance stacks every beat of an
# overnight recording at t=0.
mutate "exercise_timeline_does_not_advance" "EmuquTests/StrapExerciseDecoderTests" \
    "Emuqu/Sources/Collection/StrapExerciseDecoder.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapExerciseDecoder.swift');s=p.read_text();o='            cumulativeMs += Int64(interval)';assert s.count(o)==1;p.write_text(s.replace(o,'            cumulativeMs += 1'))"

# The ECG path deliberately does NOT filter: an outlier from an H10 is far
# more likely to be a real ectopic beat than sensor noise, and the artifact
# detector judges it with the whole series in view. Filtering here hides it
# from the layer that should decide.
mutate "exercise_drops_implausible_beats" "EmuquTests/StrapExerciseDecoderTests" \
    "Emuqu/Sources/Collection/StrapExerciseDecoder.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapExerciseDecoder.swift');s=p.read_text();o='            points.append(RRPoint(t_ms: cumulativeMs, rr_ms: interval))';assert s.count(o)==1;p.write_text(s.replace(o,'            if interval >= 300, interval <= 2000 { points.append(RRPoint(t_ms: cumulativeMs, rr_ms: interval)) }'))"

# Trusting the app's own "is recording" flag instead of asking the strap loses
# a night the app never saw end: the strap refuses the new recording, and the
# old one is neither recorded nor rescued.
mutate "arming_trusts_the_stale_recording_flag" "EmuquTests/StrapNightTests" \
    "Emuqu/Sources/Collection/StrapRecordingCoordinator+Recording.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapRecordingCoordinator+Recording.swift');s=p.read_text();o='        if await deviceIsRecording() { try await setAsideRunningRecording() }';assert s.count(o)==1;p.write_text(s.replace(o,'        if device.isRecordingOnDevice { try await setAsideRunningRecording() }'))"

# The morning fetch must read the night before anything clears it.
mutate "morning_fetch_skips_the_stop" "EmuquTests/StrapNightTests" \
    "Emuqu/Sources/Collection/StrapRecordingCoordinator+Transfer.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapRecordingCoordinator+Transfer.swift');s=p.read_text();o='                try await self.stopRunningRecording(api: api, deviceId: deviceId, showsProgress: budget.showsProgress)';assert s.count(o)==1;p.write_text(s.replace(o,'                false'))"

# The strap notice waits out the start of a workout: at t=0 nothing has spoken
# yet, so "silent" is the starting state of every workout. Without the grace
# the user is told their strap is missing on the first tick.
mutate "strap_notice_before_strap_can_speak" "EmuquTests/WorkoutTickLogicTests" \
    "Emuqu/Sources/Collection/WorkoutTicker+HRArbitration.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutTicker+HRArbitration.swift');s=p.read_text();o='                  TimeInterval(inputs.recordingElapsedSeconds) > strapNoticeGraceSec,\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"

# Only one thread crashed. Flattening every thread buries the frames that
# matter under hundreds of idle ones, which is how a crash report becomes
# unreadable without being wrong.
mutate "crash_stack_ignores_attributed_thread" "EmuquTests/MetricKitCrashStackTests" \
    "Emuqu/Sources/Utilities/MetricKitCrashStack.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/MetricKitCrashStack.swift');s=p.read_text();o='stacks.filter { \$0[\"threadAttributed\"] as? Bool == true }';assert s.count(o)==1;p.write_text(s.replace(o,'[]'))"

# MetricKit nests callees under `subFrames`. Not recursing yields only the
# outermost frame of each thread — a stack trace with everything below the
# thread entry point missing, including the crash site.
mutate "crash_stack_drops_nested_frames" "EmuquTests/MetricKitCrashStackTests" \
    "Emuqu/Sources/Utilities/MetricKitCrashStack.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/MetricKitCrashStack.swift');s=p.read_text();o='        for sub in frame[\"subFrames\"] as? [[String: Any]] ?? [] {\n            append(sub, into: &out, depth: depth + 1)\n        }\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"

# CoreMotion distance is unvalidated OS input, and the published value is
# divided and `Int(...)`-converted for split index, mile markers and MET pace.
# `Int(Double.nan)` traps. Dropping the finiteness guard publishes NaN.
mutate "pedometer_publishes_unvalidated_distance" "EmuquTests/PedometerSampleTests" \
    "Emuqu/Sources/Collection/WorkoutPedometer.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutPedometer.swift');s=p.read_text();o='guard let meters = rawDistanceMeters, meters.isFinite, meters >= 0,'+chr(10)+'              meters <= Self.maximumPlausibleMeters else { return nil }';assert s.count(o)==1;p.write_text(s.replace(o,'guard let meters = rawDistanceMeters else { return nil }'))"

# CMPedometer reports cadence in steps per SECOND; every display in the app is
# steps per minute. Dropping the conversion under-reports cadence 60x.
mutate "pedometer_cadence_not_converted" "EmuquTests/PedometerSampleTests" \
    "Emuqu/Sources/Collection/WorkoutPedometer.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutPedometer.swift');s=p.read_text();o='        return cadence * 60';assert s.count(o)==1;p.write_text(s.replace(o,'        return cadence'))"

# A workout imported FROM Apple Health is already in Apple Health. Without the
# stamp, the workout backfill exports it straight back as a second,
# Emuqu-authored copy of the user's own Strava run.
mutate "import_writes_health_workouts_back" "EmuquTests/ImportedWorkoutBuilderTests" \
    "Emuqu/Sources/Import/ImportedWorkoutBuilder.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/ImportedWorkoutBuilder.swift');s=p.read_text();o='        if source.alreadyInHealthKit { session.healthKitExportedAt = Date() }\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"

# GPS pace is meaningless on a treadmill, which is why the indoor flag picks a
# different sport. Ignoring it files every treadmill run as an outdoor run.
mutate "import_ignores_indoor_workouts" "EmuquTests/HealthWorkoutImporterTests" \
    "Emuqu/Sources/Import/HealthWorkoutImporter.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/HealthWorkoutImporter.swift');s=p.read_text();o='        case .running: return isIndoor ? .treadmill : .run';assert s.count(o)==1;p.write_text(s.replace(o,'        case .running: return .run'))"

# A HealthKit step sample is a count over a window. A zero-length window makes
# the division `inf`, and the cadence chart converts with `Int(...)`; a window
# that ends before it starts makes it negative. Dropping the window check lets
# the backwards window through as a negative cadence (the zero-length one is
# still stopped by the later `isFinite` guard).
mutate "import_cadence_divides_by_zero_window" "EmuquTests/HealthWorkoutImporterTests" \
    "Emuqu/Sources/Import/HealthWorkoutImporter.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/HealthWorkoutImporter.swift');s=p.read_text();o='            guard seconds > 0, sample.value >= 0 else { return nil }';assert s.count(o)==1;p.write_text(s.replace(o,'            guard sample.value >= 0 else { return nil }'))"

# Emuqu has no swim, no elliptical and no yoga. Falling back to a plausible
# neighbour files a workout under a label that is simply wrong and then hands it
# to pace and TRIMP maths written for a different activity.
mutate "import_guesses_unsupported_sports" "EmuquTests/HealthWorkoutImporterTests" \
    "Emuqu/Sources/Import/HealthWorkoutImporter.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/HealthWorkoutImporter.swift');s=p.read_text();o='        default: return nil\n        }\n    }';assert s.count(o)==1;p.write_text(s.replace(o,'        default: return .run\n        }\n    }'))"

# A rebuild has no stop event to trust. Without the gap rule it annexes the
# rest of the day's incidental steps into the workout and reports an hour's
# walk as five hours of training load.
mutate "rebuild_ignores_activity_gaps" "EmuquTests/ActivityBoutResolverTests" \
    "Emuqu/Sources/Import/ActivityBoutResolver.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/ActivityBoutResolver.swift');s=p.read_text();o='            if sample.start.timeIntervalSince(cursor) > maxGap { break }\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"

# Nothing to rebuild from must stay nil, not become a zero-length workout the
# user is told was restored.
mutate "rebuild_invents_a_bout_from_nothing" "EmuquTests/ActivityBoutResolverTests" \
    "Emuqu/Sources/Import/ActivityBoutResolver.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/ActivityBoutResolver.swift');s=p.read_text();o='        return moved ? cursor : nil';assert s.count(o)==1;p.write_text(s.replace(o,'        return cursor'))"

# The ceiling is the only bound that does not come from the data. A stuck or
# backfilled sample stream must not produce a fourteen-hour walk.
mutate "rebuild_bout_unbounded" "EmuquTests/ActivityBoutResolverTests" \
    "Emuqu/Sources/Import/ActivityBoutResolver.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/ActivityBoutResolver.swift');s=p.read_text();o='            cursor = min(sample.end, ceiling)';assert s.count(o)==1;p.write_text(s.replace(o,'            cursor = sample.end'))"

# Conflating "the file held no beats" with "the file could not be read" reports
# every strapless workout, every import, and every recording that died before
# its first beat as unrecoverable data loss — in the user's Recent Problems
# list, at error level, on every re-archive.
mutate "archive_beatless_reported_as_corrupt" "EmuquTests/ArchiveRRPreservationTests" \
    "Emuqu/Sources/Storage/ArchiveStore+Internal.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/ArchiveStore+Internal.swift');s=p.read_text();o='            return existing.rrSeries.map { .preserved(\$0, viaRawDecode: false) } ?? .noBeatsStored';assert s.count(o)==1;p.write_text(s.replace(o,'            return existing.rrSeries.map { .preserved(\$0, viaRawDecode: false) } ?? .unreadable'))"

# The splice exists so a metadata edit cannot overwrite a night's recording
# with nothing. Skipping it destroys the beat data on the next note, feeling,
# or CloudKit pull.
mutate "archive_metadata_edit_drops_beats" "EmuquTests/ArchiveRRPreservationTests" \
    "Emuqu/Sources/Storage/ArchiveStore+Internal.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/ArchiveStore+Internal.swift');s=p.read_text();o='            session.rrSeries = beats\n';assert s.count(o)==1;p.write_text(s.replace(o,'            session.rrSeries = nil\n'))"

# HealthKit rejects a workout whose collection ends where it began, identically
# every time. Without the forward-duration guard the backfill retries the same
# doomed write on every foreground until the ceiling burns through, re-archiving
# the session each time just to record the failure.
mutate "backfill_retries_zero_length_workout" "EmuquTests/WorkoutBackfillEligibilityTests" \
    "Emuqu/Sources/Collection/HealthKitBackfill.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/HealthKitBackfill.swift');s=p.read_text();o='              endDate > session.startDate\n';assert s.count(o)==1;p.write_text(s.replace(o,'              endDate >= session.startDate\n'))"

# The unarchived-backup count means "beats that exist only in a backup". Marking
# everything archived silences the one signal the user has that a recording is
# stranded outside the archive.
mutate "backup_reconcile_clears_stranded" "EmuquTests/BackupReconcileTests" \
    "Emuqu/Sources/Storage/RawRRBackup+Reconciliation.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/RawRRBackup+Reconciliation.swift');s=p.read_text();o='        index.indices.filter { !index[\$0].archived && archivedSessionIds.contains(index[\$0].id) }';assert s.count(o)==1;p.write_text(s.replace(o,'        index.indices.filter { !index[\$0].archived }'))"

# The screen stays awake during a recording by default. Decoding that key to
# false gives every user whose stored settings predate it auto-lock mid-session
# — the exact behavioural regression the default exists to prevent.
mutate "settings_screen_lock_default_flipped" "EmuquTests/UserSettingsDecodeContractTests" \
    "Emuqu/Sources/Models/UserSettings+Codable.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/UserSettings+Codable.swift');s=p.read_text();o='keepScreenOnDuringRecording = Self.decoded(Bool.self, .keepScreenOnDuringRecording, from: container, default: true)';assert s.count(o)==1;p.write_text(s.replace(o,'keepScreenOnDuringRecording = Self.decoded(Bool.self, .keepScreenOnDuringRecording, from: container, default: false)'))"

# A settings payload must survive a round trip intact. Dropping a field on
# decode silently resets it for everyone on their next launch.
mutate "settings_roundtrip_drops_a_field" "EmuquTests/UserSettingsDecodeContractTests" \
    "Emuqu/Sources/Models/UserSettings+Codable.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/UserSettings+Codable.swift');s=p.read_text();o='        baselineRMSSD = Self.optional(Double.self, .baselineRMSSD, from: container)\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"

# The composite: HRV carries 60 % of a full-signal day. A shifted weight moves
# every score the user sees and must fail a test.
mutate "composite_hrv_weight_shifted" "EmuquTests/RecoveryScoreCalculatorTests" \
    "Emuqu/Sources/Utilities/Constants.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/Constants.swift');s=p.read_text();o='        static let hrv: Double = 0.60';assert s.count(o)==1;p.write_text(s.replace(o,'        static let hrv: Double = 0.50'))"

# An upload with no key must fail closed; sealing that returns the plaintext
# would put health data in iCloud unencrypted.
mutate "cloud_seal_fails_open" "EmuquTests/CloudPayloadCodecTests" \
    "Emuqu/Sources/Storage/CloudPayloadCodec.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudPayloadCodec.swift');s=p.read_text();o='            throw CloudSyncError.encryptionUnavailable\n        }\n        return try seal(payload, with: key)';assert s.count(o)==1;p.write_text(s.replace(o,'            return payload\n        }\n        return try seal(payload, with: key)'))"

# The output guard must stop a model naming atrial fibrillation.
mutate "coach_guard_misses_atrial_fibrillation" "EmuquTests/CoachVoiceGuardTests" \
    "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='\"a-?fib\", \"atrial';assert s.count(o)==1;p.write_text(s.replace(o,'\"zzplanted\", \"zzplanted'))"

# Delete All My Data sweeps every container of everything it does not keep.
mutate "purge_sweep_keeps_everything" "EmuquTests/DataPurgeServiceTests" \
    "Emuqu/Sources/Services/DataPurgeService.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/DataPurgeService.swift');s=p.read_text();o='        for entry in entries where !kept.contains(entry.lastPathComponent) {';assert s.count(o)==1;p.write_text(s.replace(o,'        for entry in entries where kept.contains(entry.lastPathComponent) {'))"

# A restore from another device that cannot be written must leave the session
# deleted and in the Trash, not undeleted with nothing behind it.
mutate "restore_write_failure_drops_deletion" "EmuquTests/CloudPullRecordTests" \
    "Emuqu/Sources/Storage/SessionArchive+StoreAPI.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/SessionArchive+StoreAPI.swift');s=p.read_text();o='            store.reinstateDeletion(session.id, deletedAt: deletedAt)\n';assert s.count(o)==1;p.write_text(s.replace(o,'            _ = deletedAt\n'))"

# A picked GPX file is read whole; one past the limit must be refused unread.
mutate "gpx_file_size_unbounded" "EmuquTests/GPXMalformedInputTests" \
    "Emuqu/Sources/Analysis/GPXImporter.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/GPXImporter.swift');s=p.read_text();o='static let maxFileBytes = 64 * 1024 * 1024';assert s.count(o)==1;p.write_text(s.replace(o,'static let maxFileBytes = Int.max / 2'))"

# A crashed workout's strap recording belongs to workout recovery; Stop and
# Recover filing it as a night lose its route.
mutate "interrupted_workout_strap_taken_as_night" "EmuquTests/StrapRecoveryFlowTests" \
    "Emuqu/Sources/Collection/StrapRecordingGuards.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapRecordingGuards.swift');s=p.read_text();o='guard let state = recordingStore.load(), state.sessionType == .workout else { return false }';assert s.count(o)==1;p.write_text(s.replace(o,'guard let state = recordingStore.load(), state.sessionType == .quick else { return false }'))"

# A rewrite killed between the file and the index must be re-hashed at the
# next launch, or the session fails every read.
mutate "interrupted_rewrite_never_healed" "EmuquTests/ArchiveInterruptionTests" \
    "Emuqu/Sources/Storage/SessionArchive.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/SessionArchive.swift');s=p.read_text();o='        healInterruptedRewrites()\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"

# A delete killed before the Trash move must be finished at the next launch,
# or a restore loses the session's edits.
mutate "interrupted_delete_left_outside_trash" "EmuquTests/ArchiveInterruptionTests" \
    "Emuqu/Sources/Storage/SessionArchive.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/SessionArchive.swift');s=p.read_text();o='        store.finishInterruptedDeletes()\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"

# Consent is read as each cloud request leaves, not once per turn, or a
# summary or tool round goes out after the user withdrew it.
mutate "consent_checked_only_at_dispatch" "EmuquTests/ProviderConsentTrackerTests" \
    "Emuqu/Sources/Assistant/Providers/ProviderStream.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Providers/ProviderStream.swift');s=p.read_text();o='        try await requireConsent(for: provider, services: services)\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"

# The generic CSV path must keep empty fields, or the column after an empty
# one is read as RR.
mutate "csv_empty_fields_dropped" "EmuquTests/RRDataImporterTests" \
    "Emuqu/Sources/Import/RRDataImporter+CSV.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+CSV.swift');s=p.read_text();o='            let columns = Self.fields(of: line, separator: separator)\n';assert s.count(o)==1;p.write_text(s.replace(o,'            let columns = line.split(separator: separator).map { String(\$0).trimmingCharacters(in: .whitespaces) }\n'))"

# A session the history load could not read keeps the copy already shown.
mutate "history_gap_drops_shown_copy" "EmuquTests/SessionDecodeTests" \
    "Emuqu/Sources/Collection/SessionLoad.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/SessionLoad.swift');s=p.read_text();o='let previous = Dictionary(earlier.map { (\$0.id, \$0) }, uniquingKeysWith: { first, _ in first })';assert s.count(o)==1;p.write_text(s.replace(o,'let previous = [UUID: HRVSession]()'))"

# The crash handler's frame walk must stop at a link that leads back down
# the stack, or a corrupt chain spins until the frame limit.
mutate "frame_walk_follows_links_down" "EmuquTests/CrashFrameChainTests" \
    "Emuqu/Sources/Utilities/CrashSignalHandler.c" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/CrashSignalHandler.c');s=p.read_text();o='        if (next <= fp) {\n';assert s.count(o)==1;p.write_text(s.replace(o,'        if (0) {\n'))"

# A replacing baseline rebuild keeps the nights it could not read.
mutate "baseline_rebuild_drops_unread_nights" "EmuquTests/BaselineTrackerTests" \
    "Emuqu/Sources/Analysis/BaselineTracker.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/BaselineTracker.swift');s=p.read_text();o='historicalData = historicalData.filter { point in point.sessionId.map(unreadable.contains) ?? false }';assert s.count(o)==1;p.write_text(s.replace(o,'historicalData = []'))"

# A pause backs the strap's downloaded beats up before the analysis.
mutate "pause_leaves_strap_night_in_memory" "EmuquTests/StrapRecoveryFlowTests" \
    "Emuqu/Sources/Collection/OvernightStreamingCoordinator+Gather.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/OvernightStreamingCoordinator+Gather.swift');s=p.read_text();o='        await keepDownloadedNight(\n';assert s.count(o)==1;p.write_text(s.replace(o,'        _ = (\n'))"

# A Skip as the download finishes keeps the downloaded beats.
mutate "late_skip_drops_download" "EmuquTests/StrapRecoveryFlowTests" \
    "Emuqu/Sources/Collection/OvernightStreamingCoordinator+Streaming.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/OvernightStreamingCoordinator+Streaming.swift');s=p.read_text();o='        if let recording, morning.rescueDownloadedBeats(recording.points(onClockOf: baseSession.startDate), baseSession: baseSession) {\n';assert s.count(o)==1;p.write_text(s.replace(o,'        if let recording, recording.points.isEmpty {\n'))"

# Discard Night leaves nothing in the Trash.
mutate "discard_leaves_night_in_trash" "EmuquTests/RecordingDiscardTests" \
    "Emuqu/Sources/Collection/CollectorSessionControl+Discard.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/CollectorSessionControl+Discard.swift');s=p.read_text();o='        archive.store.discardTrashed(id)\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"

# A file the archive could not read is reported to the tool call resolving.
mutate "failed_read_reported_as_no_data" "EmuquTests/SessionReadWatchTests" \
    "Emuqu/Sources/Storage/SessionArchive.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/SessionArchive.swift');s=p.read_text();o='            SessionReadWatch.failures?.record()\n';assert s.count(o)==2;p.write_text(s.replace(o,''))"

# An extraction still running stores nothing after a clear or Forget everything.
mutate "auto_remember_ignores_clear" "EmuquTests/AutoRememberTests" \
    "Emuqu/Sources/Assistant/ViewModel/AssistantViewModel+Context.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/ViewModel/AssistantViewModel+Context.swift');s=p.read_text();o='factsStore.extractionEpoch == epoch';assert s.count(o)==1;p.write_text(s.replace(o,'epoch == epoch'))"

# A blank timestamp in an Emuqu export is worked out, not rejected.
mutate "blank_emuqu_timestamp_rejected" "EmuquTests/RRDataImporterTests" \
    "Emuqu/Sources/Import/RRDataImporter+FlowHRV.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+FlowHRV.swift');s=p.read_text();o=', !fields[tsIdx].isEmpty else';assert s.count(o)==1;p.write_text(s.replace(o,' else'))"

# An edit from a device that missed a same-night fold keeps the folded beats.
mutate "pull_drops_folded_beats" "EmuquTests/CloudKitSessionFreshnessTests" \
    "Emuqu/Sources/Storage/CloudKitSessionFreshness.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitSessionFreshness.swift');s=p.read_text();o='let kept = keepingBeatsOnlyHere(session, in: &merged)';assert s.count(o)==1;p.write_text(s.replace(o,'let kept = keepingBeatsOnlyHere(remote, in: &merged)'))"

# An unreadable workout counts toward the load from its index entry.
mutate "unreadable_workout_drops_from_load" "EmuquTests/TrainingLoadPrecedenceTests" \
    "Emuqu/Sources/Collection/HealthDataTypes.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/HealthDataTypes.swift');s=p.read_text();o='averageHR: meanHR, maxHR: nil';assert s.count(o)==1;p.write_text(s.replace(o,'averageHR: nil, maxHR: nil'))"

# The score screen counts earlier nights it could not read.
mutate "score_screen_hides_missing_nights" "EmuquTests/SessionDecodeTests" \
    "Emuqu/Sources/Views/MorningResultsView+Parts.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/MorningResultsView+Parts.swift');s=p.read_text();o='guard !shown.isEmpty else { return 0 }';assert s.count(o)==1;p.write_text(s.replace(o,'guard shown.isEmpty else { return 0 }'))"

# Deleting the saved route a workout follows unbinds it.
mutate "deleted_route_still_followed" "EmuquTests/SavedRouteDeletionTests" \
    "Emuqu/Sources/Collection/WorkoutRecorder+SavedRoute.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutRecorder+SavedRoute.swift');s=p.read_text();o='guard route.savedRouteId == id else { return }';assert s.count(o)==1;p.write_text(s.replace(o,'guard route.savedRouteId != id else { return }'))"

# A leading comment is never taken for the CSV header.
mutate "csv_comment_taken_for_header" "EmuquTests/RRDataImporterTests" \
    "Emuqu/Sources/Import/RRDataImporter+CSV.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+CSV.swift');s=p.read_text();o='            .filter { !Self.isComment(\$0) }\n        guard let headerLine';assert s.count(o)==1;p.write_text(s.replace(o,'            .filter { _ in true }\n        guard let headerLine'))"

# Plain text and CSV keep the same beats.
mutate "plain_text_drops_artifact_beats" "EmuquTests/RRDataImporterTests" \
    "Emuqu/Sources/Import/RRDataImporter+CSV.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+CSV.swift');s=p.read_text();o='Self.storableRRRange.contains(converted) ? converted : nil';assert s.count(o)==1;p.write_text(s.replace(o,'HRVConstants.RRInterval.isValid(converted) ? converted : nil'))"

# A file past the import limit is refused before it is read.
mutate "import_size_unbounded" "EmuquTests/RRDataImporterTests" \
    "Emuqu/Sources/Import/RRDataImporter.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter.swift');s=p.read_text();o='        throw ImportError.tooLarge\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"

# A memory save reports success only once it is on disk.
mutate "memory_add_reports_unsaved" "EmuquTests/UserFactsStoreTests" \
    "Emuqu/Sources/Assistant/Chat/UserFactsStore.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Chat/UserFactsStore.swift');s=p.read_text();o='        guard writeKeepingSetAsideCopies(next) else { return .notSaved }\n';assert s.count(o)==1;p.write_text(s.replace(o,'        _ = writeKeepingSetAsideCopies(next)\n'))"

# A pull keeping folded beats must not undo an unlink made on another device.
mutate "pull_undoes_unlink" "EmuquTests/CloudKitSessionFreshnessTests" \
    "Emuqu/Sources/Storage/CloudKitSessionFreshness.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitSessionFreshness.swift');s=p.read_text();o='              Set(local.linkedSessionIds ?? []).isSubset(of: Set(merged.linkedSessionIds ?? []))\n';assert s.count(o)==1;p.write_text(s.replace(o,'              true\n'))"

# One stray quote must not join the rest of a CSV into one record.
mutate "csv_stray_quote_swallows_file" "EmuquTests/RRDataImporterTests" \
    "Emuqu/Sources/Import/RRDataImporter+CSV.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+CSV.swift');s=p.read_text();o='quoteAware: Self.quotesPairUp(in: content))\n            .filter';assert s.count(o)==1;p.write_text(s.replace(o,'quoteAware: true)\n            .filter'))"

# A Health copy of a workout wins over an index estimate of it.
mutate "index_estimate_beats_health_copy" "EmuquTests/TrainingLoadPrecedenceTests" \
    "Emuqu/Sources/Collection/TrainingHealthQueries+Queries.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/TrainingHealthQueries+Queries.swift');s=p.read_text();o='if coversMostOfBoth(archived, hk) { return archived.isIndexEstimate }';assert s.count(o)==1;p.write_text(s.replace(o,'if coversMostOfBoth(archived, hk) { return false }'))"

mutate "facts_dedup_before_reload" "EmuquTests/UserFactsStoreTests" \
    "Emuqu/Sources/Assistant/Chat/UserFactsStore.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Chat/UserFactsStore.swift');s=p.read_text();o='guard !facts.contains(where: { Self.normalizedKey(\$0.text) == key }) else { return .alreadySaved }';assert s.count(o)==1;s=s.replace(o,'');r='        reloadIfUnreadable()\n        guard !unreadableOnDisk else { return .notSaved }';assert s.count(r)==1;p.write_text(s.replace(r,'        '+o+'\n'+r))"

mutate "nested_walk_replaces_estimate" "EmuquTests/TrainingLoadPrecedenceTests" \
    "Emuqu/Sources/Collection/TrainingHealthQueries+Queries.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/TrainingHealthQueries+Queries.swift');s=p.read_text();o='if coversMostOfBoth(archived, hk) { return archived.isIndexEstimate }';assert s.count(o)==1;p.write_text(s.replace(o,'if overlaps(archived, hk) { return archived.isIndexEstimate }'))"

mutate "elite_stray_quote_swallows_file" "EmuquTests/RRDataImporterTests" \
    "Emuqu/Sources/Import/RRDataImporter+EliteHRV.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+EliteHRV.swift');s=p.read_text();o='quoteAware: Self.quotesPairUp(in: content)';assert s.count(o)==1;p.write_text(s.replace(o,'quoteAware: true'))"

mutate "blank_fact_reported_as_failure" "EmuquTests/UserFactsStoreTests" \
    "Emuqu/Sources/Assistant/Chat/UserFactsStore.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Chat/UserFactsStore.swift');s=p.read_text();o='guard !key.isEmpty else { return .nothingToSave }';assert s.count(o)==1;p.write_text(s.replace(o,'guard !key.isEmpty else { return .notSaved }'))"

mutate "strap_part_beats_whole_health_run" "EmuquTests/TrainingLoadPrecedenceTests" \
    "Emuqu/Sources/Collection/TrainingHealthQueries+Queries.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/TrainingHealthQueries+Queries.swift');s=p.read_text();o='return hk.durationMinutes > archived.durationMinutes && overlaps(archived, hk)';assert s.count(o)==1;p.write_text(s.replace(o,'return false'))"

mutate "midfield_quote_joins_records" "EmuquTests/RRDataImporterTests" \
    "Emuqu/Sources/Import/RRDataImporter+CSV.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+CSV.swift');s=p.read_text();o=', inQuotes || atFieldStart { inQuotes.toggle() }';assert s.count(o)==1;p.write_text(s.replace(o,', !atFieldStart || atFieldStart { inQuotes.toggle() }'))"

mutate "assistant_baseline_counts_night_twice" "EmuquTests/ScoreFactorFactsTests" \
    "Emuqu/Sources/Assistant/Facts/BaselineFacts.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Facts/BaselineFacts.swift');s=p.read_text();o='return nights.values.compactMap { night in night.max { (\$0.endDate ?? \$0.date) < (\$1.endDate ?? \$1.date) } }';assert s.count(o)==1;p.write_text(s.replace(o,'return nights.values.flatMap { \$0 }'))"

# "A recovery of 200 m jog" is the rest between reps, not the score. Read as
# a score it is rewritten into a fabricated training prescription.
mutate "recovery_claim_reads_rep_recovery_as_score" "EmuquTests/RecoveryClaimPatternTests" \
    "Emuqu/Sources/Assistant/MetricsVerifier.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MetricsVerifier.swift');s=p.read_text();o='|workouts?|m|meters?|metres?|km|kilometers?|kilometres?|k|mi|miles?|yd|yards?|ft|feet|s|secs?|seconds?|bpm|beats?|w|watts?|laps?|reps?|x|sets?|rounds?|strides?|steps?';assert s.count(o)==1;p.write_text(s.replace(o,'|workouts?'))"

# A list of past nights by weekday is rewritten to today's score.
mutate "verifier_reads_a_named_day_as_today" "EmuquTests/RecoveryClaimPatternTests" \
    "Emuqu/Sources/Assistant/MetricsVerifier.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MetricsVerifier.swift');s=p.read_text();o='\"(?:mon|tues?|wed(?:nes)?|thu(?:rs?)?|fri|sat(?:ur)?|sun)(?:day)?\",';assert s.count(o)==1;p.write_text(s.replace(o,''))"
# A route name the model took from a web page joins the library, and later
# prompts, only on the user's yes.
mutate "route_save_workout_ungated" "EmuquTests/AssistantActionConfirmationTests" \
    "Emuqu/Sources/Assistant/Facts/RoutesAndDevicesFacts.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Facts/RoutesAndDevicesFacts.swift');s=p.read_text();o=') { return unconfirmed }\n        store.add(route)';assert s.count(o)==1;p.write_text(s.replace(o,') { _ = unconfirmed }\n        store.add(route)'))"

# A yes given to one contact's notes must not save a contact carrying other notes.
mutate "contact_add_notes_unbound" "EmuquTests/AssistantActionConfirmationTests" \
    "Emuqu/Sources/Assistant/Facts/AssistantEmailFacts.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Facts/AssistantEmailFacts.swift');s=p.read_text();o='target: [name, email, notes].joined';assert s.count(o)==1;p.write_text(s.replace(o,'target: [name, email].joined'))"

# Under a voice reply the question is not asked until voice has spoken it; a
# workout alert that cut it off leaves nothing a yes can confirm.
mutate "voice_confirmation_counts_unspoken" "EmuquTests/AssistantActionConfirmationTests" \
    "Emuqu/Sources/Assistant/Chat/AssistantActionConfirmations.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Chat/AssistantActionConfirmations.swift');s=p.read_text();o='        request.delivered = !spokenReply';assert s.count(o)==1;p.write_text(s.replace(o,'        request.delivered = true'))"

# A confirmation line cancelled or cut off before it finished playing does not
# deliver the question.
mutate "voice_cancelled_question_delivers" "EmuquTests/VoiceConversationControllerTests" \
    "Emuqu/Sources/Assistant/VoiceConversationController+Speech.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/VoiceConversationController+Speech.swift');s=p.read_text();o='        if finished { assistantViewModel.actionConfirmations.markSpoken(promptTurnID: spoken.turnID) }';assert s.count(o)==1;p.write_text(s.replace(o,'        assistantViewModel.actionConfirmations.markSpoken(promptTurnID: spoken.turnID)'))"

# "Me duele el pecho" or "I cannot breathe" gets the fixed safety reply, not
# the cloud model.
mutate "spoken_symptom_forms_dropped" "EmuquTests/MedicalQueryGuardTests" \
    "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='] + spokenChestPain,';assert s.count(o)==1;p.write_text(s.replace(o,'],'))"

# "I keep thinking about killing myself" gets the crisis reply.
mutate "self_harm_rumination_dropped" "EmuquTests/MedicalQueryGuardTests" \
    "Emuqu/Sources/Assistant/MedicalTermLexicon+SelfHarm.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+SelfHarm.swift');s=p.read_text();o='] + selfHarmRumination,';assert s.count(o)==1;p.write_text(s.replace(o,'],'))"

# A late Apple Health sleep delivery re-scores a night without replacing the
# window the user picked.
mutate "rescore_replaces_picked_window" "EmuquTests/RRCollectorSaveResultTests" \
    "Emuqu/Sources/Collection/SessionReanalysisCoordinator+Listeners.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/SessionReanalysisCoordinator+Listeners.swift');s=p.read_text();assert s.count('reanalyzeSession(session, preserveManualWindow: true)')==1;p.write_text(s.replace('reanalyzeSession(session, preserveManualWindow: true)','reanalyzeSession(session, preserveManualWindow: false)'))"

# Tags and notes picked on the morning card land on the night the archive kept
# after a fold.
mutate "folded_tags_written_to_own_id" "EmuquTests/SessionDiscardTests" \
    "Emuqu/Sources/Views/RecordView+Results.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/RecordView+Results.swift');s=p.read_text();o='try archive.updateTags(archive.archivedId(of: sessionId), tags: tags, notes: notes)';assert s.count(o)==1;p.write_text(s.replace(o,'try archive.updateTags(sessionId, tags: tags, notes: notes)'))"

# The perceived-readiness rating lands on the night the archive kept.
mutate "folded_readiness_written_to_own_id" "EmuquTests/MorningResultsReadinessTests" \
    "Emuqu/Sources/ViewModels/MorningResultsViewModel.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/ViewModels/MorningResultsViewModel.swift');s=p.read_text();o='services.sessionArchive.archivedId(of: session.id)';assert s.count(o)==1;p.write_text(s.replace(o,'session.id'))"

# A fold carries the user's morning feeling.
mutate "fold_drops_morning_feeling" "EmuquTests/ArchivePolicyTests" \
    "Emuqu/Sources/Storage/SessionMerger+UserContent.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/SessionMerger+UserContent.swift');s=p.read_text();o='outcome.adoptMorningFeeling = existing.morningFeeling == nil && imported.morningFeeling != nil';assert s.count(o)==1;p.write_text(s.replace(o,'outcome.adoptMorningFeeling = false'))"

# A rating cleared on the device that missed a fold stays cleared.
mutate "freshness_restores_cleared_rating" "EmuquTests/CloudKitSessionFreshnessTests" \
    "Emuqu/Sources/Storage/CloudKitSessionFreshness.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitSessionFreshness.swift');s=p.read_text();o='        merged.perceivedReadiness = edited.perceivedReadiness\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"

# A sync merge never replaces a window the user picked with the other copy's
# analysis.
mutate "merge_replaces_picked_window" "EmuquTests/CloudKitSessionFreshnessTests" \
    "Emuqu/Sources/Storage/SessionMerger.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/SessionMerger.swift');s=p.read_text();o='existing.windowUserAdjusted != true else { return false }';assert s.count(o)==1;p.write_text(s.replace(o,'existing.windowUserAdjusted != false else { return false }'))"

# An adopted hand-picked window keeps its flag.
mutate "merge_drops_picked_flag" "EmuquTests/ArchivePolicyTests" \
    "Emuqu/Sources/Storage/SessionMerger.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/SessionMerger.swift');s=p.read_text();o='        existing.windowUserAdjusted = imported.windowUserAdjusted\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"

# An on-disk file holding a session the index already lists (under another
# name, or behind a legacy absolute path) must not be adopted as a second entry.
mutate "orphan_scan_ignores_indexed_session_ids" "EmuquTests/ArchiveInterruptionTests" \
    "Emuqu/Sources/Storage/SessionArchive+IndexIdentity.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/SessionArchive+IndexIdentity.swift');s=p.read_text();o='sessionIds = Set(entries.map(';assert s.count(o)==1;p.write_text(s.replace(o,'sessionIds = Set(entries.prefix(0).map('))"

# Two entries of one session id are one recording listed twice; ranking them
# as keeper and loser tombstones the night everywhere.
mutate "dedupe_pairs_a_session_with_itself" "EmuquTests/ArchivePolicyTests" \
    "Emuqu/Sources/Storage/ArchiveMigrations+Steps.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/ArchiveMigrations+Steps.swift');s=p.read_text();o='let unlinked = SessionArchiveEntry.oneEntryPerSession(dayEntries';assert s.count(o)==1;p.write_text(s.replace(o,'let unlinked = (dayEntries'))"

# Launch rewrites legacy absolute paths to bare names and collapses same-id entries.
mutate "boot_skips_index_normalisation" "EmuquTests/ArchiveInterruptionTests" \
    "Emuqu/Sources/Storage/SessionArchive.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/SessionArchive.swift');s=p.read_text();o='normalizeIndexIdentity()\n        reconcileOrphanFiles()';assert s.count(o)==1;p.write_text(s.replace(o,'reconcileOrphanFiles()'))"

# A live backup pulled from another device is that device's crash-safety copy
# while it records; retiring it because a scan here pulled it deletes it mid-night.
mutate "pulled_live_backup_retired_from_icloud" "EmuquTests/LostSessionRecoveryTests" \
    "Emuqu/Sources/Services/SessionRecoveryService.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SessionRecoveryService.swift');s=p.read_text();o='? .retire : .keep';assert s.count(o)==1;p.write_text(s.replace(o,'? .retire : .retire'))"

# An import older than the stored nights is scored against its archived window,
# not the absolute RMSSD bands.
mutate "old_import_skips_archive_baseline" "EmuquTests/SessionImportScoringTests" \
    "Emuqu/Sources/Collection/ImportScoring.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/ImportScoring.swift');s=p.read_text();o='oldestArchivedNight: oldest) else {';assert s.count(o)==1;p.write_text(s.replace(o,'oldestArchivedNight: oldest.flatMap { _ in nil }) else {'))"

# The strap beats a saved night was scored on, rescued beside its larger
# stream backup, must not stay behind as a phantom lost session.
mutate "night_rescue_left_after_save" "EmuquTests/StrapRecoveryFlowTests" \
    "Emuqu/Sources/Collection/MorningSessionPipeline+Processing.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/MorningSessionPipeline+Processing.swift');s=p.read_text();o='if usedDevice { nightRescue';assert s.count(o)==1;p.write_text(s.replace(o,'if usedDevice && devicePoints.isEmpty { nightRescue'))"

# A deletion applied from another device keeps the tombstone's time, so a Trash
# restore made after it there still wins.
mutate "remote_deletion_dated_by_apply_time" "EmuquTests/CloudPullRecordTests" \
    "Emuqu/Sources/Storage/CloudPullCoordinator+Fetch.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudPullCoordinator+Fetch.swift');s=p.read_text();o='try manager.archive.deleteWithoutTrash(sessionId, deletedAt: deletedAt)';assert s.count(o)==1;p.write_text(s.replace(o,'try manager.archive.deleteWithoutTrash(sessionId, deletedAt: nil)'))"

# A Watch End queued out of range ends the workout at the tap. Ending it on
# arrival saves the time after the tap as workout time.
mutate "watch_stop_ends_at_arrival" "EmuquTests/WorkoutStopTimeTests" \
    "Emuqu/Sources/Collection/WorkoutRecorder+StopTime.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutRecorder+StopTime.swift');s=p.read_text();o='return min(max(requested, startedAt ?? requested), now)';assert s.count(o)==1;p.write_text(s.replace(o,'return max(requested, now)'))"

# A Verity Sense whose PPI intervals are all rejected still sends its heart
# rate. Ignoring that reading reads the strap as silent and drops the HR.
mutate "strap_hr_reading_ignored_while_intervals_rejected" "EmuquTests/WorkoutStrapOwnershipTests" \
    "Emuqu/Sources/Collection/WorkoutTicker+Tick.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutTicker+Tick.swift');s=p.read_text();o='        guard lifecycle.activeHRSource == .strap,\n              let reading = Self.newStrapReading(';assert s.count(o)==1;p.write_text(s.replace(o,'        guard lifecycle.activeHRSource == .none,\n              let reading = Self.newStrapReading('))"

# With no morning training snapshot the live load is the anchor. A zero
# anchor reads a trained athlete as untrained in the morning.
mutate "live_readiness_missing_morning_atl_is_zero" "EmuquTests/LiveReadinessTests" \
    "Emuqu/Sources/Analysis/LiveReadiness.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/LiveReadiness.swift');s=p.read_text();o='morningContext?.atl ?? live.atl';assert s.count(o)==1;p.write_text(s.replace(o,'morningContext?.atl ?? 0'))"
mutate "live_readiness_missing_morning_ctl_is_zero" "EmuquTests/LiveReadinessTests" \
    "Emuqu/Sources/Analysis/LiveReadiness.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/LiveReadiness.swift');s=p.read_text();o='morningContext?.ctl ?? live.ctl';assert s.count(o)==1;p.write_text(s.replace(o,'morningContext?.ctl ?? 0'))"

# A recovered workout whose strap died mid-run ends at the last thing
# recorded. Ending at the last beat cuts the route and time after it.
mutate "recovery_end_at_last_beat" "EmuquTests/WorkoutRecoveryResolversTests" \
    "Emuqu/Sources/Services/WorkoutRecoveryService+Timeline.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/WorkoutRecoveryService+Timeline.swift');s=p.read_text();o='if rrEndIsFinal, let rrEnd { return rrEnd }';assert s.count(o)==1;p.write_text(s.replace(o,'if let rrEnd { return rrEnd }'))"

# The beats' summed clock stands still through a strap dropout. Ending a
# recovery on it ends the workout early by the length of every dropout.
mutate "recovery_beat_end_on_summed_clock" "EmuquTests/WorkoutRecoveryResolversTests" \
    "Emuqu/Sources/Services/WorkoutRecoveryService+Timeline.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/WorkoutRecoveryService+Timeline.swift');s=p.read_text();o='WorkoutAnalyzer.gapCorrectedOffsetsMs(rrPoints).last.map';assert s.count(o)==1;p.write_text(s.replace(o,'rrPoints.last.map(\\\\.t_ms).map'))"

# The review card's Save keeps the length it showed. Ending at the last kept
# beat cuts a recovered workout whose strap died before the phone stopped.
mutate "recovery_save_ignores_chosen_end" "EmuquTests/RecoveredWorkoutReviewTests" \
    "Emuqu/Sources/Services/WorkoutRecoveryService.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/WorkoutRecoveryService.swift');s=p.read_text();o='let endDate = overrides.endSec.map { startDate.addingTimeInterval(\$0) } ?? Self.resolveEndDate(';assert s.count(o)==1;p.write_text(s.replace(o,'let endDate = Self.resolveEndDate('))"

# A recovered workout keeps the pauses its crash backup holds. Dropping them
# counts paused time as moving in Apple Health and the summary.
mutate "recovery_drops_pauses" "EmuquTests/RecoveredWorkoutReviewTests" \
    "Emuqu/Sources/Services/WorkoutRecoveryService.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/WorkoutRecoveryService.swift');s=p.read_text();o='        metadata.pauseSpans = WorkoutPauseSpan.spans(of: recovered.pauses)\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"

# A recording rejected as unusable scores from the baseline; its own awake
# heart rate must not then be scored as sleep heart rate.
mutate "unusable_recording_hr_scored_as_sleep_hr" "EmuquTests/SessionImmutabilityTests" \
    "Emuqu/Sources/Analysis/RecoveryScoreCalculator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/RecoveryScoreCalculator.swift');s=p.read_text();o='let night = useBaselineHRV ? inputs.droppingRecordingHeartRate() : inputs';assert s.count(o)==1;p.write_text(s.replace(o,'let night = inputs'))"

# The strap's mean heart rate stands for sleep heart rate only on a usable recording.
mutate "sleep_hr_rule_ignores_hrv_quality" "EmuquTests/SessionImmutabilityTests" \
    "Emuqu/Sources/Models/HRVSession+SleepHeartRate.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/HRVSession+SleepHeartRate.swift');s=p.read_text();o='guard isReliableForHRVAggregates,\n              let meanHR';assert s.count(o)==1;p.write_text(s.replace(o,'guard let meanHR'))"

# On a strap+stream composite night a sleep start inside the strap's own
# stretch maps onto that stretch, not past it.
mutate "wall_clock_offset_skips_internal_beats" "EmuquTests/WindowSelectionTests" \
    "Emuqu/Sources/Analysis/WindowSelector+Scoring.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/WindowSelector+Scoring.swift');s=p.read_text();o='(\$0.wallClockMs ?? \$0.t_ms) >= wallElapsedMs';assert s.count(o)==1;p.write_text(s.replace(o,'(\$0.wallClockMs ?? Int64.min) >= wallElapsedMs'))"

# A first night scored without a baseline is re-scored after a sleep edit.
mutate "first_night_keeps_score_from_before_edit" "EmuquTests/SessionImmutabilityTests" \
    "Emuqu/Sources/Services/ReanalysisService+Baseline.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/ReanalysisService+Baseline.swift');s=p.read_text();o='let stored = session.scoreBreakdown,\n              !scoredWithoutBaseline(stored) else';assert s.count(o)==1;p.write_text(s.replace(o,'session.scoreBreakdown != nil else'))"

mutate "yes_bound_to_the_question_shown" "EmuquTests/AssistantWriteBindingTests" "Emuqu/Sources/Assistant/Chat/AssistantActionConfirmations.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Chat/AssistantActionConfirmations.swift');s=p.read_text();o='pending.target == target, pending.question == question, pending.delivered,';assert s.count(o)==1;p.write_text(s.replace(o,'pending.target == target, pending.delivered,'))"
mutate "memory_restore_asks_first" "EmuquTests/AssistantWriteBindingTests" "Emuqu/Sources/Assistant/Facts/AssistantConfirmationFacts.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Facts/AssistantConfirmationFacts.swift');s=p.read_text();o='if let unconfirmed = context.gate(action: \"assistant.memory.restore\"';assert s.count(o)==1;p.write_text(s.replace(o,'if count < 0, let unconfirmed = context.gate(action: \"assistant.memory.restore\"'))"
mutate "artifact_question_names_its_kind" "EmuquTests/AssistantWriteBindingTests" "Emuqu/Sources/Assistant/Facts/AssistantMemoryFacts.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Facts/AssistantMemoryFacts.swift');s=p.read_text();o='question: addQuestion(kind, body: body)';assert s.count(o)==1;p.write_text(s.replace(o,'question: addQuestion(.bug, body: body)'))"
mutate "artifact_body_bounded" "EmuquTests/AssistantWriteBindingTests" "Emuqu/Sources/Assistant/Facts/AssistantMemoryFacts.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Facts/AssistantMemoryFacts.swift');s=p.read_text();o='guard body.count > maxArtifactBodyLength else { return nil }';assert s.count(o)==1;p.write_text(s.replace(o,'guard body.count > maxArtifactBodyLength * 10 else { return nil }'))"
mutate "typed_address_bounded" "EmuquTests/AssistantWriteBindingTests" "Emuqu/Sources/Assistant/Facts/LiveNavigationFacts.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Facts/LiveNavigationFacts.swift');s=p.read_text();o='guard address.count <= maxAddressLength else {';assert s.count(o)==1;p.write_text(s.replace(o,'guard address.count <= maxAddressLength * 10 else {'))"
mutate "directions_to_a_typed_address_ask_first" "EmuquTests/AssistantWriteBindingTests" "Emuqu/Sources/Assistant/Facts/LiveNavigationFacts.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Facts/LiveNavigationFacts.swift');s=p.read_text();o='if let unconfirmed { return .failed(unconfirmed) }';assert s.count(o)==1;p.write_text(s.replace(o,'if let unconfirmed, addr.isEmpty { return .failed(unconfirmed) }'))"
mutate "prescore_feeling_failure_swallowed" "EmuquTests/SilentWriteFailureTests" "Emuqu/Sources/Views/RecordView+Results.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/RecordView+Results.swift');s=p.read_text();o='        try archive.update(archive.archivedId(of: id)) { stored in\n            stored.morningFeeling = stored.morningFeeling ?? value';assert s.count(o)==1;p.write_text(s.replace(o,'        _ = try? archive.update(archive.archivedId(of: id)) { stored in\n            stored.morningFeeling = stored.morningFeeling ?? value'))"
mutate "reading_edit_missing_reported" "EmuquTests/SilentWriteFailureTests" "Emuqu/Sources/Storage/ReadingEditFailure.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/ReadingEditFailure.swift');s=p.read_text();o='        case .fileNotFound?, .sessionWasDeleted?:\n            return false';assert s.count(o)==1;p.write_text(s.replace(o,'        case .fileNotFound?, .sessionWasDeleted?:\n            return true'))"
mutate "review_discard_failure_ignored" "EmuquTests/SilentWriteFailureTests" "Emuqu/Sources/Collection/RRCollector+Coordinators.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/RRCollector+Coordinators.swift');s=p.read_text();o='        guard morning.discardReviewArchivedSession() else { return false }';assert s.count(o)==1;p.write_text(s.replace(o,'        _ = morning.discardReviewArchivedSession()'))"
mutate "route_add_unreadable_library" "EmuquTests/SilentWriteFailureTests" "Emuqu/Sources/Models/SavedRoute.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/SavedRoute.swift');s=p.read_text();o='        guard isLibraryReadable() else { return false }\n        routes.append(route)';assert s.count(o)==1;p.write_text(s.replace(o,'        routes.append(route)'))"
mutate "hrr_refused_write_dropped" "EmuquTests/SilentWriteFailureTests" "Emuqu/Sources/Collection/WorkoutSessionLifecycle+Save.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutSessionLifecycle+Save.swift');s=p.read_text();o='        lifecycle.unsavedHRR[id] = samples\n        storeHRR(samples, for: id)';assert s.count(o)==1;p.write_text(s.replace(o,'        storeHRR(samples, for: id)'))"
mutate "night_export_failure_not_kept" "EmuquTests/SilentWriteFailureTests" "Emuqu/Sources/Collection/PendingNightExports.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/PendingNightExports.swift');s=p.read_text();o='        } else {\n            note(id, in: defaults)\n        }';assert s.count(o)==1;p.write_text(s.replace(o,'        }'))"
mutate "night_export_gone_reading_kept" "EmuquTests/SilentWriteFailureTests" "Emuqu/Sources/Collection/PendingNightExports.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/PendingNightExports.swift');s=p.read_text();o='        guard let session = stored else { return clear(id, in: defaults) }';assert s.count(o)==1;p.write_text(s.replace(o,'        guard let session = stored else { return }'))"
mutate "hrr_reads_another_sessions_stream" "EmuquTests/StrapSessionOwnershipTests" "Emuqu/Sources/Analysis/HRRCaptureService.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/HRRCaptureService.swift');s=p.read_text();o='guard strapStream.isBuffering(startedAt: ownStreamStart) else {';assert s.count(o)==1;p.write_text(s.replace(o,'guard strapStream.isStreaming else {'))"
mutate "stream_owner_any_live_stream" "EmuquTests/StrapSessionOwnershipTests" "Emuqu/Sources/Collection/StrapStreamSession+Ownership.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapStreamSession+Ownership.swift');s=p.read_text();o='return streamingStartTime == start';assert s.count(o)==1;p.write_text(s.replace(o,'return streamingStartTime == start || streamingStartTime != nil'))"
mutate "link_release_ignores_strap_recording" "EmuquTests/StrapSessionOwnershipTests" "Emuqu/Sources/Collection/StrapStreamSession+Ownership.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapStreamSession+Ownership.swift');s=p.read_text();o='&& !recording.isRecordingOnDevice';assert s.count(o)==1;p.write_text(s.replace(o,'&& true'))"
mutate "workout_starts_during_night_ending" "EmuquTests/StrapSessionOwnershipTests" "Emuqu/Sources/Collection/WorkoutSessionLifecycle+Start.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutSessionLifecycle+Start.swift');s=p.read_text();o='guard !core.recordScreenLifecycle.isEndingOvernight else {';assert s.count(o)==1;p.write_text(s.replace(o,'guard !core.recordScreenLifecycle.isPaused else {'))"
mutate "strap_only_starts_under_a_stream" "EmuquTests/StrapSessionOwnershipTests" "Emuqu/Sources/Collection/StrapRecordingGuards.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapRecordingGuards.swift');s=p.read_text();o='guard !strapStream.isStreaming else {';assert s.count(o)==1;p.write_text(s.replace(o,'guard !strapStream.reconnectExhausted else {'))"
mutate "hrr_release_drops_a_used_link" "EmuquTests/StrapSessionOwnershipTests" "Emuqu/Sources/Collection/WorkoutRecorder+Stop.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutRecorder+Stop.swift');s=p.read_text();o='guard strap.stream.mayReleaseLink(after: strap.streamStart, recording: strap.recording) else {';assert s.count(o)==1;p.write_text(s.replace(o,'guard !strap.stream.isStreaming else {'))"
mutate "quick_verity_release_under_new_session" "EmuquTests/StrapSessionOwnershipTests" "Emuqu/Sources/Collection/QuickReadingSession+Streaming.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/QuickReadingSession+Streaming.swift');s=p.read_text();o='strapStream.mayReleaseLink(after: nil, recording: strapRecorder.device) else { return }';assert s.count(o)==1;p.write_text(s.replace(o,'strapRecorder.device.transfersInFlight == 0 else { return }'))"
mutate "night_verity_release_under_new_session" "EmuquTests/StrapSessionOwnershipTests" "Emuqu/Sources/Collection/OvernightStreamingCoordinator+Streaming.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/OvernightStreamingCoordinator+Streaming.swift');s=p.read_text();o='strapStream.mayReleaseLink(after: nil, recording: strapRecorder.device) else { return }';assert s.count(o)==1;p.write_text(s.replace(o,'strapRecorder.device.transfersInFlight == 0 else { return }'))"
mutate "night_late_arm_stops_another_session" "EmuquTests/StrapSessionOwnershipTests" "Emuqu/Sources/Collection/OvernightStreamingCoordinator+Arming.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/OvernightStreamingCoordinator+Arming.swift');s=p.read_text();o='guard !streamingLifecycle.isOvernightStreaming, !strapStream.isStreaming,';assert s.count(o)==1;p.write_text(s.replace(o,'guard !streamingLifecycle.isOvernightStreaming,'))"
mutate "workout_late_arm_stops_another_session" "EmuquTests/StrapSessionOwnershipTests" "Emuqu/Sources/Collection/WorkoutSessionLifecycle+DeviceBackup.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutSessionLifecycle+DeviceBackup.swift');s=p.read_text();o='guard !core.strapStream.isBufferingForAnotherSession(than: owner.streamStart),';assert s.count(o)==1;p.write_text(s.replace(o,'guard !core.strapStream.isBuffering(startedAt: owner.streamStart),'))"
mutate "watch_workout_marks_downloads_saved" "EmuquTests/StrapSessionOwnershipTests" "Emuqu/Sources/Collection/WorkoutRecorder+Stop.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutRecorder+Stop.swift');s=p.read_text();o='guard outcome == .saved, lifecycle.activeHRSource == .strap else { return }';assert s.count(o)==1;p.write_text(s.replace(o,'guard outcome == .saved else { return }'))"
mutate "record_screen_clear_wipes_workout_marker" "EmuquTests/StrapSessionOwnershipTests" "Emuqu/Sources/Collection/RecordingStateStore.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/RecordingStateStore.swift');s=p.read_text();o='guard PersistedRecordingState.load()?.sessionType != .workout else {';assert s.count(o)==1;p.write_text(s.replace(o,'guard PersistedRecordingState.load()?.sessionType != .nap else {'))"
mutate "exact_clear_takes_any_marker" "EmuquTests/StrapSessionOwnershipTests" "Emuqu/Sources/Collection/RecordingStateStore.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/RecordingStateStore.swift');s=p.read_text();o='guard PersistedRecordingState.load()?.sessionId == sessionId else { return }';assert s.count(o)==1;p.write_text(s.replace(o,'guard PersistedRecordingState.load() != nil else { return }'))"
mutate "sampler_stops_with_first_recording" "EmuquTests/StrapSessionOwnershipTests" "Emuqu/Sources/Utilities/SamplingHolders.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/SamplingHolders.swift');s=p.read_text();o='return holders.isEmpty';assert s.count(o)==1;p.write_text(s.replace(o,'return true'))"
mutate "hrr_keeps_next_workouts_heart_rate" "EmuquTests/StrapSessionOwnershipTests" "Emuqu/Sources/Collection/WorkoutRecorder+Stop.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutRecorder+Stop.swift');s=p.read_text();o='guard let nextStart else { return samples }';assert s.count(o)==1;p.write_text(s.replace(o,'guard let nextStart, nextStart < stopDate else { return samples }'))"
mutate "auto_refresh_recheck" "EmuquTests/UserChoicesKeptTests" "Emuqu/Sources/Collection/SleepRefreshPolicy.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/SleepRefreshPolicy.swift');s=p.read_text();o='guard autoSleepRefreshAllowed(for: session) else { return false }';assert s.count(o)==1;p.write_text(s.replace(o,''))"
mutate "auto_sleep_update_keeps_user_bounds" "EmuquTests/UserChoicesKeptTests" "Emuqu/Sources/Services/SleepBoundaryWrite.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SleepBoundaryWrite.swift');s=p.read_text();o='guard edit.isUserAdjustment || session.sleepUserAdjusted != true else {';assert s.count(o)==1;p.write_text(s.replace(o,'guard edit.isUserAdjustment || session.sleepUserAdjusted != false else {'))"
mutate "merge_keeps_existing_user_sleep" "EmuquTests/UserChoicesKeptTests" "Emuqu/Sources/Storage/SessionMerger+UserContent.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/SessionMerger+UserContent.swift');s=p.read_text();o='if existing.sleepUserAdjusted == true { return onClock(existing, startingAt: clockStart) }';assert s.count(o)==1;p.write_text(s.replace(o,''))"
mutate "pull_keeps_local_user_sleep" "EmuquTests/UserChoicesKeptTests" "Emuqu/Sources/Storage/CloudKitSessionFreshness.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitSessionFreshness.swift');s=p.read_text();o='return local.sleepUserAdjusted != true || remote.sleepUserAdjusted == true';assert s.count(o)==1;p.write_text(s.replace(o,'return local.sleepUserAdjusted != false || remote.sleepUserAdjusted == true'))"
mutate "rewrite_upload_unstamped" "EmuquTests/CloudKitSyncManagerTests" "Emuqu/Sources/Storage/CloudKitSyncManager.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitSyncManager.swift');s=p.read_text();o='await forceReuploadSession(session, stampingEdit: false)';assert s.count(o)==1;p.write_text(s.replace(o,'await forceReuploadSession(session, stampingEdit: true)'))"
mutate "bulk_pass_keeps_picked_window" "EmuquTests/RRCollectorSaveResultTests" "Emuqu/Sources/Collection/SessionReanalysisCoordinator.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/SessionReanalysisCoordinator.swift');s=p.read_text();o='await reanalyzeSession(session, preserveManualWindow: true)';assert s.count(o)==1;p.write_text(s.replace(o,'await reanalyzeSession(session, preserveManualWindow: false)'))"
mutate "rebuild_keeps_notes" "EmuquTests/UserChoicesKeptTests" "Emuqu/Sources/Storage/SessionMerger+UserContent.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/SessionMerger+UserContent.swift');s=p.read_text();o='        rebuilt.notes = stored.notes\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"
mutate "rebuild_reclocks_user_sleep" "EmuquTests/UserChoicesKeptTests" "Emuqu/Sources/Storage/SessionMerger+UserContent.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/SessionMerger+UserContent.swift');s=p.read_text();o='keepUserSleep(of: onClock(stored, startingAt: rebuilt.startDate), in: &rebuilt)';assert s.count(o)==1;p.write_text(s.replace(o,'keepUserSleep(of: stored, in: &rebuilt)'))"
mutate "review_archive_keeps_user_edits" "EmuquTests/RRCollectorSaveResultTests" "Emuqu/Sources/Collection/MorningSessionPipeline+Processing.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/MorningSessionPipeline+Processing.swift');s=p.read_text();o='let entry = try archive.archiveRebuilt(finalSession)';assert s.count(o)==1;p.write_text(s.replace(o,'let entry = try archive.archive(finalSession)'))"
mutate "prenight_notes_merged" "EmuquTests/UserChoicesKeptTests" "Emuqu/Sources/Services/SessionAcceptanceService.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SessionAcceptanceService.swift');s=p.read_text();o='archived.notes = SessionMerger.mergedNotes(archived.notes, updated.notes)';assert s.count(o)==1;p.write_text(s.replace(o,'archived.notes = updated.notes'))"
mutate "memory_cap_keeps_user_facts" "EmuquTests/UserFactsStoreTests" "Emuqu/Sources/Assistant/Chat/UserFactsStore.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Chat/UserFactsStore.swift');s=p.read_text();o='let others = facts.filter { !'+chr(36)+'0.isFromUser }.prefix(excess)';assert s.count(o)==1;p.write_text(s.replace(o,'let others = facts.prefix(excess)'))"
mutate "insufficient_migration_rechecks_inputs" "EmuquTests/UserChoicesKeptTests" "Emuqu/Sources/Collection/SessionDataMigrations+InsufficientDataMigration.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/SessionDataMigrations+InsufficientDataMigration.swift');s=p.read_text();o='guard RescoreWrite.inputsMatch(stored, decided, kind: .scoreOnly(healedTraining: false)) else { return false }';assert s.count(o)==1;p.write_text(s.replace(o,''))"

mutate "beat_end_on_beat_sum_clock" "EmuquTests/TimeBaseTests" "Emuqu/Sources/Models/RRModels.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/RRModels.swift');s=p.read_text();o='TimeInterval(last.exportTimeMs + Int64(last.rr_ms))';assert s.count(o)==1;p.write_text(s.replace(o,'TimeInterval(last.t_ms + Int64(last.rr_ms))'))"
mutate "series_end_from_duration" "EmuquTests/TimeBaseTests" "Emuqu/Sources/Models/RRModels.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/RRModels.swift');s=p.read_text();o='points.lastBeatEnd(after: startDate) ?? startDate';assert s.count(o)==1;p.write_text(s.replace(o,'startDate.addingTimeInterval(TimeInterval(durationMs) / 1000.0)'))"
mutate "night_segment_ends_on_t_ms" "EmuquTests/TimeBaseTests" "Emuqu/Sources/Services/MorningProcessingService+Merging.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/MorningProcessingService+Merging.swift');s=p.read_text();o='points.lastBeatEnd(after: startDate) ?? startDate';assert s.count(o)==1;p.write_text(s.replace(o,'startDate.addingTimeInterval(Double(points.last?.t_ms ?? 0) / 1000)'))"
mutate "backup_ends_on_t_ms" "EmuquTests/TimeBaseTests" "Emuqu/Sources/Services/SessionRecoveryService.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SessionRecoveryService.swift');s=p.read_text();o='backup.points.lastBeatEnd(after: backup.captureDate)';assert s.count(o)==1;p.write_text(s.replace(o,'backup.points.last.map { p in backup.captureDate.addingTimeInterval(Double(p.t_ms) / 1000.0) }'))"
mutate "strap_download_ends_on_t_ms" "EmuquTests/TimeBaseTests" "Emuqu/Sources/Collection/DeviceRecordingSession+Capture.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/DeviceRecordingSession+Capture.swift');s=p.read_text();o='guard let end = series.points.lastBeatEnd(after: series.startDate) else';assert s.count(o)==1;p.write_text(s.replace(o,'guard let end = series.points.last.map({ p in series.startDate.addingTimeInterval(Double(p.endMs) / 1000) }) else'))"
mutate "t_ms_position_read_as_wall_offset" "EmuquTests/TimeBaseTests" "Emuqu/Sources/Models/RRModels.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/RRModels.swift');s=p.read_text();o='return wallClockTime(forTMs: edgeMs).addingTimeInterval(Double(tMs - edgeMs) / 1000.0)';assert s.count(o)==1;p.write_text(s.replace(o,'return absoluteTime(fromRelativeMs: tMs)'))"
mutate "recording_span_from_beat_sum" "EmuquTests/TimeBaseTests" "Emuqu/Sources/Models/RRModels.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/RRModels.swift');s=p.read_text();o='let seconds = clockTime(forTMs: last.t_ms).timeIntervalSince(clockTime(forTMs: first.t_ms))';assert s.count(o)==1;p.write_text(s.replace(o,'let seconds = Double(last.t_ms - first.t_ms) / 1000'))"
mutate "recovery_hr_chart_on_t_ms" "EmuquTests/TimeBaseTests" "Emuqu/Sources/Views/RecoveryScoreCharts+Overnight.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/RecoveryScoreCharts+Overnight.swift');s=p.read_text();o='HRPoint(time: series.clockTime(forTMs: p.t_ms), hr: hr)';assert s.count(o)==1;p.write_text(s.replace(o,'HRPoint(time: series.absoluteTime(fromRelativeMs: p.t_ms), hr: hr)'))"
mutate "recovery_rmssd_chart_on_t_ms" "EmuquTests/TimeBaseTests" "Emuqu/Sources/Views/RecoveryScoreCharts+Overnight.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/RecoveryScoreCharts+Overnight.swift');s=p.read_text();o='RMSSDPoint(time: series.clockTime(forTMs: startMs), rmssd: rmssd)';assert s.count(o)==1;p.write_text(s.replace(o,'RMSSDPoint(time: series.absoluteTime(fromRelativeMs: startMs), rmssd: rmssd)'))"
mutate "recovery_window_and_nadir_on_t_ms" "EmuquTests/TimeBaseTests" "Emuqu/Sources/Models/SessionDay.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/SessionDay.swift');s=p.read_text();o='series?.clockTime(forTMs: tMs) ??';assert s.count(o)==1;p.write_text(s.replace(o,'series?.absoluteTime(fromRelativeMs: tMs) ??'))"
mutate "window_segment_matched_on_t_ms" "EmuquTests/TimeBaseTests" "Emuqu/Sources/Services/ReanalysisService.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/ReanalysisService.swift');s=p.read_text();o='MillisecondOffset.between(series.clockTime(forTMs: tMs), and: session.startDate, fallback: tMs)';assert s.count(o)==1;p.write_text(s.replace(o,'MillisecondOffset.between(series.absoluteTime(fromRelativeMs: tMs), and: session.startDate, fallback: tMs)'))"
mutate "hr_estimated_stages_bounded_on_t_ms" "EmuquTests/TimeBaseTests" "Emuqu/Sources/Collection/HRSleepEstimator.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/HRSleepEstimator.swift');s=p.read_text();o='sleepEndMs: wakeMs.map {';assert s.count(o)==1;p.write_text(s.replace(o,'sleepEndMs: wakeMs ?? wakeMs.map {'))"
mutate "workout_beats_from_first_beat" "EmuquTests/TimeBaseTests" "Emuqu/Sources/Analysis/WorkoutAnalyzer.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/WorkoutAnalyzer.swift');s=p.read_text();o='correctionMs = max(correctionMs, wall - point.t_ms)';assert s.count(o)==1;p.write_text(s.replace(o,'correctionMs = max(correctionMs, wall - point.t_ms - (rrPoints.first?.wallClockMs ?? 0))'))"
mutate "live_beat_clock_from_first_beat" "EmuquTests/TimeBaseTests" "Emuqu/Sources/Analysis/LiveDFAAnalyzer.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/LiveDFAAnalyzer.swift');s=p.read_text();o='startMs = max(startMs, wall)';assert s.count(o)==1;p.write_text(s.replace(o,'startMs = max(startMs, wall / 2)'))"
mutate "watch_pause_keeps_samples_after_tap" "EmuquTests/TimeBaseTests" "Emuqu/Sources/Collection/WorkoutRecorder+WatchPause.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutRecorder+WatchPause.swift');s=p.read_text();o='keepRecording(throughElapsed: activeAtTap)';assert s.count(o)==1;p.write_text(s.replace(o,'keepRecording(throughElapsed: lifecycle.elapsedSeconds)'))"
mutate "watch_pause_reaches_before_resume" "EmuquTests/TimeBaseTests" "Emuqu/Sources/Collection/WorkoutRecorder+WatchPause.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutRecorder+WatchPause.swift');s=p.read_text();o='return min(max(requested, since), now)';assert s.count(o)==1;p.write_text(s.replace(o,'return min(requested, now)'))"
mutate "watch_pause_start_not_moved" "EmuquTests/TimeBaseTests" "Emuqu/Sources/Collection/WorkoutLifecycle.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutLifecycle.swift');s=p.read_text();o='        events.removeLast()\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"
mutate "rebuilt_night_load_as_of_now" "EmuquTests/TimeBaseTests" "Emuqu/Sources/Collection/MorningSessionPipeline+Processing.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/MorningSessionPipeline+Processing.swift');s=p.read_text();o='min(session.endDate ?? now, now)';assert s.count(o)==1;p.write_text(s.replace(o,'now'))"
mutate "recovered_pause_dated_by_relaunch" "EmuquTests/TimeBaseTests" "Emuqu/Sources/Services/SessionRecoveryService+Backup.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SessionRecoveryService+Backup.swift');s=p.read_text();o='min(lastBeatEnd ?? now, now)';assert s.count(o)==1;p.write_text(s.replace(o,'now'))"
mutate "offline_recordings_joined_end_to_end" "EmuquTests/TimeBaseTests" "Emuqu/Sources/Collection/StrapRecordingCoordinator+VeritySense.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapRecordingCoordinator+VeritySense.swift');s=p.read_text();o='return max(sinceFirst, afterEarlier)';assert s.count(o)==1;p.write_text(s.replace(o,'return afterEarlier'))"

mutate "fold_list_not_loaded_at_launch" "EmuquTests/ArchiveFoldIdentityTests" \
    "Emuqu/Sources/Storage/SessionArchive.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/SessionArchive.swift');s=p.read_text();o='        state.loadFoldedIndex()';assert s.count(o)==1;p.write_text(s.replace(o,'        state.foldedInto.removeAll()'))"

mutate "fold_not_recorded_on_archive" "EmuquTests/ArchiveFoldIdentityTests" \
    "Emuqu/Sources/Storage/SessionArchive.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/SessionArchive.swift');s=p.read_text();o='if folded { state.recordFold(of: session.id, into: entry.sessionId) }';assert s.count(o)==1;p.write_text(s.replace(o,'if folded {}'))"

mutate "fold_resolution_ignored" "EmuquTests/ArchiveFoldIdentityTests" \
    "Emuqu/Sources/Storage/ArchiveIndexState+Folds.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/ArchiveIndexState+Folds.swift');s=p.read_text();o='guard let next = foldedInto[current]';assert s.count(o)==1;p.write_text(s.replace(o,'guard let next = foldedInto[UUID()]'))"

mutate "held_night_checked_by_own_id" "EmuquTests/ArchiveFoldIdentityTests" \
    "Emuqu/Sources/Storage/SessionArchive.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/SessionArchive.swift');s=p.read_text();o='store.entryById(state.resolvedId(id)) != nil';assert s.count(o)==1;p.write_text(s.replace(o,'store.entryById(id) != nil'))"

mutate "batch_merge_fold_not_recorded" "EmuquTests/ArchiveFoldIdentityTests" \
    "Emuqu/Sources/Storage/ArchiveStore+Batch.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/ArchiveStore+Batch.swift');s=p.read_text();o='            state.recordFold(of: session.id, into: entry.sessionId)';assert s.count(o)==1;p.write_text(s.replace(o,'            _ = entry'))"

mutate "retired_duplicate_not_kept_under_keeper" "EmuquTests/ArchiveFoldIdentityTests" \
    "Emuqu/Sources/Storage/ArchiveMigrations+Steps.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/ArchiveMigrations+Steps.swift');s=p.read_text();o='            moves.forEach { archive.state.recordFold(of: \$0.id, into: \$0.keeper) }';assert s.count(o)==1;p.write_text(s.replace(o,'            _ = moves'))"

mutate "fold_announced_under_recording_only" "EmuquTests/ArchiveFoldIdentityTests" \
    "Emuqu/Sources/Storage/SessionArchive.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/SessionArchive.swift');s=p.read_text();o='NotificationCenter.default.post(name: .flowRecoveryArchiveChanged, object: entry.sessionId)';assert s.count(o)==1;p.write_text(s.replace(o,'NotificationCenter.default.post(name: .flowRecoveryArchiveChanged, object: session.id)'))"

mutate "folded_archive_returns_recording" "EmuquTests/ArchiveFoldIdentityTests" \
    "Emuqu/Sources/Storage/SessionArchive+StoreAPI.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/SessionArchive+StoreAPI.swift');s=p.read_text();o='return retrieveOrLog(entry.sessionId, caller: \"SessionArchive.archiveReturningNight\") ?? session';assert s.count(o)==1;p.write_text(s.replace(o,'return session'))"

mutate "folded_vitals_written_to_own_id" "EmuquTests/ArchiveFoldIdentityTests" \
    "Emuqu/Sources/Views/RecoveryScoreDetailView.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/RecoveryScoreDetailView.swift');s=p.read_text();o='try archive.update(archive.archivedId(of: id), requestingReupload: false) { fill(fresh, in: &\$0) }';assert s.count(o)==1;p.write_text(s.replace(o,'try archive.update(id, requestingReupload: false) { fill(fresh, in: &\$0) }'))"

mutate "folded_recording_listed_as_lost" "EmuquTests/LostSessionRecoveryTests" \
    "Emuqu/Sources/Services/SessionRecoveryService.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SessionRecoveryService.swift');s=p.read_text();o='.sessionId)).union(archive.foldedRecordingIds)';assert s.count(o)==1;p.write_text(s.replace(o,'.sessionId))'))"

mutate "folded_review_accepted_as_card_copy" "EmuquTests/SessionImmutabilityTests" \
    "Emuqu/Sources/Services/SessionAcceptanceService.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SessionAcceptanceService.swift');s=p.read_text();o='        let id = archive.archivedId(of: session.id)';assert s.count(o)==1;p.write_text(s.replace(o,'        let id = session.id'))"

mutate "paused_night_folded_into_another" "EmuquTests/RecordingDiscardTests" \
    "Emuqu/Sources/Collection/CollectorSessionControl+PauseResume.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/CollectorSessionControl+PauseResume.swift');s=p.read_text();o='try archive.archive(session, skipSameNightMerge: true, requestingReupload: true)';assert s.count(o)==1;p.write_text(s.replace(o,'try archive.archive(session, skipSameNightMerge: false, requestingReupload: true)'))"

mutate "folded_manual_window_on_card_copy" "EmuquTests/ReanalysisServiceTests" \
    "Emuqu/Sources/Services/ReanalysisService+Sleep.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/ReanalysisService+Sleep.swift');s=p.read_text();o='ArchivedSessionRead.read(archive.archivedId(of: session.id), from: archive, caller: \"manualWindow\")';assert s.count(o)==1;p.write_text(s.replace(o,'ArchivedSessionRead.read(session.id, from: archive, caller: \"manualWindow\")'))"

mutate "folded_sleep_edit_read_by_own_id" "EmuquTests/ReanalysisServiceTests" \
    "Emuqu/Sources/Services/ReanalysisService+Sleep.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/ReanalysisService+Sleep.swift');s=p.read_text();o='try archive.retrieve(archive.archivedId(of: sessionId))';assert s.count(o)==1;p.write_text(s.replace(o,'try archive.retrieve(sessionId)'))"

mutate "forever_delete_leaves_folded_backups" "EmuquTests/ArchiveIntegrityTests" \
    "Emuqu/Sources/Services/SessionRecoveryService.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SessionRecoveryService.swift');s=p.read_text();o='            try discardBackupsKept(under: sessionId)';assert s.count(o)==1;p.write_text(s.replace(o,'            _ = sessionId'))"

mutate "summary_key_reads_the_feeling" "EmuquTests/StaleDerivedStateTests" "Emuqu/Sources/Assistant/Chat/AnalysisSummaryCache.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Chat/AnalysisSummaryCache.swift');s=p.read_text();o='hasher.combine(session.morningFeeling)';assert s.count(o)==1;p.write_text(s.replace(o,'hasher.combine(session.tags)'))"
mutate "sleep_hr_drops_the_previous_strap_hr" "EmuquTests/StaleDerivedStateTests" "Emuqu/Sources/Models/HRVSession+SleepHeartRate.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/HRVSession+SleepHeartRate.swift');s=p.read_text();o='let withoutPrevious = previous.strapSleepHeartRate.map { vitals.droppingRestingHeartRate(copiedFrom: \$0) } ?? vitals';assert s.count(o)==1;p.write_text(s.replace(o,'let withoutPrevious = vitals'))"
mutate "rescore_writes_scored_vitals" "EmuquTests/StaleDerivedStateTests" "Emuqu/Sources/Services/RescoreWrite.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/RescoreWrite.swift');s=p.read_text();o='session.vitalsSnapshot = rescored.vitalsSnapshot';assert s.count(o)==1;p.write_text(s.replace(o,'_ = rescored.vitalsSnapshot'))"
mutate "rescore_writes_scored_quality" "EmuquTests/StaleDerivedStateTests" "Emuqu/Sources/Services/RescoreWrite.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/RescoreWrite.swift');s=p.read_text();o='session.hrvDataQuality = rescored.hrvDataQuality';assert s.count(o)==1;p.write_text(s.replace(o,'_ = rescored.hrvDataQuality'))"
mutate "score_only_reclassifies" "EmuquTests/StaleDerivedStateTests" "Emuqu/Sources/Services/ReanalysisService.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/ReanalysisService.swift');s=p.read_text();o='reclassifyHRVQuality(of: &classified, result: result)';assert s.count(o)==1;p.write_text(s.replace(o,'_ = result'))"
mutate "reanalysis_moves_sleep_hr" "EmuquTests/StaleDerivedStateTests" "Emuqu/Sources/Services/ReanalysisService.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/ReanalysisService.swift');s=p.read_text();o='session.refreshSleepHeartRate(replacing: previous)';assert s.count(o)==1;p.write_text(s.replace(o,'_ = previous'))"
mutate "sleep_edit_moves_sleep_hr" "EmuquTests/StaleDerivedStateTests" "Emuqu/Sources/Services/SleepBoundaryWrite.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SleepBoundaryWrite.swift');s=p.read_text();o='session.refreshSleepHeartRate(replacing: beforeClassifying)';assert s.count(o)==1;p.write_text(s.replace(o,'_ = beforeClassifying'))"
mutate "merge_moves_kept_sleep_hr" "EmuquTests/StaleDerivedStateTests" "Emuqu/Sources/Storage/SessionMerger.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/SessionMerger.swift');s=p.read_text();o='existing.refreshSleepHeartRate(replacing: previous)';assert s.count(o)==1;p.write_text(s.replace(o,'_ = previous'))"
mutate "pull_moves_local_sleep_hr" "EmuquTests/StaleDerivedStateTests" "Emuqu/Sources/Storage/CloudSessionPayload.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudSessionPayload.swift');s=p.read_text();o='merged.refreshSleepHeartRate(replacing: local)';assert s.count(o)==1;p.write_text(s.replace(o,'_ = local'))"
mutate "refresh_reclassifies_moved_sleep" "EmuquTests/StaleDerivedStateTests" "Emuqu/Sources/Services/SessionAcceptanceService.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SessionAcceptanceService.swift');s=p.read_text();o='let sleepMoved = !sameSleepSpan(session.sleepSnapshot, sleepBefore)';assert s.count(o)==1;p.write_text(s.replace(o,'let sleepMoved = !sameSleepSpan(sleepBefore, sleepBefore)'))"
mutate "acceptance_moves_sleep_window" "EmuquTests/StaleDerivedStateTests" "Emuqu/Sources/Services/SessionAcceptanceService.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SessionAcceptanceService.swift');s=p.read_text();o='ReanalysisService.applySleepBoundaries(fetched, to: &session, sessionStart: session.startDate)';assert s.count(o)==1;p.write_text(s.replace(o,'session.sleepSnapshot = fetched'))"
mutate "acceptance_writes_carry_window" "EmuquTests/StaleDerivedStateTests" "Emuqu/Sources/Services/SessionAcceptanceService.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SessionAcceptanceService.swift');s=p.read_text();o='stored.sleepStartMs = frozen.sleepStartMs';assert s.count(o)==1;p.write_text(s.replace(o,'_ = frozen.sleepStartMs'))"
mutate "acceptance_asks_for_rewindow" "EmuquTests/StaleDerivedStateTests" "Emuqu/Sources/Services/SessionAcceptanceService.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SessionAcceptanceService.swift');s=p.read_text();o='guard before.id == after.id, ReanalysisService.sleepWindowMoved(from: before, to: after) else { return }';assert s.count(o)==1;p.write_text(s.replace(o,'guard before.id == after.id, ReanalysisService.sleepWindowMoved(from: before, to: before) else { return }'))"
mutate "moved_sleep_window_detected" "EmuquTests/StaleDerivedStateTests" "Emuqu/Sources/Services/ReanalysisService+Sleep.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/ReanalysisService+Sleep.swift');s=p.read_text();o='before.sleepStartMs != after.sleepStartMs || before.sleepEndMs != after.sleepEndMs';assert s.count(o)==1;p.write_text(s.replace(o,'before.sleepEndMs != after.sleepEndMs'))"
mutate "reexport_skips_review_night" "EmuquTests/StaleDerivedStateTests" "Emuqu/Sources/Services/ReanalysisService+Sleep.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/ReanalysisService+Sleep.swift');s=p.read_text();o='guard HealthExportReadings(of: before) != HealthExportReadings(of: after), !isAwaitingReview(after.id) else { return }';assert s.count(o)==1;p.write_text(s.replace(o,'guard HealthExportReadings(of: before) != HealthExportReadings(of: after) else { return }'))"
mutate "export_readings_include_hr" "EmuquTests/StaleDerivedStateTests" "Emuqu/Sources/Models/HealthExportReadings.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/HealthExportReadings.swift');s=p.read_text();o='meanHR = session.analysisResult?.timeDomain.meanHR';assert s.count(o)==1;p.write_text(s.replace(o,'meanHR = nil'))"
mutate "recovered_night_in_user_sleep" "EmuquTests/StaleDerivedStateTests" "Emuqu/Sources/Collection/DeviceRecordingSession+Capture.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/DeviceRecordingSession+Capture.swift');s=p.read_text();o='let offset = MillisecondOffset.between(existing.startDate, and: start, fallback: 0)';assert s.count(o)==1;p.write_text(s.replace(o,'let offset: Int64 = 0'))"
mutate "repair_rescored_on_kept_edits" "EmuquTests/StaleDerivedStateTests" "Emuqu/Sources/Collection/SessionRecoveryCoordinator+MergeRepair.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/SessionRecoveryCoordinator+MergeRepair.swift');s=p.read_text();o='!RescoreWrite.inputsMatch(carried, rebuilt, kind: .scoreOnly(healedTraining: false))';assert s.count(o)==1;p.write_text(s.replace(o,'RescoreWrite.inputsMatch(carried, rebuilt, kind: .scoreOnly(healedTraining: false))'))"

mutate "verifier_range_delta" "EmuquTests/TrainingLoadClaimTests" "Emuqu/Sources/Assistant/MetricsVerifier.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MetricsVerifier.swift');s=p.read_text();o='!isRangeOrDelta(after: claimRange, in: ns) else';assert s.count(o)==1;p.write_text(s.replace(o,'true else'))"
mutate "sleep_delta" "EmuquTests/SleepClaimVerificationTests" "Emuqu/Sources/Assistant/MetricsVerifier.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MetricsVerifier.swift');s=p.read_text();o='!isRangeOrDelta(after: claimRange, in: ns),';assert s.count(o)==1;p.write_text(s.replace(o,'true,'))"
mutate "overnight_last_night" "EmuquTests/RecoveryClaimPatternTests" "Emuqu/Sources/Assistant/MetricsVerifier.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MetricsVerifier.swift');s=p.read_text();o='let markers = overnight ? [earlierTimeMarkers, targetMarkers] :';assert s.count(o)==1;p.write_text(s.replace(o,'let markers = overnight ? [earlierTimeMarkers, lastNightMarker, targetMarkers] :'))"
mutate "plan_negation_markers" "EmuquTests/SleepClaimVerificationTests" "Emuqu/Sources/Assistant/MetricsVerifier.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MetricsVerifier.swift');s=p.read_text();o='will|tonight|tomorrow|next|plan(?:ned)?|try|want|expect(?:ed)?|predict(?:ed)?|project(?:ed)?|not|never|without';assert s.count(o)==1;p.write_text(s.replace(o,'zzzz'))"
mutate "recovery_over_100" "EmuquTests/RecoveryClaimPatternTests" "Emuqu/Sources/Assistant/MetricsVerifier.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MetricsVerifier.swift');s=p.read_text();o='guard claimed <= 100 else { return nil }';assert s.count(o)==1;p.write_text(s.replace(o,'guard claimed <= 100000 else { return nil }'))"
mutate "ln_rmssd" "EmuquTests/TrainingLoadClaimTests" "Emuqu/Sources/Assistant/MetricsVerifier.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MetricsVerifier.swift');s=p.read_text();o='bln';assert s.count(o)==1;p.write_text(s.replace(o,'bxx'))"
mutate "tsb_typographic_minus" "EmuquTests/TrainingLoadClaimTests" "Emuqu/Sources/Assistant/MetricsVerifier.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MetricsVerifier.swift');s=p.read_text();o='(?<value>[-−]?';assert s.count(o)==1;p.write_text(s.replace(o,'(?<value>[-]?'))"
mutate "tsb_minus_word" "EmuquTests/TrainingLoadClaimTests" "Emuqu/Sources/Assistant/MetricsVerifier.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MetricsVerifier.swift');s=p.read_text();o='(?:(?:negative|minus)';assert s.count(o)==1;p.write_text(s.replace(o,'(?:(?:negative|minuz)'))"
mutate "normalizer_minus" "EmuquTests/TrainingLoadClaimTests" "Emuqu/Sources/Assistant/SpelledNumberNormalizer.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/SpelledNumberNormalizer.swift');s=p.read_text();o='negative|minus)';assert s.count(o)==1;p.write_text(s.replace(o,'negative|minuz)'))"
mutate "normalizer_spaced_hundreds" "EmuquTests/TrainingLoadClaimTests" "Emuqu/Sources/Assistant/SpelledNumberNormalizer.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/SpelledNumberNormalizer.swift');s=p.read_text();o='let colloquial = ';assert s.count(o)==1;p.write_text(s.replace(o,'let colloquial = \"(?:one|two)-(?:sixty|forty)\"; _ = '))"
mutate "echo_yes_answers_confirmation" "EmuquTests/VoiceEchoHeuristicsTests" "Emuqu/Sources/Assistant/VoiceEchoHeuristics.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/VoiceEchoHeuristics.swift');s=p.read_text();o='if AffirmationReply.isExplicitYes(transcript, question: question) { return true }';assert s.count(o)==1;p.write_text(s.replace(o,'if AffirmationReply.isExplicitYes(transcript, question: question) { return false }'))"
mutate "echo_call_site_keeps_heard_yes" "EmuquTests/VoiceEchoHeuristicsTests" "Emuqu/Sources/Assistant/VoiceAudioPipeline+Audio.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/VoiceAudioPipeline+Audio.swift');s=p.read_text();o='if controller.looksLikeEcho(of: transcript), !answersHeardConfirmation(transcript) {';assert s.count(o)==1;p.write_text(s.replace(o,'if controller.looksLikeEcho(of: transcript) {'))"
mutate "asserted_values_skip_other_times" "EmuquTests/UserCorrectionDetectorTests" "Emuqu/Sources/Assistant/UserAssertedValuesParser.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/UserAssertedValuesParser.swift');s=p.read_text();o=', !describesAnotherTime(trimmed) {';assert s.count(o)==1;p.write_text(s.replace(o,' {'))"
mutate "asserted_values_hrv_alias" "EmuquTests/UserCorrectionDetectorTests" "Emuqu/Sources/Assistant/UserAssertedValuesParser.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/UserAssertedValuesParser.swift');s=p.read_text();o='\"hrv\": \"rmssd\"';assert s.count(o)==1;p.write_text(s.replace(o,'\"hrvx\": \"rmssd\"'))"
mutate "asserted_values_keep_units" "EmuquTests/UserCorrectionDetectorTests" "Emuqu/Sources/Assistant/UserAssertedValuesParser.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/UserAssertedValuesParser.swift');s=p.read_text();o='if let unit = found.unit { signals.units[metric] = unit }';assert s.count(o)==1;p.write_text(s.replace(o,'_ = found.unit'))"
mutate "stop_saying_needs_data" "EmuquTests/UserCorrectionDetectorTests" "Emuqu/Sources/Assistant/UserAssertedValuesParser.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/UserAssertedValuesParser.swift');s=p.read_text();o='|| valueRejections.contains {';assert s.count(o)==1;p.write_text(s.replace(o,'|| !valueRejections.isEmpty || valueRejections.contains {'))"
mutate "live_triggers_whole_question" "EmuquTests/DeterministicIntentTests" "Emuqu/Sources/Assistant/Facts/DeterministicIntent+Live.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Facts/DeterministicIntent+Live.swift');s=p.read_text();o='|yet))?';assert s.count(o)==1;p.write_text(s.replace(o,'|yet))?.*'))"
mutate "spot_compare_not_directions" "EmuquTests/DeterministicIntentTests" "Emuqu/Sources/Assistant/Facts/DeterministicIntent+Live.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Facts/DeterministicIntent+Live.swift');s=p.read_text();o='(?:go|keep|bear|take';assert s.count(o)==1;p.write_text(s.replace(o,'(?:gox|keepx|bearx|takex'))"
mutate "did_i_ride_asks_rides" "EmuquTests/DeterministicIntentTests" "Emuqu/Sources/Assistant/Facts/DeterministicIntent.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Facts/DeterministicIntent.swift');s=p.read_text();o='return [.bike, .indoorBike]';assert s.count(o)==1;p.write_text(s.replace(o,'return nil'))"
mutate "log_keeps_diagnostic_numbers" "EmuquTests/RedactionPatternTests" "Emuqu/Sources/Utilities/DebugLog.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/DebugLog.swift');s=p.read_text();o='\"elapsed\", \"rms\", \"chars\", \"characters\", \"transcript\", \"tokens\"';assert s.count(o)==1;p.write_text(s.replace(o,'\"elapsedx\"'))"
mutate "web_ko_ready_not_rain" "EmuquTests/CapabilityClassifierTests" "Emuqu/Sources/Assistant/Facts/CapabilityMarkers+Languages.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Facts/CapabilityMarkers+Languages.swift');s=p.read_text();o='|(?<!준)비가|';assert s.count(o)==1;p.write_text(s.replace(o,'|비가|'))"
mutate "web_nb_please_not_weather" "EmuquTests/CapabilityClassifierTests" "Emuqu/Sources/Assistant/Facts/CapabilityMarkers+Languages.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Facts/CapabilityMarkers+Languages.swift');s=p.read_text();o='|været|værmelding';assert s.count(o)==1;p.write_text(s.replace(o,'|været|vær|værmelding'))"
mutate "web_it_try_to_not_search" "EmuquTests/CapabilityClassifierTests" "Emuqu/Sources/Assistant/Facts/CapabilityMarkers+Languages.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/Facts/CapabilityMarkers+Languages.swift');s=p.read_text();o='|cercami|cerca (?:online';assert s.count(o)==1;p.write_text(s.replace(o,'|cerca|cercami|cerca (?:online'))"
mutate "csv_semicolon_decimal_comma" "EmuquTests/RRDataImporterTests" "Emuqu/Sources/Import/RRDataImporter+CSV.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+CSV.swift');s=p.read_text();o='separator: separator, decimalComma: true';assert s.count(o)==1;p.write_text(s.replace(o,'separator: separator, decimalComma: false'))"
mutate "csv_one_column_decimal_comma" "EmuquTests/RRDataImporterTests" "Emuqu/Sources/Import/RRDataImporter+CSV.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+CSV.swift');s=p.read_text();o='guard oneColumn, rows.allSatisfy(isDecimalCommaSeconds) else {';assert s.count(o)==1;p.write_text(s.replace(o,'guard oneColumn, rows.allSatisfy(isDecimalCommaSeconds), rows.isEmpty else {'))"
mutate "text_table_reads_rr_column" "EmuquTests/RRDataImporterTests" "Emuqu/Sources/Import/RRDataImporter+CSV.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+CSV.swift');s=p.read_text();o='if let table = Self.columnarTimeColumn(lines) {';assert s.count(o)==1;p.write_text(s.replace(o,'if let table = Self.columnarTimeColumn(lines), lines.isEmpty {'))"
mutate "date_before_2000_refused" "EmuquTests/RRDataImporterTests" "Emuqu/Sources/Import/RRDataImporter+CSV.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+CSV.swift');s=p.read_text();o='date >= earliestRecordingDate';assert s.count(o)==1;p.write_text(s.replace(o,'date >= Date.distantPast'))"
mutate "date_two_digit_year_century" "EmuquTests/RRDataImporterTests" "Emuqu/Sources/Import/RRDataImporter+CSV.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+CSV.swift');s=p.read_text();o='twoDigitStartDate = Date(timeIntervalSince1970: 946_684_800)';assert s.count(o)==1;p.write_text(s.replace(o,'twoDigitStartDate = Date(timeIntervalSince1970: -2_208_988_800)'))"
mutate "json_fractional_rr_ms" "EmuquTests/RRDataImporterTests" "Emuqu/Sources/Import/RRDataImporter+JSON.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+JSON.swift');s=p.read_text();o='storableRR(roundedMilliseconds: rr)';assert s.count(o)==1;p.write_text(s.replace(o,'storableRR(roundedMilliseconds: rr.rounded(.down) == rr ? rr : -1)'))"
mutate "speculative_en_participle" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='been|gone|run|done|had|got|gotten|made|taken|felt|slept|held|kept|left|overdone|';assert s.count(o)==1;p.write_text(s.replace(o,'zzq|'))"
mutate "speculative_de_offer" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='{1,3}haben';assert s.count(o)==1;p.write_text(s.replace(o,'{0,3}'))"
mutate "speculative_es_offer" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='d[íi]a|sesi[óo]n|semana|entreno';assert s.count(o)==1;p.write_text(s.replace(o,'zzq'))"
mutate "speculative_pt_offer" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='dia|sess[ãa]o|semana|treino|descanso|folga|corrida';assert s.count(o)==1;p.write_text(s.replace(o,'zzq'))"
mutate "speculative_it_offer" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='giorn|session|settiman|allenament|riposo|bisogno|recupero';assert s.count(o)==1;p.write_text(s.replace(o,'zzq'))"
mutate "speculative_nordic_offer" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='dag|økt|pass|tur|uke|vecka';assert s.count(o)==1;p.write_text(s.replace(o,'zzq'))"
mutate "speculative_ru_offer" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='л[её]гк|отдых|выходн|тренировк|день|больше|меньше';assert s.count(o)==1;p.write_text(s.replace(o,'zzq'))"
mutate "stroke_swim_metric" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='rate|count|length|cycle|index|technique|drill|rhythm|plan';assert s.count(o)==1;p.write_text(s.replace(o,'zzq'))"
mutate "diagnosis_ja_software" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='診断(?!ログ|ツール|情報|データ)';assert s.count(o)==1;p.write_text(s.replace(o,'診断'))"
mutate "diagnosis_zh_software" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='诊断(?!日志|工具|信息|数据)';assert s.count(o)==1;p.write_text(s.replace(o,'诊断'))"
mutate "diagnosis_ko_software" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='로그|도구|정보|데이터';assert s.count(o)==1;p.write_text(s.replace(o,'zzq'))"
mutate "diagnosis_ar_software" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='(?<!سجل ال)';assert s.count(o)==1;p.write_text(s.replace(o,''))"
mutate "diagnosis_fr_from" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='bundle|from|depuis';assert s.count(o)==1;p.write_text(s.replace(o,'bundle'))"
mutate "diagnosis_romance_log" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='(?<!log';assert s.count(o)==1;p.write_text(s.replace(o,'(?<!zzqlog'))"
mutate "diagnosis_sv_settings" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='inst[äa]llningar';assert s.count(o)==1;p.write_text(s.replace(o,'zzq'))"
mutate "injury_da_nb_go" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift');s=p.read_text();o='(?:til|p[åa]|ud|ut|';assert s.count(o)==1;p.write_text(s.replace(o,'(?:zzq|'))"
mutate "injury_sv_go" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift');s=p.read_text();o='(?:till|p[åa]|ut|';assert s.count(o)==1;p.write_text(s.replace(o,'(?:zzq|'))"
mutate "injury_nl_run" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift');s=p.read_text();o='lopen(?=';assert s.count(o)==1;p.write_text(s.replace(o,'lopen(?!zzq'))"
mutate "injury_ru_go" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift');s=p.read_text();o='(?:на|в|к|сегодня|завтра)';assert s.count(o)==1;p.write_text(s.replace(o,'(?:zzq)'))"
mutate "injury_es_ride" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift');s=p.read_text();o='(?:bici|bicicleta|moto)';assert s.count(o)==1;p.write_text(s.replace(o,'(?:zzq)'))"
mutate "injury_pt_ride" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift');s=p.read_text();o='(?:bike|bici|bicicleta|moto)';assert s.count(o)==1;p.write_text(s.replace(o,'(?:zzq)'))"
mutate "injury_en_fall_idioms" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift');s=p.read_text();o='|into|';assert s.count(o)==1;p.write_text(s.replace(o,'|'))"
mutate "injury_fr_tombe_sur" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift');s=p.read_text();o='sur|malade';assert s.count(o)==1;p.write_text(s.replace(o,'zzq'))"
mutate "injury_pt_cai_no_sono" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift');s=p.read_text();o='ca[íi](?!';assert s.count(o)==1;p.write_text(s.replace(o,'ca[íi](?=|'))"
mutate "injury_ar_fell_score" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift');s=p.read_text();o='سقطت(?=';assert s.count(o)==1;p.write_text(s.replace(o,'سقطت(?=|'))"
mutate "injury_ar_illness" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift');s=p.read_text();o='مصاب(?!';assert s.count(o)==1;p.write_text(s.replace(o,'مصاب(?=|'))"
mutate "injury_cjk_fracture_noun" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift');s=p.read_text();o='骨折(?:した|して|しま)';assert s.count(o)==1;p.write_text(s.replace(o,'骨折'))"
mutate "injury_bike_computer" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift');s=p.read_text();o='computer|app|gps|light|lock';assert s.count(o)==1;p.write_text(s.replace(o,'zzq'))"
mutate "injury_triathlon_came_off" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift');s=p.read_text();o='(?:crashed|fell';assert s.count(o)==1;p.write_text(s.replace(o,'(?:crashed|came.off|fell'))"
mutate "injury_barbell_weight" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift');s=p.read_text();o='weight(?!';assert s.count(o)==1;p.write_text(s.replace(o,'weight(?=|'))"
mutate "injury_joint_pain_dropped" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift');s=p.read_text();o='nordicInjury + jointPain + [';assert s.count(o)==1;p.write_text(s.replace(o,'nordicInjury + ['))"
mutate "injury_joint_soreness" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Injury.swift');s=p.read_text();o='after|since|from|yesterday';assert s.count(o)==1;p.write_text(s.replace(o,'zzq'))"
mutate "rhythm_de_herzklopfen" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='unregelm[äa][ßs]iger';assert s.count(o)==1;p.write_text(s.replace(o,'herzklopfen|unregelm[äa][ßs]iger'))"
mutate "rhythm_fr_artefact" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='battements?';assert s.count(o)==1;p.write_text(s.replace(o,'battements?|battement'))"
mutate "rhythm_skipping_beats" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='(?:skipped|skipping|skip)';assert s.count(o)==1;p.write_text(s.replace(o,'skipped?'))"
mutate "breath_it_affanno" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='(?<!in';assert s.count(o)==1;p.write_text(s.replace(o,'(?<!zzqin'))"
mutate "breath_nl_benauwd" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='benauwdheid';assert s.count(o)==1;p.write_text(s.replace(o,'benauwd(?:heid)?'))"
mutate "breath_da_tungpustet" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='(?:er|blir|bliver)';assert s.count(o)==1;p.write_text(s.replace(o,'(?:er|blir|bliver|var)'))"
mutate "breath_sv_past" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Spoken.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Spoken.swift');s=p.read_text();o='(?<!var';assert s.count(o)==1;p.write_text(s.replace(o,'(?<!zzqvar'))"
mutate "breath_ru_past" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Spoken.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Spoken.swift');s=p.read_text();o='(?<!было';assert s.count(o)==1;p.write_text(s.replace(o,'(?<!zzqбыло'))"
mutate "breath_ja_can_breathe" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Spoken.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Spoken.swift');s=p.read_text();o='息ができな';assert s.count(o)==1;p.write_text(s.replace(o,'息ができ'))"
mutate "breath_ko_past" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Spoken.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Spoken.swift');s=p.read_text();o='숨쉬기 힘들(?!었)';assert s.count(o)==1;p.write_text(s.replace(o,'숨쉬기 힘들'))"
mutate "breath_es_swim" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Spoken.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Spoken.swift');s=p.read_text();o='cuando';assert s.count(o)==1;p.write_text(s.replace(o,'zzq'))"
mutate "syncope_faint_adjective" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='twinge|ache|pain|soreness|praise';assert s.count(o)==1;p.write_text(s.replace(o,'zzq'))"
mutate "syncope_might_faint" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='|might|may|could|will)';assert s.count(o)==1;p.write_text(s.replace(o,')'))"
mutate "syncope_screen_blackout" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='(?<!screen';assert s.count(o)==1;p.write_text(s.replace(o,'(?<!zzqscreen'))"
mutate "syncope_passed_out_handout" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='(?:the|some|flyers|water|bottles|gels|snacks|medals)';assert s.count(o)==1;p.write_text(s.replace(o,'(?:zzq)'))"
mutate "syncope_fr_vanished" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Spoken.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Spoken.swift');s=p.read_text();o='[ée]vanouissements?';assert s.count(o)==1;p.write_text(s.replace(o,'[ée]vanou[a-z]*'))"
mutate "syncope_nl_pace_collapsed" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+Spoken.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+Spoken.swift');s=p.read_text();o='|ze';assert s.count(o)==1;p.write_text(s.replace(o,'|tempo|ze'))"
mutate "arrhythmia_ja_respiratory" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='(?<!呼吸性)';assert s.count(o)==1;p.write_text(s.replace(o,''))"
mutate "arrhythmia_ru_respiratory" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='(?<!дыхательная';assert s.count(o)==1;p.write_text(s.replace(o,'(?<!zzq'))"
mutate "stroke_zh_medium_risk" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='中风(?!险)';assert s.count(o)==1;p.write_text(s.replace(o,'中风'))"
mutate "stroke_ru_oblique" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='инсульт(?:а|е|у|ом|ы)?';assert s.count(o)==1;p.write_text(s.replace(o,'инсульт'))"
mutate "self_harm_de_deprive" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+SelfHarm.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+SelfHarm.swift');s=p.read_text();o='(?:den|die|das|mein';assert s.count(o)==1;p.write_text(s.replace(o,'(?:zzq'))"
mutate "self_harm_ru_plan" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+SelfHarm.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+SelfHarm.swift');s=p.read_text();o='умереть|покончить';assert s.count(o)==1;p.write_text(s.replace(o,'умереть|покончить|покончить'))"
mutate "self_harm_pt_social" "EmuquTests/MedicalQueryGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+SelfHarm.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+SelfHarm.swift');s=p.read_text();o='vida(?!';assert s.count(o)==1;p.write_text(s.replace(o,'vida(?=|'))"
mutate "verdict_low_blood_sugar" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+MetricVerdict.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+MetricVerdict.swift');s=p.read_text();o='(?<!preventing';assert s.count(o)==1;p.write_text(s.replace(o,'(?<!zzq'))"
mutate "verdict_recovery_day" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+MetricVerdict.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+MetricVerdict.swift');s=p.read_text();o='(?:day|days|run|runs|ride';assert s.count(o)==1;p.write_text(s.replace(o,'(?:days|run|runs|ride'))"
mutate "verdict_de_echte_erholung" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon+MetricVerdict.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon+MetricVerdict.swift');s=p.read_text();o='(?<!plane';assert s.count(o)==1;p.write_text(s.replace(o,'echte|(?<!plane'))"
mutate "certainty_fi_score_copy" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='(?:yl[äa]|ala)puolella';assert s.count(o)==1;p.write_text(s.replace(o,'zzq'))"
mutate "certainty_ru_explicitly" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='(?:ли|л|ла)';assert s.count(o)==1;p.write_text(s.replace(o,'(?:zzq)'))"
mutate "cure_de_heal" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='heilmittel';assert s.count(o)==1;p.write_text(s.replace(o,'heilen|heilmittel'))"
mutate "prescription_en_pace" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='(?:pace|workout|session|intensity';assert s.count(o)==1;p.write_text(s.replace(o,'(?:zzq|workout|session|intensity'))"
mutate "prescription_nl_instructions" "EmuquTests/CoachVoiceGuardTests" "Emuqu/Sources/Assistant/MedicalTermLexicon.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/MedicalTermLexicon.swift');s=p.read_text();o='(?:arts|dokter|huisarts)s?voorschrift';assert s.count(o)==1;p.write_text(s.replace(o,'voorschrift'))"

mutate "pulled_fuller_live_backup_not_saved" "EmuquTests/FullerCopyDecisionTests" "Emuqu/Sources/Services/SessionRecoveryService.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SessionRecoveryService.swift');s=p.read_text();o='guard FullerCopy.covers(local, beats) else { return .save }';assert s.count(o)==1;p.write_text(s.replace(o,'guard FullerCopy.covers(local, 0) else { return .save }'))"
mutate "archived_fragment_retires_fuller_backup" "EmuquTests/FullerCopyDecisionTests" "Emuqu/Sources/Services/SessionRecoveryService.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SessionRecoveryService.swift');s=p.read_text();o='if FullerCopy.covers(night, beats) { return .retire }';assert s.count(o)==1;p.write_text(s.replace(o,'if FullerCopy.covers(night, 0) { return .retire }'))"
mutate "fuller_copy_rule_strict" "EmuquTests/FullerCopyDecisionTests" "Emuqu/Sources/Storage/FullerCopy.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/FullerCopy.swift');s=p.read_text();o='return kept >= dropped';assert s.count(o)==1;p.write_text(s.replace(o,'return kept > dropped'))"
mutate "upload_overwrites_unseen_version" "EmuquTests/FullerCopyDecisionTests" "Emuqu/Sources/Storage/CloudKitSessionFreshness.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitSessionFreshness.swift');s=p.read_text();o='return serverVersion != heldVersion';assert s.count(o)==1;p.write_text(s.replace(o,'return serverVersion == heldVersion'))"
mutate "pull_skips_older_copy_under_pending_upload" "EmuquTests/FullerCopyDecisionTests" "Emuqu/Sources/Storage/CloudKitSessionFreshness.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitSessionFreshness.swift');s=p.read_text();o='return heldVersion != nil || pendingUpload';assert s.count(o)==1;p.write_text(s.replace(o,'return heldVersion != nil'))"
mutate "pull_drops_older_copys_beats" "EmuquTests/FullerCopyDecisionTests" "Emuqu/Sources/Storage/CloudKitSessionFreshness.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitSessionFreshness.swift');s=p.read_text();o='guard keepingBeatsOnlyHere(remote, in: &merged) else { return }';assert s.count(o)==1;p.write_text(s.replace(o,'guard keepingBeatsOnlyHere(session, in: &merged) else { return }'))"
mutate "recovery_overwrites_fuller_archived_copy" "EmuquTests/LostSessionRecoveryTests" "Emuqu/Sources/Services/SessionRecoveryService+Backup.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SessionRecoveryService+Backup.swift');s=p.read_text();o='if let stored = keptArchivedCopy(over: data, sessionId: sessionId) { return stored }';assert s.count(o)==1;p.write_text(s.replace(o,'if let stored = keptArchivedCopy(over: data, sessionId: UUID()) { return stored }'))"
mutate "live_backup_start_dropped" "EmuquTests/SourceTimeTests" "Emuqu/Sources/Storage/LiveBackupPayload.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/LiveBackupPayload.swift');s=p.read_text();o='index == 0 ? startMs : nil';assert s.count(o)==1;p.write_text(s.replace(o,'index == -1 ? startMs : nil'))"
mutate "live_backup_restored_by_upload_time" "EmuquTests/SourceTimeTests" "Emuqu/Sources/Models/LiveBackupSummary.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/LiveBackupSummary.swift');s=p.read_text();o='var sessionStart: Date { recordingStart ?? captureDate }';assert s.count(o)==1;p.write_text(s.replace(o,'var sessionStart: Date { captureDate }'))"
mutate "live_backup_upload_drops_start" "EmuquTests/CloudUploadRecordTests" "Emuqu/Sources/Storage/CloudKitLiveBackupManager.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitLiveBackupManager.swift');s=p.read_text();o='compressedPoints(points, recordingStart: recordingStart)';assert s.count(o)==1;p.write_text(s.replace(o,'compressedPoints(points, recordingStart: .distantPast)'))"
mutate "append_backup_dated_by_first_write" "EmuquTests/SourceTimeTests" "Emuqu/Sources/Storage/RawRRBackup+Streaming.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/RawRRBackup+Streaming.swift');s=p.read_text();o='let start = captureDate ?? existingEntry?.captureDate';assert s.count(o)==1;p.write_text(s.replace(o,'let start = existingEntry?.captureDate'))"
mutate "short_pause_dated_after_download" "EmuquTests/SourceTimeTests" "Emuqu/Sources/Collection/CollectorSessionControl+PauseResume.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/CollectorSessionControl+PauseResume.swift');s=p.read_text();o='pausedDate: pausedAt';assert s.count(o)==1;p.write_text(s.replace(o,'pausedDate: Date()'))"
mutate "watch_resume_at_arrival" "EmuquTests/SourceTimeTests" "Emuqu/Sources/Collection/WorkoutRecorder+WatchPause.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutRecorder+WatchPause.swift');s=p.read_text();o='pauseControl.resume(at: resumedAt)';assert s.count(o)==1;p.write_text(s.replace(o,'pauseControl.resume(at: now)'))"
mutate "resume_motion_read_after_tap" "EmuquTests/SourceTimeTests" "Emuqu/Sources/Collection/WorkoutLifecycle.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutLifecycle.swift');s=p.read_text();o='pausedReadings.last { \$0.at <= date }';assert s.count(o)==1;p.write_text(s.replace(o,'pausedReadings.last { \$0.at >= date }'))"
mutate "resume_fixes_not_recounted" "EmuquTests/SourceTimeTests" "Emuqu/Sources/Collection/WorkoutLocationManager.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutLocationManager.swift');s=p.read_text();o='track[\$0].timestamp > resumedAt';assert s.count(o)==1;p.write_text(s.replace(o,'track[\$0].timestamp > Date()'))"
mutate "push_drains_backlog" "EmuquTests/CompletionClaimTests" "Emuqu/Sources/Storage/CloudKitSyncManager+Push.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitSyncManager+Push.swift');s=p.read_text();o='for start in stride(from: 0, to: ids.count, by: batchSize) {';assert s.count(o)==1;p.write_text(s.replace(o,'for start in stride(from: 0, to: min(ids.count, batchSize), by: batchSize) {'))"
mutate "sync_completion_needs_no_waiting_uploads" "EmuquTests/CompletionClaimTests" "Emuqu/Sources/Storage/CloudKitSyncManager.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitSyncManager.swift');s=p.read_text();o='return indexComplete && waitingUploads == 0 ? .upToDate : .incomplete';assert s.count(o)==1;p.write_text(s.replace(o,'return indexComplete ? .upToDate : .incomplete'))"
mutate "up_to_date_label_reads_waiting_uploads" "EmuquTests/CompletionClaimTests" "Emuqu/Sources/Storage/CloudKitSyncManager.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitSyncManager.swift');s=p.read_text();o='syncState == .idle && archive.hasCompleteIndex && uploadsWaitingCount == 0';assert s.count(o)==1;p.write_text(s.replace(o,'syncState == .idle && archive.hasCompleteIndex'))"
mutate "quarantined_not_waiting" "EmuquTests/CompletionClaimTests" "Emuqu/Sources/Storage/CloudKitSyncManager.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitSyncManager.swift');s=p.read_text();o='.subtracting(state.quarantinedSessionIds)';assert s.count(o)==1;p.write_text(s.replace(o,''))"
mutate "archive_migrations_wait_for_the_index" "EmuquTests/CompletionClaimTests" "Emuqu/Sources/Storage/ArchiveMigrations+Steps.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/ArchiveMigrations+Steps.swift');s=p.read_text();o='guard archive.hasCompleteIndex else {';assert s.count(o)==1;p.write_text(s.replace(o,'guard archive.hasCompleteIndex || !archive.hasCompleteIndex else {'))"
mutate "training_repair_counts_errors" "EmuquTests/CompletionClaimTests" "Emuqu/Sources/Services/ReanalysisService+Sleep.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/ReanalysisService+Sleep.swift');s=p.read_text();o='unanswered == 0 && errors == 0 && !stoppedEarly';assert s.count(o)==1;p.write_text(s.replace(o,'unanswered == 0 && !stoppedEarly'))"
mutate "segment_cumulative_skips_joins" "EmuquTests/TrackSegmentsTests" "Emuqu/Sources/Analysis/TrackSegments.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/TrackSegments.swift');s=p.read_text();o='if index > 0, !breaks.contains(index) { along +=';assert s.count(o)==1;p.write_text(s.replace(o,'if index > 0, breaks.contains(index) || true { along +='))"
mutate "gpx_parser_records_segment_starts" "EmuquTests/TrackSegmentsTests" "Emuqu/Sources/Analysis/GPXImporter.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/GPXImporter.swift');s=p.read_text();o='{ trackSegmentStarts.append(trackPoints.count) }';assert s.count(o)==1;p.write_text(s.replace(o,'{ _ = trackPoints.count }'))"
mutate "imported_join_is_a_pause" "EmuquTests/TrackSegmentsTests" "Emuqu/Sources/Import/ImportedWorkoutBuilder.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/ImportedWorkoutBuilder.swift');s=p.read_text();o='let pauses = breakPauses(of: ordered)';assert s.count(o)==1;p.write_text(s.replace(o,'let pauses: [WorkoutPauseSpan] = []'))"
mutate "imported_workout_stores_segment_starts" "EmuquTests/TrackSegmentsTests" "Emuqu/Sources/Import/ImportedWorkoutBuilder.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/ImportedWorkoutBuilder.swift');s=p.read_text();o='let starts = TrackSegments.starts(track.segmentStarts, count: track.track.count)';assert s.count(o)==1;p.write_text(s.replace(o,'let starts = TrackSegments.starts([], count: track.track.count)'))"
mutate "analyzer_leaves_out_break_steps" "EmuquTests/TrackSegmentsTests" "Emuqu/Sources/Analysis/WorkoutAnalyzer.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/WorkoutAnalyzer.swift');s=p.read_text();o='paused.contains(i) || breaks.contains(i)';assert s.count(o)==1;p.write_text(s.replace(o,'paused.contains(i)'))"
mutate "gpx_export_writes_each_trkseg" "EmuquTests/TrackSegmentsTests" "Emuqu/Sources/Analysis/GPXExporter.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/GPXExporter.swift');s=p.read_text();o='TrackSegments.split(timed, starts: metadata?.gpsSegmentStarts(count: timed.count))';assert s.count(o)==1;p.write_text(s.replace(o,'[timed]'))"
mutate "tcx_export_opens_a_track_per_segment" "EmuquTests/TrackSegmentsTests" "Emuqu/Sources/Analysis/TCXExporter.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/TCXExporter.swift');s=p.read_text();o='if starts.contains(idx) {';assert s.count(o)==1;p.write_text(s.replace(o,'if starts.contains(-1) {'))"
mutate "pause_windows_break_overlapping_steps" "EmuquTests/TrackSegmentsTests" "Emuqu/Sources/Analysis/TrackSegments.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/TrackSegments.swift');s=p.read_text();o='\$0.lowerBound < to && \$0.upperBound > from';assert s.count(o)==1;p.write_text(s.replace(o,'\$0.lowerBound < from && \$0.upperBound > to'))"
mutate "route_totals_skip_joins" "EmuquTests/TrackSegmentsTests" "Emuqu/Sources/Models/Route.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/Route.swift');s=p.read_text();o='let starts = TrackSegments.starts(segmentStarts, count: track.count)';assert s.count(o)==1;p.write_text(s.replace(o,'let starts = TrackSegments.starts([], count: track.count)'))"
mutate "place_history_splits_by_segment" "EmuquTests/TrackSegmentsTests" "Emuqu/Sources/Collection/PlaceHistory.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/PlaceHistory.swift');s=p.read_text();o='let starts = session.workoutMetadata?.gpsSegmentStarts(count: whole.points.count)';assert s.count(o)==1;p.write_text(s.replace(o,'let starts: [Int]? = nil'))"
mutate "elevation_chart_distance_skips_joins" "EmuquTests/TrackSegmentsTests" "Emuqu/Sources/Views/WorkoutStatsCards+Cards.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/WorkoutStatsCards+Cards.swift');s=p.read_text();o='let along = TrackSegments.cumulativeMeters(track, starts: starts)';assert s.count(o)==1;p.write_text(s.replace(o,'let along = TrackSegments.cumulativeMeters(track, starts: [])'))"
mutate "local_pace_stays_in_its_segment" "EmuquTests/TrackSegmentsTests" "Emuqu/Sources/Collection/WorkoutGeometry.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutGeometry.swift');s=p.read_text();o='let hi = min(segment.upperBound - 1, closestIdx + 5)';assert s.count(o)==1;p.write_text(s.replace(o,'let hi = min(track.count - 1, closestIdx + 5)'))"
mutate "alignment_distance_skips_joins" "EmuquTests/TrackSegmentsTests" "Emuqu/Sources/Analysis/TrackSampleAlignment.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/TrackSampleAlignment.swift');s=p.read_text();o='TrackSegments.cumulativeMeters(track, starts: starts)';assert s.count(o)==1;p.write_text(s.replace(o,'TrackSegments.cumulativeMeters(track, starts: [])'))"
mutate "beat_consistency_pairs_stop_at_breaks" "EmuquTests/TrackSegmentsTests" "Emuqu/Sources/Analysis/BeatConsistency.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/BeatConsistency.swift');s=p.read_text();o='\$0 == i - 1 && !TimeDomainAnalyzer.isRecordingBreak(between: rr[\$0], and: point)';assert s.count(o)==1;p.write_text(s.replace(o,'\$0 == i - 1'))"
mutate "poincare_pairs_stop_at_breaks" "EmuquTests/TrackSegmentsTests" "Emuqu/Sources/Views/MorningResultsCharts.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/MorningResultsCharts.swift');s=p.read_text();o='!TimeDomainAnalyzer.isRecordingBreak(between: series.points[i], and: series.points[i + 1]) else { return nil }';assert s.count(o)==1;p.write_text(s.replace(o,'true else { return nil }'))"
mutate "spectra_read_the_longest_unbroken_stretch" "EmuquTests/TrackSegmentsTests" "Emuqu/Sources/Analysis/TimeDomainAnalysis.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/TimeDomainAnalysis.swift');s=p.read_text();o='.map { \$0 ..< \$1 }.max { \$0.count < \$1.count } ?? clamped';assert s.count(o)==1;p.write_text(s.replace(o,'.map { \$0 ..< \$1 }.first ?? clamped'))"
mutate "chart_runs_split_at_holes" "EmuquTests/TrackSegmentsTests" "Emuqu/Sources/Analysis/TrackSegments.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/TrackSegments.swift');s=p.read_text();o='xs[index] - xs[index - 1] > maxGap';assert s.count(o)==1;p.write_text(s.replace(o,'xs[index] - xs[index - 1] > .infinity'))"
mutate "rr_waveform_runs_split_at_breaks" "EmuquTests/TrackSegmentsTests" "Emuqu/Sources/Views/HRVDetailV2View+Charts.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/HRVDetailV2View+Charts.swift');s=p.read_text();o='{ run += 1 }';assert s.count(o)==1;p.write_text(s.replace(o,'{ run += 0 }'))"
mutate "recovery_parent_clock_ignored" "EmuquTests/RecoveryCompletenessTests" "Emuqu/Sources/Services/SessionRecoveryService.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SessionRecoveryService.swift');s=p.read_text();o='if childStart <= parentStart.addingTimeInterval(parentClockTolerance) { return true }';assert s.count(o)==1;p.write_text(s.replace(o,'if childStart < parentStart { return true }'))"
mutate "recovery_parent_prefix_ignored" "EmuquTests/RecoveryCompletenessTests" "Emuqu/Sources/Services/SessionRecoveryService.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SessionRecoveryService.swift');s=p.read_text();o='return beginsWithParent(childPoints, parentPoints: parentSeries.points)';assert s.count(o)==1;p.write_text(s.replace(o,'return false'))"
mutate "merge_repair_doubles_parent" "EmuquTests/RecoveryCompletenessTests" "Emuqu/Sources/Collection/SessionRecoveryCoordinator+MergeRepair.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/SessionRecoveryCoordinator+MergeRepair.swift');s=p.read_text();o='&& !SessionRecoveryService.beginsWithParent(childSeries.points, parentPoints: parentSeries.points)';assert s.count(o)==1;p.write_text(s.replace(o,'&& true'))"
mutate "backup_part_read_swallowed" "EmuquTests/RecoveryCompletenessTests" "Emuqu/Sources/Storage/RawRRBackup+Streaming.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/RawRRBackup+Streaming.swift');s=p.read_text();o='for point in try readPointLines(at: url, sessionId: sessionId, decoder: decoder) {';assert s.count(o)==1;p.write_text(s.replace(o,'for point in (try? readPointLines(at: url, sessionId: sessionId, decoder: decoder)) ?? [] {'))"
mutate "export_over_partial_index" "EmuquTests/RecoveryCompletenessTests" "Emuqu/Sources/Export/HistoryExportGate.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Export/HistoryExportGate.swift');s=p.read_text();o='indexComplete ? nil : unreadableHistory';assert s.count(o)==1;p.write_text(s.replace(o,'nil'))"
mutate "resume_holds_saved_night_paused" "EmuquTests/RecoveryCompletenessTests" "Emuqu/Sources/Collection/SessionRecoveryCoordinator+Backup.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/SessionRecoveryCoordinator+Backup.swift');s=p.read_text();o='guard session.state == .paused else {';assert s.count(o)==1;p.write_text(s.replace(o,'guard session.state != .failed else {'))"
mutate "save_leaves_kept_paused_night_unshown" "EmuquTests/RecoveryCompletenessTests" "Emuqu/Sources/Collection/SessionRecoveryCoordinator+Backup.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/SessionRecoveryCoordinator+Backup.swift');s=p.read_text();o='if let session, session.state == .paused { await holdKeptPausedNight(session) }';assert s.count(o)==1;p.write_text(s.replace(o,'if let session, session.state == .failed { await holdKeptPausedNight(session) }'))"
mutate "stranded_backup_any_count" "EmuquTests/RecoveryCompletenessTests" "Emuqu/Sources/Services/SessionRecoveryService+Backup.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SessionRecoveryService+Backup.swift');s=p.read_text();o='}.count >= minRecoverableBeatCount';assert s.count(o)==1;p.write_text(s.replace(o,'}.count >= 0'))"
mutate "stranded_backup_left_unarchived" "EmuquTests/RecoveryCompletenessTests" "Emuqu/Sources/Services/SessionRecoveryService+Backup.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SessionRecoveryService+Backup.swift');s=p.read_text();o='rawBackup.markAsArchived(backupId)';assert s.count(o)==1;p.write_text(s.replace(o,'_ = backupId'))"
mutate "running_upload_counted_failed" "EmuquTests/RecoveryCompletenessTests" "Emuqu/Sources/Storage/CloudKitSyncManager.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/CloudKitSyncManager.swift');s=p.read_text();o='(state.uploadFailureCounts[\$0] ?? 0) > 0';assert s.count(o)==1;p.write_text(s.replace(o,'(state.uploadFailureCounts[\$0] ?? 0) >= 0'))"
mutate "recordingRunsCountsBreaks" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Analysis/TimeDomainAnalysis.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/TimeDomainAnalysis.swift');s=p.read_text();o='while next < breaks.count, breaks[next] <= index {';assert s.count(o)==1;p.write_text(s.replace(o,'while next < breaks.count, breaks[next] < 0 {'))"
mutate "morningTachogramSplitsAtBreak" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Views/MorningResultsCharts.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/MorningResultsCharts.swift');s=p.read_text();o='return (rrValues, TimeDomainAnalyzer.recordingRuns(of: Array(window), in: series.points))';assert s.count(o)==1;p.write_text(s.replace(o,'return (rrValues, rrValues.map { _ in 0 })'))"
mutate "morningHRTraceSplitsAtBreak" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Views/MorningResultsCharts.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/MorningResultsCharts.swift');s=p.read_text();o='runs: TimeDomainAnalyzer.recordingRuns(of: kept, in: series.points)';assert s.count(o)==1;p.write_text(s.replace(o,'runs: kept.map { _ in 0 }'))"
mutate "tracePathsLiftPenBetweenRuns" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Views/MorningResultsCharts.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/MorningResultsCharts.swift');s=p.read_text();o='for run in SeriesRuns.split(points, runs: runs) {';assert s.count(o)==1;p.write_text(s.replace(o,'for run in [points] {'))"
mutate "reportTachogramSplitsAtBreak" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Export/ReportSectionRenderer+Charts.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Export/ReportSectionRenderer+Charts.swift');s=p.read_text();o='let runs = TimeDomainAnalyzer.recordingRuns(of: indices, in: series.points)';assert s.count(o)==1;p.write_text(s.replace(o,'let runs = indices.map { _ in 0 }'))"
mutate "overnightPolarHRSplitsAtBreak" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Views/OvernightChartComponents.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/OvernightChartComponents.swift');s=p.read_text();o='return SeriesRuns.split(samples, runs: runs)';assert s.count(o)==1;p.write_text(s.replace(o,'return [samples]'))"
mutate "recordingCSVWritesWallClock" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Import/RRDataImporter+Timeline.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+Timeline.swift');s=p.read_text();o='point.wallClockMs.map(String.init)';assert s.count(o)==1;p.write_text(s.replace(o,'Optional<Int64>.none.map(String.init)'))"
mutate "createSessionKeepsStatedTimeline" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Import/RRDataImporter.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter.swift');s=p.read_text();o='let points = result.timeline ?? Self.endToEnd(result.rrIntervals)';assert s.count(o)==1;p.write_text(s.replace(o,'let points = Self.endToEnd(result.rrIntervals)'))"
mutate "archiveRRExportWritesWallClock" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Views/ExportAndArchiveViews.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/ExportAndArchiveViews.swift');s=p.read_text();o='point.wallClockMs.map(String.init)';assert s.count(o)==1;p.write_text(s.replace(o,'Optional<Int64>.none.map(String.init)'))"
mutate "archiveRRImportKeepsWallClock" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Import/RRDataImporter+FlowHRV.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+FlowHRV.swift');s=p.read_text();o='wallClockMs: sessionData.wallClock(at: i)';assert s.count(o)==1;p.write_text(s.replace(o,'wallClockMs: nil'))"
mutate "watchStrapBeatsEndAtOwnTime" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Collection/WatchRoutedBeats.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WatchRoutedBeats.swift');s=p.read_text();o='end -= rr';assert s.count(o)==1;p.write_text(s.replace(o,'end -= 0'))"
mutate "watchBeatNeverStartsBeforePrevious" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Collection/WatchRoutedBeats.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WatchRoutedBeats.swift');s=p.read_text();o='let start = max(Int64((beat.endEpochMs - beat.rrMillis).rounded()), lastEnd)';assert s.count(o)==1;p.write_text(s.replace(o,'let start = Int64((beat.endEpochMs - beat.rrMillis).rounded())'))"
mutate "climbsSearchedPerSegment" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Models/Route.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/Route.swift');s=p.read_text();o='return TrackSegments.ranges(count: track.count, starts: starts).flatMap { range -> [Climb] in';assert s.count(o)==1;p.write_text(s.replace(o,'return TrackSegments.ranges(count: track.count, starts: []).flatMap { range -> [Climb] in'))"
mutate "savedRouteSegmentsFollowDirection" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Services/SavedRouteStepBuilder.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SavedRouteStepBuilder.swift');s=p.read_text();o='let starts = direction == .forward ? forwardStarts : ';assert s.count(o)==1;p.write_text(s.replace(o,'let starts = direction != .forward ? forwardStarts : '))"
mutate "liveTurnsSkipJoins" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Collection/WorkoutAIContextBuilder+Context.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutAIContextBuilder+Context.swift');s=p.read_text();o='route.segmentStart(in: (i + 1) ... step.endIdx)';assert s.count(o)==1;p.write_text(s.replace(o,'route.segmentStart(in: (i + 1) ... i + 1)'))"
mutate "adjacentBeatHonoursRemovedMark" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Analysis/TimeDomainAnalysis.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/TimeDomainAnalysis.swift');s=p.read_text();o='!next.isAfterRemovedBeat && !isRecordingBreak(between: previous, and: next)';assert s.count(o)==1;p.write_text(s.replace(o,'!isRecordingBreak(between: previous, and: next)'))"
mutate "notAdjacentIncludesRemovedBeats" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Analysis/TimeDomainAnalysis.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/TimeDomainAnalysis.swift');s=p.read_text();o='beatsAfterRecordingBreak(in: points, range: range).union(beatsAfterRemovedBeat(in: points, range: range))';assert s.count(o)==1;p.write_text(s.replace(o,'beatsAfterRecordingBreak(in: points, range: range)'))"
mutate "cleanWindowAdjacencySkipsRemovedBeat" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Analysis/TimeDomainAnalysis.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/TimeDomainAnalysis.swift');s=p.read_text();o=' && !afterRemovedBeat.contains(indices[k])';assert s.count(o)==1;p.write_text(s.replace(o,''))"
mutate "cleanWindowCarriesRemovedBeats" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Analysis/TimeDomainAnalysis.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/TimeDomainAnalysis.swift');s=p.read_text();o='afterRemovedBeat: beatsAfterRemovedBeat(in: series.points, range: range)';assert s.count(o)==1;p.write_text(s.replace(o,'afterRemovedBeat: []'))"
mutate "beatConsistencySkipsRemovedBeat" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Analysis/BeatConsistency.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/BeatConsistency.swift');s=p.read_text();o=' && !point.isAfterRemovedBeat } ?? false)';assert s.count(o)==1;p.write_text(s.replace(o,' } ?? false)'))"
mutate "poincareSkipsRemovedBeat" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Views/MorningResultsCharts.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/MorningResultsCharts.swift');s=p.read_text();o='!series.points[i + 1].isAfterRemovedBeat,';assert s.count(o)==1;p.write_text(s.replace(o,'true,'))"
mutate "windowSelectionSkipsRemovedBeat" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Analysis/WindowSelector+Evaluation.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/WindowSelector+Evaluation.swift');s=p.read_text();o='breaks: breaks.union(removed))';assert s.count(o)==1;p.write_text(s.replace(o,'breaks: breaks)'))"
mutate "sleepVariabilitySkipsRemovedBeat" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Analysis/HRVSleepStageClassifier.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/HRVSleepStageClassifier.swift');s=p.read_text();o=' && !points[indices[k]].isAfterRemovedBeat';assert s.count(o)==1;p.write_text(s.replace(o,''))"
mutate "retimedKeepsRemovedMark" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Models/RRModels.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/RRModels.swift');s=p.read_text();o='hr: hr, followsRemovedBeat: isAfterRemovedBeat)';assert s.count(o)==1;p.write_text(s.replace(o,'hr: hr)'))"
mutate "removedMarkEncodedOnlyWhenSet" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Models/RRModels.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/RRModels.swift');s=p.read_text();o='self.followsRemovedBeat = followsRemovedBeat ? true : nil';assert s.count(o)==1;p.write_text(s.replace(o,'self.followsRemovedBeat = followsRemovedBeat'))"
mutate "memoryPullMarksRemovedBeat" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Collection/StrapPPIFilter.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapPPIFilter.swift');s=p.read_text();o='removedSinceLastKept && !kept.isEmpty';assert s.count(o)==1;p.write_text(s.replace(o,'false'))"
mutate "livePPIMarksRemovedBeat" "EmuquTests/WorkoutStrapOwnershipTests" "Emuqu/Sources/Collection/StrapStreamSession.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapStreamSession.swift');s=p.read_text();o='                ppiRemovedSinceLastBeat = true';assert s.count(o)==1;p.write_text(s.replace(o,'                ppiRemovedSinceLastBeat = false'))"
mutate "rrExportsWriteRemovedMark" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Import/RRDataImporter+Timeline.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+Timeline.swift');s=p.read_text();o='point.isAfterRemovedBeat ? ';assert s.count(o)==1;p.write_text(s.replace(o,'point.isAfterRemovedBeat && false ? '))"
mutate "recordingImportReadsRemovedMark" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Import/RRDataImporter+Timeline.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+Timeline.swift');s=p.read_text();o='return RRPoint(t_ms: t, rr_ms: rr, wallClockMs: wall, followsRemovedBeat: removed)';assert s.count(o)==1;p.write_text(s.replace(o,'return RRPoint(t_ms: t, rr_ms: rr, wallClockMs: wall, followsRemovedBeat: false)'))"
mutate "archiveImportReadsRemovedMark" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Import/RRDataImporter+FlowHRV.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+FlowHRV.swift');s=p.read_text();o='followsRemovedBeat: sessionData.followsRemovedBeat(at: i)';assert s.count(o)==1;p.write_text(s.replace(o,'followsRemovedBeat: false'))"
mutate "mergeKeepsRemovedMark" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Collection/WorkoutRRMerge.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutRRMerge.swift');s=p.read_text();o='return point.retimed(t_ms: clock, wallClockMs: point.wallClockMs)';assert s.count(o)==1;p.write_text(s.replace(o,'return RRPoint(t_ms: clock, rr_ms: point.rr_ms, wallClockMs: point.wallClockMs, hr: point.hr)'))"
mutate "statedTimelineReadsWallClock" "EmuquTests/RecordingBreakLeftoversTests" "Emuqu/Sources/Import/RRDataImporter+Timeline.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+Timeline.swift');s=p.read_text();o='wallClockMs: wall, followsRemovedBeat: removed)';assert s.count(o)==1;p.write_text(s.replace(o,'wallClockMs: nil, followsRemovedBeat: removed)'))"
mutate "beat_copies_matched_like_with_like" "EmuquTests/BeatTimelineTests" "Emuqu/Sources/Collection/DataSourceSelector.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/DataSourceSelector.swift');s=p.read_text();o='abs(lhsWall - rhsWall) < duplicateToleranceMs';assert s.count(o)==1;p.write_text(s.replace(o,'abs(lhsWall - rhsWall) < 0'))"
mutate "composite_coverage_on_real_clock" "EmuquTests/BeatTimelineTests" "Emuqu/Sources/Collection/DataSourceSelector.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/DataSourceSelector.swift');s=p.read_text();o='guard beat.timeMs >= first.timeMs, beat.timeMs <= endMs else { return true }';assert s.count(o)==1;p.write_text(s.replace(o,'guard beat.timeMs >= first.point.t_ms, beat.timeMs <= endMs - (last.timeMs - last.point.t_ms) else { return true }'))"
mutate "merge_sets_real_start" "EmuquTests/BeatTimelineTests" "Emuqu/Sources/Collection/DataSourceSelector.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/DataSourceSelector.swift');s=p.read_text();o='interleaved(primary, secondary).map { \$0.point.retimed(t_ms: \$0.timeMs, wallClockMs: \$0.point.wallClockMs) }';assert s.count(o)==1;p.write_text(s.replace(o,'interleaved(primary, secondary).map { \$0.point.retimed(t_ms: \$0.point.wallClockMs ?? \$0.timeMs, wallClockMs: \$0.point.wallClockMs) }'))"
mutate "arrival_clock_not_read_as_starts" "EmuquTests/BeatTimelineTests" "Emuqu/Sources/Models/BeatTimeline.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/BeatTimeline.swift');s=p.read_text();o='return after - before >= Int64(previous.rr_ms) - startClockSlackMs';assert s.count(o)==1;p.write_text(s.replace(o,'return after - before >= 0'))"
mutate "rejected_time_not_unreceived" "EmuquTests/BeatTimelineTests" "Emuqu/Sources/Models/BeatTimeline.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/BeatTimeline.swift');s=p.read_text();o='.filter { !points[\$0].isAfterRemovedBeat }';assert s.count(o)==1;p.write_text(s.replace(o,'.filter { _ in true }'))"
mutate "spectrum_on_real_clock" "EmuquTests/BeatTimelineTests" "Emuqu/Sources/Analysis/FrequencyDomainAnalysis.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/FrequencyDomainAnalysis.swift');s=p.read_text();o='let beatTimes = BeatTimeline.ms(series.points, in: range)';assert s.count(o)==1;p.write_text(s.replace(o,'let beatTimes = series.points[range].map { \$0.t_ms }'))"
mutate "respiration_on_real_clock" "EmuquTests/BeatTimelineTests" "Emuqu/Sources/Analysis/HRVAnalysisPipeline+Metrics.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/HRVAnalysisPipeline+Metrics.swift');s=p.read_text();o='let beatTimes = BeatTimeline.ms(series.points, in: windowStart ..< windowEnd)';assert s.count(o)==1;p.write_text(s.replace(o,'let beatTimes = series.points[windowStart ..< windowEnd].map { \$0.t_ms }'))"
mutate "dfa_counts_sensor_removed_beats" "EmuquTests/BeatTimelineTests" "Emuqu/Sources/Analysis/TimeDomainAnalysis.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/TimeDomainAnalysis.swift');s=p.read_text();o='removedBeatCounts: removedBeatCounts(in: series.points, range: range)';assert s.count(o)==1;p.write_text(s.replace(o,'removedBeatCounts: [:]'))"
mutate "window_dfa_counts_sensor_removed_beats" "EmuquTests/BeatTimelineTests" "Emuqu/Sources/Analysis/WindowSelector+Evaluation.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/WindowSelector+Evaluation.swift');s=p.read_text();o='removedBeatCounts: TimeDomainAnalyzer.removedBeatCounts(in: series.points, range: range)';assert s.count(o)==1;p.write_text(s.replace(o,'removedBeatCounts: [:]'))"
mutate "timeline_import_allows_batch_ties" "EmuquTests/BeatTimelineTests" "Emuqu/Sources/Import/RRDataImporter+Timeline.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+Timeline.swift');s=p.read_text();o='previous.t_ms < next.t_ms || (previous.t_ms == next.t_ms';assert s.count(o)==1;p.write_text(s.replace(o,'previous.t_ms < next.t_ms || (previous.t_ms < next.t_ms'))"
mutate "timeline_import_spreads_batch_ties" "EmuquTests/BeatTimelineTests" "Emuqu/Sources/Import/RRDataImporter+Timeline.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+Timeline.swift');s=p.read_text();o='return zip(points, BeatTimeline.ms(points)).map { \$0.retimed(t_ms: \$1, wallClockMs: \$0.wallClockMs) }';assert s.count(o)==1;p.write_text(s.replace(o,'return points'))"
mutate "export_import_spreads_batch_ties" "EmuquTests/BeatTimelineTests" "Emuqu/Sources/Import/RRDataImporter+FlowHRV.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+FlowHRV.swift');s=p.read_text();o='let points = Self.spreadingSharedTimes(sessionData.timestamps.indices.map { i in';assert s.count(o)==1;p.write_text(s.replace(o,'let points = (sessionData.timestamps.indices.map { i in'))"
mutate "backup_ties_keep_write_order" "EmuquTests/BeatTimelineTests" "Emuqu/Sources/Storage/RawRRBackup+Streaming.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/RawRRBackup+Streaming.swift');s=p.read_text();o='(\$0.element.t_ms, \$0.offset) < (\$1.element.t_ms, \$1.offset)';assert s.count(o)==1;p.write_text(s.replace(o,'(\$0.element.t_ms, \$1.offset) < (\$1.element.t_ms, \$0.offset)'))"
mutate "watch_reject_marks_next_beat" "EmuquTests/BeatTimelineTests" "Emuqu/Sources/Collection/WatchRoutedBeats.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WatchRoutedBeats.swift');s=p.read_text();o='placed.append(PlacedWatchBeat(startEpochMs: start, rrMs: rrMs, followsRemovedBeat: removedBefore))';assert s.count(o)==1;p.write_text(s.replace(o,'placed.append(PlacedWatchBeat(startEpochMs: start, rrMs: rrMs, followsRemovedBeat: false))'))"
mutate "watch_reject_keeps_its_time" "EmuquTests/BeatTimelineTests" "Emuqu/Sources/Collection/WatchRoutedBeats.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WatchRoutedBeats.swift');s=p.read_text();o='let rr = removed ? (sent.isFinite && sent > 0 ? sent : 0) : sent';assert s.count(o)==1;p.write_text(s.replace(o,'let rr = removed ? 0 : sent'))"
mutate "workout_sources_interleave_on_real_clock" "EmuquTests/BeatTimelineTests" "Emuqu/Sources/Collection/WorkoutRRMerge.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutRRMerge.swift');s=p.read_text();o='let (phoneTimes, watchTimes) = (BeatTimeline.ms(phone), BeatTimeline.ms(watch))';assert s.count(o)==1;p.write_text(s.replace(o,'let (phoneTimes, watchTimes) = (phone.map { \$0.wallClockMs ?? 0 }, watch.map { \$0.wallClockMs ?? 0 })'))"
mutate "sleep_stage_beats_own_time" "EmuquTests/BeatTimelineTests" "Emuqu/Sources/Analysis/HRVSleepStageClassifier.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/HRVSleepStageClassifier.swift');s=p.read_text();o='zip(rrPoints, BeatTimeline.ms(rrPoints)).map { \$0.retimed(t_ms: \$1, wallClockMs: \$0.wallClockMs) }';assert s.count(o)==1;p.write_text(s.replace(o,'rrPoints.map { \$0.retimed(t_ms: \$0.exportTimeMs, wallClockMs: \$0.wallClockMs) }'))"
mutate "verification_gap_on_real_clock" "EmuquTests/BeatTimelineTests" "Emuqu/Sources/Analysis/Verification.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/Verification.swift');s=p.read_text();o='let times = BeatTimeline.ms(points)';assert s.count(o)==1;p.write_text(s.replace(o,'let times = points.map { \$0.t_ms }'))"
mutate "workout_device_bound_by_real_time" "EmuquTests/BeatTimelineTests" "Emuqu/Sources/Collection/WorkoutRecorder+DeviceFetch.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutRecorder+DeviceFetch.swift');s=p.read_text();o='let bounded = zip(devicePoints, BeatTimeline.ms(devicePoints))';assert s.count(o)==1;p.write_text(s.replace(o,'let bounded = zip(devicePoints, devicePoints.map { \$0.t_ms })'))"
mutate "data_loss_excludes_rejected" "EmuquTests/BeatTimelineTests" "Emuqu/Sources/Models/RRModels.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/RRModels.swift');s=p.read_text();o='return Double(BeatTimeline.unreceivedMs(points)) / Double(spanMs) * 100.0';assert s.count(o)==1;p.write_text(s.replace(o,'return Double(spanMs - durationMs) / Double(spanMs) * 100.0'))"
mutate "beat_chart_axis_real_time" "EmuquTests/BeatTimelineTests" "Emuqu/Sources/Views/HRVDetailV2View+Charts.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/HRVDetailV2View+Charts.swift');s=p.read_text();o='let beatTimes = BeatTimeline.ms(series.points)';assert s.count(o)==1;p.write_text(s.replace(o,'let beatTimes = series.points.map { \$0.t_ms }'))"
mutate "merge_moves_analysis_times" "EmuquTests/BeatTimelineTests" "Emuqu/Sources/Storage/SessionMerger+Rebase.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/SessionMerger+Rebase.swift');s=p.read_text();o='let moved = movedTimes(result, by: beats.movedMs)';assert s.count(o)==1;p.write_text(s.replace(o,'let moved = result'))"
mutate "window_time_floor" "EmuquTests/WindowSpanSufficiencyTests" "Emuqu/Sources/Analysis/WindowSelector+Evaluation.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/WindowSelector+Evaluation.swift');s=p.read_text();o='while Self.spanMs(points, start ..< end) < config.minWindowSpanMs {';assert s.count(o)==1;p.write_text(s.replace(o,'while Self.spanMs(points, start ..< end) < 0 {'))"
mutate "block_ends_at_last_beat_end" "EmuquTests/WindowSpanSufficiencyTests" "Emuqu/Sources/Analysis/WindowSelector+Evaluation.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/WindowSelector+Evaluation.swift');s=p.read_text();o='startMs: firstPoint.t_ms, endMs: lastPoint.endMs,';assert s.count(o)==1;p.write_text(s.replace(o,'startMs: firstPoint.t_ms, endMs: lastPoint.t_ms,'))"
mutate "short_band_beat_fallback" "EmuquTests/WindowSpanSufficiencyTests" "Emuqu/Sources/Analysis/WindowSelector+Evaluation.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/WindowSelector+Evaluation.swift');s=p.read_text();o='&& Self.spanMs(points, grid.bandStart ..< grid.bandEnd) >= config.minWindowSpanMs';assert s.count(o)==1;p.write_text(s.replace(o,'&& Self.spanMs(points, grid.bandStart ..< grid.bandEnd) >= 0'))"
mutate "baseline_gate_shared_span" "EmuquTests/WindowSpanSufficiencyTests" "Emuqu/Sources/Analysis/BaselineTracker.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/BaselineTracker.swift');s=p.read_text();o='guard spanMs >= HRVConstants.MinimumDuration.forReliableWindowMs else { return false }';assert s.count(o)==1;p.write_text(s.replace(o,'guard spanMs > HRVConstants.MinimumDuration.forReliableWindowMs else { return false }'))"
mutate "manual_window_time_floor" "EmuquTests/WindowSpanSufficiencyTests" "Emuqu/Sources/Analysis/WindowSelector+Scoring.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/WindowSelector+Scoring.swift');s=p.read_text();o='let (windowStartIdx, windowEndIdx) = manualTimeFloored(points: points, start: start, end: end)';assert s.count(o)==1;p.write_text(s.replace(o,'let (windowStartIdx, windowEndIdx) = (start, end)'))"
mutate "vitals_baseline_night_floor" "EmuquTests/WindowSpanSufficiencyTests" "Emuqu/Sources/Analysis/VitalsScoring.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/VitalsScoring.swift');s=p.read_text();o='guard nights.count >= BaselineTracker.RecoveryBaselineStats.minimumDays else { return nil }';assert s.count(o)==1;p.write_text(s.replace(o,'guard nights.count >= 1 else { return nil }'))"
mutate "offline_alpha1_span" "EmuquTests/WorkoutSpanSufficiencyTests" "Emuqu/Sources/Analysis/WorkoutAlpha1Reanalyzer.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/WorkoutAlpha1Reanalyzer.swift');s=p.read_text();o='spanSec: Double(last.endMs - first.t_ms) / 1_000,';assert s.count(o)==1;p.write_text(s.replace(o,'spanSec: 120,'))"
mutate "alpha1_full_window_gate" "EmuquTests/WorkoutSpanSufficiencyTests" "Emuqu/Sources/Analysis/LiveDFAAnalyzer.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/LiveDFAAnalyzer.swift');s=p.read_text();o='beats >= minBeats && spanSec >= windowSec - windowSpanSlackSec';assert s.count(o)==1;p.write_text(s.replace(o,'beats >= minBeats'))"
mutate "segment_floor_real_clock" "EmuquTests/WorkoutSpanSufficiencyTests" "Emuqu/Sources/Services/MorningProcessingService+Merging.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/MorningProcessingService+Merging.swift');s=p.read_text();o='BeatTimeline.spanMs(points) >= minimumMergeableMinutes * 60_000';assert s.count(o)==1;p.write_text(s.replace(o,'(points.last?.endMs ?? 0) - (points.first?.t_ms ?? 0) >= minimumMergeableMinutes * 60_000'))"
mutate "hrr_measured_offset" "EmuquTests/WorkoutSpanSufficiencyTests" "Emuqu/Sources/Analysis/HRRCaptureService.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/HRRCaptureService.swift');s=p.read_text();o='max(0, Int(now.timeIntervalSince(stopDate).rounded()))';assert s.count(o)==1;p.write_text(s.replace(o,'max(0, Int(now.timeIntervalSince(stopDate).rounded()) / 60 * 60)'))"
mutate "decoupling_moving_minimum" "EmuquTests/WorkoutSpanSufficiencyTests" "Emuqu/Sources/Analysis/WorkoutAnalyzer.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/WorkoutAnalyzer.swift');s=p.read_text();o='static let decouplingMinimumMovingSeconds = 300';assert s.count(o)==1;p.write_text(s.replace(o,'static let decouplingMinimumMovingSeconds = 200'))"
mutate "live_decoupling_shared_minimum" "EmuquTests/WorkoutLiveTrendsTests" "Emuqu/Sources/Analysis/WorkoutLiveTrends.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/WorkoutLiveTrends.swift');s=p.read_text();o='last.offsetSec >= WorkoutAnalyzer.decouplingMinimumMovingSeconds else';assert s.count(o)==1;p.write_text(s.replace(o,'last.offsetSec >= halfMetricsMinSeconds else'))"
mutate "trailing_rest_in_time" "EmuquTests/WorkoutSpanSufficiencyTests" "Emuqu/Sources/Services/WorkoutRecoveryService.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/WorkoutRecoveryService.swift');s=p.read_text();o='static let minimumTrailingRestMs: Int64 = 60_000';assert s.count(o)==1;p.write_text(s.replace(o,'static let minimumTrailingRestMs: Int64 = 40_000'))"
mutate "spectral_span_fencepost" "EmuquTests/WorkoutSpanSufficiencyTests" "Emuqu/Sources/Analysis/FrequencyDomainAnalysis.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/FrequencyDomainAnalysis.swift');s=p.read_text();o='Double(max(0, sampleCount - 1)) / fs / 60.0';assert s.count(o)==1;p.write_text(s.replace(o,'Double(max(0, sampleCount)) / fs / 60.0'))"
mutate "pick_kept_when_its_beats_removed" "EmuquTests/NightBeatsEditTests" "Emuqu/Sources/Storage/NightBeatsEdit.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/NightBeatsEdit.swift');s=p.read_text();o='return kept >= result.windowEnd - result.windowStart';assert s.count(o)==1;p.write_text(s.replace(o,'return kept >= 0'))"
mutate "span_ignores_beats_tail" "EmuquTests/NightBeatsEditTests" "Emuqu/Sources/Storage/NightBeatsEdit.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/NightBeatsEdit.swift');s=p.read_text();o='session.endDate = newEnd < oldEnd ? min(end, newEnd) : max(end, newEnd)';assert s.count(o)==1;p.write_text(s.replace(o,'session.endDate = end'))"
mutate "beat_edit_keeps_old_flags" "EmuquTests/NightBeatsEditTests" "Emuqu/Sources/Storage/NightBeatsEdit.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/NightBeatsEdit.swift');s=p.read_text();o='        session.artifactFlags = nil\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"
mutate "fold_asks_no_reanalysis" "EmuquTests/NightBeatsEditTests" "Emuqu/Sources/Storage/ArchiveStore+MergeTarget.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/ArchiveStore+MergeTarget.swift');s=p.read_text();o='if merge.beatsChanged { NightBeatsEdit.requestReanalysis(of: merged, detail: \"a same-night recording was folded in\") }';assert s.count(o)==1;p.write_text(s.replace(o,'if merge.beatsChanged {}'))"
mutate "batch_fold_asks_no_reanalysis" "EmuquTests/NightBeatsEditTests" "Emuqu/Sources/Storage/ArchiveStore+Batch.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/ArchiveStore+Batch.swift');s=p.read_text();o='if merge.beatsChanged { NightBeatsEdit.requestReanalysis(of: existingSession, detail: \"an imported recording was folded in\") }';assert s.count(o)==1;p.write_text(s.replace(o,'if merge.beatsChanged {}'))"
mutate "merge_always_reports_beats" "EmuquTests/NightBeatsEditTests" "Emuqu/Sources/Storage/SessionMerger.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/SessionMerger.swift');s=p.read_text();o='return (outcome.hasChanges, outcome.rrChange != nil)';assert s.count(o)==1;p.write_text(s.replace(o,'return (outcome.hasChanges, true)'))"
mutate "failed_unlink_not_undone" "EmuquTests/ReanalysisServiceTests" "Emuqu/Sources/Services/ReanalysisService+Sleep.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/ReanalysisService+Sleep.swift');s=p.read_text();o='                try archive.archive(linked, skipSameNightMerge: false, requestingReupload: true)\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"
mutate "merge_undo_keeps_merged_beats" "EmuquTests/NightBeatsEditTests" "Emuqu/Sources/Collection/SessionRecoveryCoordinator+Backup.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/SessionRecoveryCoordinator+Backup.swift');s=p.read_text();o='        stored.rrSeries = before.rrSeries\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"
mutate "rescore_inputs_ignore_span" "EmuquTests/NightBeatsEditTests" "Emuqu/Sources/Services/RescoreWrite.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/RescoreWrite.swift');s=p.read_text();o='(startDate, endDate) = (session.startDate, session.endDate)';assert s.count(o)==1;p.write_text(s.replace(o,'(startDate, endDate) = (Date.distantPast, nil)'))"
mutate "duration_ignores_stored_active_time" "EmuquTests/WorkoutAccidentalStartTests" "Emuqu/Sources/Views/WorkoutStatsCards.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/WorkoutStatsCards.swift');s=p.read_text();o='if let active = metadata?.activeSeconds, active > 0 { return active }';assert s.count(o)==1;p.write_text(s.replace(o,'if let active = metadata?.activeSeconds, active < 0 { return active }'))"
mutate "finalize_stores_no_active_time" "EmuquTests/WorkoutAccidentalStartTests" "Emuqu/Sources/Collection/WorkoutFinalizer+Finalize.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutFinalizer+Finalize.swift');s=p.read_text();o='        metadata.activeSeconds = activeSeconds\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"
mutate "watch_ignores_not_saved" "EmuquTests/WatchMessageDecodingTests" "EmuquWatch Watch App/WatchMessageDecoding.swift" "import pathlib;p=pathlib.Path('EmuquWatch Watch App/WatchMessageDecoding.swift');s=p.read_text();o='notSaved: message[';assert s.count(o)==1;p.write_text(s.replace(o,'notSaved: false && message['))"
mutate "accidental_start_ignores_duration" "EmuquTests/WorkoutAccidentalStartTests" "Emuqu/Sources/Collection/WorkoutAccidentalStart.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutAccidentalStart.swift');s=p.read_text();o='guard activeSeconds < maxActiveSeconds else { return false }';assert s.count(o)==1;p.write_text(s.replace(o,'guard activeSeconds < .infinity else { return false }'))"
mutate "not_archived_retires_backups" "EmuquTests/WorkoutAccidentalStartTests" "Emuqu/Sources/Collection/WorkoutSessionLifecycle+Save.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutSessionLifecycle+Save.swift');s=p.read_text();o='        guard session.state != .failed else {\n            debugLog(';assert s.count(o)==1;p.write_text(s.replace(o,'        guard session.state != .failed else {\n            retireRedundantBackups(for: session)\n            debugLog('))"
mutate "save_not_archived_saves_nothing" "EmuquTests/WorkoutAccidentalStartTests" "Emuqu/Sources/Collection/WorkoutSessionLifecycle+Save.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutSessionLifecycle+Save.swift');s=p.read_text();o='lifecycle.saveOutcome = archive(session: session)';assert s.count(o)==1;p.write_text(s.replace(o,'lifecycle.saveOutcome = .notArchived'))"
mutate "leaving_accidental_start_keeps_backups" "EmuquTests/WorkoutAccidentalStartTests" "Emuqu/Sources/Collection/WorkoutRecorder+DeviceFetch.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutRecorder+DeviceFetch.swift');s=p.read_text();o='        session.discardNotArchived()\n        lifecycle.finishedSession = nil';assert s.count(o)==1;p.write_text(s.replace(o,'        lifecycle.finishedSession = nil'))"
mutate "summary_blind_to_not_archived" "EmuquTests/WorkoutAccidentalStartTests" "Emuqu/Sources/Views/FitnessPostSummaryView.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Views/FitnessPostSummaryView.swift');s=p.read_text();o='return lifecycle.saveOutcome == .notArchived && lifecycle.finishedSession?.id == initialSession.id';assert s.count(o)==1;p.write_text(s.replace(o,'return lifecycle.saveOutcome == .notSavedYet && lifecycle.finishedSession?.id == initialSession.id'))"
mutate "lost_sessions_deletes_short_backups" "EmuquTests/LostSessionRecoveryTests" "Emuqu/Sources/Services/SessionRecoveryService.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/SessionRecoveryService.swift');s=p.read_text();o='let lost = orphans.compactMap';assert s.count(o)==1;p.write_text(s.replace(o,'for orphan in orphans where (counts[orphan.id] ?? Int.max) < Self.minRecoverableBeatCount { try? rawBackup.discardBackup(orphan.id) }\n        let lost = orphans.compactMap'))"
mutate "trim_ignores_stored_track" "EmuquTests/WorkoutTrimDerivedFieldsTests" "Emuqu/Sources/Services/WorkoutRecoveryService+Streams.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/WorkoutRecoveryService+Streams.swift');s=p.read_text();o='track: overrideTrack?.fixes ?? storedTrack(prepared.existingSession),';assert s.count(o)==1;p.write_text(s.replace(o,'track: overrideTrack?.fixes ?? [],'))"
mutate "carried_samples_cut_on_wall_clock" "EmuquTests/WorkoutTrimDerivedFieldsTests" "Emuqu/Sources/Services/WorkoutRecoveryService+CarryForward.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/WorkoutRecoveryService+CarryForward.swift');s=p.read_text();o='new.activeOffset(forWallClockSeconds: \$0.timeIntervalSince(session.startDate))';assert s.count(o)==1;p.write_text(s.replace(o,'Int(\$0.timeIntervalSince(session.startDate))'))"
mutate "rebuild_ignores_sample_distance" "EmuquTests/WorkoutTrimDerivedFieldsTests" "Emuqu/Sources/Services/WorkoutRecoveryService+Streams.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/WorkoutRecoveryService+Streams.swift');s=p.read_text();o='counted > (metadata.distanceMeters ?? 0) {';assert s.count(o)==1;p.write_text(s.replace(o,'counted < 0 {'))"
mutate "rebuild_drops_sample_power" "EmuquTests/WorkoutTrimDerivedFieldsTests" "Emuqu/Sources/Services/WorkoutRecoveryService+Streams.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/WorkoutRecoveryService+Streams.swift');s=p.read_text();o='applySamplePower(to: &metadata, samples: samples, activeSeconds: activeSeconds, ftp: ftp)';assert s.count(o)==1;p.write_text(s.replace(o,'_ = (samples, ftp)'))"
mutate "trim_refuses_few_beats" "EmuquTests/WorkoutTrimDerivedFieldsTests" "Emuqu/Sources/Collection/SessionRecoveryCoordinator+Backup.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/SessionRecoveryCoordinator+Backup.swift');s=p.read_text();o='        guard archive.store.exists(sessionId) else {';assert s.count(o)==1;p.write_text(s.replace(o,'        guard clipped.count >= 30, archive.store.exists(sessionId) else {'))"
mutate "rebuild_aborts_without_beats" "EmuquTests/WorkoutTrimDerivedFieldsTests" "Emuqu/Sources/Services/WorkoutRecoveryService.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Services/WorkoutRecoveryService.swift');s=p.read_text();o='overrides.rrPoints == nil {';assert s.count(o)==1;p.write_text(s.replace(o,'overrides.rrPoints?.isEmpty ?? true {'))"
mutate "confirmation_question_spoken_even_if_rewritten" "EmuquTests/VoiceConversationControllerTests" "Emuqu/Sources/Assistant/VoiceConversationController+Speech.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/VoiceConversationController+Speech.swift');s=p.read_text();o='        guarded == text && PhoneticOverrides.stripForDisplay(text) == text';assert s.count(o)==1;p.write_text(s.replace(o,'        !guarded.isEmpty'))"
mutate "confirmation_question_through_scrubbing_speak" "EmuquTests/VoiceConversationControllerTests" "Emuqu/Sources/Assistant/VoiceAudioPipeline+Audio.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/VoiceAudioPipeline+Audio.swift');s=p.read_text();o='let line = controller.speakVerbatim(question, voice: WorkoutVoiceCoach.appLanguageVoice())';assert s.count(o)==1;p.write_text(s.replace(o,'let line = controller.speak(question, voice: WorkoutVoiceCoach.appLanguageVoice(), scripted: true)'))"
mutate "device_status_connection_inverted" "EmuquTests/RRCollectorObservableStateTests" "Emuqu/Sources/Collection/CollectorBindings+Observations.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/CollectorBindings+Observations.swift');s=p.read_text();o='bindings.deviceStatus.isDeviceConnected = state == .connected';assert s.count(o)==1;p.write_text(s.replace(o,'bindings.deviceStatus.isDeviceConnected = state != .connected'))"
mutate "device_status_battery_not_forwarded" "EmuquTests/RRCollectorObservableStateTests" "Emuqu/Sources/Collection/CollectorBindings+Observations.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/CollectorBindings+Observations.swift');s=p.read_text();o='bindings.deviceStatus.batteryLevel = level';assert s.count(o)==1;p.write_text(s.replace(o,'bindings.deviceStatus.batteryLevel = level.map { _ in 0 }'))"
mutate "hard_workout_taper_day_one" "EmuquTests/StressAnalysisTests" "Emuqu/Sources/Collection/TrainingLoad.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/TrainingLoad.swift');s=p.read_text();o='if days == 1 { return -1.0 }';assert s.count(o)==1;p.write_text(s.replace(o,'if days == 1 { return -2.0 }'))"
mutate "hard_workout_taper_positive_applied" "EmuquTests/StressAnalysisTests" "Emuqu/Sources/Analysis/StressAnalysis.swift" "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/StressAnalysis.swift');s=p.read_text();o='if trainingLoadAdjustment < 0 { score -= trainingLoadAdjustment }';assert s.count(o)==1;p.write_text(s.replace(o,'score -= trainingLoadAdjustment'))"
mutate "interval_ms_header_missed" "EmuquTests/RRDataImporterTests" \
    "Emuqu/Sources/Import/RRDataImporter+CSV.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/RRDataImporter+CSV.swift');s=p.read_text();o=' || words == [\"interval\", \"ms\"]';assert s.count(o)==1;p.write_text(s.replace(o,''))"

echo
echo "  $PASS caught, $FAIL survived, $INVALID did not compile, $SKIP skipped"
# A share that ran nothing measured nothing.
if [[ -z "$FILTER" ]] && (( PASS + FAIL + SKIP + INVALID == 0 )); then
    echo "  No mutation ran in share $SHARD: fewer suites than shares." >&2
    exit 1
fi
# A SKIP means the mutation was never applied or the suite could not be run —
# in either case that mutation was NOT verified. Treating skips as success is
# the same "reports clean while measuring nothing" failure this whole script
# exists to catch, so they fail the run.
# A mutation that does not compile was never seen by a test either.
if (( FAIL != 0 || SKIP != 0 || INVALID != 0 )); then
    if (( INVALID != 0 )); then
        echo
        echo "  $INVALID mutation(s) do not compile, so no test was asked about them."
        echo "  That is a bug in the mutation: rewrite it to change behaviour, not syntax."
    fi
    if (( SKIP != 0 )); then
        echo
        echo "  $SKIP mutation(s) were NOT verified. A skip is not a pass."
        echo "  'already red' usually means another xcodebuild was running against"
        echo "  the same derived data — run this script on its own."
    fi
    exit 1
fi
