@testable import Emuqu
import XCTest

/// Workout rows whose heart rate is Apple Watch wrist HR (Apple Health) stay
/// marked in `healthKitHROffsets` wherever the rows go: the live wrist fallback
/// on a strap workout, the crash backup, a rebuild from it, and a trim that
/// carries the archived samples forward.
@MainActor
final class WristHRMarkerTests: XCTestCase {
    private typealias Arbitration = WorkoutRecorder.HRArbitration

    // MARK: - Live wrist fallback

    func testWristHRCopiedToTheDisplayMarksTheDisplayAsWrist() {
        let decision = Arbitration.decide(Arbitration.Inputs(
            sourceMode: .strap, recordingElapsedSeconds: 600,
            strapSilentFor: 30, watchRoutedSilentFor: .infinity,
            latestWatchHR: 131, strapFeed: .stalled
        ))

        XCTAssertEqual(decision.displayHRUpdate, 131)
        XCTAssertTrue(Arbitration.displayIsWrist(decision, wasWrist: false))
    }

    func testHealthyStrapLeavesTheMarkAsTheStrapPathsSetIt() {
        let decision = Arbitration.decide(Arbitration.Inputs(
            sourceMode: .strap, recordingElapsedSeconds: 600,
            strapSilentFor: 0, watchRoutedSilentFor: .infinity,
            latestWatchHR: 131, strapFeed: .live
        ))

        XCTAssertNil(decision.displayHRUpdate)
        XCTAssertFalse(Arbitration.displayIsWrist(decision, wasWrist: false))
        XCTAssertTrue(Arbitration.displayIsWrist(decision, wasWrist: true))
    }

    func testClearedDisplayIsNotWrist() {
        let decision = Arbitration.Decision(displayHRUpdate: nil, strapNotice: nil, clearDisplayHR: true)

        XCTAssertFalse(Arbitration.displayIsWrist(decision, wasWrist: true))
    }

    func testCappingTheSampleBufferDropsMarkersOfDroppedRows() {
        XCTAssertEqual(WorkoutTicker.offsets([2, 5, 9], keptFrom: 5), [5, 9])
        XCTAssertEqual(WorkoutTicker.offsets([2, 5], keptFrom: nil), [2, 5])
    }

    /// Finalize lists the live wrist rows alongside the HealthKit backfill.
    func testFinalizeListsLiveWristRowsWithBackfilledRows() {
        let samples = (0 ..< 4).map { WorkoutSample(offsetSec: $0, heartRate: 120 + $0) }

        let offsets = WorkoutFinalizer.healthKitHROffsets(samples: samples, backfilled: [3] + [1, 2], source: .strap)

        XCTAssertEqual(offsets, [1, 2, 3])
    }

    // MARK: - Crash backup

    func testCrashBackupKeepsTheMarkersWithTheSamples() throws {
        let backup = WorkoutTrackBackup()
        let id = UUID()
        defer { backup.discard(id) }
        let start = Date(timeIntervalSince1970: 1_000)
        let samples = (0 ..< 3).map { WorkoutSample(offsetSec: $0, heartRate: 120) }
        backup.appendIncremental(
            sessionId: id, sport: .run, startDate: start, track: [],
            samples: Array(samples.prefix(2)), healthKitHROffsets: [1], barometricSamples: []
        )
        backup.appendIncremental(
            sessionId: id, sport: .run, startDate: start, track: [],
            samples: samples, healthKitHROffsets: [1, 2], barometricSamples: []
        )

        let recovered = try XCTUnwrap(backup.retrieve(id))

        XCTAssertEqual(recovered.samples.count, 3)
        XCTAssertEqual(recovered.healthKitHROffsets, [1, 2])
    }

    /// The defect this pins: past 12 h the recorder drops a sample from the
    /// head of its in-memory array for each one it adds, so the array's count
    /// stops growing, and a backup that wrote "everything past the count on
    /// disk" wrote nothing more for the rest of the workout.
    func testCrashBackupKeepsWritingAfterTheOldestSamplesAreTrimmed() throws {
        let backup = WorkoutTrackBackup()
        let id = UUID()
        defer { backup.discard(id) }
        let start = Date(timeIntervalSince1970: 1_000)
        let samples = (1 ... 6).map { WorkoutSample(offsetSec: $0, heartRate: 120) }
        backup.appendIncremental(
            sessionId: id, sport: .run, startDate: start, track: [],
            samples: Array(samples[0 ..< 4]), healthKitHROffsets: [2, 4], barometricSamples: []
        )
        // Two rows trimmed from the head, two added: the same count of four.
        let wrote = backup.appendIncremental(
            sessionId: id, sport: .run, startDate: start, track: [],
            samples: Array(samples[2 ..< 6]), healthKitHROffsets: [4, 6], barometricSamples: []
        )

        let recovered = try XCTUnwrap(backup.retrieve(id))

        XCTAssertTrue(wrote)
        XCTAssertEqual(recovered.samples.map(\.offsetSec), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(recovered.healthKitHROffsets, [2, 4, 6])
    }

    /// A snapshot taken before the last one written, arriving late (the
    /// appends run on unordered detached tasks), adds nothing.
    func testCrashBackupIgnoresAnOlderSnapshotArrivingLate() throws {
        let backup = WorkoutTrackBackup()
        let id = UUID()
        defer { backup.discard(id) }
        let start = Date(timeIntervalSince1970: 1_000)
        let samples = (1 ... 5).map { WorkoutSample(offsetSec: $0, heartRate: 120) }
        backup.appendIncremental(
            sessionId: id, sport: .run, startDate: start, track: [],
            samples: samples, healthKitHROffsets: [], barometricSamples: []
        )
        let wrote = backup.appendIncremental(
            sessionId: id, sport: .run, startDate: start, track: [],
            samples: Array(samples.prefix(3)), healthKitHROffsets: [], barometricSamples: []
        )

        XCTAssertFalse(wrote)
        XCTAssertEqual(try XCTUnwrap(backup.retrieve(id)).samples.count, 5)
    }

    func testFirstIndexAfterAKeyFindsTheUnwrittenTail() {
        let rows = [3, 4, 5, 6]
        XCTAssertEqual(WorkoutTrackBackup.firstIndex(in: rows, after: 4), 2)
        XCTAssertEqual(WorkoutTrackBackup.firstIndex(in: rows, after: 6), 4)
        XCTAssertEqual(WorkoutTrackBackup.firstIndex(in: rows, after: 1), 0)
    }

    // MARK: - Recovery

    func testRebuildKeepsOnlyMarkersOfRowsItKept() {
        let kept = (0 ..< 3).map { WorkoutSample(offsetSec: $0, heartRate: 120) }

        XCTAssertEqual(WorkoutRecoveryService.healthKitHROffsets([4, 2, 0], in: kept), [0, 2])
        XCTAssertNil(WorkoutRecoveryService.healthKitHROffsets([7], in: kept))
        XCTAssertNil(WorkoutRecoveryService.healthKitHROffsets([], in: kept))
    }

    func testTrimCarriesMarkersOfTheSamplesItKeeps() {
        let start = Date(timeIntervalSince1970: 1_000)
        var archived = HRVSession(
            id: UUID(), startDate: start, endDate: start.addingTimeInterval(10),
            state: .complete, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        var old = WorkoutMetadata(sport: .run)
        old.samples = (0 ..< 10).map { WorkoutSample(offsetSec: $0, heartRate: 120) }
        old.healthKitHROffsets = [1, 3, 8]
        archived.workoutMetadata = old
        var trimmed = HRVSession(
            id: archived.id, startDate: start, endDate: start.addingTimeInterval(5),
            state: .complete, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        trimmed.workoutMetadata = WorkoutMetadata(sport: .run)

        WorkoutRecoveryService.carryForward(from: archived, into: &trimmed)

        XCTAssertEqual(trimmed.workoutMetadata?.samples?.count, 6)
        XCTAssertEqual(trimmed.workoutMetadata?.healthKitHROffsets, [1, 3])
    }
}
