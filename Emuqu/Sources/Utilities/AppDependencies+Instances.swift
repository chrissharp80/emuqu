import Foundation

// The composition root's own instances: the services whose construction
// names other services, built here so every `.shared` read stays in the
// root. `AppDependencies.swift` serves them through its accessors.

extension SessionArchive {
    /// The app's archive: one instance, so no two operate on the same
    /// index.json. Its merge settings are read when a merge is decided, from
    /// the settings in force then.
    static let shared = SessionArchive(
        directory: nil,
        encryption: .shared,
        sleepScheduleProvider: { AppDependencies.current.app.settingsManager.settingsSnapshot.sleepSchedule },
        sessionMergeModeProvider: { AppDependencies.current.app.settingsManager.settingsSnapshot.sessionMergeMode },
        mergeGapProvider: { AppDependencies.current.app.settingsManager.settingsSnapshot.effectiveMergeGapSeconds }
    )
}

extension JSONFileSeal {
    /// The app's key (`EncryptionManager`), for the local stores that seal
    /// their files.
    static let app = JSONFileSeal(
        seal: { try AppDependencies.current.storage.encryptionManager.encrypt($0) },
        open: { try AppDependencies.current.storage.encryptionManager.openStoredJSON($0) }
    )
}

extension WorkoutTrackBackup {
    /// The app's workout backup, in the shared container.
    static let shared = WorkoutTrackBackup(directory: appDirectory, notificationCenter: .default, encryption: .shared)
}

extension RawRRBackup {
    /// A store in the app's backup directory, sealed with the app's key.
    static func app() -> RawRRBackup {
        RawRRBackup(directory: resolveBackupDirectory(), notificationCenter: .default, encryption: .shared)
    }
}

extension CloudKitSyncManager {
    /// The app's session sync, its bookkeeping at `resolveSyncStateURL()`.
    static let shared: CloudKitSyncManager = CloudKitSyncManager(
        settingsManager: .shared, archive: .shared, settingsSync: .shared, syncStateURL: resolveSyncStateURL()
    )
}

extension CloudKitSettingsSync {
    /// The app's settings-record sync.
    static let shared: CloudKitSettingsSync = CloudKitSettingsSync(
        settingsManager: .shared, archiveKey: .shared, sessionSync: { CloudKitSyncManager.shared }
    )
}

extension HeatAcclimationCache {
    /// The app's heat-acclimation cache.
    static let shared = HeatAcclimationCache(archive: .shared, settingsManager: .shared, training: HealthKitManager.shared.training)
}

extension AssistantContextSource {
    /// The app's context source, over the app's archive, settings and live brokers.
    static let shared = AssistantContextSource(services: ContextServices(.current))
}

extension VoiceConversationController {
    /// Shared instance — there's only one mic + recognizer + synth at the
    /// hardware level, and the chat view and every other surface (workout
    /// recording, the Watch) drive the same controller rather than fight for
    /// the audio session.
    static let shared = VoiceConversationController(services: VoiceServices(.current))
}

extension BreadcrumbRecorder {
    /// The app's Get Me Back trail recorder: one location manager, one trail.
    static let shared = BreadcrumbRecorder(services: BreadcrumbServices(.current))
}

extension ProviderRegistry {
    /// The app's AI providers and the one in use.
    static let shared = ProviderRegistry(services: ProviderRegistryServices(.current))
}

extension AssistantViewModel {
    /// The app's chat: one transcript, one provider choice.
    static let shared = AssistantViewModel(services: ChatServices(.current))
}

extension RecorderBox {
    /// The app's workout recorder slot, bound on first use.
    static let shared = RecorderBox(services: WorkoutServices(.current))
}

extension TrainingMetricsCache {
    /// The app's training-load cache, over the app's archive and settings.
    static let shared = TrainingMetricsCache(
        archive: { AppDependencies.current.storage.sessionArchive },
        settings: { AppDependencies.current.app.settingsManager.settings }
    )
}

extension HealthKitManager {
    /// The app's one HealthKit manager, so every consumer sees the same
    /// store, the same anchors and the same observer notifications. Its
    /// settings and archive are read when a query runs. `nonisolated` so
    /// default arguments can name it — Swift evaluates those in the caller's
    /// isolation. The isolation protects state, not the pointer.
    nonisolated static let shared = HealthKitManager(
        settingsProvider: { AppDependencies.current.app.settingsManager.settingsSnapshot },
        archiveProvider: { AppDependencies.current.storage.sessionArchive }
    )
}

extension BackgroundAudioManager {
    /// The app's cue session, its categories applied through the app's
    /// coordinator.
    static let shared = BackgroundAudioManager(
        session: SystemCueAudioSession { AppDependencies.current.services.audioSessionCoordinator }
    )
}

extension SmartProviderRouter {
    /// The app's router, its tiers proposed by the app's classifier.
    static let shared = SmartProviderRouter { AppDependencies.current.providers.capabilityClassifier }
}

extension CapabilityClassifier {
    /// The app's classifier, matching with the app's router's embedder.
    static let shared = CapabilityClassifier { AppDependencies.current.providers.smartProviderRouter.embed($0) }
}
