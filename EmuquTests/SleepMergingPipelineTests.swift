@testable import Emuqu
import HealthKit
import XCTest

final class SleepMergingPipelineTests: XCTestCase {
    // MARK: - Helpers

    private func makeInterval(
        stage: HealthKitManager.SleepStage,
        start: Date,
        durationMinutes: Int
    ) -> HealthKitManager.SleepStageInterval {
        HealthKitManager.SleepStageInterval(
            stage: stage,
            start: start,
            end: start.addingTimeInterval(Double(durationMinutes) * 60)
        )
    }

    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func date(minutesAfter: Int) -> Date {
        baseDate.addingTimeInterval(Double(minutesAfter) * 60)
    }

    // MARK: - clipIntervals

    func testClipIntervals_clipsToWindow() {
        let intervals = [
            makeInterval(stage: .deep, start: date(minutesAfter: 0), durationMinutes: 60),
            makeInterval(stage: .core, start: date(minutesAfter: 60), durationMinutes: 60),
            makeInterval(stage: .rem, start: date(minutesAfter: 120), durationMinutes: 60)
        ]
        let clipped = SleepMergingPipeline.clipIntervals(
            intervals,
            to: date(minutesAfter: 30),
            end: date(minutesAfter: 90)
        )
        XCTAssertEqual(clipped.count, 2)
        XCTAssertEqual(clipped[0].stage, .deep)
        XCTAssertEqual(clipped[0].durationMinutes, 30)
        XCTAssertEqual(clipped[1].stage, .core)
        XCTAssertEqual(clipped[1].durationMinutes, 30)
    }

    func testClipIntervals_emptyInput() {
        let clipped = SleepMergingPipeline.clipIntervals(
            [],
            to: baseDate,
            end: date(minutesAfter: 60)
        )
        XCTAssertTrue(clipped.isEmpty)
    }

    func testClipIntervals_noOverlap() {
        let intervals = [
            makeInterval(stage: .deep, start: date(minutesAfter: 0), durationMinutes: 30)
        ]
        let clipped = SleepMergingPipeline.clipIntervals(
            intervals,
            to: date(minutesAfter: 60),
            end: date(minutesAfter: 120)
        )
        XCTAssertTrue(clipped.isEmpty)
    }

    // MARK: - splitByGaps

    func testSplitByGaps_noGaps() {
        // Items are contiguous (no gap >= threshold)
        let items = [
            (start: date(minutesAfter: 0), end: date(minutesAfter: 30)),
            (start: date(minutesAfter: 30), end: date(minutesAfter: 60)),
            (start: date(minutesAfter: 60), end: date(minutesAfter: 90))
        ]
        let groups = SleepMergingPipeline.splitByGaps(
            items,
            gap: 60 * 60, // 1 hour gap threshold
            startOf: { $0.start },
            endOf: { $0.end }
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 3)
    }

    func testSplitByGaps_withLargeGap() {
        let items = [
            (start: date(minutesAfter: 0), end: date(minutesAfter: 30)),
            (start: date(minutesAfter: 120), end: date(minutesAfter: 150)) // 90 min gap
        ]
        let groups = SleepMergingPipeline.splitByGaps(
            items,
            gap: 60 * 60, // 1 hour gap threshold
            startOf: { $0.start },
            endOf: { $0.end }
        )
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].count, 1)
        XCTAssertEqual(groups[1].count, 1)
    }

    func testSplitByGaps_emptyInput() {
        let items: [(start: Date, end: Date)] = []
        let groups = SleepMergingPipeline.splitByGaps(
            items,
            gap: 60 * 60,
            startOf: { $0.start },
            endOf: { $0.end }
        )
        XCTAssertTrue(groups.isEmpty)
    }

    func testSplitByGaps_singleItem() {
        let items = [
            (start: date(minutesAfter: 0), end: date(minutesAfter: 30))
        ]
        let groups = SleepMergingPipeline.splitByGaps(
            items,
            gap: 60 * 60,
            startOf: { $0.start },
            endOf: { $0.end }
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 1)
    }

    // MARK: - accumulateStageMinutes

    func testAccumulateStageMinutes_empty() {
        let result = SleepMergingPipeline.accumulateStageMinutes([])
        XCTAssertEqual(result.deep, 0)
        XCTAssertEqual(result.rem, 0)
        XCTAssertEqual(result.core, 0)
        XCTAssertEqual(result.awake, 0)
        XCTAssertEqual(result.totalSleep, 0)
    }

    func testAccumulateStageMinutes_allStages() {
        let intervals = [
            makeInterval(stage: .deep, start: date(minutesAfter: 0), durationMinutes: 60),
            makeInterval(stage: .rem, start: date(minutesAfter: 60), durationMinutes: 30),
            makeInterval(stage: .core, start: date(minutesAfter: 90), durationMinutes: 120),
            makeInterval(stage: .awake, start: date(minutesAfter: 210), durationMinutes: 15),
            makeInterval(stage: .unspecified, start: date(minutesAfter: 225), durationMinutes: 45)
        ]
        let result = SleepMergingPipeline.accumulateStageMinutes(intervals)
        XCTAssertEqual(result.deep, 60)
        XCTAssertEqual(result.rem, 30)
        XCTAssertEqual(result.core, 120)
        XCTAssertEqual(result.awake, 15)
        XCTAssertEqual(result.unspecified, 45)
        XCTAssertTrue(result.hasDetailed)
        XCTAssertEqual(result.detailedSleep, 210)
        XCTAssertEqual(result.totalSleep, 255)
    }

    /// Watch stages don't fall on whole minutes. The sleep editor's total
    /// (`accumulateStageMinutes`) and the night's total
    /// (`SleepResolver.totalMinutes`) must agree on the same stages, or the
    /// editor opens showing a change nobody made.
    func testEditorAndNightTotalsAgreeOnFractionalMinuteStages() {
        let lengths: [TimeInterval] = [1_850, 2_710, 935, 3_345, 1_290, 2_075, 610, 4_170]
        let stages: [HealthKitManager.SleepStage] = [.core, .deep, .rem]
        var intervals: [HealthKitManager.SleepStageInterval] = []
        var start = baseDate
        for (index, seconds) in lengths.enumerated() {
            let end = start.addingTimeInterval(seconds)
            intervals.append(HealthKitManager.SleepStageInterval(stage: stages[index % 3], start: start, end: end))
            start = end
        }
        XCTAssertEqual(SleepMergingPipeline.accumulateStageMinutes(intervals).totalSleep, SleepResolver.totalMinutes(intervals))
        XCTAssertEqual(intervals[0].durationMinutes, 31, "1,850 s is 30.8 minutes, which rounds to 31")
    }

    // MARK: - buildSegmentFromIntervals

    func testBuildSegmentFromIntervals_validInput() {
        let intervals = [
            makeInterval(stage: .deep, start: date(minutesAfter: 0), durationMinutes: 60),
            makeInterval(stage: .core, start: date(minutesAfter: 60), durationMinutes: 120),
            makeInterval(stage: .rem, start: date(minutesAfter: 180), durationMinutes: 30)
        ]
        let segment = SleepMergingPipeline.buildSegmentFromIntervals(intervals)
        XCTAssertNotNil(segment)
        XCTAssertEqual(segment?.sleepStart, date(minutesAfter: 0))
        XCTAssertEqual(segment?.sleepEnd, date(minutesAfter: 210))
        XCTAssertEqual(segment?.totalSleepMinutes, 210)
        XCTAssertEqual(segment?.deepSleepMinutes, 60)
        XCTAssertEqual(segment?.remSleepMinutes, 30)
        XCTAssertEqual(segment?.coreSleepMinutes, 120)
    }

    func testBuildSegmentFromIntervals_emptyInput() {
        let segment = SleepMergingPipeline.buildSegmentFromIntervals([])
        XCTAssertNil(segment)
    }

    func testBuildSegmentFromIntervals_singleInterval() {
        let intervals = [
            makeInterval(stage: .deep, start: date(minutesAfter: 0), durationMinutes: 90)
        ]
        let segment = SleepMergingPipeline.buildSegmentFromIntervals(intervals)
        XCTAssertNotNil(segment)
        XCTAssertEqual(segment?.totalSleepMinutes, 90)
    }

    /// A staged segment with no deep recorded zero deep: it is shown as 0,
    /// not as "not tracked". A segment with no stages at all leaves them nil.
    func testBuildSegmentFromIntervals_stagedZeroIsZeroNotNil() {
        let staged = SleepMergingPipeline.buildSegmentFromIntervals([
            makeInterval(stage: .core, start: date(minutesAfter: 0), durationMinutes: 120),
            makeInterval(stage: .rem, start: date(minutesAfter: 120), durationMinutes: 30)
        ])
        XCTAssertEqual(staged?.deepSleepMinutes, 0)
        XCTAssertEqual(staged?.remSleepMinutes, 30)
        let unstaged = SleepMergingPipeline.buildSegmentFromIntervals([
            makeInterval(stage: .unspecified, start: date(minutesAfter: 0), durationMinutes: 120)
        ])
        XCTAssertNil(unstaged?.deepSleepMinutes)
        XCTAssertNil(unstaged?.remSleepMinutes)
    }

    /// One contract for both levels: `SleepResolver` treats a core-only night
    /// as unstaged (deep and REM nil, test10e in SleepResolverTests), because
    /// core-only is what a source that does not stage writes. A core-only
    /// segment must read the same way.
    func testBuildSegmentFromIntervals_coreOnlyIsUnstagedLikeTheNight() {
        let coreOnly = SleepMergingPipeline.buildSegmentFromIntervals([
            makeInterval(stage: .core, start: date(minutesAfter: 0), durationMinutes: 120)
        ])
        XCTAssertNil(coreOnly?.deepSleepMinutes)
        XCTAssertNil(coreOnly?.remSleepMinutes)
        XCTAssertEqual(coreOnly?.totalSleepMinutes, 120)
    }

    // MARK: - splitStageIntervals

    func testSplitStageIntervals_byGap() {
        let intervals = [
            makeInterval(stage: .deep, start: date(minutesAfter: 0), durationMinutes: 60),
            makeInterval(stage: .core, start: date(minutesAfter: 60), durationMinutes: 60),
            // 2 hour gap
            makeInterval(stage: .deep, start: date(minutesAfter: 240), durationMinutes: 60)
        ]
        let groups = SleepMergingPipeline.splitStageIntervals(intervals, gap: 60 * 60)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].count, 2)
        XCTAssertEqual(groups[1].count, 1)
    }

    // MARK: - processForRecording bounds

    // TestFlight build 19 trapped in `DateInterval(start:end:)` here when a
    // crash-interrupted overnight reached the pipeline with its end at or
    // before its start. These pin the widened envelope: no trap, and the
    // Watch night survives the clip instead of scoring sleepless.
    private func watchCore(fromMinute start: Int, toMinute end: Int) -> HKCategorySample {
        HKCategorySample(
            type: HKCategoryType(.sleepAnalysis),
            value: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            start: date(minutesAfter: start),
            end: date(minutesAfter: end)
        )
    }

    private func config() -> SleepMergingConfig {
        SleepMergingConfig(
            overnightWindowStart: date(minutesAfter: -120),
            overnightWindowEnd: date(minutesAfter: 600),
            awakeGapSplitMinutes: 60,
            enhanceWithRR: false
        )
    }

    func testProcessForRecording_endBeforeStart_keepsTheWatchNight() {
        let sleep = SleepMergingPipeline.processForRecording(
            samples: [watchCore(fromMinute: 0, toMinute: 420)],
            recordingStart: date(minutesAfter: 10),
            recordingEnd: date(minutesAfter: 5),
            config: config()
        )
        XCTAssertGreaterThan(sleep.nightSleepMinutes, 0)
    }

    func testProcessForRecording_zeroLengthRecording_keepsTheWatchNight() {
        let sleep = SleepMergingPipeline.processForRecording(
            samples: [watchCore(fromMinute: 0, toMinute: 420)],
            recordingStart: date(minutesAfter: 10),
            recordingEnd: date(minutesAfter: 10),
            config: config()
        )
        XCTAssertGreaterThan(sleep.nightSleepMinutes, 0)
    }
}
