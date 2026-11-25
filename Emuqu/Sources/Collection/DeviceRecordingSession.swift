import Foundation

/// A capture session that runs on the strap's own memory rather than streaming
/// to the phone: starting it, stopping it, backing up the raw intervals, and
/// running the analysis that turns them into a scored session.
///
/// Built once by the collector over the parts it uses; it calls the morning
/// pipeline for the analysis, and recovery calls it.
@MainActor
final class DeviceRecordingSession {
    let archive: SessionArchive
    let archiveSignal: ArchiveSignal
    let artifactDetector: ArtifactDetector
    let baselineTracker: BaselineTracker
    let healthKit: HealthKitManager
    let strapLink: StrapLinkState
    let strapRecording: StrapRecordingState
    let strapRecorder: StrapRecordingCoordinator
    let rawBackup: RawRRBackup
    let reconciliation: ReconciliationManager
    let recordingStore: RecordingStateStore
    let scoring: SessionScoringContext
    let sessionState: SessionState
    let strapGuards: StrapRecordingGuards
    let streamingLifecycle: StreamingLifecycle
    let verification: Verification
    let windowSelector: WindowSelector
    let morning: MorningSessionPipeline

    init(
        archive: SessionArchive,
        archiveSignal: ArchiveSignal,
        artifactDetector: ArtifactDetector,
        baselineTracker: BaselineTracker,
        healthKit: HealthKitManager,
        strapLink: StrapLinkState,
        strapRecording: StrapRecordingState,
        strapRecorder: StrapRecordingCoordinator,
        rawBackup: RawRRBackup,
        reconciliation: ReconciliationManager,
        recordingStore: RecordingStateStore,
        scoring: SessionScoringContext,
        sessionState: SessionState,
        strapGuards: StrapRecordingGuards,
        streamingLifecycle: StreamingLifecycle,
        verification: Verification,
        windowSelector: WindowSelector,
        morning: MorningSessionPipeline
    ) {
        self.archive = archive
        self.archiveSignal = archiveSignal
        self.artifactDetector = artifactDetector
        self.baselineTracker = baselineTracker
        self.healthKit = healthKit
        self.strapLink = strapLink
        self.strapRecording = strapRecording
        self.strapRecorder = strapRecorder
        self.rawBackup = rawBackup
        self.reconciliation = reconciliation
        self.recordingStore = recordingStore
        self.scoring = scoring
        self.sessionState = sessionState
        self.strapGuards = strapGuards
        self.streamingLifecycle = streamingLifecycle
        self.verification = verification
        self.windowSelector = windowSelector
        self.morning = morning
    }

}
