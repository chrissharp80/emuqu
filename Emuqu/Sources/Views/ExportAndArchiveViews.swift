import SwiftUI

// The data-export and archive-diagnostics screens, split out of
// `SettingsSubviews.swift`. Both are large, self-contained views;
// what stays behind is the log/crash/error-catalog trio and the metric
// explanations.

// MARK: - Export Data View

struct ExportDataView: View {
    @Environment(\.dependencies) var dependencies
    /// Materials go opaque when the user asks for reduced transparency —
    /// iOS does not substitute for you. See `AdaptiveMaterial`.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @Environment(RRCollector.self) var collector
    @State private var isExporting = false
    @State private var exportURL: URL?
    /// Set on export failure so the user sees a reason instead of the
    /// spinner just quietly disappearing.
    @State private var exportError: String?
    /// Set when the full export left sessions out because they could not be
    /// read; shown under the file so a partial export never reads as complete.
    @State private var exportShortfall: String?

    @ViewBuilder
    var body: some View {
        List {
            exportRrIntervalsCsvSection

            exportedFileSection

            statisticsSection
        }
        .zenFormBackground()
        .navigationTitle(String(localized: "Export Data", bundle: LanguageManager.appBundle))
        .accessibilityIdentifier("export.root")
        .overlay { exportingOverlay }
        .alert(
            String(localized: "Export failed", bundle: LanguageManager.appBundle),
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button(String(localized: "OK", bundle: LanguageManager.appBundle), role: .cancel) {}
        } message: {
            exportErrorMessage
        }
    }

    @ViewBuilder
    private var exportingOverlay: some View {
        if isExporting {
            ProgressView(String(localized: "Exporting...", bundle: LanguageManager.appBundle))
                .padding()
                .background(AdaptiveMaterial.regular(reduceTransparency))
                .cornerRadius(10)
        }
    }

    /// The finished file, offered through `ShareLink`, which opens at once.
    /// `UIActivityViewController` raised from a sheet has been measured
    /// cold-starting its share-extension scan for seconds to a minute
    /// (`FitnessPostSummaryView+Share.shareRow`).
    @ViewBuilder
    private var exportedFileSection: some View {
        if let exportURL {
            Section {
                shareExportLink(exportURL)
            } footer: {
                exportedFileFooter(exportURL)
            }
        }
    }

    /// The file's name, and — when some sessions couldn't be read — how many
    /// made it in.
    private func exportedFileFooter(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(url.lastPathComponent)
            if let exportShortfall {
                Text(exportShortfall)
                    .foregroundStyle(AppTheme.warning)
            }
        }
    }

    private func shareExportLink(_ url: URL) -> some View {
        ShareLink(item: url) {
            Label(String(localized: "Share", bundle: LanguageManager.appBundle), systemImage: "square.and.arrow.up")
        }
    }

    @ViewBuilder
    private var exportErrorMessage: some View {
        if let exportError {
            Text(exportError)
        }
    }

    private var exportRrIntervalsCsvSection: some View {
        Section {
            exportRrIntervalsCsvSection2
                .disabled(isExporting)

            exportSummaryCsvSection
                .disabled(isExporting)

            exportAllSessionsJsonSection
                .disabled(isExporting)
        } header: {
            Text(String(localized: "Export Options", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: "RR Intervals exports the raw data needed to recalculate all HRV metrics. Use this for backup and recovery.", bundle: LanguageManager.appBundle))
        }
    }

    private var exportRrIntervalsCsvSection2: some View {
        Button {
            exportRRData()
        } label: {
            Label(String(localized: "Export RR Intervals (CSV)", bundle: LanguageManager.appBundle), systemImage: "waveform.path")
        }
        .accessibilityIdentifier("export.rrIntervals")
    }

    private var exportSummaryCsvSection: some View {
        Button {
            exportCSV()
        } label: {
            Label(String(localized: "Export Summary (CSV)", bundle: LanguageManager.appBundle), systemImage: "tablecells")
        }
    }

    private var exportAllSessionsJsonSection: some View {
        Button {
            exportAllData()
        } label: {
            Label(String(localized: "Export All Sessions (JSON)", bundle: LanguageManager.appBundle), systemImage: "doc.text")
        }
    }

    private var statisticsSection: some View {
        let entries = collector.archive.entries
        return Section(String(localized: "Statistics", bundle: LanguageManager.appBundle)) {
            totalSessionsSection(entries)

            firstRecordingSection(entries)

            latestRecordingSection(entries)
        }
    }

    private func totalSessionsSection(_ entries: [SessionArchiveEntry]) -> some View {
        HStack {
            Text(String(localized: "Total Sessions", bundle: LanguageManager.appBundle))
            Spacer()
            Text("\(entries.count)")
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    private func firstRecordingSection(_ entries: [SessionArchiveEntry]) -> some View {
        if let oldest = entries.last {
            HStack {
                Text(String(localized: "First Recording", bundle: LanguageManager.appBundle))
                Spacer()
                Text(oldest.date, style: .date)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func latestRecordingSection(_ entries: [SessionArchiveEntry]) -> some View {
        if let newest = entries.first {
            HStack {
                Text(String(localized: "Latest Recording", bundle: LanguageManager.appBundle))
                Spacer()
                Text(newest.date, style: .date)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
    }

    /// Same OOM hazard as `exportAllData`: building a single
    /// `var csv = ""` and concatenating millions of rows blows the iOS memory
    /// ceiling. Stream rows directly to a FileHandle and let each session's
    /// RRSeries go out of scope between iterations via `autoreleasepool`.
    private func exportRRData() {
        isExporting = true
        Task { await runRRCSVExport() }
    }

    private func runRRCSVExport() async {
        let archive = collector.archive
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.timestampedName(prefix: "Emuqu_RR", ext: "csv"))
        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.streamRRCSV(to: tempURL, archive: archive)
            }.value
            await MainActor.run { finishExport(url: tempURL) }
        } catch {
            debugLog("[Export] RR export failed: \(error.localizedDescription)")
            _ = attempt("ExportAndArchiveViews.remove") { try FileManager.default.removeItem(at: tempURL) }
            await MainActor.run { failExport(error) }
        }
    }

    nonisolated private static func timestampedName(prefix: String, ext: String) -> String {
        let exportFormatter = DateFormatter()
        exportFormatter.dateFormat = "yyyyMMdd_HHmmss"
        return "\(prefix)_\(exportFormatter.string(from: Date())).\(ext)"
    }

    nonisolated private static func streamRRCSV(to tempURL: URL, archive: SessionArchive) throws {
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data("session_date,timestamp_ms,rr_ms\n".utf8))
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmm"
        var sessionCount = 0
        var pointCount = 0
        for entry in archive.entries {
            let beats = autoreleasepool {
                writeRRRows(for: entry, archive: archive, dateFormatter: dateFormatter, handle: handle)
            }
            sessionCount += beats > 0 ? 1 : 0
            pointCount += beats
        }
        debugLog("[Export] Streamed RR CSV: \(sessionCount) sessions, \(pointCount) beats → \(tempURL.lastPathComponent)")
    }

    /// Beats written for this entry; 0 when the session has no RR series.
    nonisolated private static func writeRRRows(
        for entry: SessionArchiveEntry,
        archive: SessionArchive,
        dateFormatter: DateFormatter,
        handle: FileHandle
    ) -> Int {
        guard let session = try? archive.retrieve(entry.sessionId),
              let rrSeries = session.rrSeries
        else { return 0 }
        writeRRChunk(rrSeries, date: dateFormatter.string(from: session.startDate), handle: handle)
        return rrSeries.points.count
    }

    /// Build a per-session string then write once. Keeps peak memory bounded by
    /// one session's RR rows (~600 KB for an overnight) instead of all sessions
    /// concatenated (~140 MB).
    nonisolated private static func writeRRChunk(_ rrSeries: RRSeries, date sessionDateStr: String, handle: FileHandle) {
        var chunk = ""
        chunk.reserveCapacity(rrSeries.points.count * 32)
        for point in rrSeries.points {
            chunk += "\(sessionDateStr),\(point.t_ms),\(point.rr_ms)\n"
        }
        guard let data = chunk.data(using: .utf8) else { return }
        // Chunked CSV export. A dropped chunk produces a file that looks
        // complete and is not — the user has no way to tell, so the log must.
        attempt("export.rrCSV.write") { try handle.write(contentsOf: data) }
    }

    private func exportCSV() {
        isExporting = true
        Task { await runSummaryCSVExport() }
    }

    private func runSummaryCSVExport() async {
        let entries = collector.archive.entries
        do {
            let tempURL = try await Task.detached(priority: .userInitiated) {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(Self.timestampedName(prefix: "Emuqu_Summary", ext: "csv"))
                try Self.summaryCSV(entries: entries).write(to: url, atomically: true, encoding: .utf8)
                return url
            }.value
            await MainActor.run { finishExport(url: tempURL) }
        } catch {
            debugLog("CSV export failed: \(error)")
            await MainActor.run { failExport(error) }
        }
    }

    nonisolated private static func summaryCSV(entries: [SessionArchiveEntry]) -> String {
        var csv = "date,session_type,recovery_score,rmssd,tags,notes\n"
        let dateFormatter = ISO8601DateFormatter()
        for entry in entries {
            csv += summaryCSVRow(entry, dateFormatter: dateFormatter)
        }
        return csv
    }

    nonisolated private static func summaryCSVRow(_ entry: SessionArchiveEntry, dateFormatter: ISO8601DateFormatter) -> String {
        let dateStr = dateFormatter.string(from: entry.date)
        let sessionType = entry.sessionType.rawValue
        let recoveryScore = entry.recoveryScore.map { String(format: "%.1f", locale: .current, $0) } ?? ""
        let rmssd = entry.meanRMSSD.map { String(format: "%.2f", locale: .current, $0) } ?? ""
        let tags = entry.tags.map(\.name).joined(separator: ";")
        let notes = (entry.notes ?? "").replacingOccurrences(of: ",", with: ";").replacingOccurrences(of: "\n", with: " ")
        return "\"\(dateStr)\",\"\(sessionType)\",\(recoveryScore),\(rmssd),\"\(tags)\",\"\(notes)\"\n"
    }

    /// Never load every session WITH `rrSeries` into a single
    /// `[HRVSession]` and JSON-encode the whole thing in one shot. With 200+
    /// sessions × ~20K beats each (~140 MB of raw beat JSON, ~280 MB
    /// pretty-printed), that hits the iOS app memory ceiling and the OS
    /// SIGKILLs us ("crashes every time I try to export").
    /// Stream session-by-session straight to disk inside an
    /// autoreleasepool so peak memory never exceeds one session's footprint.
    private func exportAllData() {
        isExporting = true
        Task { await runFullExport() }
    }

    private func runFullExport() async {
        let archive = collector.archive
        let entries = archive.entries
        let userFacts = await MainActor.run { dependencies.assistant.userFactsStore.facts }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.timestampedName(prefix: "Emuqu_Export", ext: "json"))
        do {
            let written = try await Task.detached(priority: .userInitiated) {
                try Self.streamExport(to: tempURL, archive: archive, entries: entries, userFacts: userFacts)
            }.value
            await MainActor.run {
                exportShortfall = written < entries.count
                    ? String(localized: "\(written) of \(entries.count) sessions were exported. The others couldn't be read — unlock your iPhone and export again to include them.", bundle: LanguageManager.appBundle)
                    : nil
                finishExport(url: tempURL)
            }
        } catch {
            debugLog("[Export] Export failed: \(error.localizedDescription)")
            _ = attempt("ExportAndArchiveViews.remove") { try FileManager.default.removeItem(at: tempURL) }
            await MainActor.run { failExport(error) }
        }
    }

    @MainActor
    private func finishExport(url: URL) {
        exportURL = url
        isExporting = false
    }

    @MainActor
    private func failExport(_ error: Error) {
        isExporting = false
        exportError = error.localizedDescription
    }

    /// Returns how many sessions made it into the file. The header's
    /// `sessionCount` is how many were asked for; `sessionsWritten` and
    /// `skippedSessionIds`, after the array, say what actually happened.
    @discardableResult
    nonisolated private static func streamExport(to tempURL: URL, archive: SessionArchive, entries: [SessionArchiveEntry], userFacts: [UserFactsStore.Fact]) throws -> Int {
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // No pretty-print — halves output size, halves peak memory while
        // encoding each session.
        encoder.outputFormatting = [.sortedKeys]
        try handle.write(contentsOf: envelopeHeader(encoder: encoder, count: entries.count, userFacts: userFacts))
        try handle.write(contentsOf: Data(",\"sessions\":[".utf8))
        let skipped = writeSessions(entries, archive: archive, encoder: encoder, handle: handle)
        let written = entries.count - skipped.count
        let trailer = "],\"sessionsWritten\":\(written),\"skippedSessionIds\":[" + skipped.map { "\"\($0.uuidString)\"" }.joined(separator: ",") + "]}"
        try handle.write(contentsOf: Data(trailer.utf8))
        debugLog("[Export] Streamed \(written)/\(entries.count) sessions (lightweight; raw RR omitted — use \"Export RR Intervals\" for beats) to \(tempURL.lastPathComponent)")
        return written
    }

    /// The envelope (everything except the sessions array), with its closing
    /// brace stripped so sessions can be spliced in one at a time without ever
    /// holding more than one in memory.
    nonisolated private static func envelopeHeader(encoder: JSONEncoder, count: Int, userFacts: [UserFactsStore.Fact]) throws -> Data {
        struct ExportHeader: Encodable {
            let exportedAt: Date
            let appVersion: String
            let sessionCount: Int
            let userFacts: [UserFactsStore.Fact]
        }
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let header = ExportHeader(exportedAt: Date(), appVersion: appVersion, sessionCount: count, userFacts: userFacts)
        var headerData = try encoder.encode(header)
        guard headerData.last == UInt8(ascii: "}") else {
            throw NSError(domain: "EmuquExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected encoder output"])
        }
        headerData.removeLast()
        return headerData
    }

    /// Use `retrieveLightweight` so the per-session JSON encode
    /// doesn't drag the rrSeries (~20K beats per overnight, ~600 KB encoded
    /// each) through the encoder — decoding + re-encoding millions of beats
    /// makes the export far too slow. The
    /// dedicated "Export RR Intervals (CSV)" path stays available for users who
    /// need the raw beat data; this default GDPR/account-portability export
    /// drops it.
    /// The ids that could not be written, in order.
    nonisolated private static func writeSessions(_ entries: [SessionArchiveEntry], archive: SessionArchive, encoder: JSONEncoder, handle: FileHandle) -> [UUID] {
        var written = 0
        var skipped: [UUID] = []
        for entry in entries {
            let didWrite = autoreleasepool {
                writeOneSession(entry, archive: archive, encoder: encoder, handle: handle, isFirst: written == 0)
            }
            if didWrite { written += 1 } else { skipped.append(entry.sessionId) }
        }
        return skipped
    }

    /// A dropped separator makes the JSON unparseable rather than merely
    /// incomplete, so it's written before every session but the first.
    nonisolated private static func writeOneSession(
        _ entry: SessionArchiveEntry,
        archive: SessionArchive,
        encoder: JSONEncoder,
        handle: FileHandle,
        isFirst: Bool
    ) -> Bool {
        guard let found = attempt("export.session.read", { try archive.retrieveLightweight(entry.sessionId) }),
              let session = found,
              let sessionData = attempt("export.session.encode", { try encoder.encode(session) })
        else { return false }
        // Separator and session in one write: two writes could leave a comma
        // with nothing after it, and an unparseable file.
        let chunk = isFirst ? sessionData : Data(",".utf8) + sessionData
        return attempt("export.session.write") { try handle.write(contentsOf: chunk) } != nil
    }
}

// MARK: - Archive Diagnostics View

struct ArchiveDiagnosticsView: View {
    @Environment(\.dependencies) var dependencies
    @Environment(RRCollector.self) var collector
    @State private var diagnosticInfo: String = "Loading..."
    @State private var isRepairing = false
    @State private var showingRepairConfirm = false
    @State private var showingClearConfirm = false
    @State private var repairResult: String = ""
    @State private var showingResult = false
    /// RR storage audit state. The audit walks the
    /// archive + RawRRBackup and reports per-session whether the raw
    /// beat stream (used for Poincaré + HRV waveform) is on disk in
    /// the archive, in the backup safety net, both, or neither.
    @State private var rrAuditReport: SessionStorageDiagnostic.Report?
    @State private var rrAuditRunning = false

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
                Text(String(localized: "This will remove corrupted/encrypted files and rebuild the index from valid JSON files.", bundle: LanguageManager.appBundle))
            }
            .alert(String(localized: "Clear All Data?", bundle: LanguageManager.appBundle), isPresented: $showingClearConfirm) {
                clearDialogActions
            } message: {
                Text(String(localized: "This will permanently delete ALL archived sessions. This cannot be undone.", bundle: LanguageManager.appBundle))
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

    private var actionsSection2: some View {
        Section(String(localized: "Actions", bundle: LanguageManager.appBundle)) {
            refreshButton

            repairArchiveButton
                .disabled(isRepairing)

            clearAllArchiveDataButton
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

    private var clearAllArchiveDataButton: some View {
        Button(role: .destructive) {
            showingClearConfirm = true
        } label: {
            Label(String(localized: "Clear All Archive Data", bundle: LanguageManager.appBundle), systemImage: "trash")
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
        let entries = collector.archive.entries
        diagnosticInfo = await Task.detached(priority: .userInitiated) {
            Self.indexReport(entries: entries)
        }.value
    }

    nonisolated private static func indexReport(entries: [SessionArchiveEntry]) -> String {
        var info = "Index entries: \(entries.count)\n\n"
        guard !entries.isEmpty else { return info + "No sessions in index." }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        info += "Sessions by date:\n"
        for (i, entry) in entries.prefix(50).enumerated() {
            let dateStr = dateFormatter.string(from: entry.date)
            let rmssd = entry.meanRMSSD.map { String(format: "%.1f", locale: .current, $0) } ?? "?"
            info += "\(i + 1). \(dateStr) - RMSSD: \(rmssd)\n"
            info += "   ID: \(entry.sessionId.uuidString.prefix(8))...\n"
            info += "   Path: ...\(entry.filePath.suffix(40))\n\n"
        }
        if entries.count > 50 {
            info += "... and \(entries.count - 50) more\n"
        }
        return info
    }

    /// Off main: the directory enumeration + filter passes
    /// on 200+ files are a 50–300 ms sync block that would take the UI down on
    /// every button tap. Off-loaded to a userInitiated detached task; result
    /// assigned back on MainActor.
    private func scanFileSystem() async {
        let archiveEntryCount = collector.archive.entries.count
        diagnosticInfo = await Task.detached(priority: .userInitiated) {
            Self.fileSystemReport(archiveEntryCount: archiveEntryCount)
        }.value
    }

    nonisolated private static func fileSystemReport(archiveEntryCount: Int) -> String {
        let fm = FileManager.default
        guard let containerURL = fm.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier) else {
            return "ERROR: Cannot access app group container"
        }
        let archiveDir = containerURL.appendingPathComponent(AppConfig.archiveDirectoryName)
        var info = "Archive Directory:\n\(archiveDir.path)\n\n"
        do {
            let files = try fm.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey])
            info += fileCensus(files, archiveEntryCount: archiveEntryCount)
        } catch {
            info += "Error scanning: \(error.localizedDescription)"
        }
        return info
    }

    nonisolated private static func fileCensus(_ files: [URL], archiveEntryCount: Int) -> String {
        let jsonFiles = files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.contains("index") && !$0.lastPathComponent.contains("deleted") }
        let encryptedFiles = files.filter { $0.pathExtension == "encrypted" }
        let indexFile = files.first { $0.lastPathComponent == "index.json" }
        var info = "Files found:\n"
        info += "- JSON sessions: \(jsonFiles.count)\n"
        info += "- Encrypted files: \(encryptedFiles.count)\n"
        info += "- Index file: \(indexFile != nil ? "YES" : "NO")\n\n"
        info += encryptedFileReport(encryptedFiles)
        info += "\nIndex entries: \(archiveEntryCount)\n"
        info += "Mismatch: \(abs(jsonFiles.count - archiveEntryCount)) files\n"
        return info
    }

    nonisolated private static func encryptedFileReport(_ encryptedFiles: [URL]) -> String {
        guard !encryptedFiles.isEmpty else { return "" }
        var info = "Encrypted files (cannot read):\n"
        for file in encryptedFiles.prefix(10) {
            info += "  - \(file.lastPathComponent)\n"
        }
        if encryptedFiles.count > 10 {
            info += "  ... and \(encryptedFiles.count - 10) more\n"
        }
        info += "\nRun 'Repair Archive' to remove these.\n"
        return info
    }

    private func performRepair() {
        isRepairing = true

        Task {
            let count = collector.archive.repairArchive()
            await MainActor.run {
                isRepairing = false
                repairResult = "Repair complete. \(count) sessions recovered."
                showingResult = true
            }
            await refreshDiagnostics()
        }
    }

    /// The delete + recreate of the whole archive directory must not run
    /// synchronously on the main thread: it freezes the UI for the length of
    /// the file-system walk on a large archive. The file ops run on a detached
    /// task and the result string is assigned back on the MainActor.
    private func clearAllData() {
        Task {
            repairResult = await Task.detached(priority: .userInitiated) { Self.wipeArchiveDirectory() }.value
            showingResult = true
            await refreshDiagnostics()
        }
    }

    nonisolated private static func wipeArchiveDirectory() -> String {
        let fm = FileManager.default
        guard let containerURL = fm.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier) else {
            return "ERROR: Cannot access app group container"
        }
        let archiveDir = containerURL.appendingPathComponent(AppConfig.archiveDirectoryName)
        do {
            try fm.removeItem(at: archiveDir)
            try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
            return "All archive data cleared. Restart app to reinitialize."
        } catch {
            return "Error clearing data: \(error.localizedDescription)"
        }
    }

    // MARK: - RR Storage Audit

    @ViewBuilder
    private var rrStorageAuditSection: some View {
        Section("RR Storage Audit") {
            if let report = rrAuditReport {
                rrAuditSummary(report)
                rrAuditDetailLink(report)
            } else {
                Text("Walks every archived session + the RawRRBackup safety net to show exactly where each session's beat-by-beat data lives. Read-only — won't modify anything.")
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
            HStack { ProgressView(); Text("Auditing…") }
        } else {
            Label("Run RR Storage Audit", systemImage: "magnifyingglass")
        }
    }

    @ViewBuilder
    private func rrAuditDetailLink(_ report: SessionStorageDiagnostic.Report) -> some View {
        NavigationLink {
            RRStorageAuditDetailView(report: report)
        } label: {
            Label(
                "Per-session detail (\(report.sessions.count) sessions)",
                systemImage: "list.bullet.rectangle"
            )
        }
    }

    private func rrAuditSummary(_ report: SessionStorageDiagnostic.Report) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            auditRow("Total sessions", "\(report.totalSessions)")
            auditRow("✓ Both archive + backup", "\(report.bothPresentCount)", color: .green)
            auditRow("✓ Archive only", "\(report.archivedFullCount)", color: .green)
            auditRow("⚠ Backup-only (repairable)", "\(report.backupOnlyCount)", color: .orange)
            auditRow("✗ Neither store has beats", "\(report.neitherCount)", color: .red)
            rrAuditExceptions(report)
            Divider()
            auditRow("Archive directory size", byteString(report.archiveTotalBytes))
            auditRow("Backup directory size", byteString(report.backupTotalBytes))
        }
        .font(.system(.caption, design: .monospaced))
    }

    @ViewBuilder
    private func rrAuditExceptions(_ report: SessionStorageDiagnostic.Report) -> some View {
        if report.unreadableCount > 0 {
            auditRow("? Unreadable file", "\(report.unreadableCount)", color: .red)
        }
        if !report.orphanedBackupIds.isEmpty {
            auditRow(
                "Orphaned backups (in backup but not in archive)",
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
        Section("System Diagnostics") {
            Text("MetricKit + real-time memory / thermal sampling. Captures the iOS-level reason for any background termination during a recording session.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)

            // Keyboard-focus hang investigation. Records
            // a 60 s os_signpost timeline of the chat input render
            // path so the user can capture the hang on real hardware
            // and share a trace. See KeyboardCaptureView.
            captureKeyboardPerformanceProfileSection

            diagnosticsLinks
        }
    }

    @ViewBuilder
    private var diagnosticsLinks: some View {
        let history = dependencies.app.systemDiagnosticsManager.readMetricKitHistory()
        let trace = dependencies.app.systemDiagnosticsManager.readRecentMemoryTrace(limit: 1000)

        if history.isEmpty && trace.isEmpty {
            Text("No diagnostic data yet. Record a session — memory/thermal samples capture every 5 s. After a SIGKILL, MetricKit delivers the categorized exit reason on the NEXT app launch (typically once per day).")
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
                Label("MetricKit history (\(history.count))", systemImage: "doc.text.magnifyingglass")
            }
        }
    }

    @ViewBuilder
    private func memoryTraceLink(_ trace: [[String: Any]]) -> some View {
        if !trace.isEmpty {
            NavigationLink {
                MemoryTraceView(trace: trace)
            } label: {
                Label("Memory / thermal trace (\(trace.count))", systemImage: "memorychip")
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

    @ViewBuilder
    private var clearDialogActions: some View {
        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
        Button(String(localized: "Clear Everything", bundle: LanguageManager.appBundle), role: .destructive) {
            clearAllData()
        }
    }

    private var captureKeyboardPerformanceProfileSection: some View {
        NavigationLink {
            KeyboardCaptureView()
        } label: {
            Label("Capture keyboard performance profile", systemImage: "keyboard.badge.ellipsis")
        }
    }
}
