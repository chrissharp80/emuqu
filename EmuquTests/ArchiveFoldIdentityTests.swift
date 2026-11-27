@testable import Emuqu
import XCTest

/// An id held from before the archive kept its session under another id: a
/// recording folded into a night already archived, an import merged into
/// one, a duplicate the launch cleanup retired. The archive answers for the
/// old id with the session that holds it now (`SessionArchive.archivedId(of:)`),
/// on this launch and the next, and announces a fold under both ids.
final class ArchiveFoldIdentityTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ArchiveFoldIdentityTests-\(UUID().uuidString)", isDirectory: true)

    override func tearDown() {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            // swallow-ok: a test that archived nothing leaves no directory to remove.
        }
        super.tearDown()
    }

    private var lastNight: Date { Calendar.current.startOfDay(for: Date()).addingTimeInterval(-3600) }

    private func recording(from start: Date, hours: Double, rr: Int = 1000) -> HRVSession {
        let id = UUID()
        let points = (0 ..< 200).map { RRPoint(t_ms: Int64($0) * 1000, rr_ms: $0 % 2 == 0 ? rr - 10 : rr + 10) }
        return HRVSession(
            id: id, startDate: start, endDate: start.addingTimeInterval(hours * 3600), state: .complete,
            sessionType: .overnight, rrSeries: RRSeries(points: points, sessionId: id, startDate: start),
            analysisResult: nil, artifactFlags: nil
        )
    }

    /// A night archived on its own, and a second recording of it that the
    /// archive folds into it.
    private func foldedPair(in archive: SessionArchive) throws -> (night: HRVSession, second: HRVSession) {
        let night = recording(from: lastNight, hours: 7)
        _ = try archive.archive(night, skipSameNightMerge: true)
        let second = recording(from: lastNight.addingTimeInterval(3600), hours: 5, rr: 980)
        XCTAssertEqual(try archive.archive(second).sessionId, night.id, "the fixture expects the second recording folded")
        return (night, second)
    }

    /// The fold outlives the launch that made it: the recording's backup and
    /// recording marker do too, and still name it.
    func testAFoldIsKeptAcrossLaunches() throws {
        let (night, second) = try foldedPair(in: SessionArchive(directory: directory))

        let relaunched = SessionArchive(directory: directory)

        XCTAssertEqual(relaunched.archivedId(of: second.id), night.id)
        XCTAssertTrue(relaunched.holdsNight(second.id), "the night the recording went into reads as not saved")
        XCTAssertEqual(relaunched.foldedRecordingIds, [second.id])
        XCTAssertEqual(relaunched.idsKept(under: night.id), [second.id])
        XCTAssertEqual(relaunched.archivedId(of: night.id), night.id)
        XCTAssertFalse(relaunched.holdsNight(UUID()))
    }

    /// An import merged into an archived night by a batch is kept under
    /// that night, as a single save's fold is.
    func testABatchImportMergedIntoANightIsKeptUnderIt() throws {
        let archive = SessionArchive(directory: directory)
        let night = recording(from: lastNight, hours: 7)
        _ = try archive.archive(night, skipSameNightMerge: true)
        let imported = recording(from: lastNight.addingTimeInterval(3600), hours: 5, rr: 980)

        try archive.store.archiveBatch([imported])

        XCTAssertFalse(archive.store.exists(imported.id), "the fixture expects the import merged")
        XCTAssertEqual(archive.archivedId(of: imported.id), night.id)
    }

    /// The fold changed the night the recording went into, so the change is
    /// announced under that night's id, and under the recording's, which the
    /// archive does not hold.
    func testAFoldAnnouncesTheNightItChanged() throws {
        let archive = SessionArchive(directory: directory)
        let night = recording(from: lastNight, hours: 7)
        _ = try archive.archive(night, skipSameNightMerge: true)
        let second = recording(from: lastNight.addingTimeInterval(3600), hours: 5, rr: 980)
        let seen = AnnouncedIds()
        let token = NotificationCenter.default.addObserver(forName: .flowRecoveryArchiveChanged, object: nil, queue: nil) { note in
            if let id = note.object as? UUID { seen.add(id) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        XCTAssertEqual(try archive.archive(second).sessionId, night.id, "the fixture expects the second recording folded")

        XCTAssertTrue(seen.ids.contains(night.id), "the night whose beats changed was not announced")
        XCTAssertTrue(seen.ids.contains(second.id))
    }

    /// Archiving a recording that folds returns the night it went into, the
    /// copy acceptance and recovery hand to Apple Health and iCloud.
    func testArchivingARecordingThatFoldsReturnsTheNightItWentInto() throws {
        let archive = SessionArchive(directory: directory)
        let night = recording(from: lastNight, hours: 7)
        _ = try archive.archive(night, skipSameNightMerge: true)
        let second = recording(from: lastNight.addingTimeInterval(3600), hours: 5, rr: 980)

        let held = try archive.archiveReturningNight(second)

        XCTAssertEqual(held.id, night.id, "the recording, under an id the archive does not hold, went on to Health and iCloud")
        let alone = recording(from: lastNight.addingTimeInterval(-3 * 86400), hours: 7)
        XCTAssertEqual(try archive.archiveReturningNight(alone).id, alone.id)
    }

    /// Vitals filled in on the detail screen of a folded recording land on
    /// the night it went into, not on an id the archive does not hold.
    func testVitalsFilledOnAFoldedRecordingLandOnTheNightItWentInto() throws {
        let archive = SessionArchive(directory: directory)
        let (night, second) = try foldedPair(in: archive)
        let fresh = RecoveryVitals(
            respiratoryRate: 14, respiratoryRateBaseline: 14, oxygenSaturation: 97, oxygenSaturationMin: 95,
            wristTemperature: nil, wristTemperatureBaseline: nil, restingHeartRate: 52
        )

        RecoveryVitalsBackfill.store(fresh, id: second.id, archive: archive)

        XCTAssertEqual(try archive.retrieve(night.id)?.vitalsSnapshot?.restingHeartRate, 52)
    }

    /// A duplicate the cleanup retires is kept under its keeper: an edit made
    /// on a screen that still holds the retired copy lands on the keeper.
    func testDuplicateCleanupKeepsTheRetiredCopyUnderItsKeeper() throws {
        let archive = SessionArchive(directory: directory, sessionMergeModeProvider: { .defaultGap })
        let start = Calendar.current.startOfDay(for: Date().addingTimeInterval(-30 * 86400)).addingTimeInterval(-3600)
        var keeper = HRVSession(
            id: UUID(), startDate: start, endDate: start.addingTimeInterval(8 * 3600), state: .complete,
            sessionType: .overnight, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        keeper.recoveryScore = 7.2
        let copy = HRVSession(
            id: UUID(), startDate: start.addingTimeInterval(3600), endDate: start.addingTimeInterval(7 * 3600), state: .complete,
            sessionType: .overnight, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        _ = try archive.archive(keeper, skipSameNightMerge: true)
        _ = try archive.archive(copy, skipSameNightMerge: true)

        archive.migrations.removeDuplicates()

        XCTAssertTrue(archive.store.deletedIds.contains(copy.id), "the fixture expects the copy retired")
        XCTAssertEqual(archive.archivedId(of: copy.id), keeper.id)
        try archive.updateTags(archive.archivedId(of: copy.id), tags: [ReadingTag.alcohol], notes: "kept")
        XCTAssertEqual(try archive.retrieve(keeper.id)?.notes, "kept")
    }

    /// A cycle in a damaged list ends instead of looping.
    func testAFoldCycleEnds() {
        let archive = SessionArchive(directory: directory)
        let (first, second) = (UUID(), UUID())
        archive.archiveLock.withLock {
            archive.state.recordFold(of: first, into: second)
            archive.state.recordFold(of: second, into: first)
        }

        XCTAssertTrue([first, second].contains(archive.archivedId(of: first)))
    }
}

/// The ids a notification observer saw, from whatever thread posted.
private final class AnnouncedIds: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [UUID] = []

    var ids: [UUID] { lock.withLock { seen } }

    func add(_ id: UUID) { lock.withLock { seen.append(id) } }
}
