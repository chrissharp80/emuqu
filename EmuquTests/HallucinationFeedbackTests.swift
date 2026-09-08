@testable import Emuqu
import XCTest

// MARK: - HallucinationFeedbackTests
//
// Covers the cross-turn corrections buffer added to
// MetricsVerifier in response to a real-user log showing the AI
// fabricating HR (72 vs actual 91, then 71 vs actual 88) on
// consecutive turns. The TTS-side guard substituted the right
// number, but the model kept fabricating because nothing fed the
// correction back.
//
// `recordCorrections` accumulates discrepancies; `consumePending-
// CorrectionsBlock` drains them as a single short reminder for
// the next turn's system prompt. After consume, the buffer is
// empty so subsequent turns aren't perpetually scolded.

final class HallucinationFeedbackTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Ensure a clean buffer between tests — `consume` clears
        // it, so calling once is sufficient even on first run.
        _ = MetricsVerifier.consumePendingCorrectionsBlock()
    }

    /// No corrections recorded → nil block (no system prompt clutter
    /// when the model behaved).
    func testEmptyBufferReturnsNil() {
        XCTAssertNil(MetricsVerifier.consumePendingCorrectionsBlock(),
            "no recorded corrections should produce no block")
    }

    /// Recording one discrepancy and consuming should yield a block
    /// containing the rule, the metric, both numbers, and clear the
    /// buffer.
    func testRecordOneCorrectionThenConsumeClearsBuffer() {
        let d = MetricsVerifier.Discrepancy(
            metric: "HR",
            claimed: "72",
            actual: "91",
            absoluteDelta: 19,
            range: wholeRange("72")
        )
        MetricsVerifier.recordCorrections([d])

        let block = MetricsVerifier.consumePendingCorrectionsBlock()
        XCTAssertNotNil(block)
        XCTAssertTrue(block?.contains("DO NOT FABRICATE") ?? false,
            "block should lead with the don't-fabricate rule")
        XCTAssertTrue(block?.contains("HR=72") ?? false,
            "block should include claimed value")
        XCTAssertTrue(block?.contains("actual was 91") ?? false,
            "block should include actual value")

        // Second consume after one record + one consume = empty.
        XCTAssertNil(MetricsVerifier.consumePendingCorrectionsBlock(),
            "consume should clear the buffer; second call returns nil")
    }

    /// Recording several discrepancies in one batch produces one
    /// block with all of them.
    func testRecordMultipleInOneBatch() {
        let hrD = MetricsVerifier.Discrepancy(
            metric: "HR", claimed: "72", actual: "91",
            absoluteDelta: 19, range: wholeRange("x")
        )
        let paceD = MetricsVerifier.Discrepancy(
            metric: "pace", claimed: "8:30", actual: "9:15",
            absoluteDelta: 45, range: wholeRange("x")
        )
        MetricsVerifier.recordCorrections([hrD, paceD])

        let block = MetricsVerifier.consumePendingCorrectionsBlock()
        XCTAssertNotNil(block)
        XCTAssertTrue(block?.contains("HR=72") ?? false)
        XCTAssertTrue(block?.contains("pace=8:30") ?? false)
        XCTAssertTrue(block?.contains("actual was 91") ?? false)
        XCTAssertTrue(block?.contains("actual was 9:15") ?? false)
    }

    /// Buffer caps at 4 entries — a model fabricating 6 numbers in
    /// one turn doesn't grow the reminder unboundedly. Most-recent
    /// entries win (suffix(4)).
    func testBufferCapsAtFour() {
        for i in 0..<6 {
            let d = MetricsVerifier.Discrepancy(
                metric: "metric\(i)",
                claimed: "claimed\(i)",
                actual: "actual\(i)",
                absoluteDelta: Double(i),
                range: wholeRange("x")
            )
            MetricsVerifier.recordCorrections([d])
        }
        let block = MetricsVerifier.consumePendingCorrectionsBlock()
        XCTAssertNotNil(block)
        // The 4 most-recent entries (indices 2, 3, 4, 5) should be
        // present; 0 and 1 dropped.
        XCTAssertFalse(block?.contains("metric0") ?? true,
            "earliest entries should be dropped when cap is exceeded")
        XCTAssertFalse(block?.contains("metric1") ?? true)
        XCTAssertTrue(block?.contains("metric2") ?? false)
        XCTAssertTrue(block?.contains("metric5") ?? false)
    }

    /// Recording across multiple turns accumulates until consumed.
    /// (Until the system prompt actually consumes the buffer, every
    /// subsequent guard fire adds more entries.)
    func testRecordingAcrossCallsAccumulates() {
        let d1 = MetricsVerifier.Discrepancy(
            metric: "HR", claimed: "70", actual: "85",
            absoluteDelta: 15, range: wholeRange("x")
        )
        MetricsVerifier.recordCorrections([d1])

        let d2 = MetricsVerifier.Discrepancy(
            metric: "pace", claimed: "8:00", actual: "9:30",
            absoluteDelta: 90, range: wholeRange("x")
        )
        MetricsVerifier.recordCorrections([d2])

        let block = MetricsVerifier.consumePendingCorrectionsBlock()
        XCTAssertTrue(block?.contains("HR=70") ?? false,
            "first batch survives until consumed")
        XCTAssertTrue(block?.contains("pace=8:00") ?? false,
            "second batch accumulates with first")
    }
}

/// Full range of a string literal.
///
/// These call sites read `"x".range(of: "x")!` — a string searched for itself,
/// which cannot fail. But a force-unwrap in a test target traps, and a trap
/// takes the whole test process down rather than failing one case, so the
/// provably-safe version is still the wrong shape here.
private func wholeRange(_ s: String) -> Range<String.Index> {
    s.startIndex ..< s.endIndex
}
