import SwiftUI

// MARK: - ImportDataView Preview Sections

extension ImportDataView {
    // MARK: - Header

    var headerSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(AppTheme.primary.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: "square.and.arrow.down")
                    .scaledFont(size: 32)
                    .foregroundColor(AppTheme.primary)
            }

            Text(String(localized: "Import RR Data", bundle: LanguageManager.appBundle))
                .font(.title2.bold())
                .foregroundColor(AppTheme.textPrimary)

            Text(String(localized: "Import RR interval data from other HRV apps or devices to analyze with this app.", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top)
    }

    // MARK: - Format Info

    var formatInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Supported Formats", bundle: LanguageManager.appBundle))
                .font(.headline)
                .foregroundColor(AppTheme.textPrimary)

            formatRows
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
    }

    private var formatRows: some View {
        ForEach(RRDataImporter.ImportFormat.allCases) { formatRow($0) }
    }

    private func formatRow(_ format: RRDataImporter.ImportFormat) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: formatIcon(format))
                .font(.body)
                .foregroundColor(AppTheme.primary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(format.rawValue)
                    .font(.subheadline.bold())
                    .foregroundColor(AppTheme.textPrimary)
                Text(format.description)
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    func formatIcon(_ format: RRDataImporter.ImportFormat) -> String {
        switch format {
        case .csv: "tablecells"
        case .json: "curlybraces"
        case .txt: "doc.text"
        case .kubios: "waveform.path.ecg"
        case .eliteHRV: "heart.text.square"
        case .flowHRVMultiSession: "arrow.triangle.branch"
        }
    }

    // MARK: - Import Button

    var importButtonSection: some View {
        Button {
            showingFilePicker = true
        } label: {
            importSectionLabel
        }
        .buttonStyle(.zen(AppTheme.primary))
        .disabled(isImporting)
        .accessibilityIdentifier("import.selectFile")
    }

    private var importSectionLabel: some View {
        HStack {
            if isImporting {
                ProgressView()
                    .tint(.white)
            } else {
                Image(systemName: "folder.badge.plus")
            }
            Text(isImporting ? String(localized: "Importing...", bundle: LanguageManager.appBundle) : String(localized: "Select File", bundle: LanguageManager.appBundle))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    // MARK: - Import Preview

    func importPreviewSection(_ result: RRDataImporter.ImportResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            loadedHeader(String(localized: "File Loaded Successfully", bundle: LanguageManager.appBundle))
            singleFileInfoRows(result)
            Divider()
            Button(action: startAnalysis) {
                analyzeButtonLabel
            }
            .buttonStyle(.zen(AppTheme.sage))
            .disabled(isAnalyzing)
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
    }

    private func singleFileInfoRows(_ result: RRDataImporter.ImportResult) -> some View {
        VStack(spacing: 8) {
            ImportInfoRow(label: String(localized: "File", bundle: LanguageManager.appBundle), value: result.originalFileName)
            ImportInfoRow(label: String(localized: "Format", bundle: LanguageManager.appBundle), value: result.sourceFormat.rawValue)
            ImportInfoRow(label: String(localized: "Beats", bundle: LanguageManager.appBundle), value: "\(result.beatCount)")
            ImportInfoRow(label: String(localized: "Duration", bundle: LanguageManager.appBundle), value: String(format: String(localized: "%.1f min", bundle: LanguageManager.appBundle), result.durationMinutes))
            if let date = result.recordingDate {
                ImportInfoRow(label: String(localized: "Recorded", bundle: LanguageManager.appBundle), value: formatDate(date))
            }
        }
    }

    private var analyzeButtonLabel: some View {
        HStack {
            if isAnalyzing {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "waveform.path.ecg")
            }
            Text(isAnalyzing
                ? String(localized: "Analyzing...", bundle: LanguageManager.appBundle)
                : String(localized: "Analyze Data", bundle: LanguageManager.appBundle))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Error Section

    func errorSection(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(AppTheme.terracotta)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Import Error", bundle: LanguageManager.appBundle))
                    .font(.subheadline.bold())
                    .foregroundColor(AppTheme.terracotta)
                Text(message).font(.caption).foregroundColor(AppTheme.textSecondary)
            }
            Spacer()
            Button { errorMessage = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundColor(AppTheme.textTertiary)
            }
            .accessibilityLabel(String(localized: "Close", bundle: LanguageManager.appBundle))
        }
        .padding()
        .background(AppTheme.terracotta.opacity(0.1))
        .cornerRadius(AppTheme.cornerRadius)
    }

    // MARK: - Elite HRV Preview

    func eliteHRVPreviewSection(_ result: RRDataImporter.EliteHRVSummaryResult) -> some View {
        // Filter out sessions that already exist in the archive.
        let newSessions = result.sessions.filter { !collector.archive.sessionExists(for: $0.date) }
        let alreadyImportedCount = result.sessions.count - newSessions.count
        return VStack(alignment: .leading, spacing: 16) {
            loadedHeader(String(localized: "Elite HRV Summary Loaded", bundle: LanguageManager.appBundle))
            eliteSummaryRows(result, newSessions: newSessions, alreadyImportedCount: alreadyImportedCount)
            if !newSessions.isEmpty {
                eliteSessionListPreview(newSessions)
                Divider()
            }
            eliteImportButton(newSessions)
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
    }

    private func eliteSummaryRows(
        _ result: RRDataImporter.EliteHRVSummaryResult,
        newSessions: [RRDataImporter.EliteHRVSummaryResult.SessionSummary],
        alreadyImportedCount: Int
    ) -> some View {
        VStack(spacing: 8) {
            ImportInfoRow(label: String(localized: "File", bundle: LanguageManager.appBundle), value: result.originalFileName)
            ImportInfoRow(label: String(localized: "Total Sessions", bundle: LanguageManager.appBundle), value: "\(result.sessions.count)")
            if alreadyImportedCount > 0 {
                ImportInfoRow(label: String(localized: "Already Imported", bundle: LanguageManager.appBundle), value: "\(alreadyImportedCount)")
                ImportInfoRow(label: String(localized: "New Sessions", bundle: LanguageManager.appBundle), value: "\(newSessions.count)")
            }
            if let firstDate = newSessions.first?.date, let lastDate = newSessions.last?.date {
                ImportInfoRow(label: String(localized: "Date Range", bundle: LanguageManager.appBundle), value: formatDateRange(firstDate, lastDate))
            }
            if !newSessions.isEmpty {
                let avgRMSSD = newSessions.map(\.rmssd).reduce(0, +) / Double(newSessions.count)
                ImportInfoRow(label: String(localized: "Avg RMSSD", bundle: LanguageManager.appBundle), value: String(format: String(localized: "%.1f ms", bundle: LanguageManager.appBundle), avgRMSSD))
            }
        }
    }

    private func startFlowImport() { Task { await importAllFlowHRVSessions() } }

    private func startEliteImport() { Task { await importAllEliteHRVSessions() } }

    private func startAnalysis() { Task { await analyzeImportedData() } }

    /// The green check + title shown at the top of every loaded-file preview.
    private func loadedHeader(_ title: String) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(AppTheme.sage)
            Text(title)
                .font(.headline)
                .foregroundColor(AppTheme.textPrimary)
        }
    }

    /// The first few NEW sessions.
    private func eliteSessionListPreview(
        _ newSessions: [RRDataImporter.EliteHRVSummaryResult.SessionSummary]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "New Sessions Preview", bundle: LanguageManager.appBundle))
                .font(.subheadline.bold())
                .foregroundColor(AppTheme.textPrimary)
            ForEach(newSessions.prefix(5), id: \.date) { eliteSessionRow($0) }
            moreSessionsNote(total: newSessions.count)
        }
        .padding(.vertical, 8)
    }

    private func eliteSessionRow(
        _ session: RRDataImporter.EliteHRVSummaryResult.SessionSummary
    ) -> some View {
        HStack {
            Text(formatDate(session.date))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
            Spacer()
            Text(String(format: String(localized: "RMSSD: %.1f", bundle: LanguageManager.appBundle), session.rmssd))
                .font(.caption.bold())
                .foregroundColor(AppTheme.primary)
            Text(String(localized: "\(session.beatCount) beats", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    /// The import action, or the "nothing new" confirmation when every session
    /// in the file is already in the archive.
    @ViewBuilder
    private func eliteImportButton(
        _ newSessions: [RRDataImporter.EliteHRVSummaryResult.SessionSummary]
    ) -> some View {
        if newSessions.isEmpty {
            HStack {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(AppTheme.sage)
                Text(String(localized: "All sessions already imported", bundle: LanguageManager.appBundle))
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else {
            Button(action: startEliteImport) {
                eliteImportButtonLabel(newSessions.count)
            }
            .buttonStyle(.zen(AppTheme.sage))
            .disabled(isSavingBatch)
        }
    }

    @ViewBuilder
    private func eliteImportButtonLabel(_ count: Int) -> some View {
        HStack {
            if isSavingBatch {
                ProgressView().tint(.white)
                importingProgressText
            } else {
                Image(systemName: "square.and.arrow.down.on.square")
                Text(String(localized: "Import \(count) New Sessions", bundle: LanguageManager.appBundle))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    func formatDateRange(_ start: Date, _ end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
    }

    // MARK: - Emuqu Multi-Session Preview

    func flowHRVPreviewSection(_ result: RRDataImporter.FlowHRVMultiSessionResult) -> some View {
        logImportDiagnostics(result)
        let newSessions = newFlowSessionsForPreview(result)
        let alreadyImportedCount = result.sessions.count - newSessions.count
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(AppTheme.sage)
                Text(String(localized: "Emuqu Export Loaded", bundle: LanguageManager.appBundle))
                    .font(.headline)
                    .foregroundColor(AppTheme.textPrimary)
            }
            flowSummaryRows(result, newSessions: newSessions, alreadyImportedCount: alreadyImportedCount)
            if !newSessions.isEmpty { flowSessionListPreview(newSessions) }
            flowImportButton(newSessions)
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
    }

    /// Log the incoming session dates and the archive's, so a mis-parsed
    /// timestamp is visible in the import log rather than silently duplicating.
    private func logImportDiagnostics(_ result: RRDataImporter.FlowHRVMultiSessionResult) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        log("=== Import Session Dates ===")
        for session in result.sessions {
            log("Session: \(session.sessionDate) -> Parsed: \(dateFormatter.string(from: session.date)) (\(session.beatCount) beats)")
        }
        log("=== Archive Index Dates ===")
        for entry in collector.archive.entries.prefix(20) {
            log("Archive: \(dateFormatter.string(from: entry.date)) - ID: \(entry.sessionId.uuidString.prefix(8))")
        }
        if collector.archive.entries.count > 20 {
            log("... and \(collector.archive.entries.count - 20) more archive entries")
        }
    }

    /// Filter out sessions that already exist in the archive.
    private func newFlowSessionsForPreview(
        _ result: RRDataImporter.FlowHRVMultiSessionResult
    ) -> [RRDataImporter.FlowHRVMultiSessionResult.SessionRRData] {
        let newSessions = result.sessions.filter { session in
            let exists = collector.archive.sessionExists(for: session.date)
            if exists { log("DUPLICATE: \(session.sessionDate) matches existing archive entry") }
            return !exists
        }
        log("Result: \(newSessions.count) new, \(result.sessions.count - newSessions.count) duplicates")
        return newSessions
    }

    @ViewBuilder
    private func flowSummaryRows(
        _ result: RRDataImporter.FlowHRVMultiSessionResult,
        newSessions: [RRDataImporter.FlowHRVMultiSessionResult.SessionRRData],
        alreadyImportedCount: Int
    ) -> some View {
        VStack(spacing: 8) {
            ImportInfoRow(label: String(localized: "File", bundle: LanguageManager.appBundle), value: result.originalFileName)
            ImportInfoRow(label: String(localized: "Total Sessions", bundle: LanguageManager.appBundle), value: "\(result.sessions.count)")
            if alreadyImportedCount > 0 {
                ImportInfoRow(label: String(localized: "Already Imported", bundle: LanguageManager.appBundle), value: "\(alreadyImportedCount)")
                ImportInfoRow(label: String(localized: "New Sessions", bundle: LanguageManager.appBundle), value: "\(newSessions.count)")
            }
            if let firstDate = newSessions.first?.date, let lastDate = newSessions.last?.date {
                ImportInfoRow(label: String(localized: "Date Range", bundle: LanguageManager.appBundle), value: formatDateRange(firstDate, lastDate))
            }
            let totalBeats = newSessions.reduce(0) { $0 + $1.beatCount }
            ImportInfoRow(label: String(localized: "Total RR Intervals", bundle: LanguageManager.appBundle), value: "\(totalBeats)")
            if !newSessions.isEmpty {
                let avgDuration = newSessions.map(\.durationMinutes).reduce(0, +) / Double(newSessions.count)
                ImportInfoRow(label: String(localized: "Avg Duration", bundle: LanguageManager.appBundle), value: String(format: String(localized: "%.1f min", bundle: LanguageManager.appBundle), avgDuration))
            }
        }
    }

    /// The first few NEW sessions, plus the note that each will be fully
    /// analysed on import.
    private func flowSessionListPreview(
        _ newSessions: [RRDataImporter.FlowHRVMultiSessionResult.SessionRRData]
    ) -> some View {
        Group {
            flowSessionRows(newSessions)
            Divider()
            fullAnalysisNote
        }
    }

    private func flowSessionRows(
        _ newSessions: [RRDataImporter.FlowHRVMultiSessionResult.SessionRRData]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "New Sessions Preview", bundle: LanguageManager.appBundle))
                .font(.subheadline.bold())
                .foregroundColor(AppTheme.textPrimary)
            ForEach(newSessions.prefix(5), id: \.sessionDate) { flowSessionRow($0) }
            moreSessionsNote(total: newSessions.count)
        }
        .padding(.vertical, 8)
    }

    /// "…and 35 more" when the preview is truncated.
    @ViewBuilder
    private func moreSessionsNote(total: Int) -> some View {
        if total > 5 {
            Text(String(localized: "...and \(total - 5) more", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
                .italic()
        }
    }

    private var fullAnalysisNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundColor(AppTheme.primary)
            Text(String(localized: "Each session will be fully analyzed with artifact detection and HRV metrics calculation.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
        .padding(.vertical, 4)
    }

    private func flowSessionRow(
        _ session: RRDataImporter.FlowHRVMultiSessionResult.SessionRRData
    ) -> some View {
        HStack {
            Text(formatDate(session.date))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
            Spacer()
            Text(String(localized: "\(session.beatCount) beats", bundle: LanguageManager.appBundle))
                .font(.caption.bold())
                .foregroundColor(AppTheme.primary)
            Text(String(format: String(localized: "%.1f min", bundle: LanguageManager.appBundle), session.durationMinutes))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    /// The import action, or the "nothing new" confirmation when every session
    /// in the file is already in the archive.
    @ViewBuilder
    private func flowImportButton(
        _ newSessions: [RRDataImporter.FlowHRVMultiSessionResult.SessionRRData]
    ) -> some View {
        if newSessions.isEmpty {
            HStack {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(AppTheme.sage)
                Text(String(localized: "All sessions already imported", bundle: LanguageManager.appBundle))
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else {
            Button(action: startFlowImport) {
                flowImportButtonLabel(newSessions.count)
            }
            .buttonStyle(.zen(AppTheme.sage))
            .disabled(isSavingBatch)
        }
    }

    @ViewBuilder
    private func flowImportButtonLabel(_ count: Int) -> some View {
        HStack {
            if isSavingBatch {
                ProgressView().tint(.white)
                analyzingProgressText
            } else {
                Image(systemName: "square.and.arrow.down.on.square")
                Text(String(localized: "Import & Analyze \(count) Sessions", bundle: LanguageManager.appBundle))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    /// "Analyzing 3/40…" — blank until the batch reports its first tick.
    @ViewBuilder
    private var analyzingProgressText: some View {
        if let progress = batchImportProgress {
            Text(String(localized: "Analyzing \(progress.current)/\(progress.total)...", bundle: LanguageManager.appBundle))
        }
    }

    /// "Importing 3/40…" — the Elite path's counterpart.
    @ViewBuilder
    private var importingProgressText: some View {
        if let progress = batchImportProgress {
            Text(String(localized: "Importing \(progress.current)/\(progress.total)...", bundle: LanguageManager.appBundle))
        }
    }

    // MARK: - Import Status Section

    var importStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            importStatusHeader

            importLogList
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
    }

    private var importStatusHeader: some View {
        HStack {
            importSpinner
            Text(importStatusMessage.isEmpty ? String(localized: "Processing...", bundle: LanguageManager.appBundle) : importStatusMessage)
                .font(.subheadline.bold())
                .foregroundColor(AppTheme.textPrimary)
            Spacer()

            clearLogsButton
        }
    }

    @ViewBuilder
    private var importSpinner: some View {
        if isImporting || isAnalyzing || isSavingBatch {
            ProgressView()
                .scaleEffect(0.8)
        }
    }

    /// Clear logs button when not actively processing
    @ViewBuilder
    private var clearLogsButton: some View {
        if !isImporting, !isAnalyzing, !isSavingBatch, !importLogs.isEmpty {
            Button {
                importLogs = []
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppTheme.textTertiary)
            }
            .accessibilityLabel(String(localized: "Close", bundle: LanguageManager.appBundle))
        }
    }

    /// Log display
    @ViewBuilder
    private var importLogList: some View {
        if !importLogs.isEmpty {
            importLogScroll
        }
    }

    private var importLogScroll: some View {
        ScrollView {
            importLogLines
        }
        .frame(maxHeight: 150)
        .padding(8)
        .background(Color.black.opacity(0.05))
        .cornerRadius(8)
    }

    private var importLogLines: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(importLogs.enumerated()), id: \.offset) { _, log in
                importLogLine(log)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Errors read red, successes green, everything else neutral — the log is
    /// scanned, not read line by line.
    private func importLogLine(_ log: String) -> some View {
        Text(log)
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(
                log.contains("ERROR") || log.contains("FAIL") ? AppTheme.terracotta :
                    log.contains("SUCCESS") || log.contains("COMPLETE") ? AppTheme.sage :
                    AppTheme.textSecondary
            )
    }

    func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logEntry = "[\(timestamp)] \(message)"
        debugLog("[Import] \(message)") // Also print to console
        Task { @MainActor in
            importLogs.append(logEntry)
            // Keep only last 50 logs
            if importLogs.count > 50 {
                importLogs.removeFirst()
            }
        }
    }

    func updateStatus(_ message: String) {
        Task { @MainActor in
            importStatusMessage = message
        }
        log(message)
    }
}
