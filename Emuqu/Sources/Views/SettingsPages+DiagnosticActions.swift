import SwiftUI

// The action half of `TroubleshootingPage`, split out of
// `SettingsPages+Diagnostics.swift` so that struct's body stays under
// the 500-line limit. The read-only diagnostic cards stay behind; the sections
// that *do* something — repair, re-analyse, rebuild, export — live here, along
// with the debug-mode-gated advanced controls.
//
// Only the file boundary changed. Members here dropped `private`, because
// Swift's `private` does not reach across files.

extension TroubleshootingPage {
    /// Repair / reanalysis / export controls, plus the debug-gated advanced set.
    @ViewBuilder
    var actionSections: some View {
        Group {
            // MARK: Actions

            exportActionsSection
            problemsSection

            // MARK: Reanalyze Sessions

            reanalyzeSection
            SampleDataSection()

            // MARK: Advanced Diagnostics

            debugModeSection

            // MARK: Debug Tools (visible when toggle is on)

            debugToolsSection
        }
    }

    private var exportActionsSection: some View {
        Section {
            exportLogButton
            copyLogButton
            clearProblemsButton
            clearCrashReportButton
        } header: {
            Text(String(localized: "Actions", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: "Export the diagnostic log and share it with support to help investigate issues. The log contains health readings such as HRV values and sleep times, and goes only where you choose to send it.", bundle: LanguageManager.appBundle))
        }
    }

    private var exportLogButton: some View {
        ShareLink(item: DiagnosticLogExport(), preview: DiagnosticLogExport.preview) {
            Label(
                String(localized: "Export Diagnostic Log", bundle: LanguageManager.appBundle),
                systemImage: "square.and.arrow.up"
            )
        }
        .accessibilityHint(Text("Save a log file you can share with the developer.", bundle: LanguageManager.appBundle))
    }

    // Copy-to-clipboard fallback. The share sheet
    // (UIActivityViewController / ShareLink) routes a file URL
    // through sharingd + LaunchServices, which on dev installs
    // retry-loops for seconds and often fails ("Failed to locate
    // container app bundle record … the app may have moved" — the
    // container UUID changes every Xcode reinstall, leaving stale
    // LS records). Copying the text to the pasteboard bypasses ALL
    // of that — it's instant and never touches the share machinery,
    // so the user can always get logs out, then paste them anywhere.
    private var copyLogButton: some View {
        Button { copyLogToClipboard() } label: {
            Label(
                String(localized: "Copy Log to Clipboard", bundle: LanguageManager.appBundle),
                systemImage: "doc.on.clipboard"
            )
        }
        .accessibilityHint(Text("Copy the full diagnostic log so you can paste it into a message or email.", bundle: LanguageManager.appBundle))
    }

    private func copyLogToClipboard() {
        Task {
            let text = await Task.detached(priority: .userInitiated) {
                AppDependencies.current.app.debugLogger.exportLogs()
            }.value
            await MainActor.run {
                // The debug log carries HRV values,
                // sleep timings and session ids. Local-only, expiring.
                PasteboardWriter.copy(text)
                logCopiedConfirmation = true
            }
        }
    }

    @ViewBuilder
    private var clearProblemsButton: some View {
        if !logger.errorCatalog.isEmpty {
            Button(role: .destructive) {
                dependencies.app.debugLogger.clearErrorCatalog()
            } label: {
                Label(
                    String(localized: "Clear Problems", bundle: LanguageManager.appBundle),
                    systemImage: "xmark.circle"
                )
            }
        }
    }

    @ViewBuilder
    private var clearCrashReportButton: some View {
        if dependencies.app.crashLogManager.hasPreviousCrash {
            Button(role: .destructive) {
                dependencies.app.crashLogManager.clearPreviousCrash()
            } label: {
                Label(String(localized: "Clear Crash Report", bundle: LanguageManager.appBundle), systemImage: "xmark.circle")
            }
        }
    }

    private var problemsSection: some View {
        Section {
            Toggle("Persistent Logging", isOn: Bindable(logger).persistentLoggingEnabled)
        } header: {
            Text(String(localized: "Advanced", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: "When enabled, diagnostic logs are saved to disk. Enable this before reproducing an issue, then export the log above. Logs are encrypted at rest and auto-rotate at 2 MB.", bundle: LanguageManager.appBundle))
        }
    }

    @ViewBuilder
    private var reanalyzeSection: some View {
        Section {
            reanalyzeControls
        } header: {
            Text(String(localized: "Reanalyze", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: "Recompute recovery scores and analysis using the latest algorithms. Use a date range to limit to recent sessions.", bundle: LanguageManager.appBundle))
        }
        .alert("Reanalysis Complete", isPresented: $showingReanalyzeAlert) {
            Button(String(localized: "OK", bundle: LanguageManager.appBundle)) {}
        } message: {
            Text(reanalyzeMessage)
        }
    }

    @ViewBuilder
    private var reanalyzeControls: some View {
        if !isReanalyzing {
            reanalyzeRangeControls
            reanalyzeStartButton
        } else {
            reanalyzeProgressPanel
        }
    }

    @ViewBuilder
    private var reanalyzeRangeControls: some View {
        Toggle("Date Range", isOn: $reanalyzeDateRange.animation())

        if reanalyzeDateRange {
            DatePicker("From", selection: $reanalyzeFromDate, in: ...reanalyzeToDate, displayedComponents: .date)
                .font(.subheadline)
            DatePicker("To", selection: $reanalyzeToDate, in: reanalyzeFromDate ... Date(), displayedComponents: .date)
                .font(.subheadline)
        }
    }

    @ViewBuilder
    private var reanalyzeStartButton: some View {
        Button {
            showingReanalyzeConfirm = true
        } label: {
            Label(
                reanalyzeDateRange ? "Reanalyze Selected Range" : "Reanalyze All Sessions",
                systemImage: "arrow.triangle.2.circlepath"
            )
        }
        .confirmationDialog(
            "Reanalyze Sessions?",
            isPresented: $showingReanalyzeConfirm,
            titleVisibility: .visible
        ) { reanalyzeDialogActions } message: { reanalyzeDialogMessage }
    }

    @ViewBuilder
    private var reanalyzeDialogActions: some View {
        Button(String(localized: "Reanalyze", bundle: LanguageManager.appBundle)) { startReanalysis() }
        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
    }

    @ViewBuilder
    private var reanalyzeDialogMessage: some View {
        if reanalyzeDateRange {
            Text(String(localized: "This will recompute scores for sessions between the selected dates.", bundle: LanguageManager.appBundle))
        } else {
            Text(String(localized: "This will recompute scores for all recorded sessions. This may take a while if you have a lot of data.", bundle: LanguageManager.appBundle))
        }
    }

    private var reanalyzeProgressPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "Reanalyzing\u{2026}", bundle: LanguageManager.appBundle))
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text("\(reanalyzeProgress) of \(reanalyzeTotal)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textSecondary)
            }
            ProgressView(value: reanalyzeTotal > 0 ? Double(reanalyzeProgress) / Double(reanalyzeTotal) : 0)
                .tint(.accentColor)
            Button(String(localized: "Stop", bundle: LanguageManager.appBundle), role: .destructive) {
                reanalyzeTask?.cancel()
            }
            .font(.subheadline)
        }
        .padding(.vertical, 4)
    }

    private var debugModeSection: some View {
        Section {
            Toggle(String(localized: "Advanced Diagnostics", bundle: LanguageManager.appBundle), isOn: $debugModeEnabled)
        } footer: {
            Text(String(localized: "Shows full diagnostic tools below for advanced troubleshooting.", bundle: LanguageManager.appBundle))
        }
    }

    @ViewBuilder
    private var debugToolsSection: some View {
        if debugModeEnabled {
            debugToolsListSection
            advancedRepairSection
        }
    }

    private var debugToolsListSection: some View {
        Section {
            debugLogLink
            debugCrashButton
            debugResetButton
        } header: {
            Text(String(localized: "Diagnostic Tools", bundle: LanguageManager.appBundle))
        }
    }

    @ViewBuilder
    private var debugLogLink: some View {
        NavigationLink { DebugLogView() } label: { debugLogLabel }
        NavigationLink { ErrorCatalogView() } label: { errorCatalogLabel }
    }

    private var debugLogLabel: some View {
        HStack {
            Label(String(localized: "View Logs (7 days)", bundle: LanguageManager.appBundle), systemImage: "doc.text.magnifyingglass")
            Spacer()
            Text("\(logger.entries.count)")
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    private var errorCatalogLabel: some View {
        HStack {
            Label(String(localized: "Error Catalog", bundle: LanguageManager.appBundle), systemImage: "exclamationmark.triangle.fill")
            Spacer()
            if logger.errorCatalog.count > 0 {
                Text("\(logger.errorCatalog.count)")
                    .foregroundColor(.red)
            }
        }
    }

    private var debugCrashButton: some View {
        ShareLink(item: DiagnosticLogExport(), preview: DiagnosticLogExport.preview) {
            Label(String(localized: "Export Full Logs", bundle: LanguageManager.appBundle), systemImage: "square.and.arrow.up")
        }
    }

    private var debugResetButton: some View {
        Button(role: .destructive) {
            dependencies.app.debugLogger.clear()
        } label: {
            Label(String(localized: "Clear All Logs", bundle: LanguageManager.appBundle), systemImage: "trash")
        }
    }

    private var advancedRepairSection: some View {
        Section {
            archiveDiagnosticsLink
            repairTrainingHistoryGroup
            rebuildTrainingLoadButton
        } header: {
            Text(String(localized: "Advanced", bundle: LanguageManager.appBundle))
        }
    }

    @ViewBuilder
    private var archiveDiagnosticsLink: some View {
        NavigationLink {
            ArchiveDiagnosticsView()
        } label: {
            Label(String(localized: "Archive Diagnostics", bundle: LanguageManager.appBundle), systemImage: "externaldrive.badge.questionmark")
        }

        Button { repairArchive() } label: {
            Label(String(localized: "Repair Archive", bundle: LanguageManager.appBundle), systemImage: "wrench.and.screwdriver")
        }
        .alert("Archive Repaired", isPresented: $showingRepairAlert) {
            Button(String(localized: "OK", bundle: LanguageManager.appBundle)) {}
        } message: {
            Text(repairMessage)
        }
    }

    @ViewBuilder
    private var repairTrainingHistoryGroup: some View {
        if isRepairingTraining {
            trainingRepairProgressPanel
        } else {
            Button { showingTrainingRepairConfirm = true } label: {
                Label(String(localized: "Repair Training History\u{2026}", bundle: LanguageManager.appBundle), systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }

    private var trainingRepairProgressPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "Repairing snapshots\u{2026}", bundle: LanguageManager.appBundle))
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text("\(trainingRepairProgress) of \(trainingRepairTotal)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(AppTheme.textSecondary)
            }
            ProgressView(value: trainingRepairTotal > 0 ? Double(trainingRepairProgress) / Double(trainingRepairTotal) : 0)
                .tint(.accentColor)
        }
        .padding(.vertical, 4)
    }

    // Non-destructive: recomputes the LIVE ATL/CTL/TSB series from
    // scratch (full workout decode + EWMA replay), bypassing the
    // incremental cache. The manual fallback for the incremental
    // training-load computation — use if the load number ever looks
    // stale/wrong. Does NOT rewrite historical session snapshots
    // (that's "Repair Training History" above).
    @ViewBuilder
    private var rebuildTrainingLoadButton: some View {
        Button { rebuildTrainingLoad() } label: {
            Label(
                isRebuildingLoad
                    ? String(localized: "Rebuilding load\u{2026}", bundle: LanguageManager.appBundle)
                    : String(localized: "Rebuild Training Load", bundle: LanguageManager.appBundle),
                systemImage: "gauge.with.dots.needle.bottom.50percent"
            )
        }
        .disabled(isRebuildingLoad)
        .confirmationDialog(
            "Rewrite training history?",
            isPresented: $showingTrainingRepairConfirm,
            titleVisibility: .visible
        ) { trainingRepairDialogActions } message: { trainingRepairDialogMessage }
        .alert("Training Snapshots Repaired", isPresented: $showingTrainingRepairAlert) {
            Button(String(localized: "OK", bundle: LanguageManager.appBundle)) {}
        } message: {
            Text(trainingRepairMessage)
        }
    }

    private func rebuildTrainingLoad() {
        Task { @MainActor in
            isRebuildingLoad = true
            await dependencies.analysis.trainingMetricsCache.rebuildFromScratch()
            isRebuildingLoad = false
        }
    }

    @ViewBuilder
    private var trainingRepairDialogActions: some View {
        Button(String(localized: "Repair All Sessions", bundle: LanguageManager.appBundle), role: .destructive) { repairTrainingSnapshots() }
        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
    }

    private var trainingRepairDialogMessage: some View {
        Text(String(localized: "This recomputes ATL / CTL / TSB and the readiness snapshot on every historical session using current Apple Health training-load data. Historical recovery scores may change, and this can't be undone — use it only to fix sessions that were scored with missing or zeroed training data.", bundle: LanguageManager.appBundle))
    }
}

/// The diagnostic log, handed to `ShareLink` as something to build rather
/// than a file already built.
///
/// Presenting `UIActivityViewController` from a SwiftUI sheet has been
/// measured cold-starting its share-extension scan for seconds to a minute
/// (`FitnessPostSummaryView+Share.shareRow`). `ShareLink` opens the system
/// sheet straight away, and the file is written only when a destination asks
/// for it, off the main thread.
struct DiagnosticLogExport: Transferable {
    static var preview: SharePreview<Never, Never> {
        SharePreview(String(localized: "Export Diagnostic Log", bundle: LanguageManager.appBundle))
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { _ in
            guard let url = await AppDependencies.current.app.debugLogger.exportToFileAsync() else {
                throw CocoaError(.fileWriteUnknown)
            }
            return SentTransferredFile(url)
        }
    }
}
