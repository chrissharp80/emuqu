import Foundation

/// The controls of a night in progress: pausing it so it can be split and
/// rejoined, resuming it, finishing it from a pause, discarding a recording,
/// and the paused night the Record screen offers to continue.
///
/// Built once by the collector over the parts it uses. It calls overnight
/// streaming and the morning pipeline; the bindings (`CollectorBindings`)
/// call it when the battery runs critically low or a reconnect runs out.
@MainActor
final class CollectorSessionControl {
    let archive: SessionArchive
    let archiveSignal: ArchiveSignal
    let baselineTracker: BaselineTracker
    let cloudSyncManager: CloudKitSyncManager
    let deviceStatus: DeviceStatus
    let morningCoordination: MorningCoordination
    let overnightRun: OvernightRunState
    let strapLink: StrapLinkState
    let strapStream: StrapStreamSession
    let strapRecorder: StrapRecordingCoordinator
    let strapBattery: StrapBatteryUsageTracker
    let rawBackup: RawRRBackup
    let recordingStore: RecordingStateStore
    let services: CollectorServices
    let sessionState: SessionState
    let settingsManager: SettingsManager
    let strapGuards: StrapRecordingGuards
    let streamingLifecycle: StreamingLifecycle
    let morning: MorningSessionPipeline
    let overnightStreaming: OvernightStreamingCoordinator

    init(
        archive: SessionArchive,
        archiveSignal: ArchiveSignal,
        baselineTracker: BaselineTracker,
        cloudSyncManager: CloudKitSyncManager,
        deviceStatus: DeviceStatus,
        morningCoordination: MorningCoordination,
        overnightRun: OvernightRunState,
        strapLink: StrapLinkState,
        strapStream: StrapStreamSession,
        strapRecorder: StrapRecordingCoordinator,
        strapBattery: StrapBatteryUsageTracker,
        rawBackup: RawRRBackup,
        recordingStore: RecordingStateStore,
        services: CollectorServices,
        sessionState: SessionState,
        settingsManager: SettingsManager,
        strapGuards: StrapRecordingGuards,
        streamingLifecycle: StreamingLifecycle,
        morning: MorningSessionPipeline,
        overnightStreaming: OvernightStreamingCoordinator
    ) {
        self.archive = archive
        self.archiveSignal = archiveSignal
        self.baselineTracker = baselineTracker
        self.cloudSyncManager = cloudSyncManager
        self.deviceStatus = deviceStatus
        self.morningCoordination = morningCoordination
        self.overnightRun = overnightRun
        self.strapLink = strapLink
        self.strapStream = strapStream
        self.strapRecorder = strapRecorder
        self.strapBattery = strapBattery
        self.rawBackup = rawBackup
        self.recordingStore = recordingStore
        self.services = services
        self.sessionState = sessionState
        self.settingsManager = settingsManager
        self.strapGuards = strapGuards
        self.streamingLifecycle = streamingLifecycle
        self.morning = morning
        self.overnightStreaming = overnightStreaming
    }

}
