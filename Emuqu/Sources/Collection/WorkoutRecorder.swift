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
    var phase: Phase { lifecycle.phase }
    var currentSession: HRVSession? { lifecycle.currentSession }
    var finishedSession: HRVSession? { lifecycle.finishedSession }
    var elapsedSeconds: Int { lifecycle.elapsedSeconds }
    /// HR metrics (currentHR, peakHR, beatCount) live in a dedicated
    /// sub-observable so HR-only displays aren't invalidated by motion or
    /// lifecycle updates. Getters forward
    /// `recorder.currentHR` / `peakHR` / `beatCount` reads through.
    /// Named `workoutHR` (not `hr`) to avoid shadowing local `hr` vars in
    /// tick code.
    let workoutHR = WorkoutHR()
    var currentHR: Int? { workoutHR.currentHR }
    var peakHR: Int { workoutHR.peakHR }
    var beatCount: Int { workoutHR.beatCount }
    /// Motion metrics (GPS + pedometer + foot pod) live in a
    /// dedicated sub-observable so the live-map view and the stat-chip
    /// view can subscribe to only the signal they actually use: the 1 Hz
    /// tick fires only the motion publisher instead of invalidating the
    /// entire recorder subscription.
    ///
    /// Getters below forward `recorder.distanceMeters` etc.
    /// reads through to `motion`.
    let motion = WorkoutMotion()
    var distanceMeters: Double { motion.distanceMeters }
    var elevationGainMeters: Double { motion.elevationGainMeters }
    var liveTrack: [CLLocation] { motion.liveTrack }
    var stepCount: Int { motion.stepCount }
    var cadenceStepsPerMin: Double? { motion.cadenceStepsPerMin }
    var powerWatts: Int? { motion.powerWatts }
    var footPodActive: Bool { motion.footPodActive }
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
    /// Which HR source is live for this workout. Read through to `lifecycle`.
    var activeHRSource: HRSource { lifecycle.activeHRSource }

    // MARK: Dependencies

    let core: RecordingCore
    // `location` is NOT constructed eagerly in init: that
    // pulls in `CLLocationManager` + `CMAltimeter` synchronously on
    // the main thread. The Recorder is bound at Fitness-tab appear
    // (so the Watch's "Start" command can route through it on a cold
    // tab), but the user often hasn't tapped the in-app Start button
    // for many seconds — they're picking sport / target / strap.
    // Eagerly building the location stack adds 1–3 s of main-thread
    // work to the tab swap; a user-reported freeze when going
    // (strap pair) → (voice chat) → (Fitness tab + Start) bottomed
    // out here. So it is lazy: constructed on first access (start() for a
    // GPS sport, or any view that reads `locationManager`). By that
    // point the user has explicitly committed to a workout.
    var _injectedLocation: WorkoutLocationManager?
    var _lazyLocation: WorkoutLocationManager?

    /// Start, pause, resume, archive, and the derived metrics.
    var session: WorkoutSessionLifecycle {
        WorkoutSessionLifecycle(recorder: self)
    }

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

    func pause(isAuto: Bool = false) { session.pause(isAuto: isAuto) }
    func resume() { session.resume() }
    func archive(session archived: HRVSession) async { await session.archive(session: archived) }
    func startKeepAlives(sport: Sport, hasIntervalPlan: Bool) {
        session.startKeepAlives(sport: sport, hasIntervalPlan: hasIntervalPlan)
    }

    func buildAiContextSnapshot(
        _ snap: AssistantContext.LiveWorkoutSnapshot, sport: Sport, stopDate: Date
    ) -> [String: String] {
        session.buildAiContextSnapshot(snap, sport: sport, stopDate: stopDate)
    }

    /// Pure computations — no recorder state — so they forward to the type.
    static func computeNormalizedPower(samples: [WorkoutSample]) -> Double? {
        WorkoutSessionLifecycle.computeNormalizedPower(samples: samples)
    }

    nonisolated static func estimateMETs(
        sport: Sport, paceSecPerKm: Double?, heartRate: Int?, userMaxHR: Int
    ) -> Double? {
        WorkoutSessionLifecycle.estimateMETs(
            sport: sport, paceSecPerKm: paceSecPerKm, heartRate: heartRate, userMaxHR: userMaxHR
        )
    }

    /// Two overloads rather than a defaulted parameter: repeating the default
    /// here would be a second `AppDependencies.current.app.settingsManager` reference for a value the
    /// moved function already supplies.
    static func scheduleCoachReportEmail(for session: HRVSession) {
        WorkoutSessionLifecycle.scheduleCoachReportEmail(for: session)
    }

    static func scheduleCoachReportEmail(for session: HRVSession, settings: UserSettings) {
        WorkoutSessionLifecycle.scheduleCoachReportEmail(for: session, settings: settings)
    }

    typealias HRSource = WorkoutSessionLifecycle.HRSource
    var location: WorkoutLocationManager {
        if let injected = _injectedLocation { return injected }
        if let cached = _lazyLocation { return cached }
        let fresh = WorkoutLocationManager()
        _lazyLocation = fresh
        return fresh
    }
    let pedometer = WorkoutPedometer()
    /// Optional foot pod / running power meter. Shared singleton so the
    /// Settings screen can pair it outside a workout and have the pairing
    /// still be there when a workout starts. When connected, foot-pod
    /// readings take priority over GPS + pedometer.
    let footPod: FootPodManager
    let watchBridge: WatchConnectivityBridge
    /// Voice coach — evaluates trigger rules on each tick and dispatches to
    /// TTS / haptics. Exposed so the recording UI can mute/quiet-mode it.
    let voiceCoach: WorkoutVoiceCoach
    /// Conversational voice chat. Primary AirPods loop — when the user taps
    /// Talk, they chat with the AI; when a trigger fires, it preempts this.
    let conversation: VoiceConversationController

    // MARK: Private state

    var collectedPoints: [RRPoint] = []
    var sessionStartDate: Date?

    /// Open correlation scope for the workout in progress, `nil` when idle.
    /// Plumbing lives in `WorkoutRecorder+Correlation.swift`.
    var logCorrelation: LogCorrelation.Token?
    @ObservationIgnored var tickTimer: Timer?
    @ObservationIgnored var hrSubscription: ObservationHandle?
    var lastIngestedPointCount = 0
    /// Per-second time series captured live. Persisted into
    /// `WorkoutMetadata.samples` on finalize so post-summary charts and
    /// per-row export columns don't have to reconstruct from aggregates.
    var workoutSamples: [WorkoutSample] = []

    /// Cursors for the per-tick track-backup snapshot.
    /// Without them every tick `.map`s the full `location.track` array
    /// into a `[PersistedFix]` snapshot before the detached backup task
    /// can short-circuit; on a 90-minute walk that's ~5,400 ×
    /// per-tick copies of a growing array (~24 MB cumulative allocation).
    /// We compare counts and skip the snapshot entirely on ticks
    /// where nothing new has arrived.
    var trackBackupWatermark = TrackBackupWatermark()
    /// Cached at workout start for fast per-tick lookup in
    /// `buildContext`. Computed off the main thread; nil/empty until
    /// the background task lands. See `WorkoutHistoryBaselines`.
    var cachedHistoricalBaselines: WorkoutHistoryBaselines = .empty
    /// Readiness snapshot grabbed from the morning HRV
    /// session at workout start. Frozen for the duration of the
    /// workout; the AI context surfaces it as `todayRecoveryScore`,
    /// `todayTrainingReadiness`, and `todayATL/CTL/TSB`. Nil entries
    /// when no morning reading exists yet today.
    var cachedTodayReadiness: ReadinessSnapshot = .empty

    struct ReadinessSnapshot: Equatable {
        let recoveryScore: Double?
        let trainingReadiness: Double?
        let atl: Double?
        let ctl: Double?
        let tsb: Double?

        static let empty = ReadinessSnapshot(
            recoveryScore: nil, trainingReadiness: nil,
            atl: nil, ctl: nil, tsb: nil
        )
    }

    /// Forward-looking training-load forecast, captured
    /// alongside `cachedTodayReadiness` at workout start. Two surfaces
    /// the AI uses: rest-recovery days, and steady-state TSB if today's
    /// load repeats. Both nil when there's no morning training context.
    struct TrainingProjectionSnapshot: Equatable {
        let daysUntilFresh: Int?
        let tsbTomorrowSteadyState: Double?

        static let empty = TrainingProjectionSnapshot(
            daysUntilFresh: nil, tsbTomorrowSteadyState: nil
        )
    }
    var cachedTrainingProjection: TrainingProjectionSnapshot = .empty
    /// Riegel race-time predictions captured at workout
    /// start (key: distance in meters → predicted total seconds).
    /// Empty when no comparable history exists.
    var cachedRacePredictionsByDistance: [Double: Double] = [:]
    /// Watch direct-strap fallback. When the user has paired
    /// the chest strap to the Watch (not the iPhone) and the iPhone
    /// runs the workout (e.g. phone in backpack), the Watch routes RR
    /// + HR samples over WCSession via `WatchStrapConnector`. The
    /// recorder consumes them HERE so:
    ///   • currentHR shows real strap HR (not wrist HR — different sensor)
    ///   • α1 / RMSSD / SDNN have real RR data to chew on
    ///   • finalizeSession's RR series includes Watch-routed beats
    /// `lastWatchStrapAt` is a date stamp on `WatchConnectivityBridge`;
    /// we dedupe by remembering the last one we've consumed so a slow
    /// tick doesn't re-ingest the same payload.
    var lastConsumedWatchStrapAt: Date?
    /// When we last produced beats via the Watch-routed
    /// strap path. Lives separately from `lastStrapHRAt` (which is the
    /// iPhone-paired Polar's freshness gate) so the wrist-HR fallback
    /// can tell "Polar dropped, Watch is carrying it" from "both dropped,
    /// fall through to wrist."
    var lastWatchRoutedHRAt: Date?
    /// Cumulative session-relative ms used to assign `RRPoint.t_ms` to
    /// synthesized Watch-routed beats. Starts at 0 at workout start
    /// and advances by each consumed RR interval.
    var watchRoutedCumulativeMs: Int64 = 0
    /// All RR points that arrived via the Watch fallback path. Merged
    /// into the canonical RR series at `finalizeSession()`. Kept
    /// separately so we can also see "did this workout depend on the
    /// fallback?" in diagnostics.
    var watchRoutedRRBuffer: [RRPoint] = []
    /// Read-only view of the captured per-second sample series. Exposed so
    /// the live recording view can render "avg HR", "current pace", "current
    /// METs" tiles without duplicating aggregation state. Not observed
    /// directly — it changes every tick and SwiftUI will pick up the
    /// individual observable fields (currentHR, distanceMeters, ...) that
    /// themselves drive these helpers.
    var samplesView: [WorkoutSample] { workoutSamples }
    /// Cumulative distance at the previous tick — used to derive instantaneous
    /// pace from the delta without re-scanning the track on every tick.
    var lastSampleDistance: Double = 0
    /// Wall-clock of the last captured sample, for pace calculation.
    var lastSampleAt: Date?
    /// Foot-pod session-start distance. The pod reports cumulative distance
    /// from power-on (not from workout start), so we capture its value at
    /// first reading and subtract to get session-relative distance.
    var footPodStartDistanceMeters: Double?
    /// When the strap's own recording actually started for this workout.
    var deviceBackupArmedAt: Date?

    /// Foot-pod odometers report lifetime distance, so the workout's share is
    /// the delta from whatever the pod read when this workout first saw it.
    func footPodDistanceMeters() -> Double {
        guard let reported = footPod.podReportedDistanceMeters else { return 0 }
        if footPodStartDistanceMeters == nil { footPodStartDistanceMeters = reported }
        return max(0, reported - (footPodStartDistanceMeters ?? reported))
    }
    /// Running tally of power samples for average-power computation.
    var powerSampleSum: Int = 0
    var powerSampleCount: Int = 0
    var maxPowerObserved: Int = 0
    /// Wall-clock of the most recent strap-derived HR reading. When more
    /// than ~10 s stale, we fall back to the Watch's wrist HR.
    var lastStrapHRAt: Date?
    /// Whether BackgroundAudioManager was started by THIS recorder. Used so
    /// stop() only tears down audio it put up — we never stomp on someone
    /// else's running audio session (e.g. overnight streaming).
    var didStartBackgroundAudio = false

    /// User-declared physiological constraints for ambient coaching. Set
    /// pre-workout via the start flow; the trigger engine reads these
    /// alongside its built-in rules and fires breach cues when the metric
    /// stays outside the band past `debounceSec`.
    var userThresholds: [WorkoutThreshold] = []

    /// Optional course the user bound before starting. Loaded from a GPX
    /// file via the start flow's route picker. When non-nil, every tick
    /// computes a fresh `RouteProgress` so the AI coach knows the climbs
    /// ahead and can pre-warn ("big climb in 400 m, save power"). Kept
    /// optional because route-aware coaching is opt-in — most workouts
    /// don't need it.
    var plannedRoute: Route? {
        didSet { lastRouteProgressIndex = nil }
    }
    /// The route point the last tick projected onto. Passed back to
    /// `RouteProgress.compute` so a route that loops back near itself keeps
    /// the user's place instead of jumping to the closer leg.
    @ObservationIgnored var lastRouteProgressIndex: Int?

    /// True when `plannedRoute` was assigned by the recogniser matching a
    /// route the user explicitly saved to their library. Distinct from a
    /// hand-loaded GPX. Drives the "Following Daily 1" banner.
    var plannedRouteWasAutoDetected: Bool = false

    /// When the recognised match was a reverse-direction fit (user is
    /// walking / running the saved route backwards today), the live UI +
    /// AI surface this so the climb cues read right and the user knows
    /// the app understood the directional swap.
    var plannedRouteDirection: RouteLibrary.Direction = .forward

    /// Whether we've already attempted route auto-detection this session.
    /// One-shot — fires once after `RouteLibrary.detectionTriggerMeters`
    /// of movement and never re-runs (a route that doesn't match the
    /// first 500 m never will). Reset in `start()`.
    var routeDetectionAttempted: Bool = false

    /// Per-threshold breach duration in seconds. Counts up while breached,
    /// resets to 0 the moment the metric comes back inside the band. The
    /// trigger engine compares this to each threshold's debounceSec to
    /// decide whether to fire a cue. Indexed by threshold ID.
    var thresholdBreachSec: [UUID: Int] = [:]

    // MARK: Auto-pause / auto-resume counters
    //
    // Auto-pause fires after a rolling window of "no movement" ticks and
    // auto-resume fires after a shorter window of "moving again" ticks.
    // Separate counters rather than one signed integer because the
    // thresholds are different and conflating the two made the transition
    // feel draggy — resume felt sluggish because the decrement from "−15
    // stationary" to zero took its own 15 ticks.
    /// Counters and thresholds both live in `AutoPauseDetector`.
    var autoPause = AutoPauseDetector()

    // MARK: Init

    /// Reads user settings. Defaults to the shared store so behaviour is
    /// unchanged; injecting lets a test drive this class without mutating
    /// global state. Same shape `HealthKitManager` uses. Used instead of direct
    /// `AppDependencies.current.app.settingsManager.settings` reads.
    let settingsProvider: @MainActor () -> UserSettings

    /// `location` keeps the test-injection seam but defers the
    /// production allocation. When the test passes a manager we honour it;
    /// otherwise the lazy getter constructs one on first access (typically
    /// inside `start()`).
    ///
    /// `AppDependencies.current.collection.footPodManager` is main-actor-isolated, so resolving the default
    /// inside the body (where the init is also MainActor) avoids Swift 6's
    /// "default-arg evaluates in nonisolated context" error that would fire if
    /// we wrote `= AppDependencies.current.collection.footPodManager` directly in the parameter list.
    ///
    /// `AppDependencies.current.services.watchConnectivityBridge` is a shared singleton: WCSession has
    /// one process-wide delegate, so we must not construct a fresh bridge here
    /// — that would replace the delegate installed at app boot (and kill the
    /// Watch → phone Talk trigger for any subsequent chat).
    init(
        core: RecordingCore,
        conversation: VoiceConversationController,
        location: WorkoutLocationManager? = nil,
        footPod: FootPodManager? = nil,
        settingsProvider: @escaping @MainActor () -> UserSettings = { AppDependencies.current.app.settingsManager.settings }
    ) {
        self.settingsProvider = settingsProvider
        self.core = core
        self._injectedLocation = location
        self.footPod = footPod ?? AppDependencies.current.collection.footPodManager
        let bridge = AppDependencies.current.services.watchConnectivityBridge
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
