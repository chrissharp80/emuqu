import Foundation

/// What happens to a night between the strap stopping and a score on screen:
/// gathering the data off the device, processing it into a session, running the
/// analysis and recovery score, and the accept/reject step where the user
/// decides whether to keep it.
///
/// All four live together because they are one flow — gather feeds process,
/// process runs analysis, analysis produces the score the acceptance step keeps
/// or discards — and they call each other directly at every stage. Split
/// individually, each of those crossings would need a forwarder.
///
/// Built once by the collector over the parts it uses; the overnight, device
/// and recovery paths call it, and it calls none of them.
@MainActor
final class MorningSessionPipeline {
    let acceptanceService: SessionAcceptanceService
    let analysisPipeline: HRVAnalysisPipeline
    let archive: SessionArchive
    let archiveSignal: ArchiveSignal
    let baselineRebuild: BaselineRebuilder
    let cloudSyncManager: CloudKitSyncManager
    let deviceStatus: DeviceStatus
    /// Stops the Apple Health sleep observer once a morning is accepted.
    let healthWrites: HealthWriteAndObserve
    /// The training load the morning reading is scored with.
    let trainingQueries: TrainingHealthQueries
    let morningCoordination: MorningCoordination
    let morningProcessingService: MorningProcessingService
    let strapLink: StrapLinkState
    let strapBattery: StrapBatteryUsageTracker
    let rawBackup: RawRRBackup
    let recordingStore: RecordingStateStore
    let scoring: SessionScoringContext
    let sessionState: SessionState
    let settingsManager: SettingsManager
    let sleepBoundaryResolver: SleepBoundaryResolver
    let streamingLifecycle: StreamingLifecycle

    init(
        acceptanceService: SessionAcceptanceService,
        analysisPipeline: HRVAnalysisPipeline,
        archive: SessionArchive,
        archiveSignal: ArchiveSignal,
        baselineRebuild: BaselineRebuilder,
        cloudSyncManager: CloudKitSyncManager,
        deviceStatus: DeviceStatus,
        healthWrites: HealthWriteAndObserve,
        trainingQueries: TrainingHealthQueries,
        morningCoordination: MorningCoordination,
        morningProcessingService: MorningProcessingService,
        strapLink: StrapLinkState,
        strapBattery: StrapBatteryUsageTracker,
        rawBackup: RawRRBackup,
        recordingStore: RecordingStateStore,
        scoring: SessionScoringContext,
        sessionState: SessionState,
        settingsManager: SettingsManager,
        sleepBoundaryResolver: SleepBoundaryResolver,
        streamingLifecycle: StreamingLifecycle
    ) {
        self.acceptanceService = acceptanceService
        self.analysisPipeline = analysisPipeline
        self.archive = archive
        self.archiveSignal = archiveSignal
        self.baselineRebuild = baselineRebuild
        self.cloudSyncManager = cloudSyncManager
        self.deviceStatus = deviceStatus
        self.healthWrites = healthWrites
        self.trainingQueries = trainingQueries
        self.morningCoordination = morningCoordination
        self.morningProcessingService = morningProcessingService
        self.strapLink = strapLink
        self.strapBattery = strapBattery
        self.rawBackup = rawBackup
        self.recordingStore = recordingStore
        self.scoring = scoring
        self.sessionState = sessionState
        self.settingsManager = settingsManager
        self.sleepBoundaryResolver = sleepBoundaryResolver
        self.streamingLifecycle = streamingLifecycle
    }

}
