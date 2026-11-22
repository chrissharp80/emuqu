@testable import Emuqu
import XCTest

/// The Get Me Back arrow turns to each new heading the short way round: the
/// angle it is drawn at is unwrapped (`GetMeBackView.continuousAngle`), so a
/// heading crossing ±180° moves it a few degrees, not most of a circle.
@MainActor
final class GetMeBackArrowTests: XCTestCase {
    func testCrossingSouthTurnsTheShortWay() {
        XCTAssertEqual(GetMeBackView.continuousAngle(from: 179, to: -179), 181, accuracy: 1e-9)
        XCTAssertEqual(GetMeBackView.continuousAngle(from: -179, to: 179), -181, accuracy: 1e-9)
    }

    func testASmallTurnIsUnchanged() {
        XCTAssertEqual(GetMeBackView.continuousAngle(from: 10, to: 30), 30, accuracy: 1e-9)
        XCTAssertEqual(GetMeBackView.continuousAngle(from: 30, to: 10), 10, accuracy: 1e-9)
    }

    func testAnUnwrappedAngleKeepsTurningFromWhereItIs() {
        // After several turns the drawn angle can be far outside ±180; the
        // next heading is still reached by the shortest turn from there.
        XCTAssertEqual(GetMeBackView.continuousAngle(from: 721, to: -1), 719, accuracy: 1e-9)
    }

    func testNeverTurnsMoreThanHalfACircle() {
        for current in stride(from: -720.0, through: 720.0, by: 37.5) {
            for target in stride(from: -180.0, through: 180.0, by: 22.5) {
                let next = GetMeBackView.continuousAngle(from: current, to: target)
                XCTAssertLessThanOrEqual(abs(next - current), 180, "\(current) → \(target)")
            }
        }
    }
}
