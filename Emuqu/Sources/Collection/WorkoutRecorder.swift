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
    // `location` is NOT constructed eagerly in init: that
    // pulls in `CLLocationManager` + `CMAltimeter` synchronously on
    // the main thread. The Recorder is bound at Fitness-tab appear
    // (so the Watch's "Start" command can route through it on a cold
    // tab), but the user often hasn't tapped the in-app Start button
    // for many seconds — they're picking sport / target / strap.
    // Eagerly building the location stack adds 1–3 s of main-thread
    // work to the tab swap, so it is lazy: constructed on first access (start() for a
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

    /// Returns the render task; its value says whether the PDF was attached.
    @discardableResult
    static func scheduleCoachReportEmail(
        for session: HRVSession, settings: UserSettings, services: WorkoutServices
    ) -> Task<Bool, Never> {
        WorkoutSessionLifecycle.scheduleCoachReportEmail(for: session, settings: settings, services: services)
    }

    typealias HRSource = WorkoutSessionLifecycle.HRSource
    /// The location stack if something has built it (start() for a GPS
    /// sport, or a view that read `location`); nil otherwise. Pause, stop and
    /// finalize read it through this, so an indoor workout never builds the
    /// stack (the 1–3 s of main-thread work above) only to find it empty.
    var startedLocation: WorkoutLocationManager? { _injectedLocation ?? _lazyLocation }
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
    /// The live trends of `workoutSamples`, kept as the buffer grows
    /// (`WorkoutLiveTrends.Tally`), so the per-tick snapshot and each coach
    /// turn read them without scanning the whole buffer. Read through
    /// `syncedLiveTrends()` and `liveZoneBreakdown()`.
    @ObservationIgnored var liveTrendTally = WorkoutLiveTrends.Tally()
    /// True while the heart rate on display is the Apple Watch's wrist HR
    /// (read from its HealthKit workout session) rather than the strap's.
    /// Set by the tick's HR arbitration; a strap reading clears it.
    @ObservationIgnored var hrFromWrist = false
    /// The `offsetSec` of every row captured while `hrFromWrist` held, in
    /// capture order. Joins the HealthKit backfill offsets in
    /// `WorkoutMetadata.healthKitHROffsets` at finalize and is written to the
    /// crash backup with the samples, so the iCloud upload leaves those rows'
    /// heart rate out. Cleared when the ticker starts and once finalize reads it.
    @ObservationIgnored var wristHROffsets: [Int] = []

    /// Cursors for the per-tick track-backup snapshot. Compared each tick
    /// to skip the snapshot entirely when nothing new has arrived; while
    /// recording a sample row lands every unpaused second, so that skip
    /// mostly applies while paused, and `trackBackupRows` keeps the rest
    /// from re-mapping the whole track each tick.
    var trackBackupWatermark = TrackBackupWatermark()
    /// The crash backup's track and barometer rows, extended each snapshot
    /// by what arrived since the last one.
    @ObservationIgnored var trackBackupRows = TrackBackupRows()
    /// What the app knew at the start: history baselines, today's readiness,
    /// the training-load projection and race predictions. Filled once off the
    /// main thread after start; empty until then.
    var startContext = WorkoutStartContext()
    // Watch direct-strap fallback. When the user has paired
    // the chest strap to the Watch (not the iPhone) and the iPhone
    // runs the workout (e.g. phone in backpack), the Watch routes RR
    // + HR samples over WCSession via `WatchStrapConnector`. The
    // recorder consumes them HERE so:
    //   • currentHR shows real strap HR (not wrist HR — different sensor)
    //   • α1 / RMSSD / SDNN have real RR data to chew on
    //   • finalizeSession's RR series includes Watch-routed beats
    // Each tick drains the bridge's queue of Watch-routed beats
    // (`drainPendingWatchStrapRR`), so a slow tick never re-ingests a
    // payload it already consumed.
    /// Beats the Watch forwarded from the strap, this workout.
    var watchRouted = WatchRoutedBeats()
    /// Read-only view of the captured per-second sample series. Exposed so
    /// the live recording view can render "avg HR", "current pace", "current
    /// METs" tiles without duplicating aggregation state. Not observed
    /// directly — it changes every tick and SwiftUI will pick up the
    /// individual observable fields (currentHR, distanceMeters, ...) that
    /// themselves drive these helpers.
    var samplesView: [WorkoutSample] { workoutSamples }
    /// Live speed, fed once per tick by the ticker. Every live consumer of
    /// pace or speed reads it through `currentPaceSecPerKm` / `currentSpeedMS`
    /// (see `LivePaceEstimator` for how it is measured).
    var livePace = LivePaceEstimator()
    /// The pace shown and spoken now; nil while paused, stopped or not yet measured.
    var currentPaceSecPerKm: Double? { livePace.paceSecPerKm }
    /// The speed behind `currentPaceSecPerKm`, in m/s.
    var currentSpeedMS: Double? { livePace.speedMS }
    /// This workout's foot-pod distance, kept across pod resets. The pod
    /// reports cumulative distance from power-on (not from workout start),
    /// so its first reading is the baseline subtracted to get
    /// session-relative distance. Replaced with a fresh odometer at workout
    /// start, which also drops any distance banked across a pod reset.
    var footPodOdometer = FootPodOdometer()
    /// When the strap's own recording actually started for this workout.
    var deviceBackupArmedAt: Date?
    /// `PolarManager.streamingStartTime` of the stream this recorder's last
    /// strap workout started. RRCollector's overnight and quick sessions
    /// buffer on the same manager, so a stream still live while no workout
    /// records is this recorder's to stop only when its start matches.
    @ObservationIgnored var ownedStrapStreamStart: Date?
    /// The live broker's last snapshot, taken at stop before the broker is
    /// cleared, for finalize to store as the session's `aiContext`.
    var liveSnapshotAtStop: AssistantContext.LiveWorkoutSnapshot?

    /// Foot-pod odometers report lifetime distance, so the workout's share is
    /// the delta from whatever the pod read when this workout first saw it.
    /// A reading lower than the last one is a pod reset (power cycle or
    /// reconnect): the distance covered so far is banked and the new reading
    /// becomes the baseline, so the workout's distance never goes backwards.
    /// With no reading (pod disconnected) the distance so far is returned.
    func footPodDistanceMeters() -> Double {
        guard let reported = footPod.podReportedDistanceMeters else { return footPodOdometer.distanceMeters }
        return footPodOdometer.record(reported)
    }
    /// The pedometer step count as of the last tick that saw it change, and
    /// when. Lets the indoor auto-pause tell a stopped treadmill from the
    /// last walking cadence the pedometer leaves standing.
    @ObservationIgnored var lastPedometerStepAdvance: (count: Int, at: Date?) = (0, nil)
    /// The power readings counted so far, for the average and the peak.
    var power = WorkoutPowerTally()
    /// Wall-clock of the most recent strap-derived HR reading. When more
    /// than ~10 s stale, we fall back to the Watch's wrist HR.
    var lastStrapHRAt: Date?
    /// The user's thresholds for this workout and how long each is breached.
    var thresholds = WorkoutThresholdWatch()

    /// The course this workout follows, if any, and the user's place on it.
    let route = WorkoutRouteGuidance()

    /// The live grade, with the track and barometer state it was worked out
    /// from (`WorkoutAIContextBuilder.computeCurrentGradePercent`). Reset in
    /// `start()`.
    @ObservationIgnored var gradeMemo: GradeMemo?

    struct GradeMemo {
        struct Key: Equatable {
            let fixCount: Int
            let lastFixAt: Date?
            let baroCount: Int
        }

        let key: Key
        let grade: Double?
    }

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

    /// Reads user settings: the settings store in `services` unless a test
    /// hands in its own, so a test can drive this class without mutating
    /// global state.
    let settingsProvider: @MainActor () -> UserSettings

    /// Everything a workout reads beyond its constructor arguments.
    let services: WorkoutServices

    /// `location` keeps the test-injection seam but defers the
    /// production allocation. When the test passes a manager we honour it;
    /// otherwise the lazy getter constructs one on first access (typically
    /// inside `start()`).
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
        self._injectedLocation = location
        self.footPod = footPod ?? services.footPodManager
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

/// One workout's foot-pod distance from the pod's lifetime odometer readings.
/// The pod's counter restarts when it is power-cycled or reconnects, so a
/// reading below the previous one banks the distance covered so far and
/// starts a new baseline from that reading.
struct FootPodOdometer {
    /// The pod reading this stretch of the workout is measured from.
    private(set) var baselineMeters: Double?
    private var lastReadingMeters: Double?
    private var bankedMeters: Double = 0

    init(baselineMeters: Double? = nil) {
        self.baselineMeters = baselineMeters
    }

    /// Distance covered this workout as of the last reading.
    var distanceMeters: Double {
        guard let baselineMeters, let lastReadingMeters else { return bankedMeters }
        return bankedMeters + max(0, lastReadingMeters - baselineMeters)
    }

    /// Takes a new pod reading and returns the workout's distance.
    mutating func record(_ reading: Double) -> Double {
        if let lastReadingMeters, reading < lastReadingMeters {
            bankedMeters = distanceMeters
            baselineMeters = reading
        }
        if baselineMeters == nil { baselineMeters = reading }
        lastReadingMeters = reading
        return distanceMeters
    }
}
