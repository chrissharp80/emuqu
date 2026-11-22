@testable import Emuqu
import XCTest

/// Pace, calories, a TCX lap's time and re-bucketed PDF splits are measured
/// on moving time, not on the wall-clock span that includes a stop.
final class WorkoutMovingTimeTests: XCTestCase {
    /// A 60-minute run with a 20-minute stop: 40 moving minutes of samples.
    private func runWithStop() -> WorkoutMetadata {
        var metadata = WorkoutMetadata(sport: .run)
        metadata.samples = (0 ... 2_400).map { WorkoutSample(offsetSec: $0, heartRate: 150, distanceMeters: Double($0) * 2.5) }
        metadata.pauseSpans = [WorkoutPauseSpan(atElapsed: 1_200, seconds: 1_200)]
        return metadata
    }

    func testMovingSecondsIsTheLastSampleOffsetNotTheWallClock() {
        XCTAssertEqual(runWithStop().movingSeconds(wallClockDuration: 3_600), 2_400)
    }

    func testMovingSecondsWithoutSamplesTakesThePausesOffTheWallClock() {
        var metadata = WorkoutMetadata(sport: .run)
        metadata.pauseSpans = [WorkoutPauseSpan(atElapsed: 600, seconds: 900)]
        XCTAssertEqual(metadata.movingSeconds(wallClockDuration: 3_600), 2_700)
        XCTAssertNil(WorkoutMetadata(sport: .run).movingSeconds(wallClockDuration: nil))
    }

    /// Before, pace comparisons, race predictions and history baselines took
    /// the pauses off the wall clock while the PDF and the TCX lap read the
    /// samples, so one run had two moving times. All of them read
    /// `activeWorkoutSeconds` now, which is `movingSeconds(wallClockDuration:)`.
    func testOneMovingTimeForEveryReader() {
        let run = runWithStop()
        var session = HRVSession(
            id: UUID(), startDate: Date(timeIntervalSince1970: 0), endDate: Date(timeIntervalSince1970: 3_600),
            state: .complete, sessionType: .workout, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        var metadata = run
        metadata.distanceMeters = 6_000
        session.workoutMetadata = metadata
        XCTAssertEqual(session.activeWorkoutSeconds, run.movingSeconds(wallClockDuration: 3_600))
        XCTAssertEqual(session.activeWorkoutSeconds, 2_400)
        let baselines = WorkoutHistoryBaselines.compute(from: [session], sport: .run)
        XCTAssertEqual(baselines.avgPaceSecPerKm ?? 0, 400, accuracy: 0.001)
        var bare = session
        bare.workoutMetadata = nil
        XCTAssertEqual(bare.activeWorkoutSeconds, 3_600, "Without workout metadata there are no pauses to leave out")
    }

    /// 6 km at 2.5 m/s of moving time: six 400-second kilometres, the stop in
    /// none of them, and no partial tail.
    func testSplitsFromSamplesUseMovingTime() {
        let splits = WorkoutPDFRenderer.splitsFromSamples(
            runWithStop().samples ?? [], startDate: Date(timeIntervalSince1970: 1_700_000_000), splitDistanceMeters: 1_000
        )
        XCTAssertEqual(splits.count, 6)
        for split in splits {
            XCTAssertEqual(split.durationSeconds, 400, accuracy: 0.001)
            XCTAssertEqual(split.averagePaceSecPerKm ?? 0, 400, accuracy: 0.001)
            XCTAssertEqual(split.averageHR, 150)
        }
        XCTAssertEqual(splits.map(\.index), [1, 2, 3, 4, 5, 6])
    }

    func testSplitsFromSamplesWithoutDistanceAreEmpty() {
        let samples = (0 ..< 100).map { WorkoutSample(offsetSec: $0, heartRate: 140) }
        XCTAssertTrue(WorkoutPDFRenderer.splitsFromSamples(samples, startDate: Date(), splitDistanceMeters: 1_000).isEmpty)
    }
}
