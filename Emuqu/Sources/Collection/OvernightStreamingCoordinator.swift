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
    let healthKit: HealthKitManager
    let morningCoordination: MorningCoordination
    let overnightRun: OvernightRunState
    let strapLink: StrapLinkState
    let strapLinkControl: StrapLinkControl
    let strapStream: StrapStreamSession
    let strapRecording: StrapRecordingState
    let strapRecorder: StrapRecordingCoordinator
    let strapDiscovery: StrapDiscoveryCoordinator
    let strapBattery: StrapBatteryUsageTracker
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
        healthKit: HealthKitManager,
        morningCoordination: MorningCoordination,
        overnightRun: OvernightRunState,
        strapLink: StrapLinkState,
        strapLinkControl: StrapLinkControl,
        strapStream: StrapStreamSession,
        strapRecording: StrapRecordingState,
        strapRecorder: StrapRecordingCoordinator,
        strapDiscovery: StrapDiscoveryCoordinator,
        strapBattery: StrapBatteryUsageTracker,
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
        self.healthKit = healthKit
        self.morningCoordination = morningCoordination
        self.overnightRun = overnightRun
        self.strapLink = strapLink
        self.strapLinkControl = strapLinkControl
        self.strapStream = strapStream
        self.strapRecording = strapRecording
        self.strapRecorder = strapRecorder
        self.strapDiscovery = strapDiscovery
        self.strapBattery = strapBattery
        self.rawBackup = rawBackup
        self.recordingStore = recordingStore
        self.services = services
        self.sessionState = sessionState
        self.settingsManager = settingsManager
        self.streamingLifecycle = streamingLifecycle
        self.morning = morning
    }

}
