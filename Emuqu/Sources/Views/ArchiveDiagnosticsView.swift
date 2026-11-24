import SwiftUI

// MARK: - Archive Diagnostics View

struct ArchiveDiagnosticsView: View {
    @Environment(\.dependencies) var dependencies
    @Environment(RRCollector.self) var collector
    @State private var diagnosticInfo = String(localized: "Loading...", bundle: LanguageManager.appBundle)
    @State private var isRepairing = false
    @State private var showingRepairConfirm = false
    @State private var repairResult: String = ""
    @State private var showingResult = false
    /// RR storage audit state. The audit walks the
    /// archive + RawRRBackup and reports per-session whether the raw
    /// beat stream (used for Poincaré + HRV waveform) is on disk in
    /// the archive, in the backup safety net, both, or neither.
    @State private var rrAuditReport: SessionStorageDiagnostic.Report?
    @State private var rrAuditRunning = false
    /// MetricKit history and memory trace, read from disk once per appear
    /// (`loadDiagnosticFiles`), not on every evaluation of the section.
    @State private var metricKitHistory: [[String: Any]] = []
    @State private var memoryTrace: [[String: Any]] = []

    @ViewBuilder
    var body: some View {
        withAlerts(
            List {
                archiveIndexSection

                // Surface where RR data actually lives so we
                // can answer "did my data get lost?" with file-system facts
                // instead of guesses. Read-only inspection.
                actionsSection

                fileSystemSection
            }
            .zenFormBackground()
            .navigationTitle(String(localized: "Archive Diagnostics", bundle: LanguageManager.appBundle))
            .task {
                await refreshDiagnostics()
            }
        )
    }

    private func withAlerts(_ content: some View) -> some View {
        content
            .alert(String(localized: "Repair Archive?", bundle: LanguageManager.appBundle), isPresented: $showingRepairConfirm) {
                repairDialogActions
            } message: {
                Text(String(localized: "This rebuilds the index from the session files it can read. No file is deleted.", bundle: LanguageManager.appBundle))
            }
            .alert(String(localized: "Result", bundle: LanguageManager.appBundle), isPresented: $showingResult) {
                Button(String(localized: "OK", bundle: LanguageManager.appBundle)) {}
            } message: {
                Text(repairResult)
            }
    }

    private var archiveIndexSection: some View {
        Section(String(localized: "Archive Index", bundle: LanguageManager.appBundle)) {
            Text(diagnosticInfo)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        demoSessionSection

        rrStorageAuditSection

        // MetricKit-based "why did iOS kill us?"
        // diagnostics. Categorized exit reasons + memory/thermal
        // trace samples from recordings.
        systemDiagnosticsSection

        actionsSection2
    }

    /// Sample nights, so the app can be evaluated without a chest strap. The
    /// same section Troubleshooting shows; kept here too because support notes
    /// written before it moved still point at this page.
    private var demoSessionSection: some View {
        SampleDataSection()
    }

    /// No wipe here. A local-only wipe of the archive directory takes Trash
    /// and the deletion list with it and, with no recording guard and no lock,
    /// loses unsynced nights for good. Deleting data goes through Delete
    /// All My Data, which has the typed-phrase gate and the recording guard.
    private var actionsSection2: some View {
        Section {
            refreshButton

            repairArchiveButton
                .disabled(isRepairing)
        } header: {
            Text(String(localized: "Actions", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: "To delete your data, use Settings → Advanced Data Controls → Delete All My Data.", bundle: LanguageManager.appBundle))
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await refreshDiagnostics() }
        } label: {
            Label(String(localized: "Refresh", bundle: LanguageManager.appBundle), systemImage: "arrow.clockwise")
        }
    }

    private var repairArchiveButton: some View {
        Button {
            showingRepairConfirm = true
        } label: {
            Label(String(localized: "Repair Archive", bundle: LanguageManager.appBundle), systemImage: "wrench.and.screwdriver")
        }
    }

    private var fileSystemSection: some View {
        Section(String(localized: "File System", bundle: LanguageManager.appBundle)) {
            scanArchiveDirectoryButton
        }
    }

    private var scanArchiveDirectoryButton: some View {
        Button {
            Task { await scanFileSystem() }
        } label: {
            Label(String(localized: "Scan Archive Directory", bundle: LanguageManager.appBundle), systemImage: "folder.badge.questionmark")
        }
    }

    /// Off main: a sync walk of the entire archive index plus per-entry
    /// string building would block the Settings sub-page open for 50–200 ms
    /// on a 200-session archive. Runs
    /// on a userInitiated detached task; UI displays whatever was last shown
    /// until the walk finishes, then updates atomically.
    private func refreshDiagnostics() async {
        let entries = collector.archive.store.entries
        diagnosticInfo = await Task.detached(priority: .userInitiated) {
            Self.indexReport(entries: entries)
        }.value
    }

    /// Headings are localized; ids, paths and timestamps stay in their
    /// machine form so they can be matched against logs.
    nonisolated private static func indexReport(entries: [SessionArchiveEntry]) -> String {
        let bundle = LanguageManager.appBundle
        var info = String(localized: "Index entries: \(entries.count)", bundle: bundle) + "\n\n"
        guard !entries.isEmpty else { return info + String(localized: "No sessions in index.", bundle: bundle) }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        info += String(localized: "Sessions by date:", bundle: bundle) + "\n"
        for (i, entry) in entries.prefix(50).enumerated() {
            let rmssd = entry.meanRMSSD.map { String(format: "%.1f", locale: LanguageManager.appLocale, $0) } ?? "?"
            info += "\(i + 1). \(dateFormatter.string(from: entry.date)) - RMSSD: \(rmssd)\n"
            info += "   ID: \(entry.sessionId.uuidString.prefix(8))...\n"
            info += "   …\(entry.filePath.suffix(40))\n\n"
        }
        if entries.count > 50 {
            info += String(localized: "… and \(entries.count - 50) more", bundle: bundle) + "\n"
        }
        return info
    }

    /// Off main: the directory enumeration + filter passes
    /// on 200+ files are a 50–300 ms sync block that would take the UI down on
    /// every button tap. Off-loaded to a userInitiated detached task; result
    /// assigned back on MainActor.
    private func scanFileSystem() async {
        let indexedFileNames = Set(collector.archive.store.entries.map { URL(fileURLWithPath: $0.filePath).lastPathComponent })
        diagnosticInfo = await Task.detached(priority: .userInitiated) {
            Self.fileSystemReport(indexedFileNames: indexedFileNames)
        }.value
    }

    nonisolated private static func fileSystemReport(indexedFileNames: Set<String>) -> String {
        let fm = FileManager.default
        guard let containerURL = fm.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier) else {
            return containerUnavailableMessage
        }
        let archiveDir = containerURL.appendingPathComponent(AppConfig.archiveDirectoryName)
        var info = String(localized: "Archive directory:", bundle: LanguageManager.appBundle) + "\n\(archiveDir.path)\n\n"
        do {
            let files = try fm.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey])
            info += fileCensus(files, indexedFileNames: indexedFileNames)
        } catch {
            info += String(localized: "Error scanning: \(error.localizedDescription)", bundle: LanguageManager.appBundle)
        }
        return info
    }

    nonisolated private static var containerUnavailableMessage: String {
        String(localized: "Error: the app's storage container can't be opened.", bundle: LanguageManager.appBundle)
    }

    /// Files in the archive directory that are not sessions: the index, the
    /// deleted list and every CloudKitSyncState sidecar (the same set
    /// `SessionArchive.reservedFileNames` keeps out of orphan adoption).
    nonisolated private static let nonSessionFileNames: Set<String> = [
        "index.json", "deleted.json", "sync_state.json", "pending_uploads.json",
        "quarantined_uploads.json", "local_only_sessions.json", "record_versions.json"
    ]

    nonisolated private static func fileCensus(_ files: [URL], indexedFileNames: Set<String>) -> String {
        let jsonFiles = files.filter { $0.pathExtension == "json" && !nonSessionFileNames.contains($0.lastPathComponent) }
        let notIndexed = jsonFiles.filter { !indexedFileNames.contains($0.lastPathComponent) }.count
        let encryptedFiles = files.filter { $0.pathExtension == "encrypted" }
        let indexFile = files.first { $0.lastPathComponent == "index.json" }
        let bundle = LanguageManager.appBundle
        var lines = [String(localized: "Files found:", bundle: bundle)]
        lines.append("- " + String(localized: "Session files: \(jsonFiles.count)", bundle: bundle))
        lines.append("- " + String(localized: "Encrypted files: \(encryptedFiles.count)", bundle: bundle))
        lines.append("- " + (indexFile != nil
            ? String(localized: "Index file: present", bundle: bundle)
            : String(localized: "Index file: missing", bundle: bundle)))
        var info = lines.joined(separator: "\n") + "\n\n" + encryptedFileReport(encryptedFiles)
        info += "\n" + String(localized: "Index entries: \(indexedFileNames.count)", bundle: bundle) + "\n"
        info += String(localized: "Files not in the index: \(notIndexed)", bundle: bundle) + "\n"
        return info
    }

    nonisolated private static func encryptedFileReport(_ encryptedFiles: [URL]) -> String {
        guard !encryptedFiles.isEmpty else { return "" }
        let bundle = LanguageManager.appBundle
        var info = String(localized: "Encrypted files (cannot read):", bundle: bundle) + "\n"
        for file in encryptedFiles.prefix(10) {
            info += "  - \(file.lastPathComponent)\n"
        }
        if encryptedFiles.count > 10 {
            info += "  " + String(localized: "… and \(encryptedFiles.count - 10) more", bundle: bundle) + "\n"
        }
        info += "\n" + String(localized: "Repair Archive leaves these files in place.", bundle: bundle) + "\n"
        return info
    }

    /// Repair decodes and decrypts every session file, so it runs on a
    /// detached task, not the main actor. A repair that could not list the
    /// directory or save the rebuilt index is reported as failed, with the
    /// error, never as complete.
    private func performRepair() {
        isRepairing = true
        let archive = collector.archive
        let indexedBefore = archive.store.entries.count
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { Self.repair(archive) }.value
            isRepairing = false
            // Screens keyed on the archive signal reload the rebuilt index.
            collector.notifyArchiveChanged()
            repairResult = Self.repairMessage(outcome, indexedBefore: indexedBefore)
            showingResult = true
            await refreshDiagnostics()
        }
    }

    nonisolated private static func repair(_ archive: SessionArchive) -> Result<Int, Error> {
        do {
            return .success(try archive.repairArchive())
        } catch {
            return .failure(error)
        }
    }

    /// repairArchive returns the rebuilt index's size; recovered is what it
    /// added. A repair that threw is reported with its error.
    private static func repairMessage(_ outcome: Result<Int, Error>, indexedBefore: Int) -> String {
        switch outcome {
        case .success(let count):
            let recovered = max(0, count - indexedBefore)
            return String(localized: "Repair complete. \(recovered) sessions recovered.", bundle: LanguageManager.appBundle)
        case .failure(let error):
            return String(localized: "Repair did not finish: \(error.localizedDescription)", bundle: LanguageManager.appBundle)
        }
    }

    // MARK: - RR Storage Audit

    @ViewBuilder
    private var rrStorageAuditSection: some View {
        Section(String(localized: "RR Storage Audit", bundle: LanguageManager.appBundle)) {
            if let report = rrAuditReport {
                rrAuditSummary(report)
                rrAuditDetailLink(report)
            } else {
                Text("Walks every archived session + the RawRRBackup safety net to show exactly where each session's beat-by-beat data lives. Read-only — won't modify anything.", bundle: LanguageManager.appBundle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            auditingSection
        }
    }

    private var auditingSection: some View {
        Button {
            runRRAudit()
        } label: {
            rrAuditButtonLabel
        }
        .disabled(rrAuditRunning)
    }

    @ViewBuilder
    private var rrAuditButtonLabel: some View {
        if rrAuditRunning {
            HStack { ProgressView(); Text("Auditing…", bundle: LanguageManager.appBundle) }
        } else {
            Label(String(localized: "Run RR Storage Audit", bundle: LanguageManager.appBundle), systemImage: "magnifyingglass")
        }
    }

    @ViewBuilder
    private func rrAuditDetailLink(_ report: SessionStorageDiagnostic.Report) -> some View {
        NavigationLink {
            RRStorageAuditDetailView(report: report)
        } label: {
            Label(
                String(localized: "Per-session detail (\(report.sessions.count) sessions)", bundle: LanguageManager.appBundle),
                systemImage: "list.bullet.rectangle"
            )
        }
    }

    private func rrAuditSummary(_ report: SessionStorageDiagnostic.Report) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            auditRow(String(localized: "Total sessions", bundle: LanguageManager.appBundle), "\(report.totalSessions)")
            auditRow("✓ " + String(localized: "Both archive + backup", bundle: LanguageManager.appBundle), "\(report.bothPresentCount)", color: .green)
            auditRow("✓ " + String(localized: "Archive only", bundle: LanguageManager.appBundle), "\(report.archivedFullCount)", color: .green)
            auditRow("⚠ " + String(localized: "Backup-only (repairable)", bundle: LanguageManager.appBundle), "\(report.backupOnlyCount)", color: .orange)
            auditRow("✗ " + String(localized: "Neither store has beats", bundle: LanguageManager.appBundle), "\(report.neitherCount)", color: .red)
            rrAuditExceptions(report)
            Divider()
            auditRow(String(localized: "Archive directory size", bundle: LanguageManager.appBundle), byteString(report.archiveTotalBytes))
            auditRow(String(localized: "Backup directory size", bundle: LanguageManager.appBundle), byteString(report.backupTotalBytes))
        }
        .font(.system(.caption, design: .monospaced))
    }

    @ViewBuilder
    private func rrAuditExceptions(_ report: SessionStorageDiagnostic.Report) -> some View {
        if report.unreadableCount > 0 {
            auditRow("? " + String(localized: "Unreadable file", bundle: LanguageManager.appBundle), "\(report.unreadableCount)", color: .red)
        }
        if !report.orphanedBackupIds.isEmpty {
            auditRow(
                String(localized: "Orphaned backups (in backup but not in archive)", bundle: LanguageManager.appBundle),
                "\(report.orphanedBackupIds.count)",
                color: .blue
            )
        }
    }

    @ViewBuilder
    private func auditRow(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text(value)
                .foregroundStyle(color)
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func runRRAudit() {
        rrAuditRunning = true
        let archive = collector.archive
        let backup = collector.rawBackup
        Task.detached(priority: .userInitiated) {
            let report = SessionStorageDiagnostic.run(archive: archive, backup: backup)
            await MainActor.run {
                rrAuditReport = report
                rrAuditRunning = false
            }
        }
    }
    // MARK: - System Diagnostics (MetricKit / memory / thermal)

    @ViewBuilder
    private var systemDiagnosticsSection: some View {
        Section(String(localized: "System Diagnostics", bundle: LanguageManager.appBundle)) {
            Text("MetricKit + real-time memory / thermal sampling. Captures the iOS-level reason for any background termination during a recording session.", bundle: LanguageManager.appBundle)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)

            // Keyboard-focus hang investigation. Records an
            // os_signpost timeline of the chat input render path (until
            // Stop, at most 10 minutes) so the user can capture the hang
            // on real hardware and share a trace. See KeyboardCaptureView.
            captureKeyboardPerformanceProfileSection

            diagnosticsLinks
        }
        .task { await loadDiagnosticFiles() }
    }

    /// The two files are read and parsed (up to about 1.25 MB of JSON lines)
    /// off the main actor; only the assignment runs on it.
    private func loadDiagnosticFiles() async {
        let files = await Self.readDiagnosticFiles(from: dependencies.app.systemDiagnosticsManager)
        metricKitHistory = files.history
        memoryTrace = files.trace
    }

    /// Nonisolated and async, so it runs on the global executor. The arrays
    /// are built fresh here and handed over (`sending`) to the caller.
    nonisolated private static func readDiagnosticFiles(
        from manager: SystemDiagnosticsManager
    ) async -> sending (history: [[String: Any]], trace: [[String: Any]]) {
        (manager.readMetricKitHistory(), manager.readRecentMemoryTrace(limit: 1000))
    }

    @ViewBuilder
    private var diagnosticsLinks: some View {
        let history = metricKitHistory
        let trace = memoryTrace
        if history.isEmpty && trace.isEmpty {
            Text("No diagnostic data yet. Record a session — memory/thermal samples capture every 5 s. After a SIGKILL, MetricKit delivers the categorized exit reason on the NEXT app launch (typically once per day).", bundle: LanguageManager.appBundle)
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
        } else {
            metricKitHistoryLink(history)
            memoryTraceLink(trace)
        }
    }

    @ViewBuilder
    private func metricKitHistoryLink(_ history: [[String: Any]]) -> some View {
        if !history.isEmpty {
            NavigationLink {
                MetricKitHistoryView(payloads: history)
            } label: {
                Label(String(localized: "MetricKit history (\(history.count))", bundle: LanguageManager.appBundle), systemImage: "doc.text.magnifyingglass")
            }
        }
    }

    @ViewBuilder
    private func memoryTraceLink(_ trace: [[String: Any]]) -> some View {
        if !trace.isEmpty {
            NavigationLink {
                MemoryTraceView(trace: trace)
            } label: {
                Label(String(localized: "Memory / thermal trace (\(trace.count))", bundle: LanguageManager.appBundle), systemImage: "memorychip")
            }
        }
    }

    @ViewBuilder
    private var repairDialogActions: some View {
        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
        Button(String(localized: "Repair", bundle: LanguageManager.appBundle)) {
            performRepair()
        }
    }

    private var captureKeyboardPerformanceProfileSection: some View {
        NavigationLink {
            KeyboardCaptureView()
        } label: {
            Label(String(localized: "Capture keyboard performance profile", bundle: LanguageManager.appBundle), systemImage: "keyboard.badge.ellipsis")
        }
    }
}
