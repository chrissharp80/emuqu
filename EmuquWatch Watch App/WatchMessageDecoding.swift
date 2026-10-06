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
/// - A `liveState` tick is a whole snapshot. iOS leaves an optional metric
///   out of it when that metric is not measured, so on a tick an absent
///   heart rate, pace, α1, cadence or target zone means "none", not
///   "unchanged".
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
    /// which is distinct from "sent as zero". Strap-state, voice-chat and
    /// workout-command messages carry only their own fields, so an absent
    /// field there must leave the existing value alone. A `liveState` tick
    /// (`isLiveSnapshot`) carries every metric iOS has, so its absent
    /// optional metrics mean "not measured".
    nonisolated struct StateUpdate: Equatable, Sendable {
        var heartRate: Int?
        var hrPercentOfMax: Int?
        var peakHR: Int?
        var elapsedSeconds: Int?
        var distanceMeters: Double?
        /// Written on the Watch from `paceSecPerKm` when the phone sends it,
        /// else the phone's own `paceDisplay`.
        var paceDisplay: String?
        var alpha1: Double?
        /// Named on the Watch from `bandCode` when the phone sends a code
        /// this build knows, else the phone's own `band` wording.
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
        /// When the iPhone sent this state, in seconds since 1970.
        var sentAt: Double?
        /// The iPhone's `Sport` raw value, for the Watch's own workout session.
        var sportRaw: String?
        /// True for a `liveState` tick: a whole snapshot, not a partial update.
        var isLiveSnapshot = false
    }

    /// Reads the loosely-typed payload into a typed update.
    ///
    /// A value of the wrong type is treated as absent rather than coerced. The
    /// payload crosses a process boundary from a separately-versioned iOS
    /// build, so a type mismatch means the two sides disagree about the schema
    /// — and guessing at intent there is how a stale field silently overwrites
    /// a good one.
    nonisolated static func decode(_ message: [String: Any]) -> StateUpdate {
        var update = decodedMetrics(message)
        update.targetZone = bounded(message["targetZone"] as? Int, Bounds.targetZone)
        update.unitsPreference = message["units"] as? String
        update.displayOnlyMode = message["displayOnlyMode"] as? Bool
        update.isPaused = message["isPaused"] as? Bool
        update.autoPaused = message["autoPaused"] as? Bool
        update.isRecording = message["isRecording"] as? Bool
        update.voiceChatStateLabel = message["voiceChatState"] as? String
        update.sentAt = message["ts"] as? Double
        update.sportRaw = message["sport"] as? String
        update.isLiveSnapshot = message["type"] as? String == "liveState"
        return update
    }

    /// The workout metrics half of `decode`; the session-state fields are
    /// left at their defaults for `decode` to fill.
    nonisolated private static func decodedMetrics(_ message: [String: Any]) -> StateUpdate {
        StateUpdate(
            heartRate: bounded(message["heartRate"] as? Int, Bounds.heartRate),
            hrPercentOfMax: bounded(message["hrPercentOfMax"] as? Int, Bounds.percentOfMax),
            peakHR: bounded(message["peakHR"] as? Int, Bounds.peakHR),
            elapsedSeconds: bounded(message["elapsedSec"] as? Int, Bounds.elapsedSeconds),
            distanceMeters: bounded(message["distanceMeters"] as? Double, Bounds.distanceMeters),
            paceDisplay: paceDisplay(message),
            alpha1: bounded(message["alpha1"] as? Double, Bounds.alpha1),
            band: (message["bandCode"] as? String).flatMap(bandLabel(fromCode:)) ?? message["band"] as? String,
            sportLabel: (message["sport"] as? String).map(sportLabel(fromRaw:)),
            cadenceSpm: bounded(message["cadenceSpm"] as? Double, Bounds.cadenceSpm),
            elevationGainMeters: bounded(message["elevationGainMeters"] as? Double, Bounds.elevationGainMeters)
        )
    }

    /// What each number from the phone may be. The phone is a separately
    /// versioned build, so a value outside these — or a `Double` that is not
    /// finite, which no closed range contains — is treated as absent, like a
    /// value of the wrong type, rather than shown or passed to `Int(...)`,
    /// which traps on a non-finite or huge `Double`.
    nonisolated enum Bounds {
        /// bpm a person can have; 0 is not a reading.
        static let heartRate: ClosedRange<Int> = 25 ... 250
        /// 0 before the first beat of the workout.
        static let peakHR: ClosedRange<Int> = 0 ... 250
        /// Heart rate as a percentage of the user's max; over 100 is possible.
        static let percentOfMax: ClosedRange<Int> = 0 ... 200
        static let elapsedSeconds: ClosedRange<Int> = 0 ... Int.max
        /// Up to 10,000 km.
        static let distanceMeters: ClosedRange<Double> = 0 ... 10_000_000
        /// DFA α1 sits near 0.5–1.5 in exercise; 3 leaves room for noise.
        static let alpha1: ClosedRange<Double> = 0 ... 3
        /// Steps or strokes per minute.
        static let cadenceSpm: ClosedRange<Double> = 0 ... 300
        /// Climb of up to 100 km.
        static let elevationGainMeters: ClosedRange<Double> = 0 ... 100_000
        /// The five heart-rate zones.
        static let targetZone: ClosedRange<Int> = 1 ... 5
    }

    /// `value` when `range` contains it, else nil. A NaN or infinite `Double`
    /// is never contained, so this is also the finite check.
    nonisolated static func bounded<Value: Comparable>(_ value: Value?, _ range: ClosedRange<Value>) -> Value? {
        guard let value, range.contains(value) else { return nil }
        return value
    }

    /// The iPhone's `LiveDFAAnalyzer.Band` raw value → the band's name in the
    /// Watch's language. Nil for a code this build doesn't know, so the
    /// phone's own wording is shown instead.
    nonisolated static func bandLabel(fromCode code: String) -> String? {
        switch code {
        case "unknown": "—"
        case "belowAeT": String(localized: "Easy")
        case "nearAeT": String(localized: "Threshold")
        case "aboveVT2": String(localized: "Very Hard")
        default: nil
        }
    }

    /// The pace in the Watch's language: from `paceSecPerKm` per mile or
    /// per kilometre as `units` says, else the phone's `paceDisplay`.
    nonisolated private static func paceDisplay(_ message: [String: Any]) -> String? {
        guard let secPerKm = message["paceSecPerKm"] as? Double else { return message["paceDisplay"] as? String }
        return pace(secPerKm: secPerKm, imperial: message["units"] as? String == "imperial")
    }

    /// "5:12 /km" or "8:22 /mi", minutes and seconds in the Watch locale's
    /// digits. Nil for a pace that is not a positive finite number.
    nonisolated static func pace(secPerKm: Double, imperial: Bool) -> String? {
        guard secPerKm.isFinite, secPerKm > 0 else { return nil }
        let perUnit = imperial ? secPerKm * 1.609344 : secPerKm
        let time = Duration.seconds(Int(min(perUnit, 86_400))).formatted(.time(pattern: .minuteSecond).locale(.current))
        return imperial ? String(localized: "\(time) /mi") : String(localized: "\(time) /km")
    }

    /// A refused control message, worded in the Watch's language from the
    /// phone's `errorCode`. Nil for a code this build doesn't know, so the
    /// phone's own `error` wording is shown instead. `sport` is the `Sport`
    /// raw value the Watch sent.
    nonisolated static func refusalText(code: String, sport: String?) -> String? {
        switch code {
        case "phoneNotReady": String(localized: "Phone not ready")
        case "unknownMessage": String(localized: "Unknown message")
        case "unknownSport": String(localized: "Unknown sport: \(sport ?? "")")
        case needsUnlockCode: String(localized: "Open Emuqu on your iPhone to start your free trial or unlock.")
        case "strapBusy": String(localized: "The strap is currently used by another session. Stop it first.")
        default: nil
        }
    }

    /// The phone's `errorCode` for a user its paywall would stop.
    nonisolated static let needsUnlockCode = "needsUnlock"

    /// The status line for the phone's answer to a control message:
    /// `successStatus` when it accepted. A refusal is worded on the Watch from
    /// the phone's `errorCode`, so it reads in the Watch's language; a phone
    /// build without codes is quoted as it worded it. Refusals are prefixed
    /// "iPhone:" to say which device answered, except the unlock prompt, which
    /// already names the iPhone.
    nonisolated static func controlReplyStatus(_ reply: [String: Any], sport: String?, successStatus: String) -> String {
        guard !(reply["ok"] as? Bool ?? false) else { return successStatus }
        let code = reply["errorCode"] as? String
        if code == needsUnlockCode, let prompt = refusalText(code: needsUnlockCode, sport: sport) { return prompt }
        let worded = code.flatMap { refusalText(code: $0, sport: sport) }
        let err = worded ?? (reply["error"] as? String) ?? String(localized: "unknown error")
        return String(localized: "iPhone: \(err)")
    }

    /// The iPhone's `Sport` raw value → the same localized name the iPhone
    /// shows (`Sport.localizedName`). An unknown raw value falls back to a
    /// title-cased form: `"new_sport"` → `"New Sport"`.
    nonisolated static func sportLabel(fromRaw raw: String) -> String {
        switch raw {
        case "run": String(localized: "Run")
        case "trail_run": String(localized: "Trail Run")
        case "walk": String(localized: "Walk")
        case "hike": String(localized: "Hike")
        case "bike": String(localized: "Ride")
        case "indoor_bike": String(localized: "Indoor Ride")
        case "treadmill": String(localized: "Treadmill")
        case "row": String(localized: "Row")
        case "air_bike": String(localized: "Air Bike")
        case "crossfit": String(localized: "CrossFit")
        default: raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
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
    /// mid-workout when the `requestCurrentState` reply carries
    /// `isRecording: true`.
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

// MARK: - Ending the Watch session without the iPhone

extension WatchMessageDecoding {

    /// How long the Watch keeps its workout session with no message at all
    /// from the iPhone app. A recording iPhone sends its state every second
    /// (live message or application context), and the Watch pulls it again
    /// whenever it comes back to the foreground, so half an hour of silence
    /// means the iPhone app is gone — closed, crashed, or the iPhone left far
    /// behind. Long enough that a slow context delivery while the wrist is
    /// down never ends a live workout's session; short enough that a Watch
    /// left alone does not hold the heart-rate sensor and the workout
    /// indicator for hours. The session starts again on the iPhone's next
    /// message if it is still recording.
    nonisolated static let phoneSilenceLimit: TimeInterval = 30 * 60

    /// How often the running session checks for that silence.
    nonisolated static let phoneSilenceCheckInterval: Duration = .seconds(60)

    nonisolated static func phoneSilenceExceeded(lastContact: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastContact) > phoneSilenceLimit
    }

    /// Whether the wrist Stop ends the Watch's own session at once. With the
    /// iPhone reachable, the iPhone stops the workout and its answer ends the
    /// session, as for a stop from the iPhone. Unreachable, the stop is only
    /// queued, and the session would run until the iPhone app next opened.
    nonisolated static func endsSessionOnWristStop(phoneReachable: Bool) -> Bool {
        !phoneReachable
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
        /// A live-metrics tick. Its fields are the whole message, so there is
        /// nothing to do beyond applying them.
        case liveState
        /// A voice-chat lifecycle push, applied through `voiceChatStateLabel`.
        case voiceChatState

        /// Unrecognised verb. Carried rather than dropped so a schema drift
        /// between a new iOS build and an old Watch build is visible.
        case unknown(String)
    }

    nonisolated static func command(_ message: [String: Any]) -> Command? {
        guard let raw = message["type"] as? String else { return nil }
        switch raw {
        case "startWorkout": return .startWorkout
        case "stopWorkout": return .stopWorkout
        case "liveState": return .liveState
        case "voiceChatState": return .voiceChatState
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
