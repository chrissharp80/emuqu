import SwiftUI

/// View for displaying and recovering lost sessions from backups
struct LostSessionsView: View {
    @Environment(RRCollector.self) var collector
    @Environment(\.dismiss) private var dismiss
    @Environment(\.editMode) private var editMode

    @State private var lostSessions: [(id: UUID, date: Date, beatCount: Int)] = []
    @State private var isLoading = true
    @State private var isRecovering = false
    @State private var recoveryProgress: (current: Int, total: Int)?
    @State private var currentSessionDate: Date?
    @State private var recoveredCount = 0
    @State private var failedCount = 0
    @State private var showingResult = false
    @State private var resultMessage = ""
    @State private var selectedSessions: Set<UUID> = []
    @State private var showingDeleteConfirmation = false

    private var isEditing: Bool {
        editMode?.wrappedValue.isEditing ?? false
    }

    var body: some View {
        List(selection: $selectedSessions) { lostSessionsContent }
            .zenFormBackground()
            .navigationTitle(String(localized: "Lost Sessions", bundle: LanguageManager.appBundle))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isRecovering)
            .toolbar { lostSessionsToolbar }
            .task { await loadLostSessions() }
            .alert(
                String(localized: "Recovery Complete", bundle: LanguageManager.appBundle),
                isPresented: $showingResult
            ) { recoveryCompleteActions } message: { recoveryCompleteMessage }
            .confirmationDialog(
                String(localized: "Delete \(selectedSessions.count) Sessions?", bundle: LanguageManager.appBundle),
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) { deleteDialogActions } message: { deleteDialogMessage }
    }

    @ViewBuilder
    private var recoveryCompleteActions: some View {
        // Always dismiss — if anything is left to recover, the dashboard
        // banner will surface it again. Don't trap the user here when
        // some sessions were unrecoverable.
        Button(String(localized: "OK", bundle: LanguageManager.appBundle)) { dismiss() }
    }

    private var recoveryCompleteMessage: some View {
        Text(resultMessage)
    }

    @ViewBuilder
    private var lostSessionsContent: some View {
        if isLoading {
            scanningSection
        } else if lostSessions.isEmpty {
            emptyStateSection
        } else {
            // Header with explanation
            lostSessionsHeaderSection

            // Session list
            lostSessionsListSection

            // Recovery progress or button
            recoverySection
        }
    }

    private var scanningSection: some View {
        Section {
            HStack {
                Spacer()
                scanningIndicator
                Spacer()
            }
        }
    }

    private var scanningIndicator: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(String(localized: "Scanning backups...", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
        }
        .padding()
    }

    private var emptyStateSection: some View {
        Section {
            HStack {
                Spacer()
                emptyStateCopy
                Spacer()
            }
        }
    }

    private var emptyStateCopy: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .scaledFont(size: 40)
                .foregroundColor(AppTheme.sage)
            Text(String(localized: "No Lost Sessions", bundle: LanguageManager.appBundle))
                .font(.headline)
                .foregroundColor(AppTheme.textPrimary)
            Text(String(localized: "All backup sessions are already in your archive.", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var lostSessionsHeaderSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                foundHeadline
                Text(String(localized: "These sessions have raw RR data backups but are missing from your archive. This can happen if the app was reinstalled or if data was corrupted.", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var foundHeadline: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(String(localized: "\(lostSessions.count) Lost Sessions Found", bundle: LanguageManager.appBundle))
                .font(.headline)
        }
    }

    private var lostSessionsListSection: some View {
        Section(String(localized: "Sessions", bundle: LanguageManager.appBundle)) {
            ForEach(lostSessions, id: \.id) { session in
                sessionRow(session)
                    .tag(session.id)
            }
            .onDelete(perform: deleteSessionsAtOffsets)
        }
    }

    private func sessionRow(_ session: (id: UUID, date: Date, beatCount: Int)) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(formatDate(session.date))
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textPrimary)
                Text(String(localized: "\(session.beatCount) RR intervals", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
            Spacer()
            Text(formatDuration(session.beatCount))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    private var recoverySection: some View {
        Section {
            if isRecovering {
                recoveryProgressPanel
            } else {
                recoverAllButton
            }
        }
    }

    @ViewBuilder
    private var recoveryProgressPanel: some View {
        VStack(spacing: 12) {
            if let progress = recoveryProgress {
                ProgressView(value: Double(progress.current), total: Double(progress.total))
                    .tint(AppTheme.primary)
                progressCaption(progress)
                processingLine
            } else {
                ProgressView()
                Text(String(localized: "Starting recovery...", bundle: LanguageManager.appBundle))
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
        .padding(.vertical, 8)
    }

    private func progressCaption(_ progress: (current: Int, total: Int)) -> some View {
        HStack {
            Text(String(localized: "Recovering \(progress.current) of \(progress.total)...", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
            Spacer()
            outcomeTally
        }
    }

    @ViewBuilder
    private var outcomeTally: some View {
        if recoveredCount > 0 || failedCount > 0 {
            Text(String(localized: "\(recoveredCount) OK, \(failedCount) failed", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    @ViewBuilder
    private var processingLine: some View {
        if let date = currentSessionDate {
            Text(String(localized: "Processing: \(formatDate(date))", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    private var recoverAllButton: some View {
        Button {
            recoverAllSessions()
        } label: {
            HStack {
                Spacer()
                Image(systemName: "arrow.counterclockwise.circle.fill")
                Text(String(localized: "Recover All \(lostSessions.count) Sessions", bundle: LanguageManager.appBundle))
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.vertical, 4)
        }
        .tint(AppTheme.primary)
    }

    @ToolbarContentBuilder
    private var lostSessionsToolbar: some ToolbarContent {
        // Close is disabled only while a recovery runs, so the progress and
        // result stay on screen until it finishes.
        ToolbarItem(placement: .topBarLeading) {
            Button(String(localized: "Close", bundle: LanguageManager.appBundle)) { dismiss() }
                .disabled(isRecovering)
        }
        ToolbarItem(placement: .topBarTrailing) {
            editButton
        }
        ToolbarItem(placement: .bottomBar) {
            deleteSelectedButton
        }
    }

    @ViewBuilder
    private var editButton: some View {
        if !lostSessions.isEmpty, !isRecovering {
            EditButton()
        }
    }

    @ViewBuilder
    private var deleteSelectedButton: some View {
        if isEditing, !selectedSessions.isEmpty {
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label(String(localized: "Delete \(selectedSessions.count) Selected", bundle: LanguageManager.appBundle), systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var deleteDialogActions: some View {
        Button(String(localized: "Delete", bundle: LanguageManager.appBundle), role: .destructive) {
            deleteSelectedSessions()
        }
        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
    }

    private var deleteDialogMessage: some View {
        Text(String(localized: "These sessions will be removed from the lost sessions list. Their raw backup data stays on this device.", bundle: LanguageManager.appBundle))
    }

    private func loadLostSessions() async {
        // Get collector reference on main actor, then run check
        let collectorRef = collector
        let sessions = await Task.detached(priority: .userInitiated) {
            await collectorRef.checkForLostSessions()
        }.value

        // Sort by date, newest first
        lostSessions = sessions.sorted { $0.date > $1.date }
        isLoading = false
    }

    private func deleteSessionsAtOffsets(_ offsets: IndexSet) {
        let idsToDelete = offsets.map { lostSessions[$0].id }
        collector.deleteLostSessions(idsToDelete)
        lostSessions.remove(atOffsets: offsets)
    }

    private func deleteSelectedSessions() {
        let idsToDelete = Array(selectedSessions)
        collector.deleteLostSessions(idsToDelete)
        lostSessions.removeAll { selectedSessions.contains($0.id) }
        selectedSessions.removeAll()
        editMode?.wrappedValue = .inactive
    }

    private func recoverAllSessions() {
        isRecovering = true
        recoveredCount = 0
        failedCount = 0
        Task {
            let total = lostSessions.count
            for (index, session) in lostSessions.enumerated() {
                await recoverOne(session, index: index, total: total)
                await Task.yield()  // keep the UI responsive between sessions
            }
            await MainActor.run { finishRecovery(total: total) }
        }
    }

    private func recoverOne(_ session: (id: UUID, date: Date, beatCount: Int), index: Int, total: Int) async {
        await MainActor.run {
            recoveryProgress = (index + 1, total)
            currentSessionDate = session.date
        }
        let recovered = await collector.recoverFromBackup(session.id)
        await MainActor.run {
            if recovered != nil { recoveredCount += 1 } else { failedCount += 1 }
        }
    }

    @MainActor
    private func finishRecovery(total: Int) {
        isRecovering = false
        recoveryProgress = nil
        currentSessionDate = nil
        resultMessage = recoveryResultMessage(total: total)
        showingResult = true
        // Refresh the list
        Task { await loadLostSessions() }
    }

    private func recoveryResultMessage(total: Int) -> String {
        if recoveredCount == total {
            return String(localized: "Successfully recovered all \(recoveredCount) sessions.", bundle: LanguageManager.appBundle)
        }
        if recoveredCount > 0 {
            return String(localized: "Recovered \(recoveredCount) of \(total) sessions. \(failedCount) could not be recovered (may have insufficient data).", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Could not recover any sessions. The backup data may be incomplete or corrupted.", bundle: LanguageManager.appBundle)
    }

    private func formatDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(LanguageManager.appLocale))
    }

    private func formatDuration(_ beatCount: Int) -> String {
        // Rough estimate: ~60 bpm average = 1 beat per second
        let minutes = beatCount / 60
        let duration = minutes < 60 ? LocalizedDuration.minutes(minutes) : LocalizedDuration.hoursMinutes(minutes: minutes)
        return "~\(duration)"
    }
}

#Preview {
    NavigationStack {
        LostSessionsView()
            .environment(RRCollector())
    }
}
