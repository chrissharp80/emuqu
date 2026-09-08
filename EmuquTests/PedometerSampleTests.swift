@testable import Emuqu
import XCTest

/// `PedometerSample` is the value that carries a CoreMotion reading from the
/// pedometer's own callback thread to the main actor. Two jobs, both tested
/// here: it must not let unvalidated OS numbers reach code that converts them
/// with `Int(...)`, and it must be a value type so `CMPedometerData` never
/// crosses threads.
final class PedometerSampleTests: XCTestCase {
    private func sample(
        distance: Double? = 100,
        steps: Int = 500,
        cadence: Double? = 1.5
    ) -> PedometerSample {
        PedometerSample(distanceMeters: distance, steps: steps, cadenceStepsPerSecond: cadence)
    }

    // MARK: - Distance validation

    func testFiniteNonNegativeDistanceIsPublished() {
        XCTAssertEqual(sample(distance: 1234.5).publishableDistanceMeters, 1234.5)
        XCTAssertEqual(sample(distance: 0).publishableDistanceMeters, 0)
    }

    /// The published distance is divided and then `Int(...)`-converted for
    /// split index, mile markers and MET pace. `Int(Double.nan)` traps, and so
    /// does anything past `Int.max` — so neither may ever be published.
    func testNonFiniteDistanceIsRejectedRatherThanPublished() {
        XCTAssertNil(sample(distance: .nan).publishableDistanceMeters)
        XCTAssertNil(sample(distance: .infinity).publishableDistanceMeters)
        XCTAssertNil(sample(distance: -.infinity).publishableDistanceMeters)
    }

    func testNegativeDistanceIsRejected() {
        XCTAssertNil(sample(distance: -0.5).publishableDistanceMeters)
    }

    func testMissingDistanceIsRejected() {
        XCTAssertNil(sample(distance: nil).publishableDistanceMeters)
    }

    /// Rejected, not clamped: a bad reading means no new distance this tick,
    /// not a fabricated one. A clamp would silently publish 0 and reset the
    /// user's distance mid-workout.
    func testRejectionIsNotClampedToZero() {
        XCTAssertNotEqual(sample(distance: .nan).publishableDistanceMeters, 0)
        XCTAssertNotEqual(sample(distance: -5).publishableDistanceMeters, 0)
    }

    // MARK: - Cadence conversion

    /// CMPedometer reports steps/second; every display in the app is steps/min.
    func testCadenceIsConvertedFromPerSecondToPerMinute() {
        XCTAssertEqual(sample(cadence: 1.5).publishableCadenceStepsPerMin, 90)
        XCTAssertEqual(sample(cadence: 0).publishableCadenceStepsPerMin, 0)
    }

    func testInvalidCadenceIsRejected() {
        XCTAssertNil(sample(cadence: .nan).publishableCadenceStepsPerMin)
        XCTAssertNil(sample(cadence: .infinity).publishableCadenceStepsPerMin)
        XCTAssertNil(sample(cadence: -1).publishableCadenceStepsPerMin)
        XCTAssertNil(sample(cadence: nil).publishableCadenceStepsPerMin)
    }

    // MARK: - Steps

    /// Steps are an `NSNumber`-backed integer count with no conversion to
    /// trap on, so they pass through exactly as reported.
    func testStepsPassThroughUnchanged() {
        XCTAssertEqual(sample(steps: 0).steps, 0)
        XCTAssertEqual(sample(steps: 12345).steps, 12345)
    }

    // MARK: - Sendability

    /// The whole point of the type. `CMPedometerData` is a reference type
    /// CoreMotion owns on its callback thread; if this stops being a sendable
    /// value the code goes back to capturing that object in a `Task`.
    func testSampleIsSendable() {
        func requireSendable(_ value: some Sendable) -> Bool { _ = value; return true }
        XCTAssertTrue(requireSendable(sample()))
    }
}
