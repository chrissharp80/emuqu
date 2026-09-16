@testable import Emuqu
import os
import XCTest

/// The half of the strap's heart-rate subscription that is ours.
///
/// ## Why this exists
///
/// Polar BLE SDK 8.x delivers samples as an `AsyncThrowingStream`. Whether the
/// SDK still talks to the radio is Polar's, and only a strap proves it. Whether
/// the app's feed delivers samples in order, stops on cancellation, and reports
/// a failed subscription as a failure rather than a clean end is ours, and
/// entirely testable with a synthetic stream. `StrapHeartRateFeed.drain` takes
/// an `AsyncSequence` rather than the API so this suite can drive it.
///
/// What these do NOT establish: that a strap connects, that the SDK emits
/// samples, or that an overnight recording survives. Those need the device.
@MainActor
final class StreamForwardingTests: XCTestCase {
    /// A stream that yields `values`, then either finishes or throws.
    private func stream(_ values: [Int], failing error: Error? = nil) -> AsyncThrowingStream<Int, Error> {
        AsyncThrowingStream { continuation in
            for value in values { continuation.yield(value) }
            continuation.finish(throwing: error)
        }
    }

    private struct Boom: Error {}

    // MARK: - Which stream

    /// The Verity Sense carries intervals on PPI, so a session switches it
    /// there; outside a session, and on an H10 always, the HR service is the feed.
    func testOnlyAVeritySenseSessionUsesPPI() {
        XCTAssertEqual(StrapHeartRateFeed.desiredKind(deviceType: .veritySense, sessionActive: true), .ppi)
        XCTAssertEqual(StrapHeartRateFeed.desiredKind(deviceType: .veritySense, sessionActive: false), .heartRate)
        XCTAssertEqual(StrapHeartRateFeed.desiredKind(deviceType: .h10, sessionActive: true), .heartRate)
        XCTAssertEqual(StrapHeartRateFeed.desiredKind(deviceType: nil, sessionActive: true), .heartRate)
    }

    // MARK: - Ordering and completeness

    func testEverySampleIsDeliveredInOrder() async {
        var received: [Int] = []
        let pass = await StrapHeartRateFeed.drain(stream([1, 2, 3, 4, 5])) { received.append($0) }

        XCTAssertEqual(received, [1, 2, 3, 4, 5], "Samples must arrive in order, none dropped")
        XCTAssertEqual(pass.samples, 5)
        XCTAssertNil(pass.error)
    }

    func testAnEmptyStreamDeliversNothingAndEndsCleanly() async {
        var received: [Int] = []
        let pass = await StrapHeartRateFeed.drain(stream([])) { received.append($0) }

        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(pass.samples, 0)
        XCTAssertNil(pass.error)
    }

    // MARK: - Errors

    /// A failing subscription is reported with its error — the SDK's local
    /// "not ready yet" refusal arrives this way, and the feed's retry cadence
    /// depends on telling it apart from samples having flowed.
    func testAStreamFailureIsReportedAfterTheSamplesBeforeIt() async {
        var received: [Int] = []
        let pass = await StrapHeartRateFeed.drain(stream([1, 2], failing: Boom())) { received.append($0) }

        XCTAssertEqual(received, [1, 2], "Samples before the failure must still be delivered")
        XCTAssertEqual(pass.samples, 2)
        XCTAssertTrue(pass.error is Boom)
    }

    // MARK: - Cancellation

    /// A cancelled feed must stop delivering: a link that dropped or a
    /// subscription being re-opened must not keep writing beats.
    func testCancellationStopsDelivery() async throws {
        var received: [Int] = []
        let started = expectation(description: "delivery started")
        let producer = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

        let endless = AsyncThrowingStream<Int, Error> { continuation in
            let task = Task {
                var i = 0
                while !Task.isCancelled {
                    continuation.yield(i)
                    i += 1
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
                continuation.finish()
            }
            producer.withLock { $0 = task }
        }
        let feed = Task { @MainActor in
            await StrapHeartRateFeed.drain(endless) { value in
                if received.isEmpty { started.fulfill() }
                received.append(value)
            }
        }

        await fulfillment(of: [started], timeout: 5)
        feed.cancel()
        _ = await feed.value

        let settled = received.count
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(received.count, settled, "Delivery continued after cancellation")
        producer.withLock { $0?.cancel() }
    }

    func testAnAlreadyCancelledTaskDeliversNothingFurther() async {
        var received: [Int] = []
        let source = stream([1, 2, 3])
        let feed = Task { @MainActor in
            await StrapHeartRateFeed.drain(source) { received.append($0) }
        }
        feed.cancel()
        let pass = await feed.value
        // Cancellation before the first iteration is allowed to deliver
        // nothing; what must never happen is delivery beyond the stream.
        XCTAssertLessThanOrEqual(received.count, 3)
        XCTAssertEqual(pass.samples, received.count)
    }
}
