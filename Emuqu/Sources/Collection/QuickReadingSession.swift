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
    let healthKit: HealthKitManager
    let overnightStreaming: OvernightStreamingCoordinator
    let polarManager: PolarManager
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
        healthKit: HealthKitManager,
        overnightStreaming: OvernightStreamingCoordinator,
        polarManager: PolarManager,
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
        self.healthKit = healthKit
        self.overnightStreaming = overnightStreaming
        self.polarManager = polarManager
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
