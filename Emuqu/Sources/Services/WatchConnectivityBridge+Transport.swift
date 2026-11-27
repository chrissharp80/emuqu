import Foundation
import WatchConnectivity

// The bridge's user-info queueing rule and the small value types its
// transport and control replies use.

// MARK: - Superseded user-info transfers

extension WatchConnectivityBridge {
    /// Queues `payload` with `transferUserInfo`, first cancelling any queued
    /// transfer it supersedes (`userInfoSupersedes`). User-info transfers are
    /// all delivered, in order, when the Watch app next runs; without this, a
    /// Watch app that had not run for many workouts received every start and
    /// stop since and replayed them, starting and stopping workout sessions
    /// for workouts long over, with a lone start able to leave one running.
    nonisolated static func transferLatestUserInfo(_ payload: [String: any Sendable], on session: WCSession) {
        let type = payload[MessageKey.type.rawValue] as? String
        for transfer in session.outstandingUserInfoTransfers
        where userInfoSupersedes(type, queued: transfer.userInfo[MessageKey.type.rawValue] as? String) {
            transfer.cancel()
        }
        session.transferUserInfo(payload)
    }

    /// Whether a new user-info transfer of type `type` makes a queued one of
    /// type `queued` pointless. Each of these carries the whole current state
    /// of one thing, so only the newest matters: the workout (a start or a
    /// stop), the strap, and the voice chat. A coach alert replaces a queued
    /// coach alert too: the Watch plays one only within a few seconds of when
    /// it fired (`WatchMessageDecoding.playsCoachAlert`), so the older one
    /// would reach it too late to play. A save state replaces a queued one:
    /// only whether the workout is now saved matters. Any other type, or none, is never
    /// superseded.
    nonisolated static func userInfoSupersedes(_ type: String?, queued: String?) -> Bool {
        guard let type, let queued else { return false }
        let workout: Set<String> = [MessageType.startWorkout.rawValue, MessageType.stopWorkout.rawValue]
        if workout.contains(type) { return workout.contains(queued) }
        let replacesItsOwnType: Set<String> = [
            MessageType.strapState.rawValue, "voiceChatState", MessageType.coachAlert.rawValue,
            MessageType.workoutSaveState.rawValue
        ]
        return replacesItsOwnType.contains(type) && queued == type
    }
}

// MARK: - Control refusals

/// Why the phone refused a Watch control message.
///
/// The reply carries the raw value as `errorCode`, and the Watch words it in
/// its own language from the shared catalogue, so a Watch set to another
/// language than the phone's app language shows one language. The reply's
/// `error` carries `phoneText` too, for Watch builds that predate the code.
enum WatchControlRefusal: String, Sendable {
    /// No handler is wired yet: the phone app is still launching.
    case phoneNotReady
    /// A message type this phone build doesn't know.
    case unknownMessage
    /// A sport this phone build doesn't know.
    case unknownSport
    /// The paywall would stop this user on the phone.
    case needsUnlock
    /// The strap is recording on its own (an overnight session, or one
    /// started on the device), and a workout would preempt it.
    case strapBusy
    /// A workout is already recording (or being saved) on the phone.
    case workoutInProgress

    /// The refusal in the phone's app language. `sport` is the Watch's
    /// `Sport` raw value, quoted by `unknownSport`.
    func phoneText(sport: String?) -> String {
        let bundle = LanguageManager.appBundle
        switch self {
        case .phoneNotReady: return String(localized: "Phone not ready", bundle: bundle)
        case .unknownMessage: return String(localized: "Unknown message", bundle: bundle)
        case .unknownSport: return String(localized: "Unknown sport: \(sport ?? "")", bundle: bundle)
        case .needsUnlock: return String(localized: "Open Emuqu on your iPhone to start your free trial or unlock.", bundle: bundle)
        case .strapBusy: return String(localized: "The strap is currently used by another session. Stop it first.", bundle: bundle)
        case .workoutInProgress: return String(localized: "A workout is already recording on your iPhone.", bundle: bundle)
        }
    }
}

/// The send-timeout circuit breaker's state (`WatchConnectivityBridge`'s
/// live-state transport). `timeouts` counts send timeouts since reachability
/// last came back. The breaker opens when the count reaches `threshold` and
/// stays open for `cooldown`; after that sends are tried again, and with the
/// count still at the threshold, the next timeout opens it again at once.
/// `sendMessage` without a reply handler reports failures only, so a cooldown,
/// not a successful send, is what closes it short of reachability returning.
struct WatchSendTimeoutBreaker: Sendable, Equatable {
    static let threshold = 3
    static let cooldown: TimeInterval = 30

    private(set) var timeouts = 0
    private(set) var openedAt: Date?

    func isOpen(at now: Date) -> Bool {
        guard timeouts >= Self.threshold, let openedAt else { return false }
        return now.timeIntervalSince(openedAt) < Self.cooldown
    }

    mutating func noteTimeout(at now: Date) {
        timeouts += 1
        if timeouts >= Self.threshold, !isOpen(at: now) { openedAt = now }
    }
}
