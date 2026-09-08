@testable import Emuqu
import XCTest

/// Tests for how a recovered backup is classified.
///
/// When a session is rebuilt from its raw
/// backup after a crash, this decides whether it is filed as `.overnight` or
/// `.quick`. The source comment states the stake plainly: a short fragment
/// recovered as `.overnight` "displaces a real overnight reading on the same
/// date" — the user loses the night they actually recorded.
@MainActor
final class SessionRecoveryClassificationTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_622_534_400)

    private func backup(beats: Int, durationSec: TimeInterval) -> SessionRecoveryService.BackupData {
        var t: Int64 = 0
        var points: [RRPoint] = []
        for _ in 0 ..< beats {
            points.append(RRPoint(t_ms: t, rr_ms: 1_000))
            t += 1_000
        }
        let id = UUID()
        return SessionRecoveryService.BackupData(
            backup: RawRRBackup.BackupEntry(
                id: id, captureDate: anchor, deviceId: nil, points: points, hash: ""
            ),
            series: RRSeries(points: points, sessionId: id, startDate: anchor),
            flags: [],
            sessionStart: anchor,
            endDate: anchor.addingTimeInterval(durationSec)
        )
    }

    private func classify(beats: Int, durationSec: TimeInterval) -> SessionType {
        SessionRecoveryService.recoveredSessionType(
            for: backup(beats: beats, durationSec: durationSec), sessionId: UUID()
        )
    }

    // MARK: - Both conditions must hold

    func testLongOvernightRecoversAsOvernight() {
        XCTAssertEqual(classify(beats: 20_000, durationSec: 8 * 3_600), .overnight)
    }

    func testTooFewBeatsRecoversAsQuick() {
        // Eight hours of wall-clock but almost no beats: the strap was off.
        // Filing this as overnight would bury the real reading for that night.
        XCTAssertEqual(classify(beats: 500, durationSec: 8 * 3_600), .quick)
    }

    func testTooShortRecoversAsQuick() {
        // Plenty of beats but only ten minutes — a quick reading, not a night.
        XCTAssertEqual(classify(beats: 20_000, durationSec: 600), .quick)
    }

    func testNeitherConditionRecoversAsQuick() {
        XCTAssertEqual(classify(beats: 100, durationSec: 120), .quick)
    }

    // MARK: - Boundaries

    func testExactlyAtBothThresholdsIsOvernight() {
        // 4,000 beats and one hour are the documented minimums, and the guard
        // uses `>=`, so exactly at them qualifies.
        XCTAssertEqual(classify(beats: 4_000, durationSec: 3_600), .overnight)
    }

    func testOneBeatShortIsQuick() {
        XCTAssertEqual(classify(beats: 3_999, durationSec: 3_600), .quick)
    }

    func testOneSecondShortIsQuick() {
        XCTAssertEqual(classify(beats: 4_000, durationSec: 3_599), .quick)
    }

    // MARK: - Degenerate input

    func testEmptyBackupIsQuick() {
        XCTAssertEqual(classify(beats: 0, durationSec: 0), .quick)
    }

    // MARK: - The log formatter no longer traps

    func testSecondsFormatterRejectsNonFiniteValues() {
        // The duration comes from dates in a backup file. Forcing
        // `Int(Double)` on a corrupt one traps.
        XCTAssertEqual(SessionRecoveryService.describeSeconds(.nan), "unknown")
        XCTAssertEqual(SessionRecoveryService.describeSeconds(.infinity), "unknown")
        XCTAssertEqual(SessionRecoveryService.describeSeconds(-.infinity), "unknown")
    }

    func testSecondsFormatterHandlesOrdinaryValues() {
        XCTAssertEqual(SessionRecoveryService.describeSeconds(3_600), "3600")
        XCTAssertEqual(SessionRecoveryService.describeSeconds(0), "0")
    }
}
