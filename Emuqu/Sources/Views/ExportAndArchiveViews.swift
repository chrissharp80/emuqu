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
        beginExport()
        Task { await runRRCSVExport() }
    }

    /// Clears the previous export's file and shortfall note so a warning
    /// never attaches to a different export's file.
    private func beginExport() {
        isExporting = true
        exportURL = nil
        exportShortfall = nil
    }

    /// "N of M sessions were exported…", or nil when nothing was left out.
    private static func shortfallNote(written: Int, total: Int) -> String? {
        guard written < total else { return nil }
        return String(localized: "\(written) of \(total) sessions were exported. The others couldn't be read — unlock your iPhone and export again to include them.", bundle: LanguageManager.appBundle)
    }

    private func runRRCSVExport() async {
        let archive = collector.archive
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.timestampedName(prefix: "Emuqu_RR", ext: "csv"))
        let total = archive.entries.count
        do {
            let unreadable = try await Task.detached(priority: .userInitiated) {
                try Self.streamRRCSV(to: tempURL, archive: archive)
            }.value
            await MainActor.run {
                exportShortfall = Self.shortfallNote(written: total - unreadable, total: total)
                finishExport(url: tempURL)
            }
        } catch {
            debugLog("[Export] RR export failed: \(error.localizedDescription)")
            _ = attempt("ExportAndArchiveViews.remove") { try FileManager.default.removeItem(at: tempURL) }
            await MainActor.run { failExport(error) }
        }
    }

    nonisolated private static func timestampedName(prefix: String, ext: String) -> String {
        "\(prefix)_\(machineDateFormatter("yyyyMMdd_HHmmss").string(from: Date())).\(ext)"
    }

    /// File names and CSV columns are machine formats: fixed POSIX locale and
    /// Gregorian calendar, whatever the device or app language.
    nonisolated private static func machineDateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter
    }

    /// Returns how many sessions could not be read or written, so the screen
    /// can say the file is partial.
    nonisolated private static func streamRRCSV(to tempURL: URL, archive: SessionArchive) throws -> Int {
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { attempt("export.rrCSV.close") { try handle.close() } }
        try handle.write(contentsOf: Data("session_date,timestamp_ms,rr_ms\n".utf8))
        let dateFormatter = machineDateFormatter("yyyy-MM-dd_HHmm")
        var unreadable = 0
        var pointCount = 0
        for entry in archive.entries {
            let beats = autoreleasepool {
                writeRRRows(for: entry, archive: archive, dateFormatter: dateFormatter, handle: handle)
            }
            if let beats { pointCount += beats } else { unreadable += 1 }
        }
        debugLog("[Export] Streamed RR CSV: \(pointCount) beats, \(unreadable) sessions unreadable → \(tempURL.lastPathComponent)")
        return unreadable
    }

    /// Beats written for this entry (0 when the session has no RR series), or
    /// nil when the session couldn't be read or its rows couldn't be written.
    nonisolated private static func writeRRRows(
        for entry: SessionArchiveEntry,
        archive: SessionArchive,
        dateFormatter: DateFormatter,
        handle: FileHandle
    ) -> Int? {
        guard let session = attempt("export.rrCSV.retrieve", { try archive.retrieve(entry.sessionId) }) ?? nil else {
            return nil
        }
        guard let rrSeries = session.rrSeries else { return 0 }
        let wrote = writeRRChunk(rrSeries, date: dateFormatter.string(from: session.startDate), handle: handle)
        return wrote ? rrSeries.points.count : nil
    }

    /// Build a per-session string then write once. Keeps peak memory bounded by
    /// one session's RR rows (~600 KB for an overnight) instead of all sessions
    /// concatenated (~140 MB). False when the write failed: a dropped chunk
    /// produces a file that looks complete and is not, so it's counted and
    /// reported.
    nonisolated private static func writeRRChunk(_ rrSeries: RRSeries, date sessionDateStr: String, handle: FileHandle) -> Bool {
        var chunk = ""
        chunk.reserveCapacity(rrSeries.points.count * 32)
        for point in rrSeries.points {
            chunk += "\(sessionDateStr),\(point.t_ms),\(point.rr_ms)\n"
        }
        return attempt("export.rrCSV.write") { try handle.write(contentsOf: Data(chunk.utf8)) } != nil
    }

    private func exportCSV() {
        beginExport()
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

    /// Numbers use a "." decimal separator in every locale (`locale: nil`) so
    /// a "72,5" never splits a row into extra columns.
    nonisolated private static func summaryCSVRow(_ entry: SessionArchiveEntry, dateFormatter: ISO8601DateFormatter) -> String {
        let dateStr = dateFormatter.string(from: entry.date)
        let sessionType = entry.sessionType.rawValue
        let recoveryScore = entry.recoveryScore.map { String(format: "%.1f", locale: nil, $0) } ?? ""
        let rmssd = entry.meanRMSSD.map { String(format: "%.2f", locale: nil, $0) } ?? ""
        let tags = entry.tags.map(\.name).joined(separator: ";")
        let notes = (entry.notes ?? "").replacingOccurrences(of: "\n", with: " ")
        let quoted = [dateStr, sessionType].map(csvQuoted).joined(separator: ",")
        return "\(quoted),\(recoveryScore),\(rmssd),\(csvQuoted(tags)),\(csvQuoted(notes))\n"
    }

    /// RFC 4180 field: wrapped in quotes, with embedded quotes doubled.
    nonisolated private static func csvQuoted(_ field: String) -> String {
        "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Never load every session WITH `rrSeries` into a single
    /// `[HRVSession]` and JSON-encode the whole thing in one shot. With 200+
    /// sessions × ~20K beats each (~140 MB of raw beat JSON, ~280 MB
    /// pretty-printed), that hits the iOS app memory ceiling and the OS
    /// SIGKILLs us ("crashes every time I try to export").
    /// Stream session-by-session straight to disk inside an
    /// autoreleasepool so peak memory never exceeds one session's footprint.
    private func exportAllData() {
        beginExport()
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
                exportShortfall = Self.shortfallNote(written: written, total: entries.count)
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
    @State private var diagnosticInfo = String(localized: "Loading...", bundle: LanguageManager.appBundle)
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
        let archiveEntryCount = collector.archive.entries.count
        diagnosticInfo = await Task.detached(priority: .userInitiated) {
            Self.fileSystemReport(archiveEntryCount: archiveEntryCount)
        }.value
    }

    nonisolated private static func fileSystemReport(archiveEntryCount: Int) -> String {
        let fm = FileManager.default
        guard let containerURL = fm.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier) else {
            return containerUnavailableMessage
        }
        let archiveDir = containerURL.appendingPathComponent(AppConfig.archiveDirectoryName)
        var info = String(localized: "Archive directory:", bundle: LanguageManager.appBundle) + "\n\(archiveDir.path)\n\n"
        do {
            let files = try fm.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey])
            info += fileCensus(files, archiveEntryCount: archiveEntryCount)
        } catch {
            info += String(localized: "Error scanning: \(error.localizedDescription)", bundle: LanguageManager.appBundle)
        }
        return info
    }

    nonisolated private static var containerUnavailableMessage: String {
        String(localized: "Error: the app's storage container can't be opened.", bundle: LanguageManager.appBundle)
    }

    nonisolated private static func fileCensus(_ files: [URL], archiveEntryCount: Int) -> String {
        let jsonFiles = files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.contains("index") && !$0.lastPathComponent.contains("deleted") }
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
        info += "\n" + String(localized: "Index entries: \(archiveEntryCount)", bundle: bundle) + "\n"
        info += String(localized: "Files not in the index: \(abs(jsonFiles.count - archiveEntryCount))", bundle: bundle) + "\n"
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
        info += "\n" + String(localized: "Run Repair Archive to remove these.", bundle: bundle) + "\n"
        return info
    }

    /// Repair decodes and decrypts every session file, so it runs on a
    /// detached task, not the main actor.
    private func performRepair() {
        isRepairing = true
        let archive = collector.archive
        Task {
            let count = await Task.detached(priority: .userInitiated) { archive.repairArchive() }.value
            isRepairing = false
            repairResult = String(localized: "Repair complete. \(count) sessions recovered.", bundle: LanguageManager.appBundle)
            showingResult = true
            await refreshDiagnostics()
        }
    }

    /// The delete + recreate of the whole archive directory must not run
    /// synchronously on the main thread: it freezes the UI for the length of
    /// the file-system walk on a large archive. The file ops run on a detached
    /// task. On success the archive's in-memory index is dropped too, so the
    /// app stops listing the deleted sessions and the next index save can't
    /// write them back.
    private func clearAllData() {
        let archive = collector.archive
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { Self.wipeArchiveDirectory() }.value
            if outcome.cleared {
                archive.resetInMemoryStateAfterPurge()
                collector.notifyArchiveChanged()
            }
            repairResult = outcome.message
            showingResult = true
            await refreshDiagnostics()
        }
    }

    nonisolated private static func wipeArchiveDirectory() -> (cleared: Bool, message: String) {
        let fm = FileManager.default
        guard let containerURL = fm.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier) else {
            return (false, containerUnavailableMessage)
        }
        let archiveDir = containerURL.appendingPathComponent(AppConfig.archiveDirectoryName)
        do {
            try fm.removeItem(at: archiveDir)
            try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
            return (true, String(localized: "All archive data cleared. Restart the app to reinitialize.", bundle: LanguageManager.appBundle))
        } catch {
            return (false, String(localized: "Error clearing data: \(error.localizedDescription)", bundle: LanguageManager.appBundle))
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
    }

    @ViewBuilder
    private var diagnosticsLinks: some View {
        let history = dependencies.app.systemDiagnosticsManager.readMetricKitHistory()
        let trace = dependencies.app.systemDiagnosticsManager.readRecentMemoryTrace(limit: 1000)

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
            Label(String(localized: "Capture keyboard performance profile", bundle: LanguageManager.appBundle), systemImage: "keyboard.badge.ellipsis")
        }
    }
}
