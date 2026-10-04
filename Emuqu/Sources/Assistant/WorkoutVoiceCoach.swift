import AVFoundation
import Combine
import CoreLocation
import Foundation

// MARK: - Workout Voice Coach
//
// Sits above the trigger engine and owns the output side: a fired `.spoken`
// event goes to TTS over AirPods; `.haptic` and `.silent` events stay quiet
// (there is no Watch haptic handler yet). Also tracks the in-session mute.
//
// The coach is observer-shaped: it's handed a WorkoutAIContext snapshot from
// the recorder's tick loop and decides what (if anything) to do with it.
// Silence is the default; the rule engine has to earn an interruption.
@Observable
@MainActor
final class WorkoutVoiceCoach {
    // MARK: Published

    /// Global mute — toggle from the recording UI to silence all coach output.
    var isMuted = false

    // MARK: Dependencies

    private let engine: WorkoutTriggerEngine
    /// Lazy — `AVSpeechSynthesizer()` cold init stalls main for 50-150 ms
    /// while AVFoundation preps the audio graph. The coach only speaks
    /// when trigger rules fire during an active workout, so defer init
    /// until that point rather than eating the cost at WorkoutRecorder
    /// construction (which happens the first time the user opens the
    /// Fitness tab).
    @ObservationIgnored private lazy var synthesizer = AVSpeechSynthesizer()
    private weak var watchBridge: WatchConnectivityBridge?
    /// When set, `.spoken` triggers preempt the voice-chat conversation via
    /// the controller's handleTrigger path (which kills the current TTS /
    /// LLM stream cleanly). If nil, triggers speak directly through the
    /// coach's own synthesizer.
    weak var conversation: VoiceConversationController?

    /// Has this session played the
    /// "Workout Coach here." identification preamble yet? First spoken
    /// line of each workout gets the announcement so the user knows
    /// which AI mouth is talking; subsequent lines drop the preamble
    /// to avoid being chatty. Reset on `reset()` (new session start).
    private var hasAnnouncedSubsystem = false

    /// Per-workout state for the mile-marker
    /// notifications tier (`WorkoutMileMarkerEngine`). Holds the
    /// last-fired marker index plus the start-of-split snapshots
    /// used to compute split deltas. Reset to a fresh value at
    /// workout start via `reset()`.
    private var mileMarkerState = MileMarkerState()

    /// Per-workout state for the turn-by-turn alert
    /// engine. Tracks which step + threshold (far / near / at-turn)
    /// has already been announced so each fires exactly once per
    /// step. Reset on `reset()` (new workout).
    private var turnAlertState = TurnAlertState()

    /// Per-workout state for the post-turn split
    /// engine. Tracks leg start metrics (distance / time / HR sum)
    /// so a "you turned, last leg was X" line can be built when
    /// the route advances. Reset on `reset()`.
    private var turnMarkerState = TurnMarkerState()

    /// When the route the engines are tracking was engaged. A different
    /// value means a new route, which resets both route-engine states.
    private var routeEngagedAt: Date?

    init(engine: WorkoutTriggerEngine? = nil, watchBridge: WatchConnectivityBridge? = nil) {
        self.engine = engine ?? WorkoutTriggerEngine()
        self.watchBridge = watchBridge
    }

    // MARK: - Evaluate

    /// Push a context snapshot through the engine and handle any events.
    ///
    /// Speaking is gated on BOTH the in-session `isMuted` toggle AND
    /// the persistent `coachAlertsEnabled` setting. The engines evaluate
    /// either way, so their per-workout state keeps moving while muted:
    /// unmuting at mile 4.2 doesn't announce a "split" that covers the
    /// two miles run in silence.
    ///
    /// Tier 2 mile-marker notifications run independently of alerts —
    /// they have their own toggle (`enableMileMarkerNotifications`,
    /// off by default) and don't write to alert history. Both still
    /// share the in-session `isMuted` button (one place to silence
    /// everything in flight), and both route through
    /// `conversation.handleTrigger` which respects the
    /// in-progress-user-utterance preemption guard.
    ///
    /// Turn-by-turn alerts and turn-marker splits
    /// BOTH require an active route from `directions.routeTo`.
    /// `tickRouteEngines` resolves the step result ONCE and hands it to
    /// whichever engines the user has opted into. When no route is
    /// engaged, both engines no-op — cheaper than letting them
    /// walk through their state machines.
    func tick(context: WorkoutAIContext) {
        let settings = AppDependencies.current.app.settingsManager.settings
        let events = engine.evaluate(context: context)
        if settings.coachAlertsEnabled, !isMuted {
            for event in events {
                dispatch(event: event)
            }
        }
        if settings.enableMileMarkerNotifications {
            tickMileMarker(context: context, settings: settings)
        }
        if settings.enableTurnByTurnAlerts || settings.enableTurnMarkerUpdates {
            tickRouteEngines(context: context, settings: settings)
        }
    }

    /// Run the mile-marker engine and dispatch any payload through the
    /// existing in-conversation-aware trigger queue.
    private func tickMileMarker(context: WorkoutAIContext, settings: UserSettings) {
        let imperial = UnitsPreferenceStore.current.resolved == .imperial
        let result = WorkoutMileMarkerEngine.evaluate(
            context: context,
            state: mileMarkerState,
            interval: settings.mileMarkerInterval,
            unitsImperial: imperial
        )
        mileMarkerState = result.nextState
        guard !isMuted, let payload = result.payload else { return }
        let body = MileMarkerFormatter.render(payload: payload, unitsImperial: imperial)
        if let conversation {
            conversation.handleTrigger(message: body)
        } else {
            speak(body)
        }
    }

    /// Run the turn-by-turn alert + post-turn marker engines for
    /// the active route. Both consult `ActiveRouteSession` for the
    /// step-result snapshot; if no route is engaged this exits
    /// fast. Each engine's payload (when one fires) routes through
    /// the same in-conversation-aware trigger queue as mile
    /// markers — guarantees we never wipe an in-flight user
    /// utterance.
    private func tickRouteEngines(context: WorkoutAIContext, settings: UserSettings) {
        let route = AppDependencies.current.location.activeRouteSession
        guard let snapshot = route.snapshot(), let fix = routeFix(context: context),
              let stepResult = route.currentStep(for: fix)
        else { return }
        resetRouteStateIfNewRoute(engagedAt: snapshot.engagedAt)
        let imperial = UnitsPreferenceStore.current.resolved == .imperial
        if settings.enableTurnByTurnAlerts {
            tickTurnAlert(step: stepResult, stepCount: snapshot.stepCount, imperial: imperial)
        }
        if settings.enableTurnMarkerUpdates {
            let marker = TurnMarkerEngine.evaluate(step: stepResult, context: context, state: turnMarkerState)
            turnMarkerState = marker.nextState
            if let payload = marker.payload {
                announceRouteLine(TurnMarkerFormatter.render(payload: payload, unitsImperial: imperial))
            }
        }
    }

    /// Run the turn-alert engine for one step result and speak its payload.
    private func tickTurnAlert(step: ActiveRouteSession.StepResult, stepCount: Int, imperial: Bool) {
        let isFinalStep = step.currentStepIndex >= stepCount - 1
        let alert = TurnAlertEngine.evaluate(step: step, state: turnAlertState, isFinalStep: isFinalStep)
        turnAlertState = alert.nextState
        if let payload = alert.payload {
            announceRouteLine(TurnAlertFormatter.render(payload: payload, unitsImperial: imperial))
        }
    }

    /// The position to measure turn distances from: the workout's own GPS
    /// fix from this tick's snapshot (best-accuracy, unfiltered updates),
    /// else a fix from `AmbientLocationService` no older than
    /// `ambientFixMaxAgeSec`. The ambient service runs at 100 m accuracy
    /// with a 50 m distance filter, too coarse to land inside the turn
    /// thresholds on its own.
    private func routeFix(context: WorkoutAIContext) -> CLLocation? {
        if let lat = context.currentLatitude, let lon = context.currentLongitude {
            return CLLocation(latitude: lat, longitude: lon)
        }
        return AppDependencies.current.location.ambientLocationService
            .cachedLocation(maxAgeSec: Self.ambientFixMaxAgeSec)
    }

    /// Oldest ambient fix the route engines accept when the workout has no
    /// GPS fix of its own.
    private static let ambientFixMaxAgeSec: TimeInterval = 10

    /// A route engaged mid-workout (the AI loading a second route) starts
    /// both route engines afresh, so the arrival flag and leg baseline of
    /// the previous route don't carry over to step indices of the new one.
    private func resetRouteStateIfNewRoute(engagedAt: Date) {
        guard engagedAt != routeEngagedAt else { return }
        routeEngagedAt = engagedAt
        turnAlertState = TurnAlertState()
        turnMarkerState = TurnMarkerState()
    }

    /// Speak one route line through the conversation controller when there is
    /// one (so it respects the in-progress-user-utterance guard), else
    /// directly. An empty body is a no-op — the formatters return "" when a
    /// payload has nothing worth saying.
    private func announceRouteLine(_ body: String) {
        guard !isMuted, !body.isEmpty else { return }
        if let conversation {
            conversation.handleTrigger(message: body)
        } else {
            speak(body)
        }
    }

    /// Reset cooldowns and the event log — called when a new session starts.
    /// Also claims the audio session for spoken cues: at workout start, not
    /// when the recorder is first built (opening the Fitness tab).
    func reset() {
        configureAudioSession()
        engine.reset()
        // Re-arm the subsystem-identification preamble for the new session.
        hasAnnouncedSubsystem = false
        // Fresh mile-marker state so split 1 of every
        // workout fires cleanly without inheriting last session's
        // marker counter.
        mileMarkerState = MileMarkerState()
        // Fresh turn-engine state so the first alert
        // / post-turn split of each workout don't inherit prior
        // session's threshold counter or leg-start metrics.
        turnAlertState = TurnAlertState()
        turnMarkerState = TurnMarkerState()
        routeEngagedAt = nil
    }

    // MARK: - Dispatch

    /// When the user is mid-AI-
    /// voice-conversation, suppress routine triggers entirely so the
    /// coach doesn't crash / kill the AI session. Urgent triggers
    /// (strap dropped, user-declared threshold breach) still fire —
    /// the user opted into those alerts explicitly. Suppressed triggers
    /// still sit in the engine's in-memory history, as do `.silent` ones.
    ///
    /// `.haptic` is a no-op: the Watch side has no handler for
    /// `WatchConnectivityBridge.sendVoiceTrigger`. Once
    /// the Watch grows a trigger UI, wire it here.
    private func dispatch(event: WorkoutTriggerEngine.Event) {
        if event.urgency == .routine, conversation?.isAIInFlight == true {
            debugLog("[WorkoutVoiceCoach] suppressing routine trigger '\(event.ruleID)' — AI conversation active")
            return
        }
        switch event.tier {
        case .silent, .haptic: break
        case .spoken: dispatchSpoken(event)
        }
    }

    /// Prefix automated alerts with "Coach alert —"
    /// so the user can audibly tell a scripted trigger apart
    /// from a conversational AI line. The AI's own
    /// voice never starts with this phrase, so the distinction
    /// is unambiguous in headphones.
    ///
    /// Triggers are secondary: if the conversation is active they preempt it
    /// (cancelling TTS / LLM stream cleanly). Otherwise we speak directly.
    ///
    /// The event's urgency passes through. Routine
    /// triggers respect "user is mid-utterance, queue me";
    /// urgent triggers (heart-rate threshold breaches,
    /// strap-drop, future SOS) preempt anyway and the
    /// controller copies the user's in-progress dictation
    /// to the clipboard so they can paste it back.
    private func dispatchSpoken(_ event: WorkoutTriggerEngine.Event) {
        let tagged = announcedAlertText(Self.taggedAlertText(event.message))
        if let conversation {
            let urgency: VoiceConversationController.TriggerUrgency =
                event.urgency == .urgent ? .urgent : .routine
            conversation.handleTrigger(message: tagged, urgency: urgency)
        } else {
            speak(tagged)
        }
    }

    /// On the FIRST spoken line of
    /// each session, prepend the subsystem identification
    /// ("Workout Coach here.") so the user knows which AI is
    /// talking before the alert content lands. Subsequent
    /// lines stay terse to avoid being chatty.
    ///
    /// Not only on the first trigger, though: if
    /// "Workout Coach here." is said once per
    /// session, later mid-conversation interruptions
    /// just cut the AI's voice and start the alert
    /// with "Coach alert —" — the user reported it sounded
    /// "like one continuous conversation." When the coach
    /// is about to PREEMPT an in-flight AI conversation, we
    /// re-announce the handoff so the speaker switch is
    /// unambiguous in headphones. When the AI is idle (no
    /// conversation in flight), the prefix alone is enough.
    private func announcedAlertText(_ body: String) -> String {
        let willPreemptConversation = conversation?.isAIInFlight ?? false
        guard !hasAnnouncedSubsystem || willPreemptConversation else { return body }
        hasAnnouncedSubsystem = true
        return AssistantSubsystem.workoutVoiceCoach.voiceAnnouncement + " " + body
    }

    // MARK: - TTS

    private func configureAudioSession() {
        // User report: "app disconnects randomly when
        // an alert fires". Calling
        // `setCategory(.playback…)` directly here bypasses the
        // AudioSessionCoordinator; when an AI voice conversation is
        // already running with `.playAndRecord` category, that clobber
        // drops the recording mode mid-session — which manifests as
        // the user-visible "app disconnect on alert" because the route
        // change cascaded through Bluetooth (HFP/A2DP renegotiation
        // can knock the strap's BLE link off briefly on some headsets).
        // Routing through the coordinator's strict-superset resolution
        // means we never DOWNGRADE the session category, only escalate.
        // When voice chat already holds `.playAndRecord`, our `.playback`
        // claim is satisfied without a category change.
        AppDependencies.current.services.audioSessionCoordinator.claim(.workoutCoach, mode: .playback)
    }

    /// Drop the coach's audio-session claim when the workout ends. Its own
    /// `.workoutCoach` key, so the background keepalive's claim is untouched.
    func releaseAudioSession() {
        AppDependencies.current.services.audioSessionCoordinator.release(.workoutCoach)
    }

    /// Prefix scripted-alert text with a clear lead-in so the user can
    /// tell automated coach lines apart from the conversational AI's
    /// voice (item #11). Idempotent — once tagged we don't double-tag,
    /// which matters when other dispatch paths re-route the same string.
    static func taggedAlertText(_ message: String) -> String {
        let prefix = String(localized: "Coach alert — ", bundle: LanguageManager.appBundle)
        if message.hasPrefix(prefix) { return message }
        return prefix + message
    }

    /// Scripted cue text is localized through `LanguageManager.appBundle`,
    /// so speak it with the app language's voice rather than the system
    /// locale's — otherwise a German cue could be read by an English voice
    /// (or vice versa). A compact voice, as for the start cue: one that
    /// isn't downloaded yet blocks the first `speak()` while iOS fetches it.
    static func appLanguageVoice() -> AVSpeechSynthesisVoice? {
        WorkoutStartCue.localCompactVoice(
            forLanguage: LanguageManager.appLocale.language.languageCode?.identifier ?? "en"
        )
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.appLanguageVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        // Wrap speak in SafeObjC shim. Same NSException risk
        // as VoiceConversationController's TTS path: workouts often run
        // through audio session interruptions (phone calls, alarms), and
        // the first speak after such an interruption can raise
        // NSInternalInconsistencyException uncatchable from Swift.
        // Skipping a coach line is far less bad than crashing the workout.
        var speakErr: NSError?
        if !FRSafeSpeak(synthesizer, utterance, &speakErr) {
            debugLog("[VoiceCoach] speak failed (dropping line): \(speakErr?.localizedDescription ?? "?")", level: .warning)
        }
    }
}
