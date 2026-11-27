@testable import Emuqu
import XCTest

/// Every keep, replace, retire or discard decision between two copies of one
/// recording is made by what each copy holds (`FullerCopy`), never by which
/// copy exists, is newer, or is archived. One table per decision site.
@MainActor
final class FullerCopyDecisionTests: XCTestCase {
    // MARK: - The rule

    func testACopyCoversAnotherOnlyWhenItHoldsAsManyBeats() {
        let rows: [(kept: Int?, dropped: Int, covers: Bool)] = [
            (24_000, 6_000, true),
            (6_000, 24_000, false),
            (300, 300, true),
            (nil, 0, false),
            (nil, 6_000, false),
            (0, 0, true)
        ]
        for row in rows {
            XCTAssertEqual(FullerCopy.covers(row.kept, row.dropped), row.covers, "\(String(describing: row.kept)) over \(row.dropped)")
        }
    }

    // MARK: - iCloud live backups (SessionRecoveryService.cloudBackupDisposition)

    private struct DispositionRow {
        let name: String
        let cloudBeats: Int
        var removed = false
        var night: Int??
        var local: Int?
        var uploadedHere = false
        let expected: SessionRecoveryService.CloudBackupDisposition
    }

    private static let dispositionRows: [DispositionRow] = [
        // A backup pulled early from another device (6,000 beats) and the
        // same night's later, fuller backup (24,000): the fuller one is
        // saved over the fragment, not kept out by the id being held.
        DispositionRow(name: "fuller pull over a held fragment", cloudBeats: 24_000, local: 6_000, expected: .save),
        // The night was recovered from that fragment: it is archived, but
        // holds 6,000 beats, so the fuller backup is saved and kept in iCloud.
        DispositionRow(name: "archived fragment, fragment held", cloudBeats: 24_000, night: 6_000, local: 6_000, expected: .save),
        DispositionRow(name: "archived fragment, fuller held", cloudBeats: 24_000, night: 6_000, local: 24_000, expected: .keep),
        DispositionRow(name: "archived night covers it", cloudBeats: 24_000, night: 24_000, local: 6_000, expected: .retire),
        DispositionRow(name: "archived night unreadable", cloudBeats: 24_000, night: .some(nil), local: 24_000, expected: .keep),
        DispositionRow(name: "archived night unreadable, nothing held", cloudBeats: 24_000, night: .some(nil), expected: .save),
        DispositionRow(name: "removed night", cloudBeats: 24_000, removed: true, local: 6_000, expected: .retire),
        DispositionRow(name: "own upload, covered", cloudBeats: 6_000, local: 6_000, uploadedHere: true, expected: .retire),
        DispositionRow(name: "own upload, fuller in iCloud", cloudBeats: 24_000, local: 6_000, uploadedHere: true, expected: .save),
        DispositionRow(name: "other device, covered", cloudBeats: 6_000, local: 24_000, expected: .keep),
        DispositionRow(name: "not held", cloudBeats: 300, expected: .save),
        DispositionRow(name: "not held, other device's fragment", cloudBeats: 100, expected: .keep),
        DispositionRow(name: "not held, own fragment", cloudBeats: 100, uploadedHere: true, expected: .retire)
    ]

    func testEachICloudLiveBackupIsKeptRetiredOrSavedByTheBeatsEachCopyHolds() {
        for row in Self.dispositionRows {
            let id = UUID()
            let holdings = SessionRecoveryService.CloudBackupHoldings(
                removed: row.removed ? [id] : [],
                archivedNightBeats: row.night.map { [id: $0] } ?? [:],
                localBeats: row.local.map { [id: $0] } ?? [:],
                uploadedHere: row.uploadedHere ? [id] : []
            )
            let disposition = SessionRecoveryService.cloudBackupDisposition(of: id, beats: row.cloudBeats, holdings: holdings)
            XCTAssertEqual(disposition, row.expected, row.name)
        }
    }

    /// A discarded fragment's iCloud copy goes only when this device uploaded
    /// it; another device's may have grown past the fragment since.
    func testADiscardedFragmentRetiresOnlyAnICloudCopyThisDeviceUploaded() {
        let own = UUID(), pulled = UUID()
        XCTAssertTrue(SessionRecoveryService.retiresCloudCopyOfDiscardedFragment(own, uploadedHere: [own]))
        XCTAssertFalse(SessionRecoveryService.retiresCloudCopyOfDiscardedFragment(pulled, uploadedHere: [own]))
    }

    // MARK: - Raw backup writes (RawRRBackup.backup)

    func testARawBackupIsNeverReplacedByOneWithFewerBeats() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FullerCopyDecisionTests-\(UUID().uuidString)", isDirectory: true)
        defer { removeDirectory(directory) }
        let backup = RawRRBackup(directory: directory)
        let rows = [
            WriteRow(first: 300, second: 100, refused: true, kept: 300),
            WriteRow(first: 100, second: 300, refused: false, kept: 300),
            WriteRow(first: 200, second: 200, refused: false, kept: 200)
        ]
        for row in rows {
            let id = UUID()
            _ = try backup.backup(points: Self.beats(row.first), sessionId: id)
            var refused = false
            do {
                _ = try backup.backup(points: Self.beats(row.second), sessionId: id)
            } catch {
                refused = true
            }
            XCTAssertEqual(refused, row.refused, "\(row.first) then \(row.second)")
            XCTAssertEqual(try backup.retrieve(id)?.points.count, row.kept, "\(row.first) then \(row.second)")
        }
    }

    // MARK: - Session sync (CloudKitSessionFreshness)

    func testAnUploadWaitsForAServerVersionThisDeviceHasNotRead() {
        let rows: [(server: String?, held: String?, unseen: Bool)] = [
            ("v2", "v1", true),
            ("v2", nil, true),
            ("v1", "v1", false),
            (nil, "v1", false),
            (nil, nil, false)
        ]
        for row in rows {
            XCTAssertEqual(
                CloudKitSessionFreshness.isUnseen(serverVersion: row.server, heldVersion: row.held), row.unseen,
                "\(String(describing: row.server)) held \(String(describing: row.held))"
            )
        }
    }

    func testThePullReadsAnOlderCopyThatMayHoldBeatsThisOneLacks() {
        let rows = [
            ReadRow(server: "v2", held: "v1", pending: false, reads: true),
            ReadRow(server: "v2", held: nil, pending: true, reads: true),
            ReadRow(server: "v2", held: nil, pending: false, reads: false),
            ReadRow(server: "v1", held: "v1", pending: true, reads: false),
            ReadRow(server: nil, held: nil, pending: true, reads: false)
        ]
        for row in rows {
            XCTAssertEqual(
                CloudKitSessionFreshness.readsOlderCopy(serverVersion: row.server, heldVersion: row.held, pendingUpload: row.pending),
                row.reads, "\(String(describing: row.server)) held \(String(describing: row.held)) pending \(row.pending)"
            )
        }
    }

    /// The older iCloud copy holds the full night; the copy here is a
    /// fragment with a newer edit. The beats come in, the edit stays.
    func testAnOlderCopyWithMoreBeatsGivesThemToTheNewerEdit() throws {
        let (archive, directory) = makeArchive()
        defer { removeDirectory(directory) }
        let rows = [
            MergeRow(here: 120, there: 200, kept: true, stored: 200),
            MergeRow(here: 200, there: 120, kept: false, stored: 200),
            MergeRow(here: 200, there: 200, kept: false, stored: 200)
        ]
        for row in rows {
            var local = makeSession(beats: row.here)
            local.notes = "edited here"
            _ = try archive.archive(local, skipSameNightMerge: true)
            var remote = local
            remote.rrSeries = RRSeries(points: Self.beats(row.there), sessionId: local.id, startDate: local.startDate)
            remote.notes = "older in iCloud"

            let kept = try CloudKitSessionFreshness.keepBeatsOnlyThere(remote, in: local.id, archive: archive)

            let stored = try XCTUnwrap(try archive.retrieve(local.id))
            XCTAssertEqual(kept, row.kept, "\(row.here) here, \(row.there) there")
            XCTAssertEqual(stored.rrSeries?.points.count, row.stored, "\(row.here) here, \(row.there) there")
            XCTAssertEqual(stored.notes, "edited here", "the newer edit was lost")
        }
    }

    // MARK: - Helpers

    /// A raw backup written twice under one id.
    private struct WriteRow {
        let first: Int
        let second: Int
        let refused: Bool
        let kept: Int
    }

    /// Whether the pull reads an older-stamped iCloud copy.
    private struct ReadRow {
        let server: String?
        let held: String?
        let pending: Bool
        let reads: Bool
    }

    /// Beats here and in an older iCloud copy, and what the archive keeps.
    private struct MergeRow {
        let here: Int
        let there: Int
        let kept: Bool
        let stored: Int
    }

    private static func beats(_ count: Int) -> [RRPoint] {
        (0 ..< count).map { RRPoint(t_ms: Int64($0) * 1000, rr_ms: $0 % 2 == 0 ? 990 : 1010) }
    }

    private func makeSession(beats count: Int) -> HRVSession {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var session = HRVSession(
            id: UUID(), startDate: start, endDate: start.addingTimeInterval(TimeInterval(count)), state: .complete,
            rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        session.rrSeries = RRSeries(points: Self.beats(count), sessionId: session.id, startDate: start)
        return session
    }

    private func removeDirectory(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            // swallow-ok: a test that wrote nothing leaves no directory to remove.
        }
    }

    private func makeArchive() -> (SessionArchive, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FullerCopyDecisionTests-\(UUID().uuidString)", isDirectory: true)
        let archive = SessionArchive(
            directory: directory,
            sleepScheduleProvider: { SleepSchedule(bedtimeHour: 22, bedtimeMinute: 0, sleepHours: 8.0) },
            sessionMergeModeProvider: { .defaultGap },
            mergeGapProvider: { 4.5 * 3600 }
        )
        return (archive, directory)
    }
}
