@testable import Emuqu
import XCTest

/// "Recovery" in a workout prescription is the rest between reps, and its
/// number is a distance, time, heart rate or power, never the recovery score.
/// Rewriting it would put a fabricated number into a training plan the user
/// reads and hears.
final class RecoveryClaimPatternTests: XCTestCase {
    private let score10 = 9.1

    func testARepRecoveryIsNotAScoreClaim() {
        let prescriptions = [
            "6 x 400 m with a recovery of 200 m jog.",
            "Take a recovery of 2 km easy before the tempo.",
            "Keep the recovery at 130 bpm.",
            "Recovery of 90 s between reps.",
            "Recovery 60 seconds, then go again.",
            "Hold recovery at 150 W on the bike.",
            "A recovery of 400 meters walking.",
            "Recovery is 3 laps of the track."
        ]
        for text in prescriptions {
            XCTAssertTrue(MetricsVerifier.recoveryScoreClaims(in: text, score10: score10).isEmpty, "Rewrote a prescription: \(text)")
        }
    }

    func testAWrongScoreIsStillCorrected() {
        XCTAssertEqual(MetricsVerifier.recoveryScoreClaims(in: "Your recovery score is 55 today.", score10: score10).first?.actual, "91")
        XCTAssertEqual(MetricsVerifier.recoveryScoreClaims(in: "Recovery 5 out of 10.", score10: score10).first?.actual, "9.1")
    }

    func testARightScoreIsLeftAlone() {
        XCTAssertTrue(MetricsVerifier.recoveryScoreClaims(in: "Your recovery is 91.", score10: score10).isEmpty)
        XCTAssertTrue(MetricsVerifier.recoveryScoreClaims(in: "Recovery 9.1 of 10.", score10: score10).isEmpty)
    }

    /// A list of past nights states each night's own score. Correcting them
    /// to today's would write a flat, false week into the reply.
    func testPastNightsNamedByDateOrWeekdayAreNotToday() {
        let answers = [
            "Nov 24: recovery 55\nNov 25: recovery 61\nNov 26: recovery 91",
            "On 24 November your recovery was 55.",
            "11/24 recovery 55, 11/25 recovery 61.",
            "Monday: recovery 55. Tuesday: recovery 61.",
            "This week your recovery was 55 on two nights.",
            "Over the past 7 days recovery sat at 60."
        ]
        for text in answers {
            XCTAssertTrue(MetricsVerifier.recoveryScoreClaims(in: text, score10: score10).isEmpty, "Rewrote a past value: \(text)")
        }
    }

    /// A decimal score is still a claim about today, not a date.
    func testADecimalScoreIsStillChecked() {
        XCTAssertEqual(MetricsVerifier.recoveryScoreClaims(in: "Recovery 5.5 out of 10.", score10: score10).first?.actual, "9.1")
    }
}
