import SwiftUI

// The iCloud sync status Settings → iCloud & Data shows: up to date, syncing
// (a sync running, or saves waiting for their upload), a warning for uploads
// that failed, sessions waiting for their key, or an index that did not load,
// or the sync's error.

extension DataSettingsPage {
    /// What an idle sync that is not up to date waits on.
    enum SyncWait: Equatable {
        /// The archive's index did not load, so what is waiting is unknown.
        case historyUnreadable
        /// Sessions whose last upload failed (`failedUploadsWaitingCount`).
        case failedUploads(Int)
        /// Sessions in iCloud sealed with a key this device does not hold
        /// yet (`recordsAwaitingKeyCount`): they are not on this iPhone.
        case awaitingKey
        /// Sessions whose upload has not run yet, or is running: nothing has
        /// failed, so this is shown as syncing, not as a warning.
        case uploading
    }

    /// Nil when the sync is up to date (`isUpToDate`).
    var syncWait: SyncWait? {
        guard !syncManager.isUpToDate else { return nil }
        guard syncManager.archive.hasCompleteIndex else { return .historyUnreadable }
        let failed = syncManager.failedUploadsWaitingCount
        if failed > 0 { return .failedUploads(failed) }
        return syncManager.recordsAwaitingKeyCount > 0 ? .awaitingKey : .uploading
    }

    /// The warning for a wait the user should know about: an index that did
    /// not load, or uploads that failed. Nil for none, and for uploads only
    /// waiting their turn: a save uploading right now is not "pending retry".
    var syncWarning: String? {
        switch syncWait {
        case .historyUnreadable: CloudSyncMessages.historyNotReadable
        case let .failedUploads(count): CloudSyncMessages.uploadsWaiting(count)
        case .awaitingKey: CloudPayloadCodec.CodecError.noMatchingKey.localizedDescription
        case .uploading, nil: nil
        }
    }

    static var syncingText: String {
        String(localized: "Syncing…", bundle: LanguageManager.appBundle)
    }

    @ViewBuilder
    var syncStateLabel: some View {
        switch syncManager.syncState {
        case .idle:
            if let warning = syncWarning {
                Text(warning).foregroundColor(AppTheme.softGoldText).font(.caption)
            } else if syncWait == .uploading {
                syncingLabel
            } else {
                Text("Up to date", bundle: LanguageManager.appBundle).foregroundColor(AppTheme.textSecondary)
            }
        case .syncing:
            syncingLabel
        case let .error(message):
            Text(message).foregroundColor(AppTheme.alert).font(.caption)
        }
    }

    private var syncingLabel: some View {
        HStack(spacing: 6) {
            ProgressView().scaleEffect(0.8)
            Text(Self.syncingText).foregroundColor(AppTheme.textSecondary)
        }
    }
}
