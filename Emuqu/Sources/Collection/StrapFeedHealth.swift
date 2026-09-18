import Foundation

/// Whether the strap's heart-rate feed is delivering, and what to do when it
/// is not.
///
/// Pure: the manager snapshots the clock and the feed's timestamps, this
/// decides. The escalation is deliberately gentle. Re-subscribing over the
/// same link costs almost nothing — it turns the Heart Rate Measurement
/// notifications off and on over a connection already held
/// (`StandardHeartRateLink`). Resetting the link does cost something: it drops
/// the connection, and every reconnect makes the SDK enumerate the strap's
/// services again, which on an H10 under load has taken tens of seconds. So a
/// reset is only for a recording session, only after a re-subscribe has had
/// its chance, and never twice in quick succession.
enum StrapFeedHealth {
    /// The feed as the UI should describe it.
    enum Status: Equatable, Sendable {
        /// No strap link.
        case waitingForStrap
        /// Linked, no beat yet, and still inside the setup allowance.
        case settingUp
        /// Beats are arriving.
        case live
        /// Linked, and the strap has gone quiet past the allowance.
        case stalled
    }

    enum Action: Equatable, Sendable {
        case none
        /// Cancel and re-open the subscription over the existing link.
        case resubscribe
        /// Disconnect and reconnect, so the strap sets its services up again.
        case resetLink
    }

    struct Decision: Equatable, Sendable {
        var status: Status
        var action: Action
    }

    struct Inputs: Sendable {
        var now: Date
        var isLinked: Bool
        var linkedAt: Date?
        /// When the SDK's readiness summary arrived (or the link settled without one).
        var settledAt: Date?
        var lastSampleAt: Date?
        var lastResubscribeAt: Date?
        /// Survives reconnects: the cooldown is about the strap, not one link.
        var lastLinkResetAt: Date?
        /// A workout, overnight or quick session is buffering beats.
        var sessionActive: Bool
    }

    /// An H10 notifies roughly once a second; fifteen seconds of silence on a
    /// feed that was delivering is a stall, not a slow beat.
    static let liveSilenceSec: TimeInterval = 15
    /// How long a new link may go without a first beat before it is called
    /// stalled. The first beat comes from the standard Heart Rate Service and
    /// does not wait on the SDK's setup, so it normally arrives within seconds;
    /// the allowance stays wide because calling a stall re-subscribes, and in a
    /// session escalates to a link reset that costs the SDK's whole setup again.
    /// Counted from the SDK's readiness summary when there is one ...
    static let setupGraceAfterSettleSec: TimeInterval = 45
    /// ... and from the link itself when there is not; the summary has been
    /// observed 43 s after the link on a loaded phone.
    static let setupGraceUnsettledSec: TimeInterval = 90
    /// How long a re-subscribe gets before a session escalates to a link reset.
    static let resubscribeGraceSec: TimeInterval = 30
    static let linkResetCooldownSec: TimeInterval = 180

    static func decide(_ inputs: Inputs) -> Decision {
        guard inputs.isLinked, let linkedAt = inputs.linkedAt else {
            return Decision(status: .waitingForStrap, action: .none)
        }
        if let last = inputs.lastSampleAt, inputs.now.timeIntervalSince(last) <= liveSilenceSec {
            return Decision(status: .live, action: .none)
        }
        let stalledSince = stallStart(inputs, linkedAt: linkedAt)
        guard inputs.now >= stalledSince else {
            return Decision(status: inputs.lastSampleAt == nil ? .settingUp : .live, action: .none)
        }
        return Decision(status: .stalled, action: stalledAction(inputs, stalledSince: stalledSince))
    }

    /// The moment the current silence stopped being ordinary.
    private static func stallStart(_ inputs: Inputs, linkedAt: Date) -> Date {
        if let last = inputs.lastSampleAt { return last.addingTimeInterval(liveSilenceSec) }
        if let settled = inputs.settledAt { return settled.addingTimeInterval(setupGraceAfterSettleSec) }
        return linkedAt.addingTimeInterval(setupGraceUnsettledSec)
    }

    private static func stalledAction(_ inputs: Inputs, stalledSince: Date) -> Action {
        guard let resubscribedAt = inputs.lastResubscribeAt, resubscribedAt >= stalledSince else {
            return .resubscribe
        }
        guard inputs.sessionActive,
              inputs.now.timeIntervalSince(resubscribedAt) >= resubscribeGraceSec
        else { return .none }
        if let reset = inputs.lastLinkResetAt, inputs.now.timeIntervalSince(reset) < linkResetCooldownSec {
            return .none
        }
        return .resetLink
    }

    /// Delay before re-opening a subscription that ended. The failures this
    /// covers are local — the SDK refusing before service discovery finishes —
    /// so the cadence is about not spinning, not about sparing the radio.
    static func resubscribeDelay(afterFailures failures: Int) -> TimeInterval {
        let schedule: [TimeInterval] = [1, 2, 3, 5]
        return schedule[min(max(failures, 0), schedule.count - 1)]
    }
}
