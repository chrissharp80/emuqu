@testable import Emuqu
import XCTest

/// `ScoreBreakdown.message` for the strong band (composite ≥ 80).
///
/// a real screenshot: HRV 71 (−19 % vs baseline), sleep 95,
/// vitals 96 → composite 81 and the headline "Everything is clicking — HRV,
/// sleep, and vitals are all dialed in. Go hard." directly above an
/// explanation titled "Below your baseline — Pay attention". The go-hard
/// wording now requires the HRV factor itself to be strong.
final class ScoreBreakdownMessageTests: XCTestCase {
    private typealias Factor = RecoveryScoreCalculator.ScoreFactor

    private func breakdown(hrv: Double, sleep: Double, vitals: Double) -> RecoveryScoreCalculator.ScoreBreakdown {
        let factors = [
            Factor(label: "HRV", detail: "", score: hrv, weight: 0.6, impact: hrv >= 60 ? .positive : .negative),
            Factor(label: "Sleep", detail: "", score: sleep, weight: 0.25, impact: .positive),
            Factor(label: "Vitals", detail: "", score: vitals, weight: 0.15, impact: .positive)
        ]
        let composite = hrv * 0.6 + sleep * 0.25 + vitals * 0.15
        return RecoveryScoreCalculator.ScoreBreakdown(compositeScore: composite, tier: 3, factors: factors, penalties: [])
    }

    func testStrongCompositeWithWeakHRVDoesNotSayGoHard() {
        let b = breakdown(hrv: 71, sleep: 95, vitals: 96)
        XCTAssertGreaterThanOrEqual(b.compositeScore, 80)
        XCTAssertFalse(b.message.contains("Go hard"), b.message)
        XCTAssertTrue(b.message.contains("HRV"), "the message should name the factor that is not strong: \(b.message)")
    }

    func testStrongCompositeWithStrongHRVStillSaysGoHard() {
        let b = breakdown(hrv: 88, sleep: 90, vitals: 92)
        XCTAssertTrue(b.message.contains("Go hard"), b.message)
    }

    func testStrongCompositeWithAFactorUnderSixtyNamesIt() {
        let b = breakdown(hrv: 95, sleep: 55, vitals: 95)
        XCTAssertGreaterThanOrEqual(b.compositeScore, 80)
        XCTAssertTrue(b.message.contains("sleep is holding you back"), b.message)
    }
}
