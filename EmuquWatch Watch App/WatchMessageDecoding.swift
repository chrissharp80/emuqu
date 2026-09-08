import Foundation

/// Pure decoding of the phone → Watch `WCSession` message payload.
///
/// `WatchSessionManager.apply(_:)` has three jobs: read loosely-typed values
/// out of a `[String: Any]`, decide which state transitions those values
/// imply, and perform the side effects those transitions require (starting
/// and stopping `HKWorkoutSession`, cancelling in-flight timeout tasks,
/// updating `@Published` properties).
///
/// The first two are pure and carry all the subtle rules. The third is not
/// testable without a paired Watch and a live `WCSession`. So the first two
/// live here, as value types, and `apply(_:)` is a thin shell that decodes
/// once and then performs whatever the decode says. Welding the decode to the
/// side effects is what makes a Watch target untestable. The rules below are
/// the ones worth pinning:
///
/// - `justCompleted` fires only on a true → false `isRecording` transition, so
///   a cold Watch launch that starts out `false` does not show a "Save & Done"
///   banner for a workout that never happened.
/// - `displayOnlyMode` is **sticky**: absent from a message means "unchanged",
///   not "false". iOS tells the Watch once and the Watch must not forget it
///   when a subsequent partial update arrives.
/// - A `startWorkout` message is refused in display-only mode even though iOS
///   also gates it, because a stale build or a downstream bug reaching this
///   path triggers Apple Health's "Record a workout" offer for a workout the
///   Watch does not own.
///
/// ## Isolation
///
/// Explicitly `nonisolated`. Both targets build with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise put these
/// static methods on the main actor — and they would then be unusable from the
/// `WCSession` delegate callbacks that are their only real caller, which arrive
/// off the main actor. Nothing here touches shared state, so main-actor
/// isolation would buy nothing and cost a hop (or a warning, which is how this
/// was noticed).
nonisolated enum WatchMessageDecoding {}

// MARK: - Field updates

extension WatchMessageDecoding {

    /// The subset of Watch state a phone message can carry.
    ///
    /// Every field is optional and `nil` means **absent from this message**,
    /// which is distinct from "sent as zero". Partial updates are the norm —
    /// iOS pushes only what changed — so an absent field must leave the
    /// existing value alone.
    nonisolated struct StateUpdate: Equatable, Sendable {
        var heartRate: Int?
        var hrPercentOfMax: Int?
        var peakHR: Int?
        var elapsedSeconds: Int?
        var distanceMeters: Double?
        var paceDisplay: String?
        var alpha1: Double?
        var band: String?
        var sportLabel: String?
        var cadenceSpm: Double?
        var elevationGainMeters: Double?
        var targetZone: Int?
        var unitsPreference: String?
        var displayOnlyMode: Bool?
        var isPaused: Bool?
        var autoPaused: Bool?
        var isRecording: Bool?
        var voiceChatStateLabel: String?
    }

    /// Reads the loosely-typed payload into a typed update.
    ///
    /// A value of the wrong type is treated as absent rather than coerced. The
    /// payload crosses a process boundary from a separately-versioned iOS
    /// build, so a type mismatch means the two sides disagree about the schema
    /// — and guessing at intent there is how a stale field silently overwrites
    /// a good one.
    nonisolated static func decode(_ message: [String: Any]) -> StateUpdate {
        StateUpdate(
            heartRate: message["heartRate"] as? Int,
            hrPercentOfMax: message["hrPercentOfMax"] as? Int,
            peakHR: message["peakHR"] as? Int,
            elapsedSeconds: message["elapsedSec"] as? Int,
            distanceMeters: message["distanceMeters"] as? Double,
            paceDisplay: message["paceDisplay"] as? String,
            alpha1: message["alpha1"] as? Double,
            band: message["band"] as? String,
            sportLabel: (message["sport"] as? String).map(sportLabel(fromRaw:)),
            cadenceSpm: message["cadenceSpm"] as? Double,
            elevationGainMeters: message["elevationGainMeters"] as? Double,
            targetZone: message["targetZone"] as? Int,
            unitsPreference: message["units"] as? String,
            displayOnlyMode: message["displayOnlyMode"] as? Bool,
            isPaused: message["isPaused"] as? Bool,
            autoPaused: message["autoPaused"] as? Bool,
            isRecording: message["isRecording"] as? Bool,
            voiceChatStateLabel: message["voiceChatState"] as? String
        )
    }

    /// `"trail_run"` → `"Trail Run"`.
    nonisolated static func sportLabel(fromRaw raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

// MARK: - Recording transitions

extension WatchMessageDecoding {

    /// What a change in `isRecording` requires the Watch to do.
    ///
    /// The Watch must own a running `HKWorkoutSession` for the whole workout or
    /// watchOS suspends the app when the screen darkens — the reported "it went
    /// dark, dropped the session, and offered a NEW workout on reopen" bug. So
    /// this is driven off `isRecording` rather than the mode-gated
    /// `startWorkout` message, which also makes it re-arm after an app relaunch
    /// mid-workout when the restored context carries `isRecording: true`.
    enum RecordingTransition: Equatable {
        /// No `isRecording` in the message, or no change.
        case none
        /// false → true. Start the local workout session.
        case started
        /// true → false. Stop it, and show the completion banner.
        case stopped
    }

    nonisolated static func recordingTransition(wasRecording: Bool, update: StateUpdate) -> RecordingTransition {
        guard let now = update.isRecording else { return .none }
        if now, !wasRecording { return .started }
        if !now, wasRecording { return .stopped }
        return .none
    }

    /// Whether the "Save & Done" banner should be showing after this message.
    ///
    /// Set on a true → false transition, cleared when a new workout starts. A
    /// message that does not carry `isRecording` leaves it as it was.
    nonisolated static func justCompleted(current: Bool, wasRecording: Bool, update: StateUpdate) -> Bool {
        switch recordingTransition(wasRecording: wasRecording, update: update) {
        case .stopped: true
        case .started: false
        case .none: current
        }
    }

    /// Whether an in-flight "start workout" request should be considered
    /// answered by this message.
    ///
    /// iOS confirming `isRecording: true` is the confirmation — clearing the
    /// spinner here rather than on the 10 s timeout prevents a stale overlay if
    /// the user navigates back to the Start screen before the timeout fires.
    nonisolated static func clearsStartWorkoutRequest(update: StateUpdate) -> Bool {
        update.isRecording == true
    }

    /// Whether an in-flight voice-chat request should be considered answered.
    ///
    /// Any non-idle lifecycle state means the conversation actually started.
    nonisolated static func clearsVoiceChatRequest(update: StateUpdate) -> Bool {
        guard let state = update.voiceChatStateLabel else { return false }
        return state != "idle"
    }
}

// MARK: - Typed commands

extension WatchMessageDecoding {

    /// The `type` field's command verbs, plus the rule for whether each is
    /// honoured in the current mode.
    nonisolated enum Command: Equatable, Sendable {
        case startWorkout
        case stopWorkout
        case strapState(connected: Bool?, deviceName: String?)

        /// Unrecognised verb. Carried rather than dropped so a schema drift
        /// between a new iOS build and an old Watch build is visible.
        case unknown(String)
    }

    nonisolated static func command(_ message: [String: Any]) -> Command? {
        guard let raw = message["type"] as? String else { return nil }
        switch raw {
        case "startWorkout": return .startWorkout
        case "stopWorkout": return .stopWorkout
        case "strapState":
            return .strapState(
                connected: message["strapConnected"] as? Bool,
                deviceName: message["strapDeviceName"] as? String
            )
        default: return .unknown(raw)
        }
    }

    /// Whether a `startWorkout` command should actually start a session.
    ///
    /// Refused in display-only mode. iOS gates this too, so reaching here with
    /// `displayOnlyMode == true` means a stale build or a downstream bug —
    /// and honouring it would trigger Apple Health's "Record a workout" offer
    /// for a workout the Watch does not own.
    nonisolated static func shouldStartWorkout(for command: Command, displayOnlyMode: Bool) -> Bool {
        command == .startWorkout && !displayOnlyMode
    }
}
