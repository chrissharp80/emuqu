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
    static let shared = HeatAcclimationCache(archive: .shared, settingsManager: .shared, healthKit: .shared)
}

extension AssistantContextSource {
    /// The app's context source, over the app's archive, settings and live brokers.
    static let shared = AssistantContextSource(services: ContextServices(.current))
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
