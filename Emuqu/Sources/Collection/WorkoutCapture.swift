import Foundation

/// What a workout has recorded so far: the RR beats, the per-second samples
/// and their live trends, the power readings, the Watch-routed beats, and
/// how much of the track the crash backup already holds. The ticker writes
/// it each second; start clears it and finalize reads it.
@Observable
@MainActor
final class WorkoutCapture {
    /// The RR series stop gathered for finalize (stream, Watch-routed beats
    /// and the strap's own recording merged).
    var collectedPoints: [RRPoint] = []
    /// How many of the strap stream's beats the live DFA has been handed.
    var lastIngestedPointCount = 0
    /// Per-second time series captured live. Persisted into
    /// `WorkoutMetadata.samples` on finalize so post-summary charts and
    /// per-row export columns don't have to reconstruct from aggregates.
    var workoutSamples: [WorkoutSample] = []
    /// The live trends of `workoutSamples`, kept as the buffer grows
    /// (`WorkoutLiveTrends.Tally`), so the per-tick snapshot and each coach
    /// turn read them without scanning the whole buffer. Read through
    /// `syncedLiveTrends()` and `liveZoneBreakdown(userMaxHR:)`.
    @ObservationIgnored var liveTrendTally = WorkoutLiveTrends.Tally()
    /// The `offsetSec` of every row captured while the heart rate on display
    /// was the Watch's wrist HR (`WorkoutLiveSignals.hrFromWrist`), in capture
    /// order. Joins the HealthKit backfill offsets in
    /// `WorkoutMetadata.healthKitHROffsets` at finalize and is written to the
    /// crash backup with the samples, so the iCloud upload leaves those rows'
    /// heart rate out. Cleared when the ticker starts and once finalize reads it.
    @ObservationIgnored var wristHROffsets: [Int] = []
    /// The oldest rows of `workoutSamples` and `wristHROffsets` were dropped
    /// from memory (`WorkoutTicker.capWorkoutSampleMemory`). The crash backup
    /// still holds them, and finalize reads them back from it
    /// (`WorkoutRecorder.fullSampleHistory`). Cleared at each start.
    @ObservationIgnored var sampleHeadTrimmed = false
    /// Cursors for the per-tick track-backup snapshot. Compared each tick
    /// to skip the snapshot entirely when nothing new has arrived; while
    /// recording a sample row lands every unpaused second, so that skip
    /// mostly applies while paused, and `trackBackupRows` keeps the rest
    /// from re-mapping the whole track each tick.
    var trackBackupWatermark = TrackBackupWatermark()
    /// The crash backup's track and barometer rows, extended each snapshot
    /// by what arrived since the last one.
    @ObservationIgnored var trackBackupRows = TrackBackupRows()
    /// How many pause events (`PauseTimeline.events`) each workout has handed
    /// the crash backup, so a tick without a new pause or resume skips it.
    @ObservationIgnored var pauseEventsBackedUp: [UUID: Int] = [:]
    /// The power readings counted so far, for the average and the peak.
    var power = WorkoutPowerTally()
    /// Beats the Watch forwarded from the strap, this workout. When the user
    /// has paired the chest strap to the Watch (not the iPhone) and the
    /// iPhone runs the workout, the Watch routes RR + HR samples over
    /// WCSession via `WatchStrapConnector`; each tick drains the bridge's
    /// queue of them (`drainPendingWatchStrapRR`), so a slow tick never
    /// re-ingests a payload it already consumed, and finalize merges them
    /// into the RR series.
    var watchRouted = WatchRoutedBeats()
    /// The distance on display at the stop, when the stop was dated earlier
    /// than it reached the phone (`WorkoutRecorder.endRecording(at:now:)`):
    /// the pedometer, foot-pod and erg counters kept running past it and hold
    /// no history, so finalize caps them at this. Nil for a stop dated now.
    var distanceAtEarlyStop: Double?

    /// Time in zone of the buffer for the user's max HR, from the tally
    /// (`WorkoutLiveTrends.Tally.zoneBreakdown`).
    func liveZoneBreakdown(userMaxHR: Int) -> WorkoutZoneBreakdown {
        liveTrendTally.catchUp(to: workoutSamples)
        return liveTrendTally.zoneBreakdown(of: workoutSamples, userMaxHR: userMaxHR)
    }

    /// The live trend tally brought up to the sample buffer.
    func syncedLiveTrends() -> WorkoutLiveTrends.Tally {
        liveTrendTally.catchUp(to: workoutSamples)
        return liveTrendTally
    }
}
