@testable import Emuqu
import XCTest

/// Which archived workouts the HealthKit backfill will try to export.
///
/// Every foreground runs this over the archive, so a session that is eligible
/// but unexportable is retried on every launch until its retry ceiling burns
/// through — and each failure re-archives the session just to record the count.
final class WorkoutBackfillEligibilityTests: XCTestCase {
    private func workout(
        start: Date = Date(timeIntervalSince1970: 1_800_000_000),
        durationSeconds: TimeInterval? = 1_800,
        exportedAt: Date? = nil,
        failures: Int? = nil,
        metadata: WorkoutMetadata? = WorkoutMetadata(sport: .walk)
    ) -> HRVSession {
        var session = HRVSession(startDate: start, tags: [], sessionType: .workout)
        session.endDate = durationSeconds.map { start.addingTimeInterval($0) }
        session.workoutMetadata = metadata
        session.healthKitExportedAt = exportedAt
        session.healthKitExportFailureCount = failures
        return session
    }

    func testACompletedWorkoutIsEligible() {
        XCTAssertTrue(HealthKitManager.needsBackfill(workout()))
    }

    /// The regression. HealthKit rejects a workout whose collection ends where
    /// it began — "endDate must be after startDate" — and rejects it
    /// identically every time, so retrying can only ever fail again. A field
    /// log shows one of these: the stub a crashed recording left behind.
    func testAZeroLengthWorkoutIsNotEligible() {
        XCTAssertFalse(HealthKitManager.needsBackfill(workout(durationSeconds: 0)))
    }

    func testABackwardsWorkoutIsNotEligible() {
        XCTAssertFalse(HealthKitManager.needsBackfill(workout(durationSeconds: -60)))
    }

    /// One second forward is still forward. The guard rejects what HealthKit
    /// rejects, not everything that looks short — a genuinely brief recording
    /// belongs in Health like any other.
    func testAOneSecondWorkoutIsStillEligible() {
        XCTAssertTrue(HealthKitManager.needsBackfill(workout(durationSeconds: 1)))
    }

    func testAWorkoutStillRecordingIsNotEligible() {
        XCTAssertFalse(HealthKitManager.needsBackfill(workout(durationSeconds: nil)))
    }

    func testAnAlreadyExportedWorkoutIsNotEligible() {
        XCTAssertFalse(HealthKitManager.needsBackfill(workout(exportedAt: Date())))
    }

    func testAWorkoutPastItsRetryCeilingIsNotEligible() {
        let ceiling = HRVSession.healthKitExportRetryCeiling
        XCTAssertTrue(HealthKitManager.needsBackfill(workout(failures: ceiling - 1)))
        XCTAssertFalse(HealthKitManager.needsBackfill(workout(failures: ceiling)))
    }

    func testASessionWithNoWorkoutMetadataIsNotEligible() {
        XCTAssertFalse(HealthKitManager.needsBackfill(workout(metadata: nil)))
    }
}
