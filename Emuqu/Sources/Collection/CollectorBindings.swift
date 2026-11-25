import Foundation

/// Republishes what the strap, Apple Health and iCloud report into the state
/// the views observe (`DeviceStatus`, `SessionState`, `MorningCoordination`),
/// keeps the live-HRV mirror and the resume card current, and reacts to a
/// critically low battery or an exhausted reconnect during a night through
/// the session controls.
///
/// Each binding is an observation that holds this object weakly
/// (`ObservationLoop`, `[weak owner = self]`): they outlive the call that
/// registers them, and each no-ops once these bindings are gone.
///
/// Built once by the collector over the parts it uses.
@MainActor
final class CollectorBindings {
    let archive: SessionArchive
    let archiveSignal: ArchiveSignal
    let baselineArchiveSync: BaselineArchiveSync
    let baselineRebuild: BaselineRebuilder
    let baselineTracker: BaselineTracker
    let cloudSyncManager: CloudKitSyncManager
    let control: CollectorSessionControl
    let deviceStatus: DeviceStatus
    /// Apple Health's sleep and vitals data versions, mirrored for the views.
    let healthObservation: HealthObservation
    let liveHRVMirror: LiveHRVMirror
    let morningCoordination: MorningCoordination
    let notificationObservers: NotificationTokens
    let overnightRun: OvernightRunState
    let polarManager: PolarManager
    let recovery: SessionRecoveryCoordinator
    let services: CollectorServices
    let sessionState: SessionState
    let strapGuards: StrapRecordingGuards
    let streamingLifecycle: StreamingLifecycle

    init(
        archive: SessionArchive,
        archiveSignal: ArchiveSignal,
        baselineArchiveSync: BaselineArchiveSync,
        baselineRebuild: BaselineRebuilder,
        baselineTracker: BaselineTracker,
        cloudSyncManager: CloudKitSyncManager,
        control: CollectorSessionControl,
        deviceStatus: DeviceStatus,
        healthObservation: HealthObservation,
        liveHRVMirror: LiveHRVMirror,
        morningCoordination: MorningCoordination,
        notificationObservers: NotificationTokens,
        overnightRun: OvernightRunState,
        polarManager: PolarManager,
        recovery: SessionRecoveryCoordinator,
        services: CollectorServices,
        sessionState: SessionState,
        strapGuards: StrapRecordingGuards,
        streamingLifecycle: StreamingLifecycle
    ) {
        self.archive = archive
        self.archiveSignal = archiveSignal
        self.baselineArchiveSync = baselineArchiveSync
        self.baselineRebuild = baselineRebuild
        self.baselineTracker = baselineTracker
        self.cloudSyncManager = cloudSyncManager
        self.control = control
        self.deviceStatus = deviceStatus
        self.healthObservation = healthObservation
        self.liveHRVMirror = liveHRVMirror
        self.morningCoordination = morningCoordination
        self.notificationObservers = notificationObservers
        self.overnightRun = overnightRun
        self.polarManager = polarManager
        self.recovery = recovery
        self.services = services
        self.sessionState = sessionState
        self.strapGuards = strapGuards
        self.streamingLifecycle = streamingLifecycle
    }
}
