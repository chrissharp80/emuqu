@testable import Emuqu
import HealthKit
import os
import XCTest

/// Replacing and deleting a session's exported workouts in Apple Health,
/// against the in-memory Health store (`InMemoryHealthSampleStore`), which
/// keeps each workout with the samples saved with it.
///
/// HealthKit makes a saved workout only through a builder on a real store;
/// its initialiser, deprecated in favour of the builder, is the one way to
/// make one here. The class says so with the same deprecation, which is
/// what lets it call that initialiser: these tests stand in for workouts a
/// builder saved.
@available(iOS, deprecated: 17.0, message: "Builds HKWorkout fixtures with the initialiser HealthKit deprecated for its builder")
@MainActor
final class HealthWorkoutReplacementTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_622_534_400)
    private let sessionId = UUID()

    override func tearDown() async throws {
        PendingWorkoutReplacements.clear(sessionId: sessionId)
        try await super.tearDown()
    }

    // MARK: - Re-export

    /// A re-export replaces the earlier workout through its sync identifier,
    /// and deletes what it left: the earlier copy's longer heart-rate tail
    /// and a copy saved before workouts carried an identity. A workout that
    /// starts later, and another session's, stay.
    func testAReExportLeavesOneWorkoutAndItsSamples() async throws {
        let store = InMemoryHealthSampleStore()
        let first = stamp(version: 1)
        store.saveWorkout(workout(first), with: heartRate(first, count: 3))
        store.saveWorkout(workout(nil), with: heartRate(nil, count: 1))
        let later = workout(nil, startingAt: start.addingTimeInterval(5))
        let otherSession = workout(HealthKitWorkoutExport.ExportStamp(sessionId: UUID(), version: 1))
        store.saveWorkout(later, with: [])
        store.saveWorkout(otherSession, with: [])

        let earlier = try await HealthKitWorkoutExport.EarlierExport.find(sessionId: sessionId, startDate: start, in: store)
        XCTAssertEqual(earlier.workouts.count, 2, "the earlier copy and the one without an identity")
        XCTAssertEqual(earlier.samples.count, 4)
        let second = stamp(version: 2)
        let saved = workout(second)
        let savedSamples = heartRate(second, count: 2)
        store.saveWorkout(saved, with: savedSamples)
        let keeping = Set((([saved] as [HKSample]) + savedSamples).compactMap(HealthExportIdentity.syncIdentifier(of:)))
        try await earlier.delete(keeping: keeping, from: store)

        XCTAssertEqual(Set(store.samples.map { ObjectIdentifier($0) }), Set((([saved, later, otherSession] as [HKSample]) + savedSamples).map { ObjectIdentifier($0) }))
        XCTAssertEqual(store.deletedReplacedSamples, 0, "nothing HealthKit replaced is deleted again")
        XCTAssertEqual(store.deletedTypes.last, HKObjectType.workoutType(), "workouts go last, after the samples saved with them")
    }

    /// Deleting a session forever removes each workout it exported with the
    /// samples saved with it, and nothing of another session.
    func testDeletingASessionForeverLeavesOnlyOtherSessionsWorkouts() async throws {
        let store = InMemoryHealthSampleStore()
        let own = stamp(version: 1)
        store.saveWorkout(workout(own), with: heartRate(own, count: 3))
        let other = HealthKitWorkoutExport.ExportStamp(sessionId: UUID(), version: 1)
        let otherWorkout = workout(other)
        store.saveWorkout(otherWorkout, with: [])

        let earlier = try await HealthKitWorkoutExport.EarlierExport.find(sessionId: sessionId, startDate: start, in: store)
        try await earlier.delete(keeping: [], from: store)

        XCTAssertEqual(store.samples.map { ObjectIdentifier($0) }, [ObjectIdentifier(otherWorkout)])
        XCTAssertEqual(store.deletedTypes, [HKQuantityType(.heartRate), HKObjectType.workoutType()])
    }

    /// A delete that fails for the samples still deletes the workouts, and
    /// the error reaches the caller.
    func testAFailedSampleDeleteStillDeletesTheWorkout() async throws {
        let store = InMemoryHealthSampleStore()
        let own = stamp(version: 1)
        store.saveWorkout(workout(own), with: heartRate(own, count: 2))
        let earlier = try await HealthKitWorkoutExport.EarlierExport.find(sessionId: sessionId, startDate: start, in: store)
        store.failNextDelete = true
        do {
            try await earlier.delete(keeping: [], from: store)
            XCTFail("the failed delete must be reported")
        } catch {}
        XCTAssertEqual(store.samples.count, 2, "the heart-rate samples, without their workout")
        XCTAssertFalse(store.samples.contains { $0 is HKWorkout })
    }

    // MARK: - Saved while the phone was locked

    /// A locked phone refuses the earlier-export read: the export goes ahead
    /// without it. Any other refusal still stops the export.
    func testOnlyALockedReadIsSkipped() async throws {
        let store = InMemoryHealthSampleStore()
        store.failNextRead = HKError(.errorDatabaseInaccessible)
        let locked = try await HealthKitWorkoutExport.EarlierExport.findUnlessLocked(sessionId: sessionId, startDate: start, in: store)
        XCTAssertNil(locked)

        store.failNextRead = HKError(.errorAuthorizationDenied)
        do {
            _ = try await HealthKitWorkoutExport.EarlierExport.findUnlessLocked(sessionId: sessionId, startDate: start, in: store)
            XCTFail("a read refused for another reason must stop the export")
        } catch {
            XCTAssertFalse(HealthKitWorkoutExport.EarlierExport.isLockedRead(error))
        }
        let unlocked = try await HealthKitWorkoutExport.EarlierExport.findUnlessLocked(sessionId: sessionId, startDate: start, in: store)
        XCTAssertNotNil(unlocked)
    }

    /// A workout saved while the earlier copies could not be read replaced
    /// the ones sharing its identifiers; the next return to the app deletes
    /// the rest (a longer earlier tail, left with no workout) and forgets the
    /// session.
    func testAWorkoutSavedWhileLockedHasItsEarlierCopiesDeletedLater() async throws {
        let store = InMemoryHealthSampleStore()
        let first = stamp(version: 1)
        store.saveWorkout(workout(first), with: heartRate(first, count: 3))
        let second = stamp(version: 2)
        let saved = workout(second)
        let savedSamples = heartRate(second, count: 2)
        store.saveWorkout(saved, with: savedSamples)
        PendingWorkoutReplacements.note(sessionId: sessionId, startDate: start)
        XCTAssertEqual(store.samples.count, 4, "the earlier copy's third sample is still there")

        await PendingWorkoutReplacements.finish(in: store)

        XCTAssertEqual(Set(store.samples.map { ObjectIdentifier($0) }), Set((([saved] as [HKSample]) + savedSamples).map { ObjectIdentifier($0) }))
        XCTAssertNil(PendingWorkoutReplacements.pending()[sessionId.uuidString])
    }

    /// A cleanup Health refuses again stays for the next return.
    func testAFailedCleanupIsKeptForTheNextReturn() async {
        let store = InMemoryHealthSampleStore()
        PendingWorkoutReplacements.note(sessionId: sessionId, startDate: start)
        store.failNextRead = HKError(.errorDatabaseInaccessible)
        await PendingWorkoutReplacements.finish(in: store)
        XCTAssertEqual(PendingWorkoutReplacements.pending()[sessionId.uuidString], start.timeIntervalSince1970)
    }

    /// Nothing carries a version when the newest copy is gone (deleted in
    /// Health): what is left is not deleted.
    func testNothingIsDeletedWithoutAVersionedCopy() async throws {
        let store = InMemoryHealthSampleStore()
        store.saveWorkout(workout(nil), with: heartRate(nil, count: 1))
        let earlier = try await HealthKitWorkoutExport.EarlierExport.find(sessionId: sessionId, startDate: start, in: store)
        try await earlier.deleteSuperseded(from: store)
        XCTAssertEqual(store.samples.count, 2)
    }

    // MARK: - Export stamp

    /// The export stamp is a routine write: it keeps the copy's modification
    /// time and asks for no upload, so this copy cannot overwrite a newer
    /// edit made on another device.
    func testTheExportStampAsksForNoReupload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthWorkoutReplacementTests-\(UUID().uuidString)", isDirectory: true)
        defer { removeDirectory(directory) }
        let archive = SessionArchive(
            directory: directory,
            sleepScheduleProvider: { SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0) },
            sessionMergeModeProvider: { .off }
        )
        var session = HRVSession(
            id: sessionId, startDate: start, endDate: start.addingTimeInterval(600), state: .complete,
            rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        session.sessionType = .workout
        session.modifiedAt = CloudKitSessionFreshness.stamp(at: start)
        _ = try archive.archive(session, skipSameNightMerge: true)
        let requested = OSAllocatedUnfairLock(initialState: false)
        let token = NotificationCenter.default.addObserver(
            forName: .flowRecoveryArchiveSessionsNeedReupload, object: nil, queue: nil
        ) { _ in requested.withLock { $0 = true } }
        defer { NotificationCenter.default.removeObserver(token) }

        let exportedAt = start.addingTimeInterval(700)
        try HealthKitBackfill.writeExportStamp(sessionId, at: exportedAt, archive: archive)

        let stored = try XCTUnwrap(archive.retrieve(sessionId))
        XCTAssertEqual(stored.healthKitExportedAt, exportedAt)
        XCTAssertEqual(stored.modifiedAt, session.modifiedAt)
        XCTAssertFalse(requested.withLock { $0 })
    }

    // MARK: - One read per anchor

    /// A request while a read is under way runs it once more when it ends,
    /// and never a second read beside it.
    func testARequestDuringAReadRunsItOnceMore() {
        let gate = HealthSampleWatch.ReadGate()
        XCTAssertTrue(gate.claimRead("sleep"))
        XCTAssertFalse(gate.claimRead("sleep"), "one read at a time")
        XCTAssertFalse(gate.claimRead("sleep"), "requests during it run it once")
        XCTAssertTrue(gate.claimRead("vitals"), "another anchor has its own read")
        XCTAssertTrue(gate.finishRead("sleep"), "the read runs again")
        XCTAssertFalse(gate.finishRead("sleep"), "and then the key is free")
        XCTAssertTrue(gate.claimRead("sleep"))
        XCTAssertFalse(gate.claimRead("sleep"))
        XCTAssertFalse(gate.finishRead("sleep", canRerun: false), "a read that cannot run again frees the key")
        XCTAssertTrue(gate.claimRead("sleep"))
    }

    // MARK: - Fixtures

    private func stamp(version: Int) -> HealthKitWorkoutExport.ExportStamp {
        HealthKitWorkoutExport.ExportStamp(sessionId: sessionId, version: version)
    }

    /// A ten-minute run as an export saves it; `stamp` nil for one saved
    /// before workouts carried an identity.
    private func workout(_ stamp: HealthKitWorkoutExport.ExportStamp?, startingAt date: Date? = nil) -> HKWorkout {
        let begin = date ?? start
        return HKWorkout(
            activityType: .running, start: begin, end: begin.addingTimeInterval(600), duration: 600,
            totalEnergyBurned: nil, totalDistance: nil, metadata: stamp?.metadataOfWorkout
        )
    }

    /// `count` heart-rate samples, one a minute, as the export saves them
    /// with its workout; nil `stamp` for ones without an identity.
    private func heartRate(_ stamp: HealthKitWorkoutExport.ExportStamp?, count: Int) -> [HKSample] {
        (0 ..< count).compactMap { index in
            let at = start.addingTimeInterval(Double(index * 60))
            return HealthSampleFactory.quantitySample(
                type: HKQuantityType(.heartRate), value: 120, unit: HKUnit(from: "count/min"), start: at, end: at,
                metadata: stamp?.sampleMetadata("hr", index: index)
            )
        }
    }

    private func removeDirectory(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            // swallow-ok: a test that archived nothing leaves no directory to remove.
        }
    }
}
