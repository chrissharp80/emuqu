@testable import Emuqu
import XCTest

/// `SleepData.sleepLatencyMinutes`. Measuring from the recording start —
/// which is when the strap goes on, not when the user lies down — puts
/// "Latency 157m" beside "In bed 6h 1m" and "Awake 21m" on the Sleep page.
/// Latency comes from the stage timeline, the same source as every other
/// total on that page.
final class SleepDataLatencyTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func interval(_ stage: SleepStage, _ startMin: Int, _ endMin: Int) -> SleepStageInterval {
        SleepStageInterval(
            stage: stage,
            start: t0.addingTimeInterval(Double(startMin) * 60),
            end: t0.addingTimeInterval(Double(endMin) * 60)
        )
    }

    private func sleepData(
        recordingStartMin: Int, sleepStartMin: Int, totalSleep: Int, inBed: Int, stages: [SleepStageInterval]
    ) -> SleepData {
        SleepData(
            date: t0,
            inBedStart: t0.addingTimeInterval(Double(recordingStartMin) * 60),
            sleepStart: t0.addingTimeInterval(Double(sleepStartMin) * 60),
            sleepEnd: t0.addingTimeInterval(Double(sleepStartMin + totalSleep) * 60),
            totalSleepMinutes: totalSleep,
            inBedMinutes: inBed,
            awakeMinutes: inBed - totalSleep,
            sleepEfficiency: 90,
            boundarySource: .healthKit,
            stageIntervals: stages
        )
    }

    func testLatencyIsTheAwakeStageBeforeFirstSleep() {
        // Strap on at 0, awake stage 150…157, asleep from 157.
        let stages = [interval(.awake, 150, 157), interval(.core, 157, 400)]
        let data = sleepData(recordingStartMin: 0, sleepStartMin: 157, totalSleep: 243, inBed: 250, stages: stages)
        XCTAssertEqual(data.sleepLatencyMinutes, 7, "seven awake minutes, not the 157 since the strap went on")
    }

    func testLatencyIsNilWhenStagesBeginWithSleep() {
        let stages = [interval(.core, 157, 400)]
        let data = sleepData(recordingStartMin: 0, sleepStartMin: 157, totalSleep: 243, inBed: 243, stages: stages)
        XCTAssertNil(data.sleepLatencyMinutes)
    }

    func testAwakeStageThatStraddlesSleepOnsetIsClippedAtIt() {
        let stages = [interval(.awake, 150, 170), interval(.core, 160, 400)]
        let data = sleepData(recordingStartMin: 0, sleepStartMin: 160, totalSleep: 240, inBed: 250, stages: stages)
        XCTAssertEqual(data.sleepLatencyMinutes, 10)
    }

    func testWithoutStagesLatencyIsCappedAtTheAwakeTimeInBedContains() {
        // In bed 250, asleep 243 → at most 7 awake minutes, whatever the recording start says.
        let data = sleepData(recordingStartMin: 0, sleepStartMin: 157, totalSleep: 243, inBed: 250, stages: [])
        XCTAssertEqual(data.sleepLatencyMinutes, 7)
    }

    func testWithoutStagesShortGapSurvives() {
        let data = sleepData(recordingStartMin: 0, sleepStartMin: 12, totalSleep: 400, inBed: 430, stages: [])
        XCTAssertEqual(data.sleepLatencyMinutes, 12)
    }
}
