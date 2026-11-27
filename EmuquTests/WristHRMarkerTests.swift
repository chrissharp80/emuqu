import CoreLocation
@testable import Emuqu
import UIKit
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

    /// A row holding a value that is not a finite number is backed up and
    /// recovered with that value missing, so the archive, whose encoder
    /// rejects NaN and infinity, can save the workout. Its other values stay.
    func testCrashBackupRecoversNonFiniteValuesAsMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WristHRMarkerTests-\(UUID().uuidString)", isDirectory: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let backup = WorkoutTrackBackup(directory: directory)
        let id = UUID()
        let samples = [
            WorkoutSample(offsetSec: 1, heartRate: 120, paceSecPerKm: .nan),
            WorkoutSample(offsetSec: 2, heartRate: 121, mets: .infinity),
            WorkoutSample(offsetSec: 3, heartRate: 122)
        ]
        let baro = [Date(timeIntervalSince1970: 1_001), Date(timeIntervalSince1970: 1_002)].enumerated().map {
            WorkoutTrackBackup.PersistedBaro(timestamp: $0.element, altitudeMeters: $0.offset == 0 ? .nan : 12)
        }
        backup.appendIncremental(
            sessionId: id, sport: .run, startDate: Date(timeIntervalSince1970: 1_000), track: [],
            samples: samples, healthKitHROffsets: [], barometricSamples: baro
        )

        let recovered = try XCTUnwrap(backup.retrieve(id))

        XCTAssertEqual(recovered.samples.map(\.offsetSec), [1, 2, 3])
        XCTAssertEqual(recovered.samples.map(\.heartRate), [120, 121, 122])
        XCTAssertNil(recovered.samples[0].paceSecPerKm)
        XCTAssertNil(recovered.samples[1].mets)
        XCTAssertEqual(recovered.barometricSamples.map(\.altitudeMeters), [12])
        XCTAssertNoThrow(try SessionArchive.sessionEncoder.encode(recovered.samples))
    }

    /// `finiteValuesOnly` rebuilds a sample field by field through an init
    /// whose parameters default to nil, so a field added to `WorkoutSample`
    /// and not carried over there would silently become nil. This fails
    /// until the new field is carried over and the count updated.
    func testFiniteValuesOnlyCarriesEveryField() {
        let sample = WorkoutSample(
            offsetSec: 7, heartRate: 140, distanceMeters: 1_000, paceSecPerKm: 300, cadenceStepsPerMin: 170,
            altitudeMeters: 12, alpha1: 0.8, mets: 9, powerWatts: 250
        )
        XCTAssertEqual(Mirror(reflecting: sample).children.count, 9, "WorkoutSample gained a field: carry it over in finiteValuesOnly")
        XCTAssertEqual(sample.finiteValuesOnly, sample)
    }

    /// "Delete All My Data" removes the backup folder before `purgeAll`
    /// runs. The purge still forgets what it had written and makes the folder
    /// again, so the next workout is backed up from its first row.
    func testCrashBackupWritesAgainAfterAPurgeThatFoundNoFolder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WristHRMarkerTests-\(UUID().uuidString)", isDirectory: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let backup = WorkoutTrackBackup(directory: directory)
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        let samples = (1 ... 3).map { WorkoutSample(offsetSec: $0, heartRate: 120) }
        backup.appendIncremental(
            sessionId: id, sport: .run, startDate: start, track: [],
            samples: samples, healthKitHROffsets: [], barometricSamples: []
        )
        try FileManager.default.removeItem(at: directory)

        backup.purgeAll()
        let wrote = backup.appendIncremental(
            sessionId: id, sport: .run, startDate: start, track: [],
            samples: samples, healthKitHROffsets: [], barometricSamples: []
        )

        XCTAssertTrue(wrote)
        XCTAssertEqual(try XCTUnwrap(backup.retrieve(id)).samples.count, 3)
    }

    // MARK: - Sealed streams

    /// The GPS track and the wrist-HR markers are written sealed, line by
    /// line, and read back; without a key they are plain and the workout is
    /// queued for re-encryption.
    func testCrashBackupSealsItsStreams() throws {
        let directory = try temporaryBackupFolder()
        let backup = WorkoutTrackBackup(directory: directory)
        let id = UUID()
        defer { PendingEncryptionLedger.clear(id, in: .workoutTrack) }
        let track = [CLLocation(latitude: 51.5, longitude: -0.1), CLLocation(latitude: 51.6, longitude: -0.2)]
        backup.appendIncremental(
            sessionId: id, sport: .run, startDate: Date(timeIntervalSince1970: 1_000),
            track: track.map(WorkoutTrackBackup.PersistedFix.init), samples: [], healthKitHROffsets: [4], barometricSamples: []
        )

        let sealed = SealedJSONLines.availableManager() != nil
        for name in ["track", "hkhr"] {
            let stream = try Data(contentsOf: directory.appendingPathComponent("\(id.uuidString)_workout_\(name).jsonl"))
            XCTAssertEqual(SealedJSONLines.hasPlainLine(stream), !sealed, name)
        }
        XCTAssertEqual(PendingEncryptionLedger.pending(in: .workoutTrack).contains(id), !sealed)
        let recovered = try XCTUnwrap(backup.retrieve(id))
        XCTAssertEqual(recovered.track.map(\.coordinate.latitude), [51.5, 51.6])
        XCTAssertEqual(recovered.healthKitHROffsets, [4])
    }

    /// Streams written as plain JSON lines (by a build that did not seal
    /// them, or without a key) still read, and the repair seals them and only
    /// then takes the workout off the queue.
    func testPlainStreamsReadAndAreSealedByTheRepair() throws {
        let directory = try temporaryBackupFolder()
        let backup = WorkoutTrackBackup(directory: directory)
        let id = UUID()
        defer { PendingEncryptionLedger.clear(id, in: .workoutTrack) }
        backup.appendIncremental(
            sessionId: id, sport: .run, startDate: Date(timeIntervalSince1970: 1_000),
            track: [], samples: [], healthKitHROffsets: [], barometricSamples: []
        )
        let samples = (1 ... 3).map { WorkoutSample(offsetSec: $0, heartRate: 120) }
        let samplesURL = directory.appendingPathComponent("\(id.uuidString)_workout_samples.jsonl")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try SealedJSONLines.encode(samples, with: encoder, manager: nil).data.write(to: samplesURL)
        XCTAssertEqual(try XCTUnwrap(backup.retrieve(id)).samples.map(\.offsetSec), [1, 2, 3])
        PendingEncryptionLedger.record(id, in: .workoutTrack)

        backup.reencryptPendingTracks()

        let recovered = try XCTUnwrap(backup.retrieve(id))
        let plainLeft = SealedJSONLines.hasPlainLine(try Data(contentsOf: samplesURL))
        XCTAssertEqual(plainLeft, SealedJSONLines.availableManager() == nil)
        XCTAssertEqual(PendingEncryptionLedger.pending(in: .workoutTrack).contains(id), plainLeft)
        XCTAssertEqual(recovered.samples.map(\.offsetSec), [1, 2, 3])
    }

    /// A discard removes every file of the workout and reports it.
    func testDiscardRemovesEveryFileOfTheWorkout() throws {
        let directory = try temporaryBackupFolder()
        let backup = WorkoutTrackBackup(directory: directory)
        let id = UUID()
        backup.appendIncremental(
            sessionId: id, sport: .run, startDate: Date(timeIntervalSince1970: 1_000),
            track: [], samples: [WorkoutSample(offsetSec: 1, heartRate: 120)], healthKitHROffsets: [1], barometricSamples: []
        )

        XCTAssertTrue(backup.discard(id))

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        XCTAssertNil(backup.retrieve(id))
    }

    /// A folder of its own for one test, removed afterwards.
    private func temporaryBackupFolder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WristHRMarkerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        return directory
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

/// The workout crash backup's torn-row handling and its repair on unlock.
/// Not on the main actor: the in-flight test appends from several threads.
final class WorkoutTrackBackupTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkoutTrackBackupTests-\(UUID().uuidString)", isDirectory: true)
    private let id = UUID()
    private let start = Date(timeIntervalSince1970: 1_000)
    /// The unlock notifications these stores listen on, so the host app's
    /// own activation never runs a repair during a test, and a post here
    /// reaches no other store.
    private let notifications = NotificationCenter()

    override func tearDownWithError() throws {
        PendingEncryptionLedger.clear(id, in: .workoutTrack)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private var streamFileURL: URL {
        directory.appendingPathComponent("\(id.uuidString)_workout_samples.jsonl")
    }

    private func sampleRows(_ range: ClosedRange<Int>) -> [WorkoutSample] {
        range.map { WorkoutSample(offsetSec: $0, heartRate: 120) }
    }

    @discardableResult
    private func append(_ rows: [WorkoutSample], to backup: WorkoutTrackBackup) -> Bool {
        backup.appendIncremental(
            sessionId: id, sport: .run, startDate: start, track: [],
            samples: rows, healthKitHROffsets: [], barometricSamples: []
        )
    }

    /// A kill part way through a row leaves the stream ending in a
    /// fragment. After a relaunch the next append cuts it off and writes
    /// that row again, so every row reads back once.
    func testAnAppendAfterATornRowKeepsEveryRow() throws {
        append(sampleRows(1 ... 3), to: WorkoutTrackBackup(directory: directory, notificationCenter: notifications))
        try (Data(contentsOf: streamFileURL) + Data("{\"offsetSec\":4,\"hea".utf8)).write(to: streamFileURL)

        let relaunched = WorkoutTrackBackup(directory: directory, notificationCenter: notifications)
        XCTAssertTrue(append(sampleRows(1 ... 6), to: relaunched))

        XCTAssertEqual(try XCTUnwrap(relaunched.retrieve(id)).samples.map(\.offsetSec), [1, 2, 3, 4, 5, 6])
    }

    /// Protected data becoming available reseals a workout queued with
    /// plain rows, as a launch does.
    func testUnlockResealsAQueuedWorkout() throws {
        let backup = try plainQueuedWorkout(rows: 3)

        notifications.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)

        let recovered = try XCTUnwrap(backup.retrieve(id))
        let plainLeft = SealedJSONLines.hasPlainLine(try Data(contentsOf: streamFileURL))
        XCTAssertEqual(plainLeft, SealedJSONLines.availableManager() == nil)
        XCTAssertEqual(PendingEncryptionLedger.pending(in: .workoutTrack).contains(id), plainLeft)
        XCTAssertEqual(recovered.samples.map(\.offsetSec), [1, 2, 3])
    }

    /// The reseal rewrites the live stream while appends to it keep arriving
    /// from other threads. It runs between appends, never under one, so no
    /// row is lost or written twice.
    func testUnlockResealLeavesAppendsInFlightIntact() throws {
        let backup = try plainQueuedWorkout(rows: 3)
        let rows = sampleRows(1 ... 203)
        let (id, start) = (id, start)

        DispatchQueue.concurrentPerform(iterations: 200) { step in
            if step % 50 == 25 { backup.reencryptPendingTracks() }
            backup.appendIncremental(
                sessionId: id, sport: .run, startDate: start, track: [],
                samples: Array(rows[..<(4 + step)]), healthKitHROffsets: [], barometricSamples: []
            )
        }

        XCTAssertEqual(try XCTUnwrap(backup.retrieve(id)).samples.map(\.offsetSec), Array(1 ... 203))
        let data = try Data(contentsOf: streamFileURL)
        XCTAssertEqual(data.filter { $0 == UInt8(ascii: "\n") }.count, 203)
        XCTAssertEqual(SealedJSONLines.hasPlainLine(data), SealedJSONLines.availableManager() == nil)
    }

    /// A store whose workout has a header and `rows` samples written as
    /// plain lines, queued for re-encryption.
    private func plainQueuedWorkout(rows: Int) throws -> WorkoutTrackBackup {
        let backup = WorkoutTrackBackup(directory: directory, notificationCenter: notifications)
        append([], to: backup)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try SealedJSONLines.encode(sampleRows(1 ... rows), with: encoder, manager: nil).data.write(to: streamFileURL)
        PendingEncryptionLedger.record(id, in: .workoutTrack)
        return backup
    }

    /// The pauses go into the backup as they begin and end, and come back
    /// after a relaunch: one still open at the crash is there too.
    func testPausesAreBackedUpAsTheyHappen() throws {
        let backup = WorkoutTrackBackup(directory: directory, notificationCenter: notifications)
        append(sampleRows(1 ... 3), to: backup)
        var timeline = PauseTimeline()
        timeline.pause(atElapsed: 600, now: start.addingTimeInterval(600))
        backup.appendPauses(sessionId: id, events: timeline.events)
        timeline.resume(now: start.addingTimeInterval(900))
        timeline.pause(atElapsed: 1_000, now: start.addingTimeInterval(1_300))
        backup.appendPauses(sessionId: id, events: timeline.events)

        let relaunched = WorkoutTrackBackup(directory: directory, notificationCenter: notifications)
        let events = try XCTUnwrap(relaunched.retrieve(id)).pauseEvents

        XCTAssertEqual(events, timeline.events)
        let restored = PauseTimeline.restored(from: events, endingAt: start.addingTimeInterval(1_500))
        XCTAssertEqual(restored.spans, [
            PauseTimeline.Span(atElapsed: 600, seconds: 300), PauseTimeline.Span(atElapsed: 1_000, seconds: 200)
        ])
    }
}
