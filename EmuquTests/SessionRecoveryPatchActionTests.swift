@testable import Emuqu
import Foundation
import XCTest

/// Tests for `SessionRecoveryService.patchAction` — the decision that says what
/// a recovery import is actually doing to an existing session.
///
/// Choosing wrong here either destroys good data (replacing a complete series
/// with a partial one) or silently does nothing when a repair was asked for.
@MainActor
final class SessionRecoveryPatchActionTests: XCTestCase {
    private let sessionId = UUID()
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func points(count: Int, startMs: Int64 = 0, rrMs: Int = 1_000) -> [RRPoint] {
        (0 ..< count).map { i in
            RRPoint(
                t_ms: startMs + Int64(i * rrMs),
                rr_ms: rrMs,
                wallClockMs: nil,
                hr: 60
            )
        }
    }

    private func series(_ pts: [RRPoint]) -> RRSeries {
        RRSeries(points: pts, sessionId: sessionId, startDate: start)
    }

    // MARK: - Nothing there yet

    func testNoExistingSeriesAddsMissingData() throws {
        let action = try SessionRecoveryService.patchAction(
            existingRR: nil,
            incomingPoints: points(count: 100),
            hasAnalysisResult: false,
            hasArtifactFlags: false
        )
        guard case .addMissingData = action else {
            return XCTFail("expected .addMissingData, got \(action)")
        }
    }

    func testEmptyExistingSeriesAddsMissingData() throws {
        // A series that exists but holds no beats is the same situation as none
        // at all — this is what a crashed recording leaves behind.
        let action = try SessionRecoveryService.patchAction(
            existingRR: series([]),
            incomingPoints: points(count: 100),
            hasAnalysisResult: false,
            hasArtifactFlags: false
        )
        guard case .addMissingData = action else {
            return XCTFail("expected .addMissingData, got \(action)")
        }
    }

    // MARK: - Different data

    func testDifferentBeatCountReplacesWithNewData() throws {
        let action = try SessionRecoveryService.patchAction(
            existingRR: series(points(count: 100)),
            incomingPoints: points(count: 250),
            hasAnalysisResult: true,
            hasArtifactFlags: true
        )
        guard case let .replaceWithNewData(existingCount, newCount) = action else {
            return XCTFail("expected .replaceWithNewData, got \(action)")
        }
        XCTAssertEqual(existingCount, 100)
        XCTAssertEqual(newCount, 250)
    }

    func testSameCountButShiftedTimestampsReplacesWithNewData() throws {
        // Same number of beats from a different stretch of the night is
        // different data, not a duplicate import.
        let action = try SessionRecoveryService.patchAction(
            existingRR: series(points(count: 100)),
            incomingPoints: points(count: 100, startMs: 3_600_000),
            hasAnalysisResult: true,
            hasArtifactFlags: true
        )
        guard case .replaceWithNewData = action else {
            return XCTFail("expected .replaceWithNewData, got \(action)")
        }
    }

    // MARK: - Same data

    func testSameDataMissingAnalysisTriggersReanalysis() throws {
        let action = try SessionRecoveryService.patchAction(
            existingRR: series(points(count: 100)),
            incomingPoints: points(count: 100),
            hasAnalysisResult: false,
            hasArtifactFlags: true
        )
        guard case .reanalyzeNoResult = action else {
            return XCTFail("expected .reanalyzeNoResult, got \(action)")
        }
    }

    func testSameDataMissingFlagsTriggersReanalysis() throws {
        let action = try SessionRecoveryService.patchAction(
            existingRR: series(points(count: 100)),
            incomingPoints: points(count: 100),
            hasAnalysisResult: true,
            hasArtifactFlags: false
        )
        guard case .reanalyzeNoFlags = action else {
            return XCTFail("expected .reanalyzeNoFlags, got \(action)")
        }
    }

    func testMissingResultTakesPriorityOverMissingFlags() throws {
        // Both absent: the analysis result is checked first, and reanalysis
        // produces the flags anyway.
        let action = try SessionRecoveryService.patchAction(
            existingRR: series(points(count: 100)),
            incomingPoints: points(count: 100),
            hasAnalysisResult: false,
            hasArtifactFlags: false
        )
        guard case .reanalyzeNoResult = action else {
            return XCTFail("expected .reanalyzeNoResult, got \(action)")
        }
    }

    func testSameDataWithNothingMissingIsRejected() throws {
        // The genuine no-op. The caller is told rather than left thinking a
        // repair happened.
        XCTAssertThrowsError(
            try SessionRecoveryService.patchAction(
                existingRR: series(points(count: 100)),
                incomingPoints: points(count: 100),
                hasAnalysisResult: true,
                hasArtifactFlags: true
            )
        ) { error in
            XCTAssertEqual(
                error as? RRCollector.CollectorError,
                .dataAlreadyExists,
                "re-importing identical data with nothing missing must report it"
            )
        }
    }

    // MARK: - The one-second tolerance

    func testTimestampsWithinOneSecondCountAsTheSameData() throws {
        // Device and streaming clocks disagree slightly; under a second apart
        // is the same recording, not a new one.
        let action = try SessionRecoveryService.patchAction(
            existingRR: series(points(count: 100)),
            incomingPoints: points(count: 100, startMs: 900),
            hasAnalysisResult: false,
            hasArtifactFlags: true
        )
        guard case .reanalyzeNoResult = action else {
            return XCTFail("expected same-data handling, got \(action)")
        }
    }

    func testTimestampsBeyondOneSecondCountAsDifferentData() throws {
        let action = try SessionRecoveryService.patchAction(
            existingRR: series(points(count: 100)),
            incomingPoints: points(count: 100, startMs: 1_100),
            hasAnalysisResult: false,
            hasArtifactFlags: true
        )
        guard case .replaceWithNewData = action else {
            return XCTFail("expected .replaceWithNewData, got \(action)")
        }
    }
}
