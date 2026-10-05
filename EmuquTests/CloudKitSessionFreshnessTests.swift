import CloudKit
@testable import Emuqu
import XCTest

/// Last-writer-wins between devices that hold the same session: a pull
/// replaces a held copy only with a strictly newer one, and an upload never
/// overwrites a newer iCloud copy.
final class CloudKitSessionFreshnessTests: XCTestCase {
    private let earlier = Date(timeIntervalSince1970: 1_800_000_000)
    private let later = Date(timeIntervalSince1970: 1_800_000_060)

    // MARK: - Decision

    func testRemoteWithoutStampNeverReplacesTheLocalCopy() {
        XCTAssertEqual(decide(local: nil, remote: nil), .keepLocal)
        XCTAssertEqual(decide(local: earlier, remote: nil), .keepLocal)
    }

    /// A copy never edited since stamping began is older than any edit.
    func testStampedRemoteReplacesAnUnstampedLocalCopy() {
        XCTAssertEqual(decide(local: nil, remote: earlier), .importRemote)
    }

    func testStrictlyNewerRemoteIsImported() {
        XCTAssertEqual(decide(local: earlier, remote: later), .importRemote)
    }

    /// The device that uploaded an edit sees its own copy come back equal.
    func testEqualStampsKeepTheLocalCopy() {
        XCTAssertEqual(decide(local: later, remote: later), .keepLocal)
    }

    /// An unsynced local edit is stamped when made, so it survives a pull of
    /// the older iCloud copy it has not replaced yet.
    func testLocalEditNewerThanRemoteIsKept() {
        XCTAssertEqual(decide(local: later, remote: earlier), .keepLocal)
    }

    /// ISO-8601 payload dates drop the fraction; a sub-second difference must
    /// not read as a newer copy, or each pull would re-import the same edit.
    func testSubSecondDifferenceIsNotNewer() {
        let precise = earlier.addingTimeInterval(0.75)
        XCTAssertEqual(decide(local: earlier, remote: precise), .keepLocal)
        XCTAssertEqual(decide(local: precise, remote: earlier), .keepLocal)
    }

    func testStampIsWholeSeconds() {
        let stamp = CloudKitSessionFreshness.stamp(at: earlier.addingTimeInterval(0.9))
        XCTAssertEqual(stamp, earlier)
    }

    // MARK: - Upload

    func testRecordCarriesTheStampOnlyWhenTheSessionHasOne() {
        var session = makeSession()
        let unstamped = makeRecord(for: session.id)
        CloudKitSessionFreshness.stampRecord(unstamped, from: session)
        XCTAssertNil(unstamped[CloudKitSessionFreshness.modifiedAtField])

        session.modifiedAt = later
        let stamped = makeRecord(for: session.id)
        CloudKitSessionFreshness.stampRecord(stamped, from: session)
        XCTAssertEqual(CloudKitSessionFreshness.modifiedAt(of: stamped), later)
    }

    /// A routine re-upload of an older copy must not undo an edit made on
    /// another device; the session counts as uploaded and the pull imports.
    func testUploadDoesNotOverwriteANewerServerCopy() {
        let id = UUID()
        let server = makeRecord(for: id, modifiedAt: later, probe: "server")
        let local = makeRecord(for: id, modifiedAt: earlier, probe: "local")
        var state = makeSyncState()
        state.markRemoved(id)

        XCTAssertFalse(CloudKitSessionFreshness.overwrite(server, with: local, yieldingIn: &state))
        XCTAssertEqual(server["probe"] as? String, "server")
        XCTAssertTrue(state.uploadedSessionIds.contains(id))
        XCTAssertFalse(state.pendingUploadIds.contains(id))
    }

    func testUnstampedUploadYieldsToAStampedServerCopy() {
        let id = UUID()
        let server = makeRecord(for: id, modifiedAt: earlier, probe: "server")
        let local = makeRecord(for: id, modifiedAt: nil, probe: "local")
        var state = makeSyncState()
        XCTAssertFalse(CloudKitSessionFreshness.overwrite(server, with: local, yieldingIn: &state))
        XCTAssertEqual(server["probe"] as? String, "server")
    }

    func testNewerLocalEditOverwritesTheServerCopy() {
        let id = UUID()
        let server = makeRecord(for: id, modifiedAt: earlier, probe: "server")
        let local = makeRecord(for: id, modifiedAt: later, probe: "local")
        var state = makeSyncState()
        XCTAssertTrue(CloudKitSessionFreshness.overwrite(server, with: local, yieldingIn: &state))
        XCTAssertEqual(server["probe"] as? String, "local")
        XCTAssertEqual(CloudKitSessionFreshness.modifiedAt(of: server), later)
        XCTAssertFalse(state.uploadedSessionIds.contains(id))
    }

    /// A restore carries no newer stamp than the tombstone it replaces; it
    /// must still override it rather than leave the deletion in iCloud.
    func testRestoreOverridesANewerTombstone() {
        let id = UUID()
        let server = makeRecord(for: id, modifiedAt: later)
        server["isDeleted"] = 1 as CKRecordValue
        let local = makeRecord(for: id, modifiedAt: earlier, probe: "local")
        local["isDeleted"] = 0 as CKRecordValue
        var state = makeSyncState()
        XCTAssertTrue(CloudKitSessionFreshness.overwrite(server, with: local, restoring: true, yieldingIn: &state))
        XCTAssertEqual(server["probe"] as? String, "local")
    }

    /// A routine re-upload writes `isDeleted = 0`; the restore marker already
    /// on the record must survive it.
    func testReuploadKeepsTheRestoreMarker() {
        let id = UUID()
        let server = makeRecord(for: id, modifiedAt: earlier)
        server["isDeleted"] = TrashRestoreCoordinator.restoredMarker as CKRecordValue
        let local = makeRecord(for: id, modifiedAt: later)
        local["isDeleted"] = 0 as CKRecordValue
        var state = makeSyncState()
        XCTAssertTrue(CloudKitSessionFreshness.overwrite(server, with: local, yieldingIn: &state))
        XCTAssertEqual(server["isDeleted"] as? Int64, TrashRestoreCoordinator.restoredMarker)
    }

    /// Fields an older build wrote and this one no longer does are cleared.
    func testOverwriteClearsFieldsTheLocalRecordDoesNotCarry() {
        let id = UUID()
        let server = makeRecord(for: id, modifiedAt: earlier)
        server["recoveryScore"] = 7.5 as CKRecordValue
        let local = makeRecord(for: id, modifiedAt: later, probe: "local")
        var state = makeSyncState()
        XCTAssertTrue(CloudKitSessionFreshness.overwrite(server, with: local, yieldingIn: &state))
        XCTAssertNil(server["recoveryScore"])
        XCTAssertEqual(server["probe"] as? String, "local")
    }

    // MARK: - Pull

    /// What the upload strips is kept from the local copy while the sleep
    /// window is unchanged; the edit itself comes from the remote copy.
    func testReplacementKeepsLocalOnlyFields() {
        var local = makeSession()
        local.sleepSnapshot = makeSleep()
        local.vitalsSnapshot = makeVitals()
        local.healthKitExportedAt = earlier
        var remote = local
        remote.sleepSnapshot = nil
        remote.vitalsSnapshot = nil
        remote.healthKitExportedAt = nil
        remote.morningFeeling = 2
        remote.modifiedAt = later

        let merged = CloudKitSessionFreshness.replacing(local, with: remote)
        XCTAssertEqual(merged.morningFeeling, 2)
        XCTAssertEqual(merged.modifiedAt, later)
        XCTAssertNotNil(merged.sleepSnapshot)
        XCTAssertEqual(merged.vitalsSnapshot, local.vitalsSnapshot)
        XCTAssertEqual(merged.healthKitExportedAt, earlier)
    }

    /// After a sleep edit the local snapshot describes the old window; it is
    /// dropped so the pulled-session backfill re-derives it.
    func testReplacementDropsSleepSnapshotAfterASleepEdit() {
        var local = makeSession()
        local.sleepSnapshot = makeSleep()
        var remote = local
        remote.sleepSnapshot = nil
        remote.sleepStartMs = 1_800_000
        remote.sleepUserAdjusted = true

        XCTAssertNil(CloudKitSessionFreshness.replacing(local, with: remote).sleepSnapshot)
    }

    /// An iCloud copy without a sleep window (sleep stays on each device)
    /// does not take this device's sleep away.
    func testReplacementKeepsLocalSleepWhenTheICloudCopyHasNone() {
        var local = makeSession()
        local.sleepSnapshot = makeSleep()
        local.sleepStartMs = 600_000
        local.sleepEndMs = 25_000_000
        local.sleepUserAdjusted = true
        let remote = CloudSessionPayload.uploadable(local)

        let merged = CloudKitSessionFreshness.replacing(local, with: remote)
        XCTAssertEqual(merged.sleepStartMs, 600_000)
        XCTAssertEqual(merged.sleepEndMs, 25_000_000)
        XCTAssertEqual(merged.sleepUserAdjusted, true)
        XCTAssertNotNil(merged.sleepSnapshot)
    }

    // MARK: - What leaves the device

    /// Nothing read from HealthKit is in the uploaded session; the app's own
    /// measurements and scores are.
    func testUploadablePayloadCarriesNoHealthKitReadings() {
        let session = makeSessionWithHealthKitReadings()
        let payload = CloudSessionPayload.uploadable(session)

        XCTAssertNil(payload.sleepSnapshot)
        XCTAssertNil(payload.vitalsSnapshot)
        XCTAssertNil(payload.sleepStartMs)
        XCTAssertNil(payload.sleepEndMs)
        XCTAssertNil(payload.sleepUserAdjusted)
        XCTAssertNil(payload.trainingSnapshot?.vo2Max)
        XCTAssertNil(payload.trainingSnapshot?.recentWorkouts)
        XCTAssertEqual(payload.trainingSnapshot?.ctl, 50)
        XCTAssertEqual(payload.scoreBreakdown?.factors.first { $0.label == "Sleep" }?.detail, "")
        XCTAssertEqual(payload.scoreBreakdown?.factors.first { $0.label == "Sleep" }?.score, 70)
        XCTAssertEqual(payload.scoreBreakdown?.factors.first { $0.label == "HRV" }?.detail, "RMSSD 60 ms")
        XCTAssertEqual(payload.workoutMetadata?.hrrSamples?.map(\.provenance), [.strap])
        XCTAssertEqual(payload.recoveryScore, 7.5)
    }

    /// A device holding the session gets its HealthKit readings back when a
    /// newer iCloud copy replaces it.
    func testReplacementRestoresLocalHealthKitReadings() {
        let local = makeSessionWithHealthKitReadings()
        var remote = CloudSessionPayload.uploadable(local)
        remote.morningFeeling = 4

        let merged = CloudKitSessionFreshness.replacing(local, with: remote)
        XCTAssertEqual(merged.morningFeeling, 4)
        XCTAssertEqual(merged.trainingSnapshot?.vo2Max, 52)
        XCTAssertEqual(merged.trainingSnapshot?.recentWorkouts?.count, 1)
        XCTAssertEqual(merged.scoreBreakdown?.factors.first { $0.label == "Sleep" }?.detail, "7h 10m asleep")
        XCTAssertEqual(merged.workoutMetadata?.hrrSamples?.count, 2)
        XCTAssertEqual(merged.vitalsSnapshot, local.vitalsSnapshot)
    }

    /// Sessions read out of Apple Health whole are refused by the one record
    /// builder every upload goes through.
    func testHealthKitSourcedSessionsAreNeverBuiltIntoARecord() {
        var imported = makeSession()
        imported.deviceProvenance = DeviceProvenance(
            deviceId: "healthkit-import", deviceModel: "Apple Health", firmwareVersion: nil,
            recordingMode: .imported, appVersion: "1", osVersion: "1", capturedAt: earlier
        )
        let zone = CKRecordZone.ID(zoneName: "FreshnessTests", ownerName: CKCurrentUserDefaultName)
        XCTAssertTrue(CloudSessionPayload.isHealthKitSourced(imported))
        XCTAssertThrowsError(try CloudKitSyncManager.buildSessionRecord(from: imported, zoneID: zone, recordTypeName: "HRVSession")) {
            XCTAssertTrue($0 is CloudUploadExclusion)
        }
        var breathe = makeSession()
        breathe.sessionType = .breathe
        XCTAssertTrue(CloudSessionPayload.isHealthKitSourced(breathe))
        XCTAssertFalse(CloudSessionPayload.isHealthKitSourced(makeSession()))
    }

    /// The ids the importer stamps are the ones the upload refuses.
    @MainActor
    func testHealthKitDeviceIdsMatchTheImporter() {
        XCTAssertEqual(CloudSessionPayload.healthKitDeviceIds, [
            ImportedWorkoutBuilder.Source.appleHealth(sourceName: "").deviceId,
            ImportedWorkoutBuilder.Source.appleHealthSamples.deviceId
        ])
    }

    // MARK: - Stored field

    func testModifiedAtRoundTripsAndIsAbsentFromLegacyPayloads() throws {
        var session = makeSession()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let legacy = try decoder.decode(HRVSession.self, from: encoder.encode(session))
        XCTAssertNil(legacy.modifiedAt)

        session.modifiedAt = later
        let decoded = try decoder.decode(HRVSession.self, from: encoder.encode(session))
        XCTAssertEqual(decoded.modifiedAt, later)
        let entry = SessionArchiveEntry.make(from: decoded, hash: "h", filePath: "f.json")
        XCTAssertEqual(entry.modifiedAt, later)
        let entryCopy = try decoder.decode(SessionArchiveEntry.self, from: encoder.encode(entry))
        XCTAssertEqual(entryCopy.modifiedAt, later)
    }

    // MARK: - Helpers

    private func decide(local: Date?, remote: Date?) -> CloudKitSessionFreshness.Decision {
        CloudKitSessionFreshness.decide(localModifiedAt: local, remoteModifiedAt: remote)
    }

    private func makeSession() -> HRVSession {
        HRVSession(
            id: UUID(), startDate: earlier, endDate: later, state: .complete,
            rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
    }

    private func makeRecord(for id: UUID, modifiedAt: Date? = nil, probe: String? = nil) -> CKRecord {
        let zone = CKRecordZone.ID(zoneName: "FreshnessTests", ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(recordType: "HRVSession", recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zone))
        if let modifiedAt { record[CloudKitSessionFreshness.modifiedAtField] = modifiedAt as CKRecordValue }
        if let probe { record["probe"] = probe as CKRecordValue }
        return record
    }

    private func makeSyncState() -> CloudKitSyncState {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudKitSessionFreshnessTests_\(UUID().uuidString).json")
        return CloudKitSyncState(syncStateURL: url)
    }

    private func makeSessionWithHealthKitReadings() -> HRVSession {
        var session = makeSession()
        session.recoveryScore = 7.5
        session.sleepSnapshot = makeSleep()
        session.vitalsSnapshot = makeVitals()
        session.sleepStartMs = 600_000
        session.sleepEndMs = 25_000_000
        session.sleepUserAdjusted = true
        session.trainingSnapshot = TrainingContext(
            atl: 40, ctl: 50, tsb: 10, yesterdayTrimp: 80, vo2Max: 52, daysSinceHardWorkout: 2,
            recentWorkouts: [WorkoutSnapshot(date: earlier, type: "Run", durationMinutes: 45, trimp: 80)]
        )
        session.scoreBreakdown = RecoveryScoreCalculator.ScoreBreakdown(
            compositeScore: 75, tier: 2,
            factors: [
                .init(label: "HRV", detail: "RMSSD 60 ms", score: 80, weight: 0.7, impact: .positive),
                .init(label: "Sleep", detail: "7h 10m asleep", score: 70, weight: 0.3, impact: .neutral)
            ],
            penalties: []
        )
        var workout = WorkoutMetadata(sport: .run)
        workout.hrrSamples = [
            HRRSample(offsetSec: 60, hr: 130, drop: 30, peakHR: 160, provenance: .strap),
            HRRSample(offsetSec: 60, hr: 132, drop: 28, peakHR: 160, provenance: .watchSamples)
        ]
        session.workoutMetadata = workout
        return session
    }

    private func makeSleep() -> SleepData {
        SleepData(
            date: earlier, totalSleepMinutes: 420, inBedMinutes: 460,
            deepSleepMinutes: 90, remSleepMinutes: 80, awakeMinutes: 20,
            sleepEfficiency: 91, boundarySource: .recordingBounds
        )
    }

    private func makeVitals() -> RecoveryVitals {
        RecoveryVitals(
            respiratoryRate: 14, respiratoryRateBaseline: 14.5, oxygenSaturation: nil,
            oxygenSaturationMin: nil, wristTemperature: nil, wristTemperatureBaseline: nil,
            restingHeartRate: 52
        )
    }
}
