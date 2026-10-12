import SwiftUI

// The data-export screen, split out of `SettingsSubviews.swift` together
// with the archive-diagnostics screen (now `ArchiveDiagnosticsView.swift`).
// Both are large, self-contained views; what stays behind is the
// log/crash/error-catalog trio and the metric explanations.

// MARK: - Export Data View

struct ExportDataView: View {
    @Environment(\.dependencies) var dependencies
    /// Materials go opaque when the user asks for reduced transparency —
    /// iOS does not substitute for you. See `AdaptiveMaterial`.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @Environment(RRCollector.self) var collector
    @State private var isExporting = false
    @State private var exportURL: URL?
    /// The running export, cancelled when the screen closes so its file is
    /// deleted on arrival instead of left in tmp (`finishExport`).
    @State private var exportTask: Task<Void, Never>?
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
        .onDisappear { closeScreen() }
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
        exportTask = Task { await runRRCSVExport() }
    }

    /// Clears the previous export's file and shortfall note so a warning
    /// never attaches to a different export's file. The previous file is
    /// deleted, not just forgotten: it is plaintext health data in tmp.
    private func beginExport() {
        isExporting = true
        removeExportFile()
        exportShortfall = nil
    }

    /// The screen is going away: cancel a running export (its file is then
    /// deleted when it arrives) and delete the finished one.
    private func closeScreen() {
        exportTask?.cancel()
        removeExportFile()
    }

    /// Deletes the finished export from tmp once it is replaced or the screen
    /// closes, so plaintext health data doesn't pile up there.
    private func removeExportFile() {
        guard let url = exportURL else { return }
        exportURL = nil
        _ = attempt("ExportDataView.removeExportFile") { try FileManager.default.removeItem(at: url) }
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
        // One snapshot for both the walk and the total, so a session archived
        // or deleted meanwhile cannot skew the shortfall note.
        let entries = archive.entries
        let total = entries.count
        do {
            let unreadable = try await Task.detached(priority: .userInitiated) {
                try Self.streamRRCSV(to: tempURL, archive: archive, entries: entries)
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
    nonisolated private static func streamRRCSV(to tempURL: URL, archive: SessionArchive, entries: [SessionArchiveEntry]) throws -> Int {
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { attempt("export.rrCSV.close") { try handle.close() } }
        try handle.write(contentsOf: Data("session_date,timestamp_ms,rr_ms,session_type\n".utf8))
        let dateFormatter = machineDateFormatter("yyyy-MM-dd_HHmm")
        var unreadable = 0
        var pointCount = 0
        for entry in entries {
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
        let wrote = writeRRChunk(
            rrSeries, date: dateFormatter.string(from: session.startDate), type: session.sessionType, handle: handle)
        return wrote ? rrSeries.points.count : nil
    }

    /// Build a per-session string then write once. Keeps peak memory bounded by
    /// one session's RR rows (~600 KB for an overnight) instead of all sessions
    /// concatenated (~140 MB). False when the write failed: a dropped chunk
    /// produces a file that looks complete and is not, so it's counted and
    /// reported. Each row carries the session type, which the importer reads
    /// back so a nap or quick reading is not re-imported as an overnight.
    nonisolated private static func writeRRChunk(
        _ rrSeries: RRSeries, date sessionDateStr: String, type: SessionType, handle: FileHandle
    ) -> Bool {
        var chunk = ""
        chunk.reserveCapacity(rrSeries.points.count * 40)
        for point in rrSeries.points {
            chunk += "\(sessionDateStr),\(point.t_ms),\(point.rr_ms),\(type.rawValue)\n"
        }
        return attempt("export.rrCSV.write") { try handle.write(contentsOf: Data(chunk.utf8)) } != nil
    }

    private func exportCSV() {
        beginExport()
        exportTask = Task { await runSummaryCSVExport() }
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
        return "\(quoted),\(recoveryScore),\(rmssd),\(csvQuoted(formulaSafe(tags))),\(csvQuoted(formulaSafe(notes)))\n"
    }

    /// User-typed text that a spreadsheet would run as a formula (leading
    /// `=`, `+`, `-`, `@`, tab or carriage return) gets a leading apostrophe,
    /// the OWASP CSV-injection guard, so Excel / Numbers show it as text.
    nonisolated private static func formulaSafe(_ field: String) -> String {
        guard let first = field.first, "=+-@\t\r".contains(first) else { return field }
        return "'" + field
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
        exportTask = Task { await runFullExport() }
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
        isExporting = false
        // The screen closed while this export ran (its task was cancelled on
        // disappear): delete the plaintext health-data file, nobody can share it.
        guard !Task.isCancelled else {
            _ = attempt("ExportDataView.finishExport.discard") { try FileManager.default.removeItem(at: url) }
            return
        }
        exportURL = url
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
