import Foundation

/// Everything the app does to rescue a recording that did not end cleanly.
///
/// Interrupted workouts, sessions still sitting on the strap, corrupted files,
/// cloud backups, the trash, and the paused-state restore path.
///
/// Built once by the collector over the parts it uses; it calls the morning
/// pipeline and device recording, and session control calls it.
@MainActor
final class SessionRecoveryCoordinator {
    /// The recovery service, once `recoveryService` has built it.
    var cachedRecoveryService: SessionRecoveryService?
    let archive: SessionArchive
    let archiveSignal: ArchiveSignal
    let artifactDetector: ArtifactDetector
    let baselineTracker: BaselineTracker
    let cloudSyncManager: CloudKitSyncManager
    let healthKit: HealthKitManager
    let morningCoordination: MorningCoordination
    let overnightRun: OvernightRunState
    let strapRecorder: StrapRecordingCoordinator
    let rawBackup: RawRRBackup
    let recordingStore: RecordingStateStore
    let scoring: SessionScoringContext
    let services: CollectorServices
    let sessionState: SessionState
    let settingsManager: SettingsManager
    let strapGuards: StrapRecordingGuards
    let streamingLifecycle: StreamingLifecycle
    let windowSelector: WindowSelector
    let deviceRecording: DeviceRecordingSession
    let morning: MorningSessionPipeline

    init(
        archive: SessionArchive,
        archiveSignal: ArchiveSignal,
        artifactDetector: ArtifactDetector,
        baselineTracker: BaselineTracker,
        cloudSyncManager: CloudKitSyncManager,
        healthKit: HealthKitManager,
        morningCoordination: MorningCoordination,
        overnightRun: OvernightRunState,
        strapRecorder: StrapRecordingCoordinator,
        rawBackup: RawRRBackup,
        recordingStore: RecordingStateStore,
        scoring: SessionScoringContext,
        services: CollectorServices,
        sessionState: SessionState,
        settingsManager: SettingsManager,
        strapGuards: StrapRecordingGuards,
        streamingLifecycle: StreamingLifecycle,
        windowSelector: WindowSelector,
        deviceRecording: DeviceRecordingSession,
        morning: MorningSessionPipeline
    ) {
        self.archive = archive
        self.archiveSignal = archiveSignal
        self.artifactDetector = artifactDetector
        self.baselineTracker = baselineTracker
        self.cloudSyncManager = cloudSyncManager
        self.healthKit = healthKit
        self.morningCoordination = morningCoordination
        self.overnightRun = overnightRun
        self.strapRecorder = strapRecorder
        self.rawBackup = rawBackup
        self.recordingStore = recordingStore
        self.scoring = scoring
        self.services = services
        self.sessionState = sessionState
        self.settingsManager = settingsManager
        self.strapGuards = strapGuards
        self.streamingLifecycle = streamingLifecycle
        self.windowSelector = windowSelector
        self.deviceRecording = deviceRecording
        self.morning = morning
    }

}
