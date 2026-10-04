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

    /// The regression itself: Morning Results and its VoiceOver label render
    /// through `RecoveryScoreCalculator.displayScore`, while the Dashboard ring,
    /// History, the citation sheet and the morning notification render through
    /// `ScoreVerdict.safeDisplayScore`. Both must give the same integer for every
    /// raw score, including stored 0–10 scores scaled by 10 and non-finite input.
    func testAllSurfacesAgreeForTheSameScore() {
        let edges: [Double] = [-.infinity, -0.4, -0.6, 100.4, 100.6, .infinity, .nan]
        for raw in Array(stride(from: -5.0, through: 105.0, by: 0.1)) + edges {
            XCTAssertEqual(
                RecoveryScoreCalculator.displayScore(raw), ScoreVerdict.safeDisplayScore(raw),
                "Morning Results and the Dashboard disagree for \(raw)"
            )
        }
        for score10 in stride(from: 0.0, through: 10.0, by: 0.01) {
            XCTAssertEqual(
                RecoveryScoreCalculator.displayScore(score10 * 10), ScoreVerdict.safeDisplayScore(score10 * 10),
                "the 0–10 stored score renders differently for \(score10)"
            )
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
