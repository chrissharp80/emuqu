import AudioToolbox
import AVFoundation
import Combine
import CoreLocation
import Foundation
import UIKit

// MARK: - Workout Recorder
//
// Orchestrates a live workout session. Sibling of RRCollector, not a subclass
// or extension — both consume the shared RecordingCore substrate (Polar BLE,
// archive, CloudKit, analysis pipeline) so workout-specific concerns stay out
// of the HRV pipeline and vice versa.
//
// Responsibilities:
//   - Start/stop a workout HRVSession
//   - Stream RR from the Polar strap (same shared PolarManager as HRV path)
//   - Track GPS fixes via WorkoutLocationManager for GPS-enabled sports
//   - Incremental backup + CloudKit live upload (reuses shared archive/cloud)
//   - Archive the finalized session with workoutMetadata populated
//   - Live DFA α1, the voice coach, and the HRR capture window after stop
@Observable
@MainActor
final class WorkoutRecorder {
    // MARK: Published state

    enum Phase: Equatable {
        case idle
        case recording
        case finalizing
        case finished
        case failed(String)
    }

    /// Lifecycle state (phase / sessions / elapsed / HR source / target zone)
    /// lives in `WorkoutLifecycle` so session-chrome views can subscribe
    /// to that alone. Forwarding keeps `recorder.phase`,
    /// `recorder.currentSession`, etc. readable.
    let lifecycle = WorkoutLifecycle()
    /// HR metrics (currentHR, peakHR, beatCount) live in a dedicated
    /// sub-observable so HR-only displays aren't invalidated by motion or
    /// lifecycle updates. Getters forward
    /// `recorder.currentHR` / `peakHR` / `beatCount` reads through.
    /// Named `workoutHR` (not `hr`) to avoid shadowing local `hr` vars in
    /// tick code.
    let workoutHR = WorkoutHR()
    /// Motion metrics (GPS + pedometer + foot pod) live in a
    /// dedicated sub-observable so the live-map view and the stat-chip
    /// view can subscribe to only the signal they actually use: the 1 Hz
    /// tick fires only the motion publisher instead of invalidating the
    /// entire recorder subscription.
    ///
    /// Getters below forward `recorder.distanceMeters` etc.
    /// reads through to `motion`.
    let motion = WorkoutMotion()
    /// Live DFA α1 + band. Owns its own rolling window.
    let dfa = LiveDFAAnalyzer()
    /// Structured-interval controller. Nil unless the user picked an interval
    /// plan on the ready screen; non-nil drives per-step transitions + voice
    /// announcements.
    let intervalController = IntervalController()
    /// User-selected target HR zone — the only public writable slot, used
    /// by the ready-screen picker. Get/set forwards to `lifecycle`.
    var targetZone: Int? {
        get { lifecycle.targetZone }
        set { lifecycle.targetZone = newValue }
    }

    // MARK: Dependencies

    let core: RecordingCore
    /// The GPS and barometer (built on first use), pedometer and foot pod,
    /// and this workout's readings of them.
    let sensors: WorkoutSensors

    func start(
        sport: Sport,
        source: HRSource = .strap,
        intervalPlan: IntervalPlan? = nil,
        thresholds: [WorkoutThreshold] = [],
        route: Route? = nil
    ) throws {
        try session.start(
            sport: sport, source: source, intervalPlan: intervalPlan,
            thresholds: thresholds, route: route
        )
    }

    /// Returns the render task; its value says whether the PDF was attached.
    @discardableResult
    static func scheduleCoachReportEmail(
        for session: HRVSession, settings: UserSettings, services: WorkoutServices
    ) -> Task<Bool, Never> {
        WorkoutSessionLifecycle.scheduleCoachReportEmail(for: session, settings: settings, services: services)
    }

    typealias HRSource = WorkoutSessionLifecycle.HRSource
    var startedLocation: WorkoutLocationManager? { sensors.startedLocation }
    var location: WorkoutLocationManager { sensors.location }
    var pedometer: WorkoutPedometer { sensors.pedometer }
    var footPod: FootPodManager { sensors.footPod }
    let watchBridge: WatchConnectivityBridge
    /// Voice coach — evaluates trigger rules on each tick and dispatches to
    /// TTS / haptics. Exposed so the recording UI can mute/quiet-mode it.
    let voiceCoach: WorkoutVoiceCoach
    /// Conversational voice chat. Primary AirPods loop — when the user taps
    /// Talk, they chat with the AI; when a trigger fires, it preempts this.
    let conversation: VoiceConversationController

    // MARK: Owned state, by job

    /// What the workout has recorded so far: beats, samples, power, the
    /// Watch-routed beats and the crash-backup cursors.
    let capture = WorkoutCapture()
    /// Strap and wrist HR freshness and the live pace.
    let signals = WorkoutLiveSignals()
    /// The thresholds, the start context and the live grade the coach reads.
    let coaching = WorkoutCoachingInputs()
    /// The course this workout follows, if any, and the user's place on it.
    let route = WorkoutRouteGuidance()

    // MARK: Parts, by job
    //
    // Each is built once, on first use, from the owned state and services
    // it reads; none holds the recorder.

    /// Pausing and resuming, by hand or automatically.
    @ObservationIgnored lazy var pauseControl = WorkoutPauseControl(lifecycle: lifecycle, sensors: sensors)

    /// The live context the coach is given.
    @ObservationIgnored lazy var aiContext = WorkoutAIContextBuilder(
        core: core, services: services, settingsProvider: settingsProvider,
        lifecycle: lifecycle, workoutHR: workoutHR, motion: motion, dfa: dfa,
        routeGuidance: route, sensors: sensors, capture: capture, signals: signals, coaching: coaching
    )

    /// The once-per-second loop over the live signals.
    @ObservationIgnored lazy var ticker = WorkoutTicker(
        core: core, services: services, settingsProvider: settingsProvider,
        lifecycle: lifecycle, workoutHR: workoutHR, motion: motion, dfa: dfa,
        intervalController: intervalController, routeGuidance: route, sensors: sensors,
        capture: capture, signals: signals, coaching: coaching,
        voiceCoach: voiceCoach, aiContext: aiContext, pauseControl: pauseControl
    )

    /// Start, the deferred start work, the archive, and the derived metrics.
    @ObservationIgnored lazy var session = WorkoutSessionLifecycle(
        core: core, services: services, settingsProvider: settingsProvider,
        conversation: conversation, lifecycle: lifecycle, workoutHR: workoutHR,
        motion: motion, dfa: dfa, intervalController: intervalController, routeGuidance: route,
        sensors: sensors, capture: capture, signals: signals, coaching: coaching,
        pauseControl: pauseControl, voiceCoach: voiceCoach, ticker: ticker, aiContext: aiContext
    )

    /// Read-only view of the captured per-second sample series. Exposed so
    /// the live recording view can render "avg HR", "current pace", "current
    /// METs" tiles without duplicating aggregation state.
    var samplesView: [WorkoutSample] { capture.workoutSamples }
    /// The pace shown and spoken now; nil while paused, stopped or not yet measured.
    var currentPaceSecPerKm: Double? { signals.currentPaceSecPerKm }
    /// The speed behind `currentPaceSecPerKm`, in m/s.
    var currentSpeedMS: Double? { signals.currentSpeedMS }

    // MARK: Init

    /// Reads user settings: the settings store in `services` unless a test
    /// hands in its own, so a test can drive this class without mutating
    /// global state.
    let settingsProvider: @MainActor () -> UserSettings

    /// Everything a workout reads beyond its constructor arguments.
    let services: WorkoutServices

    /// `location` keeps the test-injection seam (`WorkoutSensors`) but defers
    /// the production allocation to the first access (typically inside
    /// `start()`).
    ///
    /// The foot-pod manager and the Watch bridge come from `services`. The
    /// bridge must be the shared one: WCSession has one process-wide delegate,
    /// so a fresh bridge here would replace the delegate installed at launch
    /// and cut the Watch's Talk trigger for every later chat.
    init(
        core: RecordingCore,
        conversation: VoiceConversationController,
        services: WorkoutServices,
        location: WorkoutLocationManager? = nil,
        footPod: FootPodManager? = nil,
        settingsProvider: (@MainActor () -> UserSettings)? = nil
    ) {
        self.services = services
        let settingsManager = services.settingsManager
        self.settingsProvider = settingsProvider ?? { settingsManager.settings }
        self.core = core
        self.sensors = WorkoutSensors(location: location, footPod: footPod ?? services.footPodManager)
        let bridge = services.watchConnectivityBridge
        self.watchBridge = bridge
        let coach = WorkoutVoiceCoach(watchBridge: bridge)
        self.voiceCoach = coach
        self.conversation = conversation
        // Route spoken triggers through the shared conversation so they
        // preempt the live LLM / TTS cleanly instead of overlapping it.
        coach.conversation = conversation
    }

    // Expose the location manager so SwiftUI can observe distance/track.
    var locationManager: WorkoutLocationManager { location }
}
