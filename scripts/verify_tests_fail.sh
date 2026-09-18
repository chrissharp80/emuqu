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

FILTER="${1:-}"
PROJECT="Emuqu.xcodeproj"
SCHEME="Emuqu"
DERIVED="${MUTATION_DERIVED_DATA:-build/MutationDerivedData}"
PASS=0; FAIL=0; SKIP=0

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

# Returns 0 = tests passed, 1 = tests failed, 2 = the BUILD failed.
#
# Collapsing all three into a single non-zero reports a transient build
# failure as "the suite was already red" and silently skips the mutation —
# several suites at once on a bad run, each of them passing individually. A
# build failure is an infrastructure problem, not evidence about the tests,
# and must not be mistaken for one.
run_suite() {
    local log="$BACKUP_DIR/run.log"
    if xcodebuild test -project "$PROJECT" -scheme "$SCHEME" -destination "$DEST" \
        -derivedDataPath "$DERIVED" -only-testing:"$1" \
        -parallel-testing-enabled NO >"$log" 2>&1; then
        return 0
    fi
    # No test ever executed => the build (or the runner) failed.
    if grep -qE "\*\* (BUILD|TEST BUILD) FAILED \*\*|error: (Building|Failed to)" "$log" \
       || ! grep -q "Test Suite\|Test Case" "$log"; then
        return 2
    fi
    return 1
}

# mutate <name> <suite> <file> <python mutation>
mutate() {
    local name="$1" suite="$2" file="$3" script="$4"

    if [[ -n "$FILTER" && "$name" != *"$FILTER"* ]]; then return; fi

    # The suite must be green before the mutation, or a red afterwards proves
    # nothing about the mutation.
    run_suite "$suite"; local baseline=$?
    if (( baseline == 2 )); then
        # One retry: these are usually transient, and a build failure must not
        # be recorded as evidence about the tests either way.
        run_suite "$suite"; baseline=$?
    fi
    if (( baseline != 0 )); then
        if (( baseline == 2 )); then
            printf "  \033[33mSKIP\033[0m  %-30s BUILD failed (not a test result)\n" "$name"
        else
            printf "  \033[33mSKIP\033[0m  %-30s %s was already red\n" "$name" "$suite"
        fi
        SKIP=$((SKIP + 1)); return
    fi

    backup "$file"
    if ! python3 -c "$script" 2>/dev/null; then
        printf "  \033[33mSKIP\033[0m  %-30s could not apply the mutation\n" "$name"
        restore_all; SKIP=$((SKIP + 1)); return
    fi

    run_suite "$suite"; local code=$?
    restore_all

    if (( code != 0 )); then
        printf "  \033[32mPASS\033[0m  %-30s %s caught it\n" "$name" "$suite"
        PASS=$((PASS + 1))
    else
        printf "  \033[31mFAIL\033[0m  %-30s SURVIVED — %s asserts nothing about this\n" "$name" "$suite"
        FAIL=$((FAIL + 1))
    fi
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

# The comparison that decides which recovery label a user sees. Flipping it
# inverts the advice at the top of the dashboard.
mutate "recovery_label_inverted" "EmuquTests/RecoveryScoreCalculatorTests" \
    "Emuqu/Sources/Analysis/RecoveryScoreCalculator+Composite.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/RecoveryScoreCalculator+Composite.swift');s=p.read_text();o='if score >= RecoveryScoreConstants.DisplayThresholds.excellent { return \"Excellent\" }';assert s.count(o)==1;p.write_text(s.replace(o,'if score <= RecoveryScoreConstants.DisplayThresholds.excellent { return \"Excellent\" }'))"

# The branch that decides whether a session is written encrypted. If nothing
# asserts on it, the encrypted write can silently regress to a plaintext fallback.
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
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/GPSAccuracyLevel.swift');s=p.read_text();o='        guard let meters, meters.isFinite,\n              meters >= Double(Int.min), meters <= Double(Int.max) else { return nil }';assert s.count(o)==1;p.write_text(s.replace(o,'        guard let meters else { return nil }'))"

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
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/LiveDFAAnalyzer.swift');s=p.read_text();o='let ectopicRatio: Double = 0.20';assert s.count(o)==1;p.write_text(s.replace(o,'let ectopicRatio: Double = 0.50'))"

# Scrubbing genuine beat-to-beat variation flattens alpha-1 the other way, so
# the lower bound matters as much as the upper one.
mutate "dfa_cleans_normal_variation" "EmuquTests/LiveDFAAnalyzerTests" \
    "Emuqu/Sources/Analysis/LiveDFAAnalyzer.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/LiveDFAAnalyzer.swift');s=p.read_text();o='let ectopicRatio: Double = 0.20';assert s.count(o)==1;p.write_text(s.replace(o,'let ectopicRatio: Double = 0.05'))"

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
    "Emuqu/Sources/Analysis/TopoElevationService.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/TopoElevationService.swift');s=p.read_text();o='            if sign == 0 { return }                      // flat: not a reversal';assert s.count(o)==1;p.write_text(s.replace(o,'            if sign == 0 { runSign = 0; return }'))"

# The threshold is what keeps DEM wobble out of the gain figure. Dropping it
# inflates elevation on every workout.
mutate "elevation_threshold_removed" "EmuquTests/TopoElevationServiceTests" \
    "Emuqu/Sources/Analysis/TopoElevationService.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/TopoElevationService.swift');s=p.read_text();o='            guard abs(runSum) >= threshold else { return }';assert s.count(o)==1;p.write_text(s.replace(o,'            guard abs(runSum) >= 0 else { return }'))"

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
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Models/UserSettings+Model.swift');s=p.read_text();o='        if let user = userRestingHR, user > 30 { return user }';assert s.count(o)==1;p.write_text(s.replace(o,'        if let user = userRestingHR, user > 0 { return user }'))"

# Normalized power's FOURTH power is what makes it differ from average power.
# Dropping to squared (or to a plain mean) makes every ragged ride read as if
# it were ridden steadily.
mutate "normalized_power_not_fourth_power" "EmuquTests/NormalizedPowerTests" \
    "Emuqu/Sources/Collection/WorkoutRecorder+Metrics.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutRecorder+Metrics.swift');s=p.read_text();o='        let fourths = windowMeans.map { pow(' + chr(36) + '0, 4) }';assert s.count(o)==1;p.write_text(s.replace(o,'        let fourths = windowMeans.map { pow(' + chr(36) + '0, 2) }'))"

# The 30-second window is what separates a sustained surge from sample noise.
mutate "normalized_power_window_shrunk" "EmuquTests/NormalizedPowerTests" \
    "Emuqu/Sources/Collection/WorkoutRecorder+Metrics.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutRecorder+Metrics.swift');s=p.read_text();o='            let mean = slice.reduce(0, +) / 30.0';assert s.count(o)==1;p.write_text(s.replace(o,'            let mean = slice.reduce(0, +) / 10.0'))"

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
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/HRVSleepStageClassifier+Watch.swift');s=p.read_text();o='        let clamped = p.isFinite ? min(max(p, 0), 1) : 0';assert s.count(o)==1;p.write_text(s.replace(o,'        let clamped = p'))"

mutate "merge_offset_range_unguarded" "EmuquTests/OvernightMergeOffsetTests" \
    "Emuqu/Sources/Utilities/MillisecondOffset.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Utilities/MillisecondOffset.swift');s=p.read_text();o='        guard ms >= -representableLimitMs, ms <= representableLimitMs else { return nil }';assert s.count(o)==1;p.write_text(s.replace(o,''))"

# Karvonen uses heart-rate RESERVE — (hr - rest) / (max - rest). Dropping the
# resting term makes it a plain %max, which shifts every training zone and
# every TRIMP figure derived from them.
mutate "karvonen_ignores_resting_hr" "EmuquTests/WorkoutGeometryTests" \
    "Emuqu/Sources/Collection/WorkoutGeometry.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutGeometry.swift');s=p.read_text();o='        let pct = Double(hr - restingHR) / Double(maxHR - restingHR)';assert s.count(o)==1;p.write_text(s.replace(o,'        let pct = Double(hr) / Double(maxHR)'))"

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

mutate "plaintext_write_undetected" "EmuquTests/PendingEncryptionLedgerTests" \
    "Emuqu/Sources/Storage/Archive+PendingEncryption.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/Archive+PendingEncryption.swift');s=p.read_text();o='return [.atomic, .completeFileProtection]';assert s.count(o)==1;p.write_text(s.replace(o,'return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]'))"

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

# The onset clamp is needed in each of the three sibling detectors. Removing
# it reinstates a 69-minute bogus onset that shrinks a 337-minute night to 268
# and skews the score.
mutate "hr_sleep_onset_clamp_removed" "EmuquTests/HRSleepEstimatorTests" \
    "Emuqu/Sources/Collection/HRSleepEstimator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/HRSleepEstimator.swift');s=p.read_text();o='        return min(sleepOnsetDetected, windowStart.addingTimeInterval(maxOnsetLatency))';assert s.count(o)==1;p.write_text(s.replace(o,'        return sleepOnsetDetected'))"

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
    "Emuqu/Sources/Collection/TrainingLoadPrecedence.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/TrainingLoadPrecedence.swift');s=p.read_text();o='        if let p = meta.powerTSS, p > 0 { return (p, .power) }';assert s.count(o)==1;p.write_text(s.replace(o,'        if let p = meta.powerTSS { return (p, .power) }'))"

# The AI's spoken zone call. Session-observed PEAK HR as the denominator
# produces "Zone 5 at 100 bpm" when the peak is only 105; the correct
# denominator is the user's physiological max.
mutate "zone_label_uses_session_peak_as_denominator" "EmuquTests/WorkoutMileMarkerEngineTests" \
    "Emuqu/Sources/Assistant/WorkoutMileMarkerEngine.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Assistant/WorkoutMileMarkerEngine.swift');s=p.read_text();o='        let frac = Double(hr) / Double(context.userMaxHR)';assert s.count(o)==1;p.write_text(s.replace(o,'        let frac = Double(hr) / Double(context.peakHR)'))"

# When every stored-HR point in the window was artifact-rejected the answer is
# nil, so the caller derives a real HR from the RR beats instead. Fabricating
# a 60 bpm sentinel biases the RHR z-score the recovery score is built on.
mutate "stored_hr_fabricates_a_sentinel" "EmuquTests/TimeDomainTests" \
    "Emuqu/Sources/Analysis/TimeDomainAnalysis.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/TimeDomainAnalysis.swift');s=p.read_text();o='        guard !hrValues.isEmpty else { return nil }';assert s.count(o)==1;p.write_text(s.replace(o,'        guard !hrValues.isEmpty else { return statistics(of: [60]) }'))"

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
    "Emuqu/Sources/Storage/Archive+Internal.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/Archive+Internal.swift');s=p.read_text();o='            return existing'+ chr(10) + '        }';assert s.count(o)==1;p.write_text(s.replace(o,'            return nil'+chr(10)+'        }'))"

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
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapLinkCoordinator.swift');s=p.read_text();o='        clearLinkReadings(preserveDeviceIdentity: wasStreaming)';assert s.count(o)==1;p.write_text(s.replace(o,'        clearLinkReadings(preserveDeviceIdentity: wasStreaming); manager.isRecordingOnDevice = false'))"

# An explicit disconnect must not reset the device recording either: the strap
# keeps writing after the phone lets go, and the morning pull retrieves it.
mutate "explicit_disconnect_stops_device_recording" "EmuquTests/PolarConnectionLifecycleTests" \
    "Emuqu/Sources/Collection/StrapDiscoveryCoordinator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapDiscoveryCoordinator.swift');s=p.read_text();o='            manager.hasReceivedSoftwareRevision = false\n            manager.connectionState = .disconnected';assert s.count(o)==1;p.write_text(s.replace(o,'            manager.hasReceivedSoftwareRevision = false; manager.isRecordingOnDevice = false\n            manager.connectionState = .disconnected'))"

# `cancelConnection` is documented safe from any state. Without the guard it
# tears down a healthy connection.
mutate "cancel_connection_drops_a_live_connection" "EmuquTests/PolarConnectionLifecycleTests" \
    "Emuqu/Sources/Collection/StrapDiscoveryCoordinator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapDiscoveryCoordinator.swift');s=p.read_text();o='            guard manager.connectionState == .connecting, let deviceId = manager.pendingDeviceId else { return }';assert s.count(o)==1;p.write_text(s.replace(o,'            guard let deviceId = manager.pendingDeviceId ?? manager.connectedDeviceId else { return }'))"

# A late callback from a previous connection must not tear down the current
# one. Without the device match, any drop for any strap clears the live link.
mutate "stale_drop_tears_down_current_link" "EmuquTests/PolarConnectionLifecycleTests" \
    "Emuqu/Sources/Collection/StrapLinkCoordinator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapLinkCoordinator.swift');s=p.read_text();o='              deviceId == manager.connectedDeviceId || deviceId == manager.pendingDeviceId';assert s.count(o)==1;p.write_text(s.replace(o,'              !deviceId.isEmpty'))"

# A session whose strap drops is given the reconnect window. Without the
# deadline nothing ever ends the wait for a strap that is not coming back.
mutate "session_drop_not_given_a_window" "EmuquTests/PolarConnectionLifecycleTests" \
    "Emuqu/Sources/Collection/StrapLinkCoordinator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapLinkCoordinator.swift');s=p.read_text();o='            if wasStreaming { armReconnectDeadline() }';assert s.count(o)==1;p.write_text(s.replace(o,'            _ = wasStreaming'))"

# A lost pairing cannot be repaired by reconnecting. A session waiting on it
# must be told now, not twenty minutes later.
mutate "pairing_loss_leaves_the_session_waiting" "EmuquTests/PolarConnectionLifecycleTests" \
    "Emuqu/Sources/Collection/StrapLinkCoordinator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapLinkCoordinator.swift');s=p.read_text();o='        if wasStreaming { manager.reconnectExhausted = true }';assert s.count(o)==1;p.write_text(s.replace(o,'        _ = wasStreaming'))"

# SDK 8.x refuses a feature call locally until the strap is ready. Treating
# that refusal as a failure abandons a recording the strap would accept a
# second later.
mutate "not_ready_refusal_treated_as_failure" "EmuquTests/PolarConnectionLifecycleTests" \
    "Emuqu/Sources/Collection/StrapLinkCoordinator.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapLinkCoordinator.swift');s=p.read_text();o='            } catch where StrapErrorClassifier.isNotReadyYet(error) {';assert s.count(o)==1;p.write_text(s.replace(o,'            } catch where StrapErrorClassifier.isNotReadyYet(error) && refusals < 0 {'))"

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
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapExerciseDecoder.swift');s=p.read_text();o='        return dated.filter { \$0.1 >= notBefore }.max { \$0.1 < \$1.1 }?.0';assert s.count(o)==1;p.write_text(s.replace(o,'        return dated.max { \$0.1 < \$1.1 }?.0'))"

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
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapPPIFilter.swift');s=p.read_text();o='            cumulativeMs += Int64(interval)';assert s.count(o)==1;p.write_text(s.replace(o,'            cumulativeMs += 0'))"

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
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapRecordingPolicy.swift');s=p.read_text();o='        StatusOutcome(isRecordingOnDevice: ongoing, recordingState: ongoing ? .recording : nil)';assert s.count(o)==1;p.write_text(s.replace(o,'        StatusOutcome(isRecordingOnDevice: ongoing, recordingState: ongoing ? .recording : .idle)'))"

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
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Analysis/MaxHeartRate.swift');s=p.read_text();o='        if let userEntered, userEntered > 0 { return userEntered }';assert s.count(o)==1;p.write_text(s.replace(o,'        if let userEntered, userEntered > 0, birthday == nil { return userEntered }'))"

# A workout that bounced between the phone and the Watch has interleaved
# timestamps. Out of order, successive differences become enormous — and
# RMSSD squares them.
mutate "rr_merge_leaves_series_unsorted" "EmuquTests/WorkoutRRMergeTests" \
    "Emuqu/Sources/Collection/WorkoutRRMerge.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutRRMerge.swift');s=p.read_text();o='        points.sort { '+chr(36)+'0.t_ms < '+chr(36)+'1.t_ms }';assert s.count(o)==1;p.write_text(s.replace(o,'        points.sort { '+chr(36)+'0.t_ms > '+chr(36)+'1.t_ms }'))"

# A watch or sourceless workout never started a strap stream. Adopting that
# buffer fabricates beats from an earlier session.
mutate "rr_merge_adopts_stale_stream_for_watch_workouts" "EmuquTests/WorkoutRRMergeTests" \
    "Emuqu/Sources/Collection/WorkoutRRMerge.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutRRMerge.swift');s=p.read_text();o='        var points: [RRPoint] = source == .strap ? streaming : []';assert s.count(o)==1;p.write_text(s.replace(o,'        var points: [RRPoint] = streaming'))"

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
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapStartSequence.swift');s=p.read_text();o='            return [.rescueExisting, .clearExisting, .beginRecording]';assert s.count(o)==1;p.write_text(s.replace(o,'            return [.clearExisting, .rescueExisting, .beginRecording]'))"

# The H10 refuses to start with a stored exercise present (error 106), and
# recording before the rescue overwrites the file being downloaded.
mutate "strap_records_before_clearing" "EmuquTests/StrapStartSequenceTests" \
    "Emuqu/Sources/Collection/StrapStartSequence.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/StrapStartSequence.swift');s=p.read_text();o='            return [.clearExisting, .beginRecording]';assert s.count(o)==1;p.write_text(s.replace(o,'            return [.beginRecording, .clearExisting]'))"

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
    "Emuqu/Sources/Collection/PolarManager+Recording.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/PolarManager+Recording.swift');s=p.read_text();o='        if await deviceIsRecording() {';assert s.count(o)==1;p.write_text(s.replace(o,'        if manager.isRecordingOnDevice {'))"

# The morning fetch must read the night before anything clears it.
mutate "morning_fetch_skips_the_stop" "EmuquTests/StrapNightTests" \
    "Emuqu/Sources/Collection/PolarManager+Recording.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/PolarManager+Recording.swift');s=p.read_text();o='        try await stopH10IfRecording(api: api, deviceId: deviceId, deviceName: deviceName)';assert s.count(o)==1;p.write_text(s.replace(o,''))"

# The strap notice waits out the start of a workout: at t=0 nothing has spoken
# yet, so "silent" is the starting state of every workout. Without the grace
# the user is told their strap is missing on the first tick.
mutate "strap_notice_before_strap_can_speak" "EmuquTests/WorkoutTickLogicTests" \
    "Emuqu/Sources/Collection/WorkoutRecorder+Ticker.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutRecorder+Ticker.swift');s=p.read_text();o='                  TimeInterval(inputs.recordingElapsedSeconds) > strapNoticeGraceSec,\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"

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
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/WorkoutPedometer.swift');s=p.read_text();o='guard let meters = rawDistanceMeters, meters.isFinite, meters >= 0 else { return nil }';assert s.count(o)==1;p.write_text(s.replace(o,'guard let meters = rawDistanceMeters else { return nil }'))"

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
# the division `inf`, and the cadence chart converts with `Int(...)`.
mutate "import_cadence_divides_by_zero_window" "EmuquTests/HealthWorkoutImporterTests" \
    "Emuqu/Sources/Import/HealthWorkoutImporter.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Import/HealthWorkoutImporter.swift');s=p.read_text();o='            guard seconds > 0, sample.value >= 0 else { return nil }';assert s.count(o)==1;p.write_text(s.replace(o,'            guard sample.count >= 0 else { return nil }'))"

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
    "Emuqu/Sources/Storage/Archive+Internal.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/Archive+Internal.swift');s=p.read_text();o='            return existing.rrSeries.map { .preserved(\$0, viaRawDecode: false) } ?? .noBeatsStored';assert s.count(o)==1;p.write_text(s.replace(o,'            return existing.rrSeries.map { .preserved(\$0, viaRawDecode: false) } ?? .unreadable'))"

# The splice exists so a metadata edit cannot overwrite a night's recording
# with nothing. Skipping it destroys the beat data on the next note, feeling,
# or CloudKit pull.
mutate "archive_metadata_edit_drops_beats" "EmuquTests/ArchiveRRPreservationTests" \
    "Emuqu/Sources/Storage/Archive+Internal.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/Archive+Internal.swift');s=p.read_text();o='            session.rrSeries = beats\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"

# HealthKit rejects a workout whose collection ends where it began, identically
# every time. Without the forward-duration guard the backfill retries the same
# doomed write on every foreground until the ceiling burns through, re-archiving
# the session each time just to record the failure.
mutate "backfill_retries_zero_length_workout" "EmuquTests/WorkoutBackfillEligibilityTests" \
    "Emuqu/Sources/Collection/HealthKitManager.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Collection/HealthKitManager.swift');s=p.read_text();o='              endDate > session.startDate\n';assert s.count(o)==1;p.write_text(s.replace(o,''))"

# The unarchived-backup count means "beats that exist only in a backup". Marking
# everything archived silences the one signal the user has that a recording is
# stranded outside the archive.
mutate "backup_reconcile_clears_stranded" "EmuquTests/BackupReconcileTests" \
    "Emuqu/Sources/Storage/RawRRBackup.swift" \
    "import pathlib;p=pathlib.Path('Emuqu/Sources/Storage/RawRRBackup.swift');s=p.read_text();o='        index.indices.filter { !index[\$0].archived && archivedSessionIds.contains(index[\$0].id) }';assert s.count(o)==1;p.write_text(s.replace(o,'        index.indices.filter { !index[\$0].archived }'))"

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

echo
echo "  $PASS caught, $FAIL survived, $SKIP skipped"
# A SKIP means the mutation was never applied or the suite could not be run —
# in either case that mutation was NOT verified. Treating skips as success is
# the same "reports clean while measuring nothing" failure this whole script
# exists to catch, so they fail the run.
if (( FAIL != 0 || SKIP != 0 )); then
    if (( SKIP != 0 )); then
        echo
        echo "  $SKIP mutation(s) were NOT verified. A skip is not a pass."
        echo "  'already red' usually means another xcodebuild was running against"
        echo "  the same derived data — run this script on its own."
    fi
    exit 1
fi
