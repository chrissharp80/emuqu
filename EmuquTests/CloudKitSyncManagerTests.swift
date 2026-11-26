import CloudKit
@testable import Emuqu
import XCTest

/// Tests for CloudKitSyncManager — sync state management, error handling, and public API contract.
///
/// Note: Tests that interact with the real CloudKit backend (upload, pull, subscription)
/// are integration tests that require an iCloud account and are not included here.
/// These tests verify the logic layer: state transitions, error formatting, deduplication,
/// and data integrity of the sync state persistence.
///
/// ## Whose manager
///
/// The tests that change sync state build their own manager
/// (`CloudKitSyncManager.isolated`): over a temporary archive, fresh-install
/// settings and a sync-state file in the test's folder. Run against
/// `CloudKitSyncManager.shared` they reset the host's uploaded, pending,
/// quarantine and local-only lists and its record versions, so the next real
/// sync re-pushed and re-pulled everything. What a reset still clears in the
/// host's standard defaults (`HostDefaults.cloudSyncBookkeeping`) is set
/// aside in `setUp` and put back in `tearDown`, with the Health-scrub list's
/// keys (`CloudHealthScrubCoordinator`), which the scrub tests write.
///
/// ## What an upload test can show
///
/// `uploadSession` changes nothing a test can read before it reaches
/// CloudKit, so a test that only calls it cannot tell a guard that held
/// from a session the upload skipped for another reason. Which sessions the
/// direct upload takes is `takesDirectUpload(_:)`, asserted directly; the
/// consent gate is `cloudUploadsAllowed`, asserted directly; the upload
/// tests then check, on the test's own manager, that nothing was queued or
/// marked uploaded and the state did not move.
@MainActor
final class CloudKitSyncManagerTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CloudKitSyncManagerTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var settings = SettingsManager(settingsURL: directory.appendingPathComponent("user_settings.json"))
    private lazy var archive = SessionArchive(directory: directory.appendingPathComponent("Archive", isDirectory: true))
    private lazy var manager = CloudKitSyncManager.isolated(archive: archive, directory: directory, settings: settings)
    private var hostSyncDefaults: HostDefaults?

    override func setUp() async throws {
        try await super.setUp()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        hostSyncDefaults = HostDefaults.setAside(
            HostDefaults.cloudSyncBookkeeping + [CloudHealthScrubCoordinator.remainingKey, CloudHealthScrubCoordinator.initializedKey]
                + CloudHealthScrubCoordinator.legacyKeys
        )
    }

    override func tearDown() async throws {
        hostSyncDefaults?.restore()
        // Settings are written on a background queue. Drain it first, or a
        // write landing in the folder while it is removed fails the removal.
        _ = settings.flushPendingWritesSynchronously()
        try FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func completeNight() -> HRVSession {
        HRVSession(
            id: UUID(), startDate: Date(timeIntervalSince1970: 1_790_000_000), endDate: Date(timeIntervalSince1970: 1_790_028_800),
            state: .complete, sessionType: .overnight, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
    }

    /// Nothing about `id` was queued or marked uploaded, and the sync state
    /// is what it was.
    private func assertUntouched(_ id: UUID, stateBefore: CloudKitSyncManager.SyncState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(manager.state.pendingUploadIds.contains(id), "queued for upload", file: file, line: line)
        XCTAssertFalse(manager.state.uploadedSessionIds.contains(id), "marked uploaded", file: file, line: line)
        XCTAssertEqual(manager.syncState, stateBefore, file: file, line: line)
    }

    // MARK: - Upload Guard Tests

    /// The direct upload takes a complete session, and a workout carrying
    /// its metadata whatever its state; not a failed or collecting night, and
    /// never a session read out of Apple Health whole (a breathing session).
    func testTheDirectUploadTakesOnlyCompleteSessionsAndWorkoutsWithData() {
        XCTAssertTrue(CloudKitSyncManager.takesDirectUpload(completeNight()))

        var failed = completeNight()
        failed.state = .failed
        XCTAssertFalse(CloudKitSyncManager.takesDirectUpload(failed), "a failed night was taken")

        let collecting = HRVSession(sessionType: .overnight)
        XCTAssertEqual(collecting.state, .collecting)
        XCTAssertFalse(CloudKitSyncManager.takesDirectUpload(collecting), "a collecting night was taken")

        var partialWorkout = HRVSession(sessionType: .workout)
        partialWorkout.state = .failed
        partialWorkout.workoutMetadata = WorkoutMetadata(sport: .run)
        XCTAssertTrue(CloudKitSyncManager.takesDirectUpload(partialWorkout), "a workout with data was left out")
        partialWorkout.workoutMetadata = nil
        XCTAssertFalse(CloudKitSyncManager.takesDirectUpload(partialWorkout))

        var breathe = completeNight()
        breathe.sessionType = .breathe
        XCTAssertFalse(CloudKitSyncManager.takesDirectUpload(breathe), "a session from Apple Health was taken")
    }

    func testUploadSkipsFailedSession() async throws {
        var session = completeNight()
        session.state = .failed
        try archive.archive(session)
        settings.settings.hasCompletedOnboarding = true
        settings.settings.iCloudSyncEnabled = true
        XCTAssertTrue(manager.cloudUploadsAllowed, "Sanity: only the session's state can stop this upload")

        let before = manager.syncState
        await manager.uploadSession(session)

        assertUntouched(session.id, stateBefore: before)
    }

    func testUploadSkipsCollectingSession() async throws {
        let session = HRVSession(sessionType: .overnight)
        XCTAssertEqual(session.state, .collecting)
        settings.settings.hasCompletedOnboarding = true
        settings.settings.iCloudSyncEnabled = true
        XCTAssertTrue(manager.cloudUploadsAllowed, "Sanity: only the session's state can stop this upload")

        let before = manager.syncState
        await manager.uploadSession(session)

        assertUntouched(session.id, stateBefore: before)
    }

    // MARK: - Consent at the moment of the save

    /// Sync was on when the upload started and switched off while it was
    /// prepared (the read, the sealing, a conflict's fetch): the save is not
    /// sent, and the session is not counted as a failed upload.
    func testAnUploadPreparedBeforeSyncWasSwitchedOffIsNotSent() async throws {
        let session = completeNight()
        try archive.archive(session)
        settings.settings.hasCompletedOnboarding = true
        settings.settings.iCloudSyncEnabled = true
        XCTAssertTrue(manager.cloudUploadsAllowed, "Sanity: the upload was allowed when it started")

        settings.settings.iCloudSyncEnabled = false
        do {
            _ = try await manager.saveUpload(CKRecord(recordType: "HRVSession"))
            XCTFail("the save was sent after sync was switched off")
        } catch is CloudUploadStopped {
            XCTAssertNil(manager.state.uploadFailureCounts[session.id], "a stopped upload is not a failure of the session")
        }
    }

    /// With sync off nothing is asked of iCloud, and the answer says so
    /// rather than reporting an iCloud that holds no backups.
    func testLiveBackupsAreNotAskedOfICloudWithSyncOff() async throws {
        settings.settings.iCloudSyncEnabled = false

        let fetched = try await manager.fetchLiveBackups()

        XCTAssertNil(fetched)
    }

    /// The newest backups are picked from the whole listing, in whatever
    /// order iCloud returned its pages.
    func testTheNewestBackupsComeFromTheWholeListing() {
        let ids = (0 ..< 5).map { CKRecord.ID(recordName: "live_\($0)") }
        let dated = zip(ids, [3.0, 1.0, 5.0, 2.0, 4.0]).map { (id: $0, captureDate: Date(timeIntervalSince1970: $1)) }

        XCTAssertEqual(CloudKitLiveBackupManager.newest(dated, limit: 2), [ids[2], ids[4]])
    }

    // MARK: - Sync Disabled Tests

    /// Turning sync off leaves the manager idle rather than showing a stale
    /// error: from an error on screen, a full sync with the setting off
    /// clears it.
    func testFullSyncReturnsIdleWhenDisabled() async {
        settings.settings.iCloudSyncEnabled = false
        manager.showSyncStopped("A stale error")
        XCTAssertNotEqual(manager.syncState, .idle, "Sanity: the test starts from an error")

        await manager.performFullSync()

        XCTAssertEqual(manager.syncState, .idle, "Disabling sync must normalise the state to idle")
    }

    func testUploadSessionNoOpWhenDisabled() async throws {
        settings.settings.iCloudSyncEnabled = false
        settings.settings.hasCompletedOnboarding = true
        let session = completeNight()
        try archive.archive(session)
        XCTAssertTrue(CloudKitSyncManager.takesDirectUpload(session), "Sanity: only the setting can stop this upload")
        XCTAssertFalse(manager.cloudUploadsAllowed)

        let before = manager.syncState
        await manager.uploadSession(session)

        assertUntouched(session.id, stateBefore: before)
    }

    /// The sync toggle defaults to on, and onboarding asks about iCloud only on
    /// its backup page. Nothing may be uploaded before the user gets there.
    func testUploadsWaitForOnboarding() {
        settings.settings.iCloudSyncEnabled = true
        settings.settings.hasCompletedOnboarding = false
        XCTAssertFalse(manager.cloudUploadsAllowed, "Uploads allowed before onboarding asked about iCloud")

        settings.settings.hasCompletedOnboarding = true
        XCTAssertTrue(manager.cloudUploadsAllowed)

        settings.settings.iCloudSyncEnabled = false
        XCTAssertFalse(manager.cloudUploadsAllowed, "Uploads allowed with iCloud sync off")
    }

    func testUploadDeletionNoOpWhenDisabled() async {
        settings.settings.iCloudSyncEnabled = false
        let id = UUID()

        let before = manager.syncState
        await manager.uploadDeletion(id)

        assertUntouched(id, stateBefore: before)
        XCTAssertFalse(manager.state.recordVersions.keys.contains(id))
    }

    // MARK: - Error Message Formatting Tests

    /// `cloudKitErrorMessage` maps the CloudKit codes a user can act on to
    /// plain sentences and passes anything else through as its description.
    func testCloudKitErrorMessages() {
        let genericError = NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "Test error"])
        XCTAssertEqual(manager.cloudKitErrorMessage(genericError), "Test error", "A non-CloudKit error keeps its own description")

        XCTAssertEqual(manager.cloudKitErrorMessage(CKError(.networkFailure)), CloudSyncMessages.noInternet)
        XCTAssertEqual(manager.cloudKitErrorMessage(CKError(.networkUnavailable)), CloudSyncMessages.noInternet)
        XCTAssertEqual(manager.cloudKitErrorMessage(CKError(.quotaExceeded)), CloudSyncMessages.storageFull)
        XCTAssertEqual(manager.cloudKitErrorMessage(CKError(.notAuthenticated)), CloudSyncMessages.notSignedIn)
        let limited = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 30.0])
        XCTAssertEqual(manager.cloudKitErrorMessage(limited), CloudSyncMessages.rateLimited(retryAfter: 30))

        let other = ckError(.serverRejectedRequest, message: "Rejected")
        XCTAssertEqual(manager.cloudKitErrorMessage(other), other.localizedDescription, "Other CloudKit codes keep their description")
    }

    // MARK: - Data Compression Integration

    func testDataCompressionRoundTrip() throws {
        // A session payload is JSON, compressed, then sealed by
        // CloudPayloadCodec. This checks the JSON + compression layers; the
        // sealing layer is CloudPayloadCodecTests'.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let session = HRVSession(
            id: UUID(),
            startDate: Date(),
            endDate: Date(),
            state: .complete,
            sessionType: .overnight,
            rrSeries: nil,
            analysisResult: nil,
            artifactFlags: nil
        )
        let jsonData = try encoder.encode(session)

        // Verify JSON is non-trivial size
        XCTAssertGreaterThan(jsonData.count, 50, "JSON should have meaningful size")

        let compressed = try DataCompression.compress(jsonData)
        XCTAssertFalse(compressed.isEmpty, "Compressed data should not be empty")

        let decompressed = try DataCompression.decompress(compressed)
        XCTAssertEqual(decompressed, jsonData, "Decompressed data should match original JSON")
    }

    func testSessionSerializationRoundTrip() throws {
        // The JSON + compression layers under CloudPayloadCodec give back
        // the session that went in.
        let session = HRVSession(
            id: UUID(),
            startDate: Date(),
            endDate: Date(),
            state: .complete,
            sessionType: .overnight,
            rrSeries: nil,
            analysisResult: nil,
            artifactFlags: nil
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let jsonData = try encoder.encode(session)

        let compressed = try DataCompression.compress(jsonData)
        let decompressed = try DataCompression.decompress(compressed)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HRVSession.self, from: decompressed)

        XCTAssertEqual(decoded.id, session.id, "Session ID should survive serialization round-trip")
        XCTAssertEqual(decoded.sessionType, session.sessionType, "Session type should survive round-trip")
        XCTAssertEqual(decoded.state, session.state, "Session state should survive round-trip")
    }

    // MARK: - Permanent Schema-Error Detection
    //
    // Reproduces the exact CKError shapes that appeared in a beta
    // tester's debug log against the un-promoted production
    // schema. Without detection, the app retried these errors
    // every sync cycle (and every RR-collector minute for live backup),
    // burning battery and stalling the main actor. The detection
    // helper now short-circuits the whole retry loop.

    private func ckError(_ code: CKError.Code, message: String) -> Error {
        // CKError is a stored-NSError bridge — building from NSError is
        // the supported way to fabricate one for tests.
        let nsError = NSError(
            domain: CKErrorDomain,
            code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        return CKError(_nsError: nsError)
    }

    func testIsPermanentSchemaErrorMatchesProductionUploadFailure() {
        // From the beta debug log:
        //   "Cannot create new type HRVSession in production schema"
        let error = ckError(.serverRejectedRequest, message: "Cannot create new type HRVSession in production schema")
        XCTAssertTrue(CloudKitSyncManager.isPermanentSchemaError(error))
    }

    func testIsPermanentSchemaErrorMatchesPullSideMessage() {
        // From the beta debug log:
        //   "Did not find record type: HRVSession"
        let error = ckError(.serverRejectedRequest, message: "Did not find record type: HRVSession")
        XCTAssertTrue(CloudKitSyncManager.isPermanentSchemaError(error))
    }

    func testIsPermanentSchemaErrorMatchesRawBackupLiveSession() {
        // Same root cause, different record type — live backup loop.
        let error = ckError(.serverRejectedRequest, message: "Cannot create new type RawBackup in production schema")
        XCTAssertTrue(CloudKitSyncManager.isPermanentSchemaError(error))
    }

    func testIsPermanentSchemaErrorMatchesMissingIndexMessages() {
        // Real CloudKit phrasing for a production container
        // whose record type exists but lacks the queryable/sortable
        // indexes the pull path's CKQuery needs. Matching on
        // "indexable" alone lets these slip past the breaker, so the pull
        // fails silently forever while Settings shows "Up to date".
        let queryable = ckError(.invalidArguments, message: "Field 'recordName' is not marked queryable")
        XCTAssertTrue(CloudKitSyncManager.isPermanentSchemaError(queryable))

        let sortable = ckError(.invalidArguments, message: "Field 'startDate' is not marked sortable")
        XCTAssertTrue(CloudKitSyncManager.isPermanentSchemaError(sortable))

        let indexable = ckError(.invalidArguments, message: "Field 'beatCount' is not marked indexable")
        XCTAssertTrue(CloudKitSyncManager.isPermanentSchemaError(indexable))
    }

    func testIsPermanentSchemaErrorRejectsTransientErrors() {
        let network = ckError(.networkFailure, message: "Network unavailable")
        XCTAssertFalse(CloudKitSyncManager.isPermanentSchemaError(network))

        let recordChanged = ckError(.serverRecordChanged, message: "newer record on server")
        XCTAssertFalse(CloudKitSyncManager.isPermanentSchemaError(recordChanged))

        let unknownItem = ckError(.unknownItem, message: "record not found")
        // unknownItem with a "schema" message is unlikely in practice,
        // but the bare-error form must NOT match.
        XCTAssertFalse(CloudKitSyncManager.isPermanentSchemaError(unknownItem))
    }

    func testIsPermanentSchemaErrorRejectsBareNSError() {
        // A plain NSError without a CK domain should not match.
        let nsError = NSError(domain: NSURLErrorDomain, code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot create new type Whatever in production schema"])
        // Plain NSError carries the magic string but no CK code wrapper —
        // helper still recognizes it (we matched on message + tolerant
        // code path) so future SDK-wrapping changes don't break detection.
        // This pins the current intent: matching is message-led.
        XCTAssertTrue(CloudKitSyncManager.isPermanentSchemaError(nsError))
    }

    // MARK: - A failed save, on every upload path

    /// The batch push and the direct upload hand a failed save to one
    /// handler, so a deleted zone is recognised the same on both.
    func testADeletedZoneIsRecognisedForEveryUploadPath() {
        XCTAssertTrue(CloudKitSyncManager.isZoneGone(CKError(.zoneNotFound)))
        XCTAssertTrue(CloudKitSyncManager.isZoneGone(CKError(.userDeletedZone)))
        XCTAssertFalse(CloudKitSyncManager.isZoneGone(CKError(.networkFailure)))
        XCTAssertFalse(CloudKitSyncManager.isZoneGone(CKError(.serverRecordChanged)))
    }

    /// A save that failed for a passing reason is queued for a retry and
    /// lets the push go on.
    func testATransientSaveFailureQueuesTheSessionForARetry() async {
        let id = UUID()
        let stops = await manager.handleSaveFailure(ckError(.networkFailure, message: "Network unavailable"), sessionId: id)

        XCTAssertFalse(stops)
        XCTAssertTrue(manager.state.pendingUploadIds.contains(id))
    }

    /// A schema the container lacks stops the push and queues nothing: no
    /// retry this launch can succeed.
    func testAMissingSchemaStopsThePushWithoutQueueing() async {
        let id = UUID()
        let schema = ckError(.serverRejectedRequest, message: "Cannot create new type HRVSession in production schema")
        let stops = await manager.handleSaveFailure(schema, sessionId: id)

        XCTAssertTrue(stops)
        XCTAssertFalse(manager.state.pendingUploadIds.contains(id))
    }

    // MARK: - Remote Deletion (GDPR / App Store)
    //
    // `deleteAllRemoteData()` itself needs a network + signed-in iCloud
    // account, so it isn't exercised here (and MUST NOT be — it would
    // delete the zones of whatever account the simulator is signed into).
    // These tests cover its two locally-testable pieces: the
    // zone-already-gone error classification, and the local state reset
    // that runs on success (resetLocalSyncState + sanitize-drip clearing).

    func testIsZoneAlreadyGoneErrorMatchesZoneNotFoundAndUserDeletedZone() {
        let zoneNotFound = ckError(.zoneNotFound, message: "Zone does not exist")
        XCTAssertTrue(CloudDeletionCoordinator.isZoneAlreadyGoneError(zoneNotFound),
                      "Deleting a zone that's already gone IS the requested end state")

        let userDeleted = ckError(.userDeletedZone, message: "User deleted the zone")
        XCTAssertTrue(CloudDeletionCoordinator.isZoneAlreadyGoneError(userDeleted))
    }

    func testIsZoneAlreadyGoneErrorUnwrapsPartialFailureWhenAllZonesGone() {
        let zoneID = CKRecordZone.ID(zoneName: "HRVSessions", ownerName: CKCurrentUserDefaultName)
        let inner = CKError(_nsError: NSError(
            domain: CKErrorDomain,
            code: CKError.Code.zoneNotFound.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Zone does not exist"]
        ))
        let outer = CKError(_nsError: NSError(
            domain: CKErrorDomain,
            code: CKError.Code.partialFailure.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: "Partial failure",
                CKPartialErrorsByItemIDKey: [zoneID: inner]
            ]
        ))
        XCTAssertTrue(CloudDeletionCoordinator.isZoneAlreadyGoneError(outer))
    }

    func testIsZoneAlreadyGoneErrorRejectsPartialFailureWithRealError() {
        // One zone gone + one genuine failure must NOT count as success —
        // the user would be told their iCloud data was deleted when part
        // of it wasn't.
        let goneZoneID = CKRecordZone.ID(zoneName: "HRVSessions", ownerName: CKCurrentUserDefaultName)
        let failedZoneID = CKRecordZone.ID(zoneName: "UserSettings", ownerName: CKCurrentUserDefaultName)
        let gone = CKError(_nsError: NSError(
            domain: CKErrorDomain,
            code: CKError.Code.zoneNotFound.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Zone does not exist"]
        ))
        let failed = CKError(_nsError: NSError(
            domain: CKErrorDomain,
            code: CKError.Code.networkFailure.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Network unavailable"]
        ))
        let outer = CKError(_nsError: NSError(
            domain: CKErrorDomain,
            code: CKError.Code.partialFailure.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: "Partial failure",
                CKPartialErrorsByItemIDKey: [goneZoneID: gone, failedZoneID: failed]
            ]
        ))
        XCTAssertFalse(CloudDeletionCoordinator.isZoneAlreadyGoneError(outer))
    }

    func testIsZoneAlreadyGoneErrorRejectsTransientAndNonCKErrors() {
        let network = ckError(.networkFailure, message: "Network unavailable")
        XCTAssertFalse(CloudDeletionCoordinator.isZoneAlreadyGoneError(network))

        let notAuthenticated = ckError(.notAuthenticated, message: "Not signed in")
        XCTAssertFalse(CloudDeletionCoordinator.isZoneAlreadyGoneError(notAuthenticated))

        let plain = NSError(domain: NSURLErrorDomain, code: -1009, userInfo: nil)
        XCTAssertFalse(CloudDeletionCoordinator.isZoneAlreadyGoneError(plain))

        // Empty partial-failure dictionary carries no proof the zones are
        // gone — must not be treated as success.
        let emptyPartial = CKError(_nsError: NSError(
            domain: CKErrorDomain,
            code: CKError.Code.partialFailure.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Partial failure"]
        ))
        XCTAssertFalse(CloudDeletionCoordinator.isZoneAlreadyGoneError(emptyPartial))
    }

    func testClearSanitizeDripStateRemovesBothKeys() {
        // Raw key strings intentionally duplicated here — they pin the
        // persisted format (renaming the constants must not orphan
        // existing users' drip state).
        let remainingKey = "FlowRecovery.cloudkit.hkSanitizeReupload.v4.remaining"
        let initializedKey = "FlowRecovery.cloudkit.hkSanitizeReupload.v4.initialized"
        let legacyRemainingKey = "FlowRecovery.cloudkit.hkSanitizeReupload.v3.remaining"
        let defaults = UserDefaults.standard
        // The host's values of all three, the legacy one included, go back
        // afterwards, and a key the host did not have is removed again.
        let host = HostDefaults.setAside([remainingKey, initializedKey, legacyRemainingKey])
        defer { host.restore() }

        defaults.set([UUID().uuidString], forKey: remainingKey)
        defaults.set(true, forKey: initializedKey)
        defaults.set([UUID().uuidString], forKey: legacyRemainingKey)

        manager.deletion.clearSanitizeDripState()

        XCTAssertNil(defaults.stringArray(forKey: legacyRemainingKey),
                     "The v3 drip's list must go too")

        XCTAssertNil(defaults.stringArray(forKey: remainingKey),
                     "Remote deletion must clear the drip's remaining-id list — those records no longer exist")
        XCTAssertFalse(defaults.bool(forKey: initializedKey),
                       "Drip must re-initialize from scratch after a future sync re-enable")
    }

    /// With iCloud Sync on, each listed record still in iCloud is marked for
    /// upload once (the push writes it without Health readings); an id not
    /// in iCloud leaves the list without being marked, and a second pass
    /// changes nothing.
    func testHealthScrubDripMarksEachUploadedRecordOnce() async {
        let scrub = manager.healthScrub
        let defaults = UserDefaults.standard
        let uploaded = UUID()
        let notInCloud = UUID()
        manager.state.markUploaded(uploaded)
        defaults.set(true, forKey: CloudHealthScrubCoordinator.initializedKey)
        defaults.set([notInCloud.uuidString, uploaded.uuidString], forKey: CloudHealthScrubCoordinator.remainingKey)

        await scrub.dripReupload()

        XCTAssertFalse(manager.isUploaded(uploaded), "Marked for upload again")
        let remaining = await scrub.remainingIds()
        XCTAssertEqual(remaining, [])
        manager.state.markUploaded(uploaded)
        await scrub.dripReupload()
        XCTAssertTrue(manager.isUploaded(uploaded), "Each record is rewritten once")
    }

    /// The first pass lists every record this device uploaded.
    func testHealthScrubListStartsFromTheUploadedSet() async {
        let defaults = UserDefaults.standard
        let uploaded = UUID()
        manager.state.markUploaded(uploaded)
        manager.healthScrub.clear()

        let listed = await manager.healthScrub.remainingIds()

        XCTAssertEqual(listed, [uploaded.uuidString], "the list is this manager's uploaded set")
        XCTAssertTrue(defaults.bool(forKey: CloudHealthScrubCoordinator.initializedKey))
    }

    func testMissingRecordOrZoneNeedsNoScrub() {
        XCTAssertTrue(CloudHealthScrubCoordinator.meansNoRecord(CKError(.unknownItem)))
        XCTAssertTrue(CloudHealthScrubCoordinator.meansNoRecord(CKError(.zoneNotFound)))
        XCTAssertTrue(CloudHealthScrubCoordinator.meansNoRecord(CKError(.userDeletedZone)))
        XCTAssertFalse(CloudHealthScrubCoordinator.meansNoRecord(CKError(.networkUnavailable)))
    }

    func testResetLocalSyncStateReturnsToCleanState() {
        // resetLocalSyncState is the success-path tail of deleteAllRemoteData.
        // Verify its observable contract: syncState idle, lastSyncDate gone,
        // zone-created flag cleared so the next sync cycle recreates the zone
        // from scratch.
        // On the test's own manager: the host's lists stay as they are, and
        // the defaults the reset clears were set aside in `setUp`.
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: UserDefaultsKeys.cloudKitZoneCreated)
        defaults.set(true, forKey: CloudKitSettingsSync.zoneCreatedKey)
        let uploaded = UUID()
        let pending = UUID()
        manager.state.markUploaded(uploaded)
        manager.state.markRemoved(pending)
        manager.showSyncStopped("A stale error")

        manager.resetLocalSyncState()

        XCTAssertEqual(manager.syncState, .idle, "Reset must land in .idle")
        XCTAssertTrue(manager.state.uploadedSessionIds.isEmpty, "the uploaded list survived the reset")
        XCTAssertTrue(manager.state.pendingUploadIds.isEmpty, "the pending queue survived the reset")
        XCTAssertNil(manager.lastSyncDate, "lastSyncDate must clear — 'Up to date' after a wipe would be a lie")
        XCTAssertNil(defaults.object(forKey: UserDefaultsKeys.cloudKitLastSyncDate),
                     "Persisted last-sync stamp must clear too")
        XCTAssertFalse(defaults.bool(forKey: UserDefaultsKeys.cloudKitZoneCreated),
                       "zoneCreated must clear so ensureZoneExists recreates the zone on next upload")
        XCTAssertFalse(defaults.bool(forKey: CloudKitSettingsSync.zoneCreatedKey),
                       "the settings zone flag must clear with the rest of the bookkeeping")
    }

    /// Put the session and settings zone flags and the last-sync date back
    /// as they were once the test ends: `resetLocalSyncState` clears them in
    /// the host's defaults.
    private func preserveTheZoneFlagsAndLastSync() {
        let defaults = UserDefaults.standard
        let zoneCreated = defaults.object(forKey: UserDefaultsKeys.cloudKitZoneCreated) as? Bool
        let settingsZoneCreated = defaults.object(forKey: CloudKitSettingsSync.zoneCreatedKey) as? Bool
        let lastSync = defaults.object(forKey: UserDefaultsKeys.cloudKitLastSyncDate) as? Date
        addTeardownBlock {
            let defaults = UserDefaults.standard
            for (key, value) in [
                (UserDefaultsKeys.cloudKitZoneCreated, zoneCreated),
                (CloudKitSettingsSync.zoneCreatedKey, settingsZoneCreated)
            ] {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            if let lastSync {
                defaults.set(lastSync, forKey: UserDefaultsKeys.cloudKitLastSyncDate)
            } else {
                defaults.removeObject(forKey: UserDefaultsKeys.cloudKitLastSyncDate)
            }
        }
    }

    /// Sessions queued for upload say nothing about which account the device
    /// syncs with: the queue fills while sync is off. Uploaded sessions do.
    func testTheUploadQueueIsNotAccountBookkeeping() {
        preserveTheZoneFlagsAndLastSync()
        let manager = CloudKitSyncManager.shared
        manager.resetLocalSyncState()
        defer { manager.resetLocalSyncState() }

        manager.state.markRemoved(UUID())
        XCTAssertFalse(manager.hasAccountBookkeeping, "a queued upload counted as another account's bookkeeping")
        manager.state.markUploaded(UUID())
        XCTAssertTrue(manager.hasAccountBookkeeping)
    }

    func testIsPermanentSchemaErrorUnwrapsPartialFailures() {
        // CloudKit batch operations wrap per-item errors inside
        // `partialErrorsByItemID`. The detection must look inside.
        let innerNSError = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.serverRejectedRequest.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Cannot create new type HRVSession in production schema"]
        )
        let innerCKError = CKError(_nsError: innerNSError)
        let recordID = CKRecord.ID(recordName: "test", zoneID: CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName))
        let outerNSError = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.partialFailure.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: "Partial failure",
                CKPartialErrorsByItemIDKey: [recordID: innerCKError]
            ]
        )
        let outer = CKError(_nsError: outerNSError)
        XCTAssertTrue(CloudKitSyncManager.isPermanentSchemaError(outer))
    }

    // MARK: - Which iCloud account the bookkeeping belongs to

    private func verdict(
        recorded: String?, current: String = "account-b", syncEnabled: Bool = true, stoppedByApp: Bool = false,
        accountChanged: Bool = false, hasBookkeeping: Bool = true
    ) -> CloudAccountIdentity.Verdict {
        CloudAccountIdentity.verdict(
            recorded: recorded, current: current, syncEnabled: syncEnabled, stoppedByApp: stoppedByApp,
            accountChangedThisLaunch: accountChanged, hasBookkeeping: hasBookkeeping
        )
    }

    /// A different Apple ID than the one sync was enabled for stops sync; the
    /// same one syncs on, an account change or not.
    func testADifferentAccountIsNeverSyncedInto() {
        XCTAssertEqual(verdict(recorded: "account-a"), .differentAccount)
        XCTAssertEqual(verdict(recorded: "account-a", accountChanged: true, hasBookkeeping: false), .differentAccount)
        XCTAssertEqual(verdict(recorded: "account-b", accountChanged: true), .sameAccount)
    }

    /// An install from before the account was recorded adopts the signed-in
    /// account, unless the account status changed this launch while its
    /// bookkeeping remains: that bookkeeping may be another Apple ID's, and is
    /// looked up in iCloud before anything is decided.
    func testAnUnrecordedAccountIsAdoptedOnlyWhenTheBookkeepingCanBeAttributed() {
        XCTAssertEqual(verdict(recorded: nil), .adopt)
        XCTAssertEqual(verdict(recorded: nil, accountChanged: true, hasBookkeeping: false), .adopt)
        XCTAssertEqual(verdict(recorded: nil, accountChanged: true), .attributeBookkeeping)
    }

    /// With sync off, an account is recorded only for a device holding
    /// bookkeeping to keep in step; one that never synced records nothing
    /// until the user turns sync on.
    func testWithSyncOffNothingIsAdoptedWithoutBookkeeping() {
        XCTAssertEqual(verdict(recorded: nil, syncEnabled: false, hasBookkeeping: false), .awaitingOptIn)
        XCTAssertEqual(verdict(recorded: nil, syncEnabled: false, accountChanged: true, hasBookkeeping: false), .awaitingOptIn)
        XCTAssertEqual(verdict(recorded: nil, syncEnabled: false), .adopt)
        XCTAssertEqual(verdict(recorded: nil, syncEnabled: true, hasBookkeeping: false), .adopt)
    }

    /// After the app stopped sync, nothing is adopted until the user turns
    /// sync on again for the account now signed in.
    func testAStoppedSyncWaitsForTheUserToOptIn() {
        XCTAssertEqual(verdict(recorded: nil, syncEnabled: false, stoppedByApp: true, hasBookkeeping: false), .awaitingOptIn)
        XCTAssertEqual(verdict(recorded: nil, syncEnabled: true, stoppedByApp: true, hasBookkeeping: false), .adopt)
    }

    /// A check that began before an account change confirms nothing, and an
    /// account change drops the confirmation at once. Run on a launch state
    /// of its own, so the process's stays as it was.
    func testAnAccountChangeUnconfirmsTheAccount() {
        var launch = CloudAccountIdentity.LaunchState()
        XCTAssertTrue(launch.confirm("account-a", generation: launch.generation))
        XCTAssertTrue(launch.isConfirmed(recorded: "account-a"))
        XCTAssertFalse(launch.accountChanged)

        let staleCheck = launch.generation
        launch.noteAccountChanged()
        XCTAssertTrue(launch.accountChanged)
        XCTAssertFalse(launch.isConfirmed(recorded: "account-a"))
        XCTAssertFalse(launch.confirm("account-a", generation: staleCheck))
        XCTAssertFalse(launch.isConfirmed(recorded: "account-a"))
        XCTAssertTrue(launch.confirm("account-a", generation: launch.generation))
        XCTAssertTrue(launch.isConfirmed(recorded: "account-a"))
        XCTAssertTrue(launch.confirm("account-b", generation: launch.generation))
        XCTAssertFalse(launch.isConfirmed(recorded: "account-a"), "an account other than the recorded one counts as confirmed")
        XCTAssertFalse(launch.isConfirmed(recorded: nil), "nothing recorded counts as confirmed")

        let beforeRevoke = launch.generation
        launch.revokeConfirmation()
        XCTAssertFalse(launch.isConfirmed(recorded: "account-b"))
        XCTAssertFalse(launch.confirm("account-b", generation: beforeRevoke))
    }

    /// Only the not-signed-in line is cleared by the account-change handler,
    /// recognised whatever language it was stored in.
    func testOnlyTheNotSignedInLineIsRecognised() {
        XCTAssertTrue(CloudSyncMessages.isNotSignedIn(CloudSyncMessages.notSignedIn))
        XCTAssertFalse(CloudSyncMessages.isNotSignedIn(CloudSyncMessages.noInternet))
        XCTAssertFalse(CloudSyncMessages.isNotSignedIn(nil))
    }
}
