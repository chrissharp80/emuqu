@testable import Emuqu
import XCTest

/// Nothing is shown or stored as done while part of the work it covers is
/// still outstanding: a sync is "Up to date" only once no session waits to
/// go up, the push works through a backlog instead of one capped batch, and
/// a one-shot pass does not set its done flag over an index that did not
/// load or after a night it could not read or write.
@MainActor
final class CompletionClaimTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CompletionClaimTests-\(UUID().uuidString)", isDirectory: true)
    private var archiveDirectory: URL { directory.appendingPathComponent("Archive", isDirectory: true) }
    private lazy var settings = SettingsManager(settingsURL: directory.appendingPathComponent("user_settings.json"))
    private var hostDefaults: HostDefaults?

    /// The archive backfills' done flags (`ArchiveMigrations.MigrationFlag`).
    private static let archiveMigrationFlags = [
        "FlowRecovery.migration.recoveryScores.v1.done",
        "FlowRecovery.migration.endDates.v1.done",
        "FlowRecovery.migration.metrics.v1.done",
        "FlowRecovery.migration.sleepIndexFields.v1.done",
        "FlowRecovery.migration.legacyEliteIndex.v1.done"
    ]

    override func setUp() async throws {
        try await super.setUp()
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        hostDefaults = HostDefaults.setAside(HostDefaults.cloudSyncBookkeeping + Self.archiveMigrationFlags)
    }

    override func tearDown() async throws {
        hostDefaults?.restore()
        _ = settings.flushPendingWritesSynchronously()
        try FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func night(_ day: Int) -> HRVSession {
        let start = Date(timeIntervalSince1970: 1_790_000_000 + Double(day) * 86_400)
        return HRVSession(
            id: UUID(), startDate: start, endDate: start.addingTimeInterval(28_800),
            state: .complete, sessionType: .overnight, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
    }

    private func ids(_ count: Int) -> [UUID] {
        (0 ..< count).map { _ in UUID() }
    }

    /// What a fake push did, shared by the push and outstanding closures.
    private final class PushLog {
        var outstanding: Set<UUID>
        var batches: [[UUID]] = []
        init(_ outstanding: [UUID]) { self.outstanding = Set(outstanding) }
        var tried: Int { batches.reduce(0) { $0 + $1.count } }
    }

    // MARK: - The push drains its backlog

    /// 60 never-uploaded sessions after iCloud is turned on all go up in one
    /// sync, not the first 25 of them.
    func testAPushThatMakesProgressDrainsTheWholeBacklog() async {
        let backlog = ids(60)
        let log = PushLog(backlog)
        await CloudKitSyncManager.drain(
            backlog, batchSize: CloudKitSyncManager.pushBatchLimit,
            push: { batch in
                log.batches.append(batch)
                log.outstanding.subtract(batch)
                return false
            },
            outstanding: { log.outstanding }
        )

        XCTAssertTrue(log.outstanding.isEmpty, "\(log.outstanding.count) of 60 sessions left unsent by a sync that kept succeeding")
        XCTAssertEqual(log.batches.count, 3)
        XCTAssertEqual(log.tried, 60, "every session is tried once")
        XCTAssertEqual(Set(log.batches.flatMap { $0 }), Set(backlog))
    }

    /// A batch that moves nothing (iCloud unreachable) ends the push: a
    /// failing backlog costs one batch per sync.
    func testAPushThatMovesNothingStopsAfterOneBatch() async {
        let backlog = ids(60)
        let log = PushLog(backlog)
        await CloudKitSyncManager.drain(
            backlog, batchSize: 25,
            push: { batch in
                log.batches.append(batch)
                return false
            },
            outstanding: { log.outstanding }
        )
        XCTAssertEqual(log.tried, 25)
    }

    /// A batch that asks the push to stop (the zone gone, sync off, another
    /// account, the watchdog) is the last one.
    func testAPushThatIsToldToStopStops() async {
        let backlog = ids(60)
        let log = PushLog(backlog)
        await CloudKitSyncManager.drain(
            backlog, batchSize: 25,
            push: { batch in
                log.batches.append(batch)
                log.outstanding.subtract(batch)
                return true
            },
            outstanding: { log.outstanding }
        )
        XCTAssertEqual(log.tried, 25)
    }

    // MARK: - How a sync ends

    /// The one rule, across every way a sync that ran all its phases ends.
    func testASyncIsUpToDateOnlyWhenNothingItCoversIsOutstanding() {
        struct Case {
            let error: String?, unsaved: Bool, index: Bool, waiting: Int
            let expected: CloudKitSyncManager.SyncCompletion
        }
        let cases = [
            Case(error: nil, unsaved: false, index: true, waiting: 0, expected: .upToDate),
            Case(error: nil, unsaved: false, index: true, waiting: 35, expected: .incomplete),
            Case(error: nil, unsaved: false, index: true, waiting: 1, expected: .incomplete),
            Case(error: nil, unsaved: false, index: false, waiting: 0, expected: .incomplete),
            Case(error: "pull failed", unsaved: false, index: true, waiting: 0, expected: .failed("pull failed")),
            Case(error: "push failed", unsaved: false, index: true, waiting: 35, expected: .failed("push failed")),
            Case(error: nil, unsaved: true, index: true, waiting: 0, expected: .failed(CloudSyncMessages.progressNotSaved))
        ]
        for c in cases {
            let outcome = CloudKitSyncManager.completion(
                syncError: c.error, bookkeepingUnsaved: c.unsaved, indexComplete: c.index, waitingUploads: c.waiting
            )
            XCTAssertEqual(outcome, c.expected, "error \(c.error ?? "none"), unsaved \(c.unsaved), index \(c.index), waiting \(c.waiting)")
        }
    }

    /// Settings' "Up to date" reads the sessions still to go up: with 35 of
    /// 60 archived nights not in iCloud it is not shown, and once they are
    /// all uploaded it is.
    func testUpToDateIsNotShownWhileArchivedSessionsWaitToUpload() throws {
        try requireEncryptionKey()
        let archive = SessionArchive(directory: archiveDirectory)
        let manager = CloudKitSyncManager.isolated(archive: archive, directory: directory, settings: settings)
        let nights = (0 ..< 60).map(night)
        for session in nights { _ = try archive.archive(session, skipSameNightMerge: true) }
        for session in nights.prefix(25) { manager.state.markUploaded(session.id) }

        XCTAssertEqual(manager.syncState, .idle)
        XCTAssertEqual(manager.uploadsWaitingCount, 35)
        XCTAssertFalse(manager.isUpToDate, "35 recordings are not in iCloud")

        for session in nights.dropFirst(25) { manager.state.markUploaded(session.id) }
        XCTAssertTrue(manager.isUpToDate)
    }

    /// Quarantined and kept-on-device sessions are accounted for elsewhere
    /// and never upload: they do not hold "Up to date" back.
    func testQuarantinedAndLocalOnlySessionsAreNotWaiting() throws {
        try requireEncryptionKey()
        let archive = SessionArchive(directory: archiveDirectory)
        let manager = CloudKitSyncManager.isolated(archive: archive, directory: directory, settings: settings)
        let (quarantined, localOnly) = (night(0), night(1))
        _ = try archive.archive(quarantined, skipSameNightMerge: true)
        _ = try archive.archive(localOnly, skipSameNightMerge: true)
        manager.state.markQuarantined(quarantined.id)
        manager.state.markLocalOnly(localOnly.id)

        XCTAssertEqual(manager.uploadsWaitingCount, 0)
        XCTAssertTrue(manager.isUpToDate)
    }

    // MARK: - An index that did not load is not an empty history

    private func archiveWithUnreadableIndex() throws -> SessionArchive {
        try Data("not an index".utf8).write(to: archiveDirectory.appendingPathComponent("index.json"))
        let archive = SessionArchive(directory: archiveDirectory)
        XCTAssertFalse(archive.hasCompleteIndex)
        return archive
    }

    /// Sync over an index that did not load sees nothing to push; that is
    /// not "Up to date".
    func testSyncIsNotUpToDateOverAnIndexThatDidNotLoad() throws {
        let archive = try archiveWithUnreadableIndex()
        let manager = CloudKitSyncManager.isolated(archive: archive, directory: directory, settings: settings)

        XCTAssertEqual(manager.uploadsWaitingCount, 0)
        XCTAssertFalse(manager.isUpToDate)
    }

    /// The archive backfills read nothing over an index that did not load,
    /// and set none of their done flags.
    func testArchiveMigrationsSetNoFlagOverAnIndexThatDidNotLoad() throws {
        let archive = try archiveWithUnreadableIndex()

        archive.migrations.runDeferredMigrations()

        for flag in Self.archiveMigrationFlags {
            XCTAssertFalse(UserDefaults.standard.bool(forKey: flag), "\(flag) set over an index that did not load")
        }
    }

    // MARK: - One-shot passes

    /// A pass that could not read or write a night is not complete.
    func testAOneShotMigrationIsNotFlaggedWhileANightWasMissed() throws {
        let suite = "CompletionClaimTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(SessionDataMigrations.finishTrainingMigration(key: "pass", complete: false, defaults: defaults))
        XCTAssertFalse(defaults.bool(forKey: "pass"))
        XCTAssertTrue(SessionDataMigrations.finishTrainingMigration(key: "pass", complete: true, defaults: defaults))
        XCTAssertTrue(defaults.bool(forKey: "pass"))
    }

    /// The TRIMP repair covers every session only when none was left
    /// unanswered, unread or unwritten, and the pass was not cut short.
    func testTheTrainingRepairCoversEverySessionOnlyWhenNothingWasMissed() {
        func result(unanswered: Int = 0, errors: Int = 0, stoppedEarly: Bool = false) -> ReanalysisService.TrainingRepairResult {
            var r = ReanalysisService.TrainingRepairResult(totalSessions: 10, candidates: 10, nilContext: 0, repaired: 10, errors: errors)
            r.unanswered = unanswered
            r.stoppedEarly = stoppedEarly
            return r
        }
        XCTAssertTrue(result().coversEverySession)
        XCTAssertFalse(result(unanswered: 1).coversEverySession)
        XCTAssertFalse(result(errors: 1).coversEverySession, "a session that could not be read or written")
        XCTAssertFalse(result(stoppedEarly: true).coversEverySession)
    }
}
