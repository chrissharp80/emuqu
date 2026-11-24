import CloudKit
@testable import Emuqu
import Foundation

// The stores take their key and settings at construction; the app's are built
// in the composition root. These test constructions use the app's key and the
// settings in force, so a suite can build a store in a directory of its own.

extension SessionArchive {
    convenience init(
        directory: URL? = nil,
        sleepScheduleProvider: @escaping () -> SleepSchedule = {
            AppDependencies.current.app.settingsManager.settingsSnapshot.sleepSchedule
        },
        sessionMergeModeProvider: @escaping () -> SessionMergeMode = {
            AppDependencies.current.app.settingsManager.settingsSnapshot.sessionMergeMode
        },
        mergeGapProvider: @escaping () -> TimeInterval = {
            AppDependencies.current.app.settingsManager.settingsSnapshot.effectiveMergeGapSeconds
        }
    ) {
        self.init(
            directory: directory, encryption: .shared, sleepScheduleProvider: sleepScheduleProvider,
            sessionMergeModeProvider: sessionMergeModeProvider, mergeGapProvider: mergeGapProvider
        )
    }

    static func indexJSON(_ stored: Data) throws -> Data {
        try indexJSON(stored, encryption: .shared)
    }
}

extension RawRRBackup {
    convenience init() {
        self.init(directory: Self.resolveBackupDirectory())
    }

    convenience init(directory: URL) {
        self.init(directory: directory, notificationCenter: .default)
    }

    convenience init(directory: URL, notificationCenter: NotificationCenter) {
        self.init(directory: directory, notificationCenter: notificationCenter, encryption: .shared)
    }

    static func decodeLegacyBackup(at filePath: URL) throws -> BackupEntry {
        try decodeLegacyBackup(at: filePath, encryption: .shared)
    }
}

extension WorkoutTrackBackup {
    convenience init() {
        self.init(directory: Self.appDirectory)
    }

    convenience init(directory: URL) {
        self.init(directory: directory, notificationCenter: .default)
    }

    convenience init(directory: URL, notificationCenter: NotificationCenter) {
        self.init(directory: directory, notificationCenter: notificationCenter, encryption: .shared)
    }
}

extension RawBackupSealer {
    static func writeEntry(_ entry: RawRRBackup.BackupEntry, to url: URL, sessionId: UUID) throws {
        try RawBackupSealer(directory: url.deletingLastPathComponent(), encryption: .shared)
            .writeEntry(entry, to: url, sessionId: sessionId)
    }
}

extension OneShotBackupName {
    static func fullerUnindexedBackup(than entry: RawRRBackup.BackupIndex, in directory: URL) throws -> RawRRBackup.BackupEntry? {
        try fullerUnindexedBackup(than: entry, in: directory, encryption: .shared)
    }
}

extension SealedJSONLines {
    static func availableManager() -> EncryptionManager? {
        availableManager(.shared)
    }
}

extension CloudPayloadCodec {
    static func decode(_ raw: Data) throws -> Data {
        try decode(raw, archiveKey: .shared)
    }
}

extension CloudSettingsRecord {
    static func settingsJSON(from record: CKRecord) throws -> Data {
        try settingsJSON(from: record, archiveKey: .shared)
    }
}

@MainActor
extension CloudKitSyncManager {
    convenience init(settingsManager: SettingsManager, archive: SessionArchive, syncStateURL: URL) {
        self.init(
            settingsManager: settingsManager, archive: archive,
            settingsSync: AppDependencies.current.storage.cloudKitSettingsSync, syncStateURL: syncStateURL
        )
    }
}

@MainActor
extension HeatAcclimationCache {
    convenience init(archive: SessionArchive) {
        self.init(
            archive: archive, settingsManager: AppDependencies.current.app.settingsManager,
            healthKit: AppDependencies.current.collection.healthKitManager
        )
    }
}
