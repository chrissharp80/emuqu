@testable import Emuqu
import XCTest

/// A spoken pace target follows the user's units, as the workout screen does.
@MainActor
final class IntervalSpokenCueTests: XCTestCase {
    func testMetricPaceIsSpokenPerKilometre() {
        let line = IntervalSpokenCue.spokenPace(secondsPerKm: 300, units: .metric)
        XCTAssertTrue(line.contains("5:00"), line)
    }

    /// 5:00 per kilometre is 8:03 per mile (300 × 1.609344 = 482.8 s).
    func testImperialPaceIsSpokenPerMile() {
        let line = IntervalSpokenCue.spokenPace(secondsPerKm: 300, units: .imperial)
        XCTAssertTrue(line.contains("8:03"), line)
        XCTAssertFalse(line.contains("5:00"), line)
    }
}
