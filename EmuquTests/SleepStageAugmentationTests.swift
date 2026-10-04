@testable import Emuqu
import XCTest

/// The Apple Watch augmentation and validation helpers in
/// `HRVSleepStageClassifier+Watch.swift` are pure functions over stages and
/// scores, and until the ownership change the file sat at 19 % line coverage. These pin
/// the decision table, the confusion-matrix arithmetic and the epoch mapping.
final class SleepStageAugmentationTests: XCTestCase {
    private typealias Classifier = HRVSleepStageClassifier
    private typealias Stage = HealthKitManager.SleepStage

    private func scores(deep: Double = 0.3, rem: Double = 0.3, awake: Double = 0.3,
                        freq: Bool = true, stage: Stage = .core) -> Classifier.WindowScores {
        Classifier.WindowScores(deepScore: deep, remScore: rem, awakeScore: awake, classifiedStage: stage, hasFreqDomain: freq)
    }

    private func window(_ start: TimeInterval, minutes: Double = 5) -> Classifier.FeatureWindow {
        let s = Date(timeIntervalSinceReferenceDate: start)
        return Classifier.FeatureWindow(
            startDate: s, endDate: s.addingTimeInterval(minutes * 60), midpointMs: Int64(start * 1000),
            hr: 55, rmssd: 40, sdnn: 50, hrCV: 0.03, dfaAlpha1: 0.9, lfHfRatio: 1.0, hfPower: 500
        )
    }

    private func interval(_ stage: Stage, _ start: TimeInterval, _ end: TimeInterval) -> HealthKitManager.SleepStageInterval {
        HealthKitManager.SleepStageInterval(
            stage: stage, start: Date(timeIntervalSinceReferenceDate: start), end: Date(timeIntervalSinceReferenceDate: end)
        )
    }

    // MARK: - Decision table

    func testCoreBecomesDeepOnStrongDeepEvidence() {
        let s = scores(deep: Classifier.augmentCoreToDeepThreshold + 0.05, rem: 0.2)
        XCTAssertEqual(Classifier.decideAugmentedStage(watch: .core, score: s), .deep)
    }

    func testCoreBecomesREMOnlyWithFrequencyDomain() {
        let strongREM = scores(deep: 0.2, rem: Classifier.augmentCoreToREMThreshold + 0.05, freq: true)
        XCTAssertEqual(Classifier.decideAugmentedStage(watch: .core, score: strongREM), .rem)
        let noFreq = scores(deep: 0.2, rem: Classifier.augmentCoreToREMThreshold + 0.05, freq: false)
        XCTAssertEqual(Classifier.decideAugmentedStage(watch: .core, score: noFreq), .core, "REM needs LF/HF")
    }

    func testCoreStaysCoreOnWeakEvidence() {
        XCTAssertEqual(Classifier.decideAugmentedStage(watch: .core, score: scores()), .core)
        XCTAssertEqual(Classifier.decideAugmentedStage(watch: .unspecified, score: scores()), .unspecified)
    }

    func testAwakeBecomesREMOnlyWhenAwakeScoreIsLow() {
        let rem = Classifier.augmentAwakeToREMThreshold + 0.05
        let lowAwake = scores(rem: rem, awake: Classifier.awakeScoreThreshold - 0.1)
        XCTAssertEqual(Classifier.decideAugmentedStage(watch: .awake, score: lowAwake), .rem)
        let highAwake = scores(rem: rem, awake: Classifier.awakeScoreThreshold + 0.1)
        XCTAssertEqual(Classifier.decideAugmentedStage(watch: .awake, score: highAwake), .awake)
    }

    func testDeepAndREMSwapOnlyWithStrongOpposingEvidence() {
        let toREM = scores(deep: Classifier.augmentCrossStageRejectThreshold - 0.05, rem: Classifier.augmentCrossStageThreshold + 0.05)
        XCTAssertEqual(Classifier.decideAugmentedStage(watch: .deep, score: toREM), .rem)
        let toDeep = scores(deep: Classifier.augmentCrossStageThreshold + 0.05, rem: Classifier.augmentCrossStageRejectThreshold - 0.05)
        XCTAssertEqual(Classifier.decideAugmentedStage(watch: .rem, score: toDeep), .deep)
        let ambiguous = scores(deep: Classifier.augmentCrossStageThreshold + 0.05, rem: Classifier.augmentCrossStageThreshold + 0.05)
        XCTAssertEqual(Classifier.decideAugmentedStage(watch: .deep, score: ambiguous), .deep)
        XCTAssertEqual(Classifier.decideAugmentedStage(watch: .rem, score: ambiguous), .rem)
    }

    func testAugmentationScoreReportsTheJustifyingScore() {
        let s = scores(deep: 0.71, rem: 0.62, awake: 0.15)
        XCTAssertEqual(Classifier.augmentationScore(for: .deep, in: s), 0.71)
        XCTAssertEqual(Classifier.augmentationScore(for: .rem, in: s), 0.62)
        XCTAssertEqual(Classifier.augmentationScore(for: .core, in: s), 0.15)
    }

    // Returns only the overrides now: augmentation repaints the Watch's own
    // intervals rather than rebuilding a stage list per epoch.
    func testApplyAugmentationDecisionsRecordsOnlyChangedEpochs() {
        let windows = [window(0), window(300), window(600)]
        let watch: [Stage?] = [.core, .core, .awake]
        let scored = [scores(), scores(deep: Classifier.augmentCoreToDeepThreshold + 0.1, rem: 0.1), scores()]
        let augmentations = Classifier.applyAugmentationDecisions(windows: windows, watchStages: watch, scores: scored)
        XCTAssertEqual(augmentations.count, 1)
        XCTAssertEqual(augmentations.first?.watchStage, .core)
        XCTAssertEqual(augmentations.first?.augmentedStage, .deep)
        XCTAssertEqual(augmentations.first?.windowStart, windows[1].startDate)
        XCTAssertEqual(augmentations.first?.windowEnd, windows[1].endDate)
    }

    func testEpochsTheWatchDoesNotCoverAreNeverOverridden() {
        let windows = [window(0), window(300)]
        let strongDeep = scores(deep: Classifier.augmentCoreToDeepThreshold + 0.1, rem: 0.1)
        let augmentations = Classifier.applyAugmentationDecisions(
            windows: windows, watchStages: [nil, .core], scores: [strongDeep, strongDeep]
        )
        XCTAssertEqual(augmentations.map(\.windowStart), [windows[1].startDate])
    }

    // MARK: - Repainting the Watch's intervals

    private func epochOverride(_ start: TimeInterval, from watch: Stage, to stage: Stage) -> Classifier.Augmentation {
        Classifier.Augmentation(
            windowStart: Date(timeIntervalSinceReferenceDate: start),
            windowEnd: Date(timeIntervalSinceReferenceDate: start + 300),
            watchStage: watch, augmentedStage: stage, score: 0.8
        )
    }

    func testOverridesRepaintOnlyTheirEpochAndKeepTheWatchNightIntact() {
        // Watch: core 0–3600 (strap covers only part of it). One epoch
        // 1200–1500 is overridden core → deep.
        let watch = [interval(.core, 0, 3600)]
        let result = Classifier.applyOverrides([epochOverride(1200, from: .core, to: .deep)], to: watch)
        XCTAssertEqual(result.map(\.stage), [.core, .deep, .core])
        XCTAssertEqual(result.first?.start, Date(timeIntervalSinceReferenceDate: 0), "Watch sleep before the override survives")
        XCTAssertEqual(result.last?.end, Date(timeIntervalSinceReferenceDate: 3600), "Watch sleep after the override survives")
        XCTAssertEqual(result[1].provenance, .hrvDerived)
        XCTAssertEqual(result[0].provenance, .watch)
        let total = result.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        XCTAssertEqual(total, 3600, "Repainting never adds or removes time")
    }

    func testAMinorityStageInsideAnOverriddenEpochKeepsItsLabel() {
        // Epoch 0–300 is mostly core, with a 60 s Watch REM blip the HRV
        // pass never overrode. Only the core part becomes deep.
        let watch = [interval(.core, 0, 240), interval(.rem, 240, 300)]
        let result = Classifier.applyOverrides([epochOverride(0, from: .core, to: .deep)], to: watch)
        XCTAssertEqual(result.map(\.stage), [.deep, .rem])
    }

    func testNoOverridesReturnTheWatchIntervalsUnchanged() {
        let watch = [interval(.core, 0, 600), interval(.rem, 600, 900)]
        let result = Classifier.applyOverrides([], to: watch)
        XCTAssertEqual(result.map(\.stage), [.core, .rem])
        XCTAssertEqual(result.map(\.start), watch.map(\.start))
        XCTAssertEqual(result.map(\.end), watch.map(\.end))
    }

    // MARK: - Minutes and epoch mapping

    func testAccumulateStageMinutesFoldsUnspecifiedIntoCore() {
        let intervals = [
            interval(.deep, 0, 600), interval(.core, 600, 1200), interval(.unspecified, 1200, 1500),
            interval(.rem, 1500, 2100), interval(.awake, 2100, 2400)
        ]
        let m = Classifier.accumulateStageMinutes(intervals)
        XCTAssertEqual(m.deep, 10)
        XCTAssertEqual(m.core, 15)
        XCTAssertEqual(m.rem, 10)
        XCTAssertEqual(m.awake, 5)
    }

    func testDominantStageIsTheLargestOverlap() {
        let w = window(0) // 0…300
        let intervals = [interval(.awake, -100, 100), interval(.rem, 100, 300)]
        XCTAssertEqual(Classifier.dominantStage(in: w, watchIntervals: intervals), .rem)
        XCTAssertNil(Classifier.dominantStage(in: w, watchIntervals: [interval(.deep, 1000, 2000)]))
    }

    func testAugmentationResultTotalsMatchIntervals() {
        let intervals = [interval(.deep, 0, 1800), interval(.rem, 1800, 2400)]
        let r = Classifier.augmentationResult(intervals: intervals, augmentations: [], epochs: 8)
        XCTAssertEqual(r.deepSleepMinutes, 30)
        XCTAssertEqual(r.remSleepMinutes, 10)
        XCTAssertEqual(r.coreSleepMinutes, 0)
        XCTAssertEqual(r.augmentationCount, 0)
        XCTAssertEqual(r.stageIntervals.count, 2)
    }
}
