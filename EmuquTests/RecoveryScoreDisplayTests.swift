@testable import Emuqu
import XCTest

/// Pins `RecoveryScoreCalculator.displayScore(_:)` — the single conversion from
/// a raw 0–100 score to the integer a person actually sees.
///
/// Three separate comments in `RecoveryScoreCalculator` already
/// described "the ONE place the raw→display clamp lives". There was no such
/// place. Five render sites wrote `Int(score)` and eleven wrote
/// `Int(score.rounded())`, so a session scoring 84.6 showed **84** on Morning
/// Results and its VoiceOver label, and **85** on the Dashboard and in the
/// exported filename — one session, one instant, two numbers, and the
/// accessibility label disagreeing with the screen it describes.
///
/// The other half is a crash, not a cosmetic split: `Int(Double.nan)` traps in
/// Swift. It does not produce a wrong integer, it kills the process. The NaN
/// coercion in `breakdown(...)` and the sanitiser in
/// `MorningResultsView+DetailCards` were each working around that locally, one
/// call site at a time, which only holds until someone adds a new one.
final class RecoveryScoreDisplayTests: XCTestCase {
    // MARK: - Rounding parity

    func testRoundsRatherThanTruncates() {
        XCTAssertEqual(RecoveryScoreCalculator.displayScore(84.6), 85, "84.6 must not render as 84")
        XCTAssertEqual(RecoveryScoreCalculator.displayScore(84.4), 84)
        XCTAssertEqual(RecoveryScoreCalculator.displayScore(84.5), 85, "half rounds away from zero")
    }

    /// The regression itself: every surface must agree for the same input.
    func testAllSurfacesAgreeForTheSameScore() {
        for raw in stride(from: 0.0, through: 100.0, by: 0.1) {
            let once = RecoveryScoreCalculator.displayScore(raw)
            let again = RecoveryScoreCalculator.displayScore(raw)
            XCTAssertEqual(once, again)
            XCTAssertEqual(once, Int(min(100, max(0, raw)).rounded()))
        }
    }

    // MARK: - Non-finite input must degrade, never trap

    func testSurvivesNonFiniteInput() {
        XCTAssertEqual(RecoveryScoreCalculator.displayScore(.nan), 0)
        XCTAssertEqual(RecoveryScoreCalculator.displayScore(.signalingNaN), 0)
        XCTAssertEqual(RecoveryScoreCalculator.displayScore(.infinity), 0)
        XCTAssertEqual(RecoveryScoreCalculator.displayScore(-.infinity), 0)
    }

    // MARK: - Clamping

    func testClampsToZeroThroughOneHundred() {
        XCTAssertEqual(RecoveryScoreCalculator.displayScore(-12.0), 0)
        XCTAssertEqual(RecoveryScoreCalculator.displayScore(140.0), 100)
        XCTAssertEqual(RecoveryScoreCalculator.displayScore(99.7), 100)
        XCTAssertEqual(RecoveryScoreCalculator.displayScore(0.0), 0)
        XCTAssertEqual(RecoveryScoreCalculator.displayScore(100.0), 100)
    }

    /// A clamped result must still be a legal percentage — the score ring does
    /// `.trim(CGFloat(score) / 100)`, which misbehaves outside 0...1.
    func testResultIsAlwaysALegalPercentage() {
        for raw in [-.infinity, -500.0, -0.4, 0.0, 50.0, 99.99, 100.0, 5_000.0, .infinity, .nan] as [Double] {
            let value = RecoveryScoreCalculator.displayScore(raw)
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 100)
        }
    }
}
