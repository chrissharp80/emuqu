import Foundation

/// A Polar SDK callback, reduced to what the app acts on.
///
/// The SDK raises its observer callbacks on its own queue. Each one used to
/// spawn its own `Task { @MainActor }`, and nothing guarantees those tasks run
/// in the order they were created — so a disconnect could be applied after the
/// reconnect that followed it, clearing the new link's readiness. Events are
/// instead yielded in order into one stream and applied one at a time.
enum StrapEvent: Sendable {
    case connecting(deviceId: String)
    case connected(deviceId: String, name: String)
    case disconnected(deviceId: String, loss: StrapLinkLoss)
    case featureReady(deviceId: String, feature: StrapFeature)
    case readinessSummary(deviceId: String, ready: Set<StrapFeature>, unavailable: Set<StrapFeature>)
    case powerOn
    case powerOff
    case battery(deviceId: String, level: UInt)
    case deviceInformation(deviceId: String, uuid: String, value: String)
    case deviceInformationKey(deviceId: String, key: String, value: String)
}

/// Why a link dropped, and whether anything should try to get it back.
enum StrapLinkLoss: Equatable, Sendable {
    /// Range, radio or power. The SDK reconnects on its own.
    case connectionLost
    /// The pairing is unusable. Only the user can repair it.
    case pairingLost(reason: String)
    /// A device command the app sent (restart, power off) ended the link on purpose.
    case deviceCommand

    var needsUserRepair: Bool {
        if case .pairingLost = self { return true }
        return false
    }
}

/// Ordered delivery of `StrapEvent`s from any thread to the main actor.
final class StrapEventPump: Sendable {
    let events: AsyncStream<StrapEvent>
    private let continuation: AsyncStream<StrapEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream(of: StrapEvent.self, bufferingPolicy: .unbounded)
    }

    /// Callable from the SDK's queue. Yield order is delivery order.
    func send(_ event: StrapEvent) { continuation.yield(event) }

    func finish() { continuation.finish() }
}

/// What the link coordinator remembers between events. Owned by
/// `PolarManager`, not observed: none of it is for display.
@MainActor
final class StrapLinkRuntime {
    let pump = StrapEventPump()
    let signal = StrapSignal()

    var deliveryTask: Task<Void, Never>?
    /// The long-lived heart-rate subscription for the current link.
    var feedTask: Task<Void, Never>?
    /// Watches the feed and applies `StrapFeedHealth` decisions.
    var healthTask: Task<Void, Never>?
    /// Settles readiness if the SDK never delivers its summary.
    var settleTask: Task<Void, Never>?
    /// Reads the strap's recording status once its recording feature is usable.
    var statusCheckTask: Task<Void, Never>?
    /// Ends a session's wait for a strap that is not coming back.
    var reconnectDeadlineTask: Task<Void, Never>?

    var linkedAt: Date?
    var settledAt: Date?
    var lastSampleAt: Date?
    var lastResubscribeAt: Date?
    var lastLinkResetAt: Date?

    /// The user asked to disconnect; the drop that follows is not a loss.
    var userDisconnectRequested = false
    /// The health policy reset the link; reconnect as soon as it drops.
    var linkResetInProgress = false
    /// The strap this app is trying to get back after an unexpected drop.
    var reconnectTargetId: String?

    isolated deinit {
        [deliveryTask, feedTask, healthTask, settleTask, statusCheckTask, reconnectDeadlineTask]
            .forEach { $0?.cancel() }
        pump.finish()
    }

    /// Stop everything that belongs to one link.
    func cancelLinkTasks() {
        [feedTask, healthTask, settleTask, statusCheckTask].forEach { $0?.cancel() }
        feedTask = nil
        healthTask = nil
        settleTask = nil
        statusCheckTask = nil
        linkedAt = nil
        settledAt = nil
        lastSampleAt = nil
        lastResubscribeAt = nil
    }
}
