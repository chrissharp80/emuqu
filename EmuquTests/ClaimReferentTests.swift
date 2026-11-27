@testable import Emuqu
import XCTest

/// A number is checked only against the entity the sentence is about. A nap,
/// a quick or live reading and a workout each have their own RMSSD, a value
/// the user reported is theirs, and "heart rate recovery" is not the recovery
/// score: rewriting any of them to last night's overnight value would put a
/// false number in the reply and queue a "you fabricated" reminder for a true
/// one.
final class ClaimReferentTests: XCTestCase {
    private let rmssd = 48.0
    private let score10 = 9.1

    func testAnotherReadingsRMSSDIsLeftAlone() {
        let otherReadings = [
            "Your nap RMSSD is 31 ms.",
            "In your nap, RMSSD 31 ms.",
            "Your quick reading this afternoon: RMSSD 30 ms.",
            "Live RMSSD is 25 ms.",
            "RMSSD right now 25 ms.",
            "During your workout, RMSSD 12 ms.",
            "In the breathing session your RMSSD reads 70 ms.",
            "You said your RMSSD is 38 ms.",
            "Your Garmin shows RMSSD 60 ms.",
            "On the 24th, RMSSD 30 ms."
        ]
        for text in otherReadings {
            XCTAssertTrue(MetricsVerifier.rmssdClaims(in: text, rmssd: rmssd).isEmpty, "Rewrote another reading: \(text)")
        }
    }

    func testTheOvernightRMSSDIsStillChecked() {
        let overnightClaims = ["Your RMSSD is 30 ms today.", "Last night: RMSSD 30 ms.", "RMSSD 30 ms during the night."]
        for text in overnightClaims {
            XCTAssertEqual(MetricsVerifier.rmssdClaims(in: text, rmssd: rmssd).first?.actual, "48 ms", "Missed: \(text)")
        }
    }

    func testOtherRecoveriesAreNotTheScore() {
        let notTheScore = [
            "Your heart rate recovery is 30.",
            "HR recovery of 25 after the last rep.",
            "Your nap recovery score is 55.",
            "You told me your recovery is 60.",
            "Your Whoop says recovery 40."
        ]
        for text in notTheScore {
            XCTAssertTrue(MetricsVerifier.recoveryScoreClaims(in: text, score10: score10).isEmpty, "Rewrote a non-score: \(text)")
        }
        XCTAssertEqual(MetricsVerifier.recoveryScoreClaims(in: "Your recovery score is 55.", score10: score10).first?.actual, "91")
    }

    func testAUserReportedLoadIsLeftAlone() {
        let reported = ["Going with what you told me, TSB -8.", "You said your TSB is -8.", "You mentioned CTL 60."]
        for text in reported {
            XCTAssertTrue(
                MetricsVerifier.trainingLoadClaims(in: text, tsb: -20, atl: 40, ctl: 42, acwr: nil).isEmpty,
                "Rewrote a value the user stated: \(text)"
            )
        }
        XCTAssertEqual(MetricsVerifier.trainingLoadClaims(in: "TSB is -8.", tsb: -20, atl: 40, ctl: 42, acwr: nil).map(\.metric), ["TSB"])
    }

    func testANapsSleepIsNotLastNight() {
        let naps = ["You slept 1 hour and 10 minutes in your nap.", "During your nap you slept 2 hours."]
        for text in naps {
            XCTAssertTrue(MetricsVerifier.sleepDiscrepancies(in: text, nightMinutes: 415, efficiency: nil).isEmpty, "Rewrote a nap: \(text)")
        }
        let night = "During the night you slept 5 hours and 10 minutes."
        XCTAssertEqual(MetricsVerifier.sleepDiscrepancies(in: night, nightMinutes: 415, efficiency: nil).first?.actual, "6 hours and 55 minutes")
    }
}
