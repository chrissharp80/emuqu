import Foundation

// The Watch manager's pure helpers: how the iPhone's voice-chat reply reads
// on the Watch, and how long a queued control request stays actionable.

extension WatchSessionManager {
    // MARK: - Voice-chat reply wording

    /// The status line for a refused voice-chat request, worded like every
    /// other control refusal (`WatchMessageDecoding.controlReplyStatus`). Nil
    /// when the iPhone accepted it, or asked for its AI disclaimer, which has
    /// its own wording.
    nonisolated static func voiceChatRefusalStatus(_ reply: [String: Any]) -> String? {
        guard reply["ok"] as? Bool == false, reply["needsDisclaimer"] as? Bool != true else { return nil }
        return WatchMessageDecoding.controlReplyStatus(reply, sport: nil, successStatus: "")
    }

    /// The iPhone sends its voice-chat state as a fixed English token
    /// (`VoiceConversationController.State.watchLabel`); this is its word.
    /// Nil for "idle" or a token this build does not know, where each caller
    /// shows its own resting word ("Off" in a status line, "Talk to AI" on the
    /// button). The one table for both, so a new iOS state is added once.
    static func voiceChatStateWord(_ token: String) -> String? {
        switch token {
        case "starting": String(localized: "Connecting…")
        case "listening": String(localized: "Listening")
        case "thinking": String(localized: "Thinking…")
        case "speaking": String(localized: "Speaking")
        case "alert": String(localized: "Alert")
        default: nil
        }
    }

    // MARK: - Queued-request expiry

    /// How long a queued control request stays actionable. A tap meant "now":
    /// a pause, resume or start acted on hours later, when the iPhone next
    /// wakes, is not what the user asked for.
    static let queuedRequestLifetime: TimeInterval = 60

    /// How long a queued End stays actionable. Not "now" like the others: an
    /// End tapped while the iPhone is unreachable has already ended the
    /// Watch's own session (`WatchWorkoutManager.noteWristStop`), so an End
    /// that expired would leave the iPhone recording a workout the user
    /// ended. The iPhone refuses an End stamped before its current workout
    /// began, so a late one cannot end the next workout.
    static let queuedStopLifetime: TimeInterval = 12 * 60 * 60

    /// Adds `expiresAt` (seconds since 1970) for the iPhone to check before
    /// acting on a queued request.
    static func withQueueExpiry(_ payload: [String: Any]) -> [String: Any] {
        let isStop = payload["type"] as? String == WatchMessageDecoding.stopIntentType
        var stamped = payload
        stamped["expiresAt"] = Date()
            .addingTimeInterval(isStop ? queuedStopLifetime : queuedRequestLifetime)
            .timeIntervalSince1970
        return stamped
    }
}
