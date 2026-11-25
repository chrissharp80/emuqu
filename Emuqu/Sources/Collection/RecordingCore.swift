import Foundation

/// The services every recorder of an `HRVSession` shares: the strap's parts,
/// Apple Health, the archive, iCloud sync, the raw RR backup, the analysis
/// pipeline and the signal that tells views the archive changed. HRV recordings
/// (`RRCollector`) and workouts (`WorkoutRecorder`) are both built over the
/// same instances, which the collector hands out as `recordingCore`.
///
/// Recorder-specific state (overnight device refinement, workout GPS) lives
/// on the recorders, not here.
@MainActor
struct RecordingCore {
    /// The strap's link (H10, Verity Sense): which strap, its live heart rate
    /// and feed health.
    let strapLink: StrapLinkState
    /// The strap's streaming session: start, stop and the buffered beats.
    let strapStream: StrapStreamSession
    /// What the strap's own memory is doing.
    let strapRecording: StrapRecordingState
    /// Recording to the strap's own memory, and downloads off it.
    let strapRecorder: StrapRecordingCoordinator
    /// Reconnecting to the last strap, and disconnecting.
    let strapDiscovery: StrapDiscoveryCoordinator
    /// The strap's battery-usage counters.
    let strapBattery: StrapBatteryUsageTracker
    /// The straps this app knows.
    let strapPairings: StrapPairings

    /// The Health store and settings HealthKit reads and exports run through.
    let healthAccess: HealthKitAccess

    /// Apple Health heart rate: the wrist-HR backfill and heart-rate recovery.
    let heartRate: HeartRateHealthQueries

    /// Training load for a finished workout's snapshot.
    let training: TrainingHealthQueries

    /// The store a workout export replaces its earlier copies through.
    let healthSampleStore: any HealthSampleStore

    /// On-disk session archive.
    let archive: SessionArchive

    /// CloudKit synchronization.
    let cloudSyncManager: CloudKitSyncManager

    /// Append-only raw RR backup. Shared across recorders so crash recovery
    /// (`SessionRecoveryService`) can enumerate everything the device has
    /// captured, HRV and workout, from one place. A workout appends its
    /// latest beats here about every 60 s, so an iOS kill or crash can be
    /// restored from disk.
    let rawBackup: RawRRBackup

    /// Shared HRV analysis pipeline: workouts use the same time-domain,
    /// frequency-domain and DFA machinery as overnight sessions; what differs
    /// is the window and downstream interpretation, not the analysis itself.
    let analysisPipeline: HRVAnalysisPipeline

    /// Bumped after a session is archived so the dashboard, trends and
    /// history re-render.
    let archiveSignal: ArchiveSignal

    /// Tells the views the archive changed.
    func notifyArchiveChanged() {
        archiveSignal.notifyChanged()
    }
}
