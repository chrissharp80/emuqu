import SwiftUI

// Neither view in this file is placed on a screen in the current app; both
// are kept, with snapshot tests (`UncoveredScreenSnapshotTests`), for the
// recovery card described below.

// MARK: - ArchiveStatusLine

//
// Compact "✓ Saved · ☁ iCloud" line for the recovery card. Shows where the
// current session lives — local archive, iCloud, both, or still saving —
// so users stop wondering whether their data is safe. Tappable for details.
//
// Observes `collector.archiveVersion` (bumps on every archive write) and
// `syncManager.pullVersion` + `syncManager.syncState` so the line updates
// live when state changes.

struct ArchiveStatusLine: View {
    let session: HRVSession
    let collector: RRCollector
    var archiveSignal: ArchiveSignal
    var syncManager: CloudKitSyncManager

    @State private var showingDetails = false

    private var isArchived: Bool {
        collector.archive.exists(session.id)
    }

    private var isUploaded: Bool {
        syncManager.isUploaded(session.id)
    }

    private var isPendingRetry: Bool {
        syncManager.isPendingRetry(session.id)
    }

    private var isSyncing: Bool {
        syncManager.syncState == .syncing
    }

    @ViewBuilder
    var body: some View {
        Button {
            showingDetails = true
        } label: {
            savedStatusRow
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingDetails) {
            ArchiveStatusDetailSheet(
                session: session,
                collector: collector,
                archiveSignal: archiveSignal,
                syncManager: syncManager
            )
            .presentationDetents([.medium])
        }
    }

    private var savedStatusRow: some View {
        HStack(spacing: 6) {
            // Archive status
            archiveStatusSection

            Text(String(localized: "·", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textTertiary)

            // iCloud status
            icloudStatusSection

            Spacer(minLength: 0)

            Image(systemName: "info.circle")
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var archiveStatusSection: some View {
        if isArchived {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(AppTheme.sage)
            Text(String(localized: "Saved", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textSecondary)
        } else {
            ProgressView().scaleEffect(0.6)
            Text(String(localized: "Saving…", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    private var icloudStatusSection: some View {
        if isUploaded {
            Image(systemName: "icloud.fill")
                .foregroundColor(AppTheme.primary)
            Text(String(localized: "iCloud", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textSecondary)
        } else if isPendingRetry {
            Image(systemName: "icloud.and.arrow.up")
                .foregroundColor(AppTheme.softGold)
            Text(String(localized: "Retrying…", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textSecondary)
        } else if isSyncing {
            ProgressView().scaleEffect(0.6)
            Text(String(localized: "Syncing…", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textSecondary)
        } else {
            Image(systemName: "icloud.slash")
                .foregroundColor(AppTheme.textTertiary)
            Text(String(localized: "Local only", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textTertiary)
        }
    }
}

// MARK: - Details sheet

/// Tapping the status line opens this — shows archive path, hash, upload time,
/// and why the state is what it is. Removes all mystery about where data lives.
struct ArchiveStatusDetailSheet: View {
    let session: HRVSession
    let collector: RRCollector
    var archiveSignal: ArchiveSignal
    var syncManager: CloudKitSyncManager

    @Environment(\.dismiss) private var dismiss

    private var archiveEntry: SessionArchiveEntry? {
        collector.archive.entries.first { $0.sessionId == session.id }
    }

    var body: some View {
        NavigationStack {
            storageForm
                .navigationTitle(String(localized: "Session Storage", bundle: LanguageManager.appBundle))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { doneToolbar }
        }
    }

    private var storageForm: some View {
        Form {
            localArchiveSection

            icloudSection

            forceIcloudSyncSection
        }
    }

    @ToolbarContentBuilder
    private var doneToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) { dismiss() }
        }
    }

    private var forceIcloudSyncSection: some View {
        Section {
            forceIcloudSyncButton
                .disabled(syncManager.syncState == .syncing || !syncManager.isCloudKitAvailable)
        }
    }

    private var forceIcloudSyncButton: some View {
        Button {
            Task { await syncManager.performFullSync() }
        } label: {
            Label(String(localized: "Force iCloud Sync", bundle: LanguageManager.appBundle), systemImage: "arrow.triangle.2.circlepath.icloud")
        }
    }

    private var localArchiveSection: some View {
        Section(String(localized: "Local Archive", bundle: LanguageManager.appBundle)) {
            if let entry = archiveEntry {
                LabeledRow("Status", value: String(localized: "✓ Archived", bundle: LanguageManager.appBundle))
                LabeledRow("Archived at", value: formatDate(entry.date))
                LabeledRow("File hash", value: String(entry.fileHash.prefix(12)) + "…")
                LabeledRow("File path", value: entry.filePath)
            } else {
                LabeledRow("Status", value: String(localized: "Not archived yet", bundle: LanguageManager.appBundle))
            }
        }
    }

    private var icloudSection: some View {
        Section(String(localized: "iCloud", bundle: LanguageManager.appBundle)) {
            icloudStatusRows
            LabeledRow("Pending queue", value: String(localized: "\(syncManager.pendingUploadCount) sessions", bundle: LanguageManager.appBundle))
        }
    }

    @ViewBuilder
    private var icloudStatusRows: some View {
        if !syncManager.isCloudKitAvailable {
            LabeledRow("Status", value: String(localized: "iCloud unavailable", bundle: LanguageManager.appBundle))
        } else if syncManager.isUploaded(session.id) {
            LabeledRow("Status", value: String(localized: "✓ Uploaded", bundle: LanguageManager.appBundle))
            if let last = syncManager.lastSyncDate {
                LabeledRow("Last sync", value: formatDate(last))
            }
        } else if syncManager.isPendingRetry(session.id) {
            LabeledRow("Status", value: String(localized: "Upload failed — queued for retry", bundle: LanguageManager.appBundle))
        } else {
            LabeledRow("Status", value: String(localized: "Not uploaded", bundle: LanguageManager.appBundle))
        }
    }

}

/// `label` is a catalog key, shown in the app's language.
private struct LabeledRow: View {
    let label: LocalizedStringKey
    let value: String
    init(_ label: LocalizedStringKey, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label, bundle: LanguageManager.appBundle)
                .foregroundColor(AppTheme.textSecondary)
            Spacer()
            Text(value)
                .foregroundColor(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
    }
}

// MARK: - File-scope helpers

private func formatDate(_ date: Date) -> String {
    date.formatted(Date.FormatStyle(date: .numeric, time: .shortened).locale(LanguageManager.appLocale))
}
