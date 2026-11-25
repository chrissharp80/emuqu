import Foundation

/// Overnight capture in bluetooth-central (streaming) mode: starting the
/// stream, the keep-alive timer, reconnect handling, and the merge of the
/// strap's own internal recording into the streamed night, and the gather
/// that ends it (`gatherOvernightData`, RRCollector+OvernightGather).
///
/// Built once by the collector over the parts it uses; it hands the gathered
/// night to the morning pipeline, and session control calls it.
@MainActor
final class OvernightStreamingCoordinator {
    let archive: SessionArchive
    let baselineTracker: BaselineTracker
    let cloudSyncManager: CloudKitSyncManager
    /// Starts the Apple Health sleep observer for the night.
    let healthWrites: HealthWriteAndObserve
    /// Apple Health sleep, read while the strap's night downloads.
    let sleepQueries: SleepHealthQueries
    /// Starts the Apple Health vitals observers for the night.
    let vitalsQueries: VitalsHealthQueries
    let morningCoordination: MorningCoordination
    let overnightRun: OvernightRunState
    let polarManager: PolarManager
    let rawBackup: RawRRBackup
    let recordingStore: RecordingStateStore
    let services: CollectorServices
    let sessionState: SessionState
    let settingsManager: SettingsManager
    let streamingLifecycle: StreamingLifecycle
    let morning: MorningSessionPipeline

    init(
        archive: SessionArchive,
        baselineTracker: BaselineTracker,
        cloudSyncManager: CloudKitSyncManager,
        healthWrites: HealthWriteAndObserve,
        sleepQueries: SleepHealthQueries,
        vitalsQueries: VitalsHealthQueries,
        morningCoordination: MorningCoordination,
        overnightRun: OvernightRunState,
        polarManager: PolarManager,
        rawBackup: RawRRBackup,
        recordingStore: RecordingStateStore,
        services: CollectorServices,
        sessionState: SessionState,
        settingsManager: SettingsManager,
        streamingLifecycle: StreamingLifecycle,
        morning: MorningSessionPipeline
    ) {
        self.archive = archive
        self.baselineTracker = baselineTracker
        self.cloudSyncManager = cloudSyncManager
        self.healthWrites = healthWrites
        self.sleepQueries = sleepQueries
        self.vitalsQueries = vitalsQueries
        self.morningCoordination = morningCoordination
        self.overnightRun = overnightRun
        self.polarManager = polarManager
        self.rawBackup = rawBackup
        self.recordingStore = recordingStore
        self.services = services
        self.sessionState = sessionState
        self.settingsManager = settingsManager
        self.streamingLifecycle = streamingLifecycle
        self.morning = morning
    }

}
