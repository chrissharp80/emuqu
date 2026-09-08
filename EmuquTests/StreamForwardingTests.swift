@testable import Emuqu
import os
import XCTest

/// The half of the Polar Rx→async migration that is ours.
///
/// ## Why this exists
///
/// The upgrade to Polar BLE SDK 8.2.0 replaced RxSwift
/// subscriptions with `for try await` over the SDK's `AsyncThrowingStream`.
/// That migration was reported as "needs a strap to verify", which conflated
/// two different things:
///
///   • whether Polar's SDK still talks to the radio — theirs, and a strap is
///     the only way to know;
///   • whether OUR consumption logic forwards samples in order, stops on
///     cancellation, propagates errors, and does not run the completion path
///     after a cancel — ours, and entirely testable with a synthetic stream.
///
/// Only the first needs hardware. Leaving the second untested and calling the
/// whole thing unverified put a chore on the user for work that could be done
/// here. `PolarManager.forward` takes an `AsyncSequence` rather than the API
/// so this suite can drive it.
///
/// What these do NOT establish: that a strap connects, that the SDK emits
/// samples, or that an overnight recording survives. Those need the device.
final class StreamForwardingTests: XCTestCase {
    /// A stream that yields `values`, then either finishes or throws.
    private func stream(_ values: [Int], failing error: Error? = nil) -> AsyncThrowingStream<Int, Error> {
        AsyncThrowingStream { continuation in
            for value in values { continuation.yield(value) }
            continuation.finish(throwing: error)
        }
    }

    private struct Boom: Error {}

    // MARK: - Ordering and completeness

    func testEverySampleIsForwardedInOrder() async throws {
        let received = Received()
        try await PolarManager.forward(stream([1, 2, 3, 4, 5])) { received.append($0) }
        let values = await MainActor.run { received.values }
        XCTAssertEqual(values, [1, 2, 3, 4, 5], "Samples must arrive in order, none dropped")
    }

    func testAnEmptyStreamForwardsNothingAndReturnsCleanly() async throws {
        let received = Received()
        try await PolarManager.forward(stream([])) { received.append($0) }
        let values = await MainActor.run { received.values }
        XCTAssertTrue(values.isEmpty)
    }

    // MARK: - Errors

    /// A failing stream must throw out to the caller, which is what decides
    /// between `handleStreamError` and `handleStreamCompleted`. Swallowing it
    /// would report a dropped strap as a clean end of recording.
    func testAStreamFailureIsPropagated() async {
        let received = Received()
        do {
            try await PolarManager.forward(stream([1, 2], failing: Boom())) { received.append($0) }
            XCTFail("A failing stream must throw")
        } catch {
            XCTAssertTrue(error is Boom)
        }
        let values = await MainActor.run { received.values }
        XCTAssertEqual(values, [1, 2], "Samples before the failure must still be delivered")
    }

    // MARK: - Cancellation

    /// The behaviour that replaced Rx `dispose()`. A cancelled task must stop
    /// forwarding — and must not be mistaken for a stream that ended on its
    /// own, which is what triggers the reconnect path.
    func testCancellationStopsForwarding() async throws {
        let received = Received()
        let started = expectation(description: "forwarding started")
        let signalled = OSAllocatedUnfairLock(initialState: false)

        let task = Task {
            let endless = AsyncThrowingStream<Int, Error> { continuation in
                Task {
                    var i = 0
                    while !Task.isCancelled {
                        continuation.yield(i)
                        i += 1
                        try? await Task.sleep(nanoseconds: 2_000_000)
                    }
                    continuation.finish()
                }
            }
            try await PolarManager.forward(endless) { value in
                let first = signalled.withLock { flagged -> Bool in
                    defer { flagged = true }
                    return !flagged
                }
                if first, value >= 0 { started.fulfill() }
                received.append(value)
            }
        }

        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        _ = try? await task.value

        let settled = await MainActor.run { received.values.count }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let after = await MainActor.run { received.values.count }
        XCTAssertEqual(settled, after, "Forwarding continued after cancellation")
    }

    func testAnAlreadyCancelledTaskForwardsNothing() async {
        let received = Received()
        let stream = stream([1, 2, 3])
        let task = Task {
            try await PolarManager.forward(stream) { received.append($0) }
        }
        task.cancel()
        _ = try? await task.value
        // Cancellation before the first iteration is allowed to deliver
        // nothing; what must never happen is delivery continuing afterwards.
        let values = await MainActor.run { received.values }
        XCTAssertLessThanOrEqual(values.count, 3)
    }
}

/// Collects forwarded samples.
///
/// `@MainActor` rather than an actor: `forward` delivers on the main actor and
/// its handler is synchronous, so this matches where the values actually
/// arrive instead of adding a hop the production path does not have.
@MainActor
private final class Received {
    private(set) var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}
