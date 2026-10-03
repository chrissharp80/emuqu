import SwiftUI

/// View for managing deleted sessions (trash bin)
/// Shows sessions that were intentionally deleted and can be restored or permanently removed
struct TrashView: View {
    @Environment(RRCollector.self) var collector
    @State private var deletedSessions: [(id: UUID, date: Date, beatCount: Int)] = []
    @State private var isRestoring = false
    @State private var restoringId: UUID?
    @State private var showingClearAllConfirmation = false
    @State private var statusMessage: String?
    /// The session whose permanent delete is awaiting confirmation.
    @State private var pendingDeleteId: UUID?

    var body: some View {
        List {
            emptyTrashSection

            trashStatusSection
        }
        .zenFormBackground()
        .navigationTitle(String(localized: "Trash", bundle: LanguageManager.appBundle))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadDeletedSessions()
        }
        .confirmationDialog(
            String(localized: "Permanently Delete All?", bundle: LanguageManager.appBundle),
            isPresented: $showingClearAllConfirmation,
            titleVisibility: .visible
        ) { clearAllActions } message: { clearAllMessage }
        .modifier(SingleDeleteConfirmation(pendingDeleteId: $pendingDeleteId, onDelete: permanentlyDelete))
    }

    @ViewBuilder
    private var clearAllActions: some View {
        Button(String(localized: "Delete All", bundle: LanguageManager.appBundle), role: .destructive) {
            permanentlyDeleteAll()
        }
        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
    }

    private var clearAllMessage: some View {
        Text(String(localized: "This will permanently remove all \(deletedSessions.count) deleted sessions. This cannot be undone.", bundle: LanguageManager.appBundle))
    }

    @ViewBuilder
    private var emptyTrashSection: some View {
        if deletedSessions.isEmpty {
            trashIsEmptySection
        } else {
            deletedSessionsSection
            clearAllSection
        }
    }

    private var deletedSessionsSection: some View {
        Section {
            ForEach(deletedSessions, id: \.id) { session in
                deletedSessionRow(session)
            }
        } header: {
            Text(String(localized: "\(deletedSessions.count) Deleted Sessions", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: "Deleted sessions stay here for 90 days unless you remove them sooner.", bundle: LanguageManager.appBundle))
        }
    }

    private var clearAllSection: some View {
        Section {
            Button(role: .destructive) {
                showingClearAllConfirmation = true
            } label: {
                bodyLabel
            }
        }
    }

    @ViewBuilder
    private var trashStatusSection: some View {
        if let message = statusMessage {
            Section {
                Text(message)
                    .font(.caption)
                    .foregroundColor(AppTheme.sageText)
            }
        }
    }

    private var trashIsEmptySection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "trash.slash")
                    .scaledFont(size: 48)
                    .foregroundColor(AppTheme.textTertiary)
                Text(String(localized: "Trash is Empty", bundle: LanguageManager.appBundle))
                    .font(.headline)
                    .foregroundColor(AppTheme.textSecondary)
                Text(String(localized: "Deleted sessions will appear here for recovery", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
    }

    private var bodyLabel: some View {
        HStack {
            Image(systemName: "trash.fill")
            Text(String(localized: "Permanently Delete All", bundle: LanguageManager.appBundle))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Deleted Session Row

    private func deletedSessionRow(_ session: (id: UUID, date: Date, beatCount: Int)) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(formatDate(session.date))
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(AppTheme.textPrimary)
                Text(String(localized: "\(session.beatCount) beats", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }
            Spacer()
            if isRestoring, restoringId == session.id {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                trashRowActions(session.id)
            }
        }
        .padding(.vertical, 4)
    }

    private func trashRowActions(_ id: UUID) -> some View {
        HStack(spacing: 8) {
            trashRowButton(
                glyph: "arrow.uturn.backward.circle.fill",
                tint: AppTheme.sage,
                label: String(localized: "Restore session", bundle: LanguageManager.appBundle),
                hint: String(localized: "Moves this session back to your archive", bundle: LanguageManager.appBundle)
            ) { restoreSession(id) }
            trashRowButton(
                glyph: "xmark.circle.fill",
                tint: AppTheme.terracotta,
                label: String(localized: "Permanently delete session", bundle: LanguageManager.appBundle),
                hint: String(localized: "Removes this session forever; cannot be undone", bundle: LanguageManager.appBundle)
            ) { pendingDeleteId = id }
        }
    }

    private func trashRowButton(glyph: String, tint: Color, label: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.title2)
                .foregroundColor(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }

    // MARK: - Actions

    private func loadDeletedSessions() {
        deletedSessions = collector.checkForDeletedSessions()
    }

    private func restoreSession(_ id: UUID) {
        isRestoring = true
        restoringId = id
        Task {
            let restored = await collector.restoreFromTrash(id) != nil
            await MainActor.run { finishRestore(succeeded: restored) }
        }
    }

    @MainActor
    private func finishRestore(succeeded: Bool) {
        isRestoring = false
        restoringId = nil
        if succeeded {
            statusMessage = String(localized: "Session restored successfully", bundle: LanguageManager.appBundle)
            loadDeletedSessions()
            clearStatusMessageAfterDelay()
        } else {
            statusMessage = String(localized: "Failed to restore session", bundle: LanguageManager.appBundle)
        }
    }

    /// The success banner is transient — three seconds, then it clears itself.
    /// The failure message stays until the next action so the user can read it.
    private func clearStatusMessageAfterDelay() {
        Task {
            await sleepQuietly(3_000_000_000, context: "clearStatusMessageAfterDelay")
            await MainActor.run { statusMessage = nil }
        }
    }

    private func permanentlyDelete(_ id: UUID) {
        collector.permanentlyDelete(id)
        loadDeletedSessions()
    }

    private func permanentlyDeleteAll() {
        for session in deletedSessions {
            collector.permanentlyDelete(session.id)
        }
        loadDeletedSessions()
        statusMessage = String(localized: "All deleted sessions permanently removed", bundle: LanguageManager.appBundle)

        Task {
            await sleepQuietly(3_000_000_000, context: "permanentlyDeleteAll")
            await MainActor.run {
                statusMessage = nil
            }
        }
    }

    // MARK: - Helpers

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = LanguageManager.appLocale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// Confirms a single permanent delete: it removes the trashed file, its raw
/// backup and its iCloud copy, and a slip of the finger must not do that.
private struct SingleDeleteConfirmation: ViewModifier {
    @Binding var pendingDeleteId: UUID?
    let onDelete: (UUID) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            String(localized: "Permanently Delete Session?", bundle: LanguageManager.appBundle),
            isPresented: Binding(get: { pendingDeleteId != nil }, set: { if !$0 { pendingDeleteId = nil } }),
            titleVisibility: .visible
        ) { actions } message: {
            Text(String(localized: "This session and its backups will be removed for good. This cannot be undone.", bundle: LanguageManager.appBundle))
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button(String(localized: "Delete", bundle: LanguageManager.appBundle), role: .destructive) {
            if let id = pendingDeleteId { onDelete(id) }
            pendingDeleteId = nil
        }
        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) { pendingDeleteId = nil }
    }
}

#Preview {
    NavigationStack {
        TrashView()
            .environment(RRCollector())
    }
}
