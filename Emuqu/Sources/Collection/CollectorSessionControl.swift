import Foundation

/// Driving a capture session while it runs: the short streaming sessions, the
/// pause/resume path that lets a night be split and rejoined, and the Combine
/// bindings that republish the sub-objects' state for the views.
///
/// All three live together because pause/resume and the streaming session are
/// the same state machine seen from two directions, and the bindings republish
/// exactly what those two change.
///
/// The bindings' observation handlers hold these controls weakly
/// (`[weak owner = self]`, and `ObservationLoop` holds its owner weakly):
/// they outlive the call that registers them, so a strong capture would keep
/// the controls alive; each no-ops once they are gone.
///
/// Built once by the collector over the parts it uses, and the top of the
/// coordinators: it calls the morning pipeline, overnight streaming and
/// recovery, and none of them calls it.
@MainActor
final class CollectorSessionControl {
    let analysisPipeline: HRVAnalysisPipeline
    let archive: SessionArchive
    let archiveSignal: ArchiveSignal
    let artifactDetector: ArtifactDetector
    let baselineArchiveSync: BaselineArchiveSync
    let baselineRebuild: BaselineRebuilder
    let baselineTracker: BaselineTracker
    let cloudSyncManager: CloudKitSyncManager
    let deviceStatus: DeviceStatus
    let healthKit: HealthKitManager
    let liveHRVMirror: LiveHRVMirror
    let morningCoordination: MorningCoordination
    let notificationObservers: NotificationTokens
    let overnightRun: OvernightRunState
    let polarManager: PolarManager
    let rawBackup: RawRRBackup
    let recordingStore: RecordingStateStore
    let scoring: SessionScoringContext
    let services: CollectorServices
    let sessionState: SessionState
    let settingsManager: SettingsManager
    let strapGuards: StrapRecordingGuards
    let streamingLifecycle: StreamingLifecycle
    let streamingVerification: Verification
    let morning: MorningSessionPipeline
    let overnightStreaming: OvernightStreamingCoordinator
    let recovery: SessionRecoveryCoordinator

    init(
        analysisPipeline: HRVAnalysisPipeline,
        archive: SessionArchive,
        archiveSignal: ArchiveSignal,
        artifactDetector: ArtifactDetector,
        baselineArchiveSync: BaselineArchiveSync,
        baselineRebuild: BaselineRebuilder,
        baselineTracker: BaselineTracker,
        cloudSyncManager: CloudKitSyncManager,
        deviceStatus: DeviceStatus,
        healthKit: HealthKitManager,
        liveHRVMirror: LiveHRVMirror,
        morningCoordination: MorningCoordination,
        notificationObservers: NotificationTokens,
        overnightRun: OvernightRunState,
        polarManager: PolarManager,
        rawBackup: RawRRBackup,
        recordingStore: RecordingStateStore,
        scoring: SessionScoringContext,
        services: CollectorServices,
        sessionState: SessionState,
        settingsManager: SettingsManager,
        strapGuards: StrapRecordingGuards,
        streamingLifecycle: StreamingLifecycle,
        streamingVerification: Verification,
        morning: MorningSessionPipeline,
        overnightStreaming: OvernightStreamingCoordinator,
        recovery: SessionRecoveryCoordinator
    ) {
        self.analysisPipeline = analysisPipeline
        self.archive = archive
        self.archiveSignal = archiveSignal
        self.artifactDetector = artifactDetector
        self.baselineArchiveSync = baselineArchiveSync
        self.baselineRebuild = baselineRebuild
        self.baselineTracker = baselineTracker
        self.cloudSyncManager = cloudSyncManager
        self.deviceStatus = deviceStatus
        self.healthKit = healthKit
        self.liveHRVMirror = liveHRVMirror
        self.morningCoordination = morningCoordination
        self.notificationObservers = notificationObservers
        self.overnightRun = overnightRun
        self.polarManager = polarManager
        self.rawBackup = rawBackup
        self.recordingStore = recordingStore
        self.scoring = scoring
        self.services = services
        self.sessionState = sessionState
        self.settingsManager = settingsManager
        self.strapGuards = strapGuards
        self.streamingLifecycle = streamingLifecycle
        self.streamingVerification = streamingVerification
        self.morning = morning
        self.overnightStreaming = overnightStreaming
        self.recovery = recovery
    }

}
