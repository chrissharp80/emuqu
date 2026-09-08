@testable import Emuqu
import XCTest

/// Tests for the RR-data storage classification.
///
/// This is what the diagnostics screen tells a
/// user about whether their raw beat data still exists. Getting it wrong in the
/// reassuring direction — reporting data present when it is gone — is the worst
/// possible failure for a screen whose entire job is to answer "did I lose my
/// recordings?".
final class SessionStorageDiagnosticTests: XCTestCase {
    private typealias Status = SessionStorageDiagnostic.RRStatus

    // MARK: - Classification

    func testBothSourcesPresent() {
        XCTAssertEqual(
            SessionStorageDiagnostic.status(archiveBeats: 5_000, backupBeats: 5_000),
            .bothPresent
        )
    }

    func testArchiveOnly() {
        XCTAssertEqual(
            SessionStorageDiagnostic.status(archiveBeats: 5_000, backupBeats: 0),
            .archivedFull
        )
    }

    func testBackupOnly() {
        // The archive lost the series but the raw backup still has it — this
        // is the recoverable case, and mislabelling it as `.neither` would tell
        // a user their data is gone when it can still be restored.
        XCTAssertEqual(
            SessionStorageDiagnostic.status(archiveBeats: 0, backupBeats: 5_000),
            .backupOnly
        )
    }

    func testNeitherSourceHasBeats() {
        XCTAssertEqual(SessionStorageDiagnostic.status(archiveBeats: 0, backupBeats: 0), .neither)
    }

    // MARK: - A single beat still counts as present

    func testOneBeatIsNotNothing() {
        // The test is `> 0`, not a threshold. A one-beat file is degenerate
        // but it is not absent, and claiming otherwise would be a false
        // "your data is gone".
        XCTAssertEqual(SessionStorageDiagnostic.status(archiveBeats: 1, backupBeats: 0), .archivedFull)
        XCTAssertEqual(SessionStorageDiagnostic.status(archiveBeats: 0, backupBeats: 1), .backupOnly)
    }

    // MARK: - Tallying

    private func report(_ status: Status) -> SessionStorageDiagnostic.SessionReport {
        SessionStorageDiagnostic.SessionReport(
            sessionId: UUID(),
            date: Date(timeIntervalSince1970: 1_622_534_400),
            sessionType: .overnight,
            recoveryScore: 70,
            archiveFileSize: 1_024,
            archiveBeatCount: status == .archivedFull || status == .bothPresent ? 100 : 0,
            backupBeatCount: status == .backupOnly || status == .bothPresent ? 100 : 0,
            status: status,
            analysisSummary: nil
        )
    }

    func testCountsTallyEachStatus() {
        let reports = [
            report(.bothPresent), report(.bothPresent),
            report(.archivedFull),
            report(.neither)
        ]
        let counts = SessionStorageDiagnostic.statusCounts(in: reports)
        XCTAssertEqual(counts[.bothPresent], 2)
        XCTAssertEqual(counts[.archivedFull], 1)
        XCTAssertEqual(counts[.neither], 1)
        XCTAssertNil(counts[.backupOnly], "a status with no sessions must not appear as zero")
    }

    func testEmptyInputTalliesNothing() {
        XCTAssertTrue(SessionStorageDiagnostic.statusCounts(in: []).isEmpty)
    }

    func testTotalOfCountsMatchesInput() {
        let reports = (0 ..< 7).map { report($0.isMultiple(of: 2) ? .bothPresent : .backupOnly) }
        let counts = SessionStorageDiagnostic.statusCounts(in: reports)
        XCTAssertEqual(counts.values.reduce(0, +), reports.count, "no session may be lost in the tally")
    }
}
