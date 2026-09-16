import Foundation

/// The strap capabilities the app depends on, named independently of the SDK.
///
/// Polar reports readiness per `PolarBleSdkFeature`. The app only acts on four
/// of them, and naming them here keeps the readiness rules below free of the
/// SDK so they can be exercised without a strap.
enum StrapFeature: Sendable, CaseIterable {
    /// The standard BLE Heart Rate service: HR plus RR intervals (H10), HR (Verity).
    case heartRate
    /// H10 exercise recording to the strap's own memory.
    case h10Recording
    /// Verity Sense offline recording to the sensor's own memory.
    case offlineRecording
    /// Polar measurement streaming (PMD) — PPI on the Verity Sense.
    case onlineStreaming
}

/// What the current connection knows about one feature.
enum StrapFeatureState: Equatable, Sendable {
    /// Not reported yet on this connection.
    case pending
    /// The SDK reported it ready, or an operation that needs it succeeded.
    case ready
    /// The SDK reported the strap does not offer it.
    case unavailable
}

/// What an operation waiting on a feature learns.
enum StrapFeatureWait: Equatable, Sendable {
    /// The SDK reported the feature ready on this connection.
    case ready
    /// The SDK finished its readiness check without reporting the feature.
    ///
    /// Polar documents that such a feature "can still become ready later and
    /// will be reported via `bleSdkFeatureReady`", but 8.x stops checking at a
    /// ten-second deadline and never reports it. Every SDK call that needs a
    /// feature checks readiness itself before touching the radio and throws
    /// `notificationNotEnabled` locally when it is not, so the caller may try
    /// the operation and let that guard decide.
    case unconfirmed
    /// The strap does not offer the feature.
    case unavailable
    /// No answer before the caller's deadline.
    case timedOut
}

/// Feature readiness for the strap connection that is current right now.
///
/// Each connection is a new `generation`: everything learned about the
/// previous link is discarded the moment it drops, because a flag left set is
/// a later call believing it can record on a strap that is not there.
struct StrapReadiness: Equatable, Sendable {
    /// Increments on every established link. Zero before the first one.
    private(set) var generation = 0
    private(set) var isLinked = false
    /// True once the SDK has delivered its readiness summary for this link, or
    /// the link has been up long enough that it never will.
    private(set) var isSettled = false
    private(set) var states: [StrapFeature: StrapFeatureState] = [:]

    static let initial = StrapReadiness()

    func state(of feature: StrapFeature) -> StrapFeatureState {
        guard isLinked else { return .pending }
        return states[feature] ?? .pending
    }

    func isReady(_ feature: StrapFeature) -> Bool { state(of: feature) == .ready }

    /// The answer for a waiter right now, or nil while it should keep waiting.
    func waitOutcome(for feature: StrapFeature) -> StrapFeatureWait? {
        guard isLinked else { return nil }
        switch state(of: feature) {
        case .ready: return .ready
        case .unavailable: return .unavailable
        case .pending: return isSettled ? .unconfirmed : nil
        }
    }

    mutating func linkEstablished() {
        generation += 1
        isLinked = true
        isSettled = false
        states = Dictionary(uniqueKeysWithValues: StrapFeature.allCases.map { ($0, .pending) })
    }

    mutating func linkLost() {
        isLinked = false
        isSettled = false
        states = [:]
    }

    /// A per-feature `bleSdkFeatureReady` report.
    mutating func markReady(_ feature: StrapFeature) {
        guard isLinked else { return }
        states[feature] = .ready
    }

    /// The SDK's `bleSdkFeaturesReadiness` summary. Features in neither list
    /// stay pending: the summary means the SDK stopped checking, not that they
    /// are absent.
    mutating func applySummary(ready: Set<StrapFeature>, unavailable: Set<StrapFeature>) {
        guard isLinked else { return }
        for feature in ready { states[feature] = .ready }
        for feature in unavailable where states[feature] != .ready { states[feature] = .unavailable }
        isSettled = true
    }

    /// The link has been up past the SDK's readiness window with no summary.
    mutating func settleWithoutSummary() {
        guard isLinked else { return }
        isSettled = true
    }

    /// An operation that required the feature succeeded, which is proof the
    /// feature is usable whatever the SDK reported.
    mutating func confirm(_ feature: StrapFeature) {
        guard isLinked else { return }
        states[feature] = .ready
    }
}
