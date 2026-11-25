import Foundation

/// A quick HRV reading: a few minutes of streamed beats from the strap,
/// analysed and archived when the countdown ends or the user stops it.
///
/// Built once by the collector over the parts it uses; a night in progress
/// refuses it (`StrapRecordingGuards`).
@MainActor
final class QuickReadingSession {
    let analysisPipeline: HRVAnalysisPipeline
    let archive: SessionArchive
    let archiveSignal: ArchiveSignal
    let artifactDetector: ArtifactDetector
    let baselineTracker: BaselineTracker
    let cloudSyncManager: CloudKitSyncManager
    let deviceStatus: DeviceStatus
    /// The training load a quick reading is scored with.
    let trainingQueries: TrainingHealthQueries
    let overnightStreaming: OvernightStreamingCoordinator
    let strapStream: StrapStreamSession
    let strapRecorder: StrapRecordingCoordinator
    let strapBattery: StrapBatteryUsageTracker
    let rawBackup: RawRRBackup
    let recordingStore: RecordingStateStore
    let scoring: SessionScoringContext
    let sessionState: SessionState
    let settingsManager: SettingsManager
    let strapGuards: StrapRecordingGuards
    let streamingLifecycle: StreamingLifecycle
    let streamingVerification: Verification

    init(
        analysisPipeline: HRVAnalysisPipeline,
        archive: SessionArchive,
        archiveSignal: ArchiveSignal,
        artifactDetector: ArtifactDetector,
        baselineTracker: BaselineTracker,
        cloudSyncManager: CloudKitSyncManager,
        deviceStatus: DeviceStatus,
        trainingQueries: TrainingHealthQueries,
        overnightStreaming: OvernightStreamingCoordinator,
        strapStream: StrapStreamSession,
        strapRecorder: StrapRecordingCoordinator,
        strapBattery: StrapBatteryUsageTracker,
        rawBackup: RawRRBackup,
        recordingStore: RecordingStateStore,
        scoring: SessionScoringContext,
        sessionState: SessionState,
        settingsManager: SettingsManager,
        strapGuards: StrapRecordingGuards,
        streamingLifecycle: StreamingLifecycle,
        streamingVerification: Verification
    ) {
        self.analysisPipeline = analysisPipeline
        self.archive = archive
        self.archiveSignal = archiveSignal
        self.artifactDetector = artifactDetector
        self.baselineTracker = baselineTracker
        self.cloudSyncManager = cloudSyncManager
        self.deviceStatus = deviceStatus
        self.trainingQueries = trainingQueries
        self.overnightStreaming = overnightStreaming
        self.strapStream = strapStream
        self.strapRecorder = strapRecorder
        self.strapBattery = strapBattery
        self.rawBackup = rawBackup
        self.recordingStore = recordingStore
        self.scoring = scoring
        self.sessionState = sessionState
        self.settingsManager = settingsManager
        self.strapGuards = strapGuards
        self.streamingLifecycle = streamingLifecycle
        self.streamingVerification = streamingVerification
    }
}
