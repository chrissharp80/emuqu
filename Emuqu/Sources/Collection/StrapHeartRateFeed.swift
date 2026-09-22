import Foundation
#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

/// One heart-rate sample from the strap's HR service.
struct StrapHRSample: Equatable, Sendable {
    let hr: Int
    let rrsMs: [Int]
    let rrAvailable: Bool
}

/// One optical interval from a Verity Sense PPI stream.
struct StrapPPIReading: Equatable, Sendable {
    let ppInMs: Int
    let ppErrorEstimate: Int
    let blockerBit: Int
    let hr: Int
}

/// The strap's heart-rate subscription: one per link, opened as soon as the
/// link exists and kept open for the life of the link.
///
/// ## Why one long-lived subscription
///
/// It used to be two: a "live HR monitor" opened at connect, and a second
/// stream opened when a session started — which cancelled the monitor first.
/// SDK 8.x shares one upstream per device between subscribers and tears it down
/// when the last subscriber leaves; cancelling one subscriber and opening
/// another in the same breath can race that teardown and end the new stream.
/// A single subscription has nothing to race. Sessions do not subscribe: they
/// start buffering the beats this feed already delivers.
///
/// ## Where the beats come from
///
/// Heart rate is read from the strap's standard Heart Rate Service through
/// `StandardHeartRateLink`, not from the SDK: the SDK delivers heart rate only
/// once its whole setup of the strap is done, which on a slow link was the
/// better part of a minute. The subscription is opened as soon as the SDK
/// reports the link, on the peripheral the SDK named; if it ends, the feed
/// re-opens it on a short schedule and on every link change.
///
/// A Verity Sense switches to its PPI stream for a session (PPI carries the
/// intervals), and back to HR afterwards.
@MainActor
struct StrapHeartRateFeed {
    let manager: PolarManager

    enum Kind: Equatable, Sendable {
        case heartRate
        case ppi
    }

    /// The task holds the manager strongly. A `[weak manager]` capture here
    /// is diagnosed by the optimizer as "weak reference will always be nil"
    /// once `restart()` is inlined into a `PolarManager` method, which fails
    /// every Release build under warnings-as-errors while Debug builds pass.
    /// The strong reference costs nothing: the manager lives as long as the
    /// app, and the loop ends as soon as its link generation is superseded or
    /// the task is cancelled, which releases it.
    func start(generation: Int) {
        let manager = manager
        manager.linkRuntime.feedTask?.cancel()
        manager.linkRuntime.feedTask = Task {
            await Self.run(generation: generation, manager: manager)
        }
    }

    /// Re-open the subscription on the current link.
    func restart() {
        guard manager.readiness.isLinked else { return }
        start(generation: manager.readiness.generation)
    }

    func stop() {
        manager.linkRuntime.feedTask?.cancel()
        manager.linkRuntime.feedTask = nil
    }

    static func desiredKind(deviceType: PolarDeviceType?, sessionActive: Bool) -> Kind {
        deviceType == .veritySense && sessionActive ? .ppi : .heartRate
    }

    private static func isCurrent(_ manager: PolarManager, generation: Int) -> Bool {
        manager.readiness.isLinked && manager.readiness.generation == generation
    }

    private static func run(generation: Int, manager: PolarManager?) async {
        var failures = 0
        var lastFailure = ""
        let openedAt = Date()
        while !Task.isCancelled, let manager, isCurrent(manager, generation: generation) {
            let kind = await resolveKind(manager: manager, generation: generation)
            guard !Task.isCancelled, isCurrent(manager, generation: generation) else { return }
            let pass = await openAndDrain(kind: kind, manager: manager)
            guard !Task.isCancelled else { return }
            failures = pass.samples > 0 ? 0 : failures + 1
            let failure = pass.error.map { "\($0)" } ?? "stream ended"
            if failure != lastFailure || failures % 10 == 0 {
                logPass(kind, pass, failure: failure, attempt: failures, since: openedAt)
                lastFailure = failure
            }
            _ = await manager.linkRuntime.signal.wait(timeout: StrapFeedHealth.resubscribeDelay(afterFailures: failures))
        }
    }

    /// A changed outcome, and every tenth identical one, so a strap that keeps
    /// refusing shows up as a count and a duration rather than going silent.
    private static func logPass(_ kind: Kind, _ pass: Pass, failure: String, attempt: Int, since openedAt: Date) {
        let elapsed = Int(Date().timeIntervalSince(openedAt))
        debugLog("[PolarManager] \(kind) subscription ended after \(pass.samples) sample(s): \(failure) — attempt \(attempt), \(elapsed) s since the link came up; re-opening")
    }

    /// PPI needs the measurement service; a strap that does not offer it is
    /// served from HR.
    private static func resolveKind(manager: PolarManager, generation: Int) async -> Kind {
        let kind = desiredKind(deviceType: manager.connectedDeviceType, sessionActive: manager.isStreaming)
        guard kind == .ppi else { return .heartRate }
        let outcome = await manager.link.awaitFeature(
            .onlineStreaming, until: nil, while: { isCurrent(manager, generation: generation) }
        )
        return outcome == .unavailable ? .heartRate : .ppi
    }

    /// What one opened subscription delivered before it ended.
    struct Pass {
        var samples = 0
        var error: Error?
    }

    private static func openAndDrain(kind: Kind, manager: PolarManager) async -> Pass {
        #if canImport(PolarBleSdk)
            guard let api = manager.strapAPI, let deviceId = manager.connectedDeviceId else { return Pass() }
            switch kind {
            case .heartRate:
                let peripheralId = manager.linkRuntime.linkedPeripheralId
                return await drain(api.startHrStreaming(deviceId, peripheralId: peripheralId)) { manager.ingestHeartRate($0) }
            case .ppi:
                return await drain(api.startPpiStreaming(deviceId)) { manager.ingestPpi(ppiReadings($0)) }
            }
        #else
            return Pass()
        #endif
    }

    #if canImport(PolarBleSdk)
        private static func ppiReadings(_ data: PolarPpiData) -> [StrapPPIReading] {
            data.samples.map {
                StrapPPIReading(
                    ppInMs: Int($0.ppInMs), ppErrorEstimate: Int($0.ppErrorEstimate),
                    blockerBit: $0.blockerBit, hr: Int($0.hr)
                )
            }
        }
    #endif

    /// Deliver every element of `stream` to `handle` in order until the stream
    /// ends, fails, or the task is cancelled, and report how it went.
    ///
    /// Takes the sequence rather than the SDK so ordering, cancellation and
    /// failure handling are testable with a synthetic stream; what only a strap
    /// proves is that the SDK's radio code emits samples.
    static func drain<Stream: AsyncSequence>(
        _ stream: Stream,
        _ handle: (Stream.Element) -> Void
    ) async -> Pass {
        var pass = Pass()
        do {
            try await forward(stream, counting: &pass.samples, handle)
        } catch {
            pass.error = error
        }
        return pass
    }

    private static func forward<Stream: AsyncSequence>(
        _ stream: Stream,
        counting count: inout Int,
        _ handle: (Stream.Element) -> Void
    ) async throws {
        for try await element in stream {
            guard !Task.isCancelled else { return }
            count += 1
            handle(element)
        }
    }
}
