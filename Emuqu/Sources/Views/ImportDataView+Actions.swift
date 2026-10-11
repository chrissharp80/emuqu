import SwiftUI
import UniformTypeIdentifiers

// MARK: - ImportDataView Actions

extension ImportDataView {
    // MARK: - Actions

    func handleFileSelection(_ result: Result<[URL], Error>) {
        errorMessage = nil
        importResult = nil
        eliteHRVResult = nil
        flowHRVResult = nil
        flowNewSessions = []
        eliteNewSessions = []
        importRecordingDate = nil
        importedSleep = nil
        importStatusMessage = ""
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            isImporting = true
            Task { await loadFile(at: url) }
        case let .failure(error):
            log("ERROR: File picker error - \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// What a picked file turned out to be, parsed off the main actor.
    enum ParsedImportFile {
        case flowHRV(RRDataImporter.FlowHRVMultiSessionResult)
        case eliteHRV(RRDataImporter.EliteHRVSummaryResult)
        case standardRR(RRDataImporter.ImportResult)
    }

    /// Read the picked file and hand it to whichever parser its shape calls
    /// for. The read, the format check, the parse and the archive check run
    /// off the main actor, so a multi-megabyte export doesn't freeze the
    /// screen.
    private func loadFile(at url: URL) async {
        do {
            updateStatus(String(localized: "Opening file: \(url.lastPathComponent)", bundle: LanguageManager.appBundle))
            let importer = importer
            let parsed = try await Task.detached(priority: .userInitiated) {
                try Self.parseFile(at: url, importer: importer)
            }.value
            switch parsed {
            case .flowHRV(let result): await showFlowHRV(result)
            case .eliteHRV(let result): await showEliteHRV(result)
            case .standardRR(let result): showStandardRR(result)
            }
        } catch {
            log("ERROR: \(error.localizedDescription)")
            await MainActor.run {
                errorMessage = error.localizedDescription
                isImporting = false
                importStatusMessage = String(localized: "Import failed", bundle: LanguageManager.appBundle)
            }
        }
    }

    /// One read of the file (`RRDataImporter.readFile`, which holds the
    /// security scope), then whichever parser its shape calls for. A plain RR
    /// file is parsed from the same text rather than read a second time.
    nonisolated private static func parseFile(at url: URL, importer: RRDataImporter) throws -> ParsedImportFile {
        let content = try importer.readFile(at: url)
        let fileName = url.lastPathComponent
        if importer.isFlowHRVMultiSession(content) {
            return .flowHRV(try importer.parseFlowHRVMultiSession(content, fileName: fileName))
        }
        if importer.isEliteHRVSummary(content) {
            return .eliteHRV(try importer.parseEliteHRVSummary(content, fileName: fileName))
        }
        return .standardRR(try importer.importContent(content, fileName: fileName))
    }

    /// Emuqu's own multi-session RR export. The count on screen is the
    /// sessions the button will import, not every session in the file.
    private func showFlowHRV(_ flowResult: RRDataImporter.FlowHRVMultiSessionResult) async {
        log("Detected Emuqu multi-session RR export format")
        log("SUCCESS: Found \(flowResult.sessions.count) sessions with raw RR data")
        log("Total RR intervals: \(flowResult.sessions.reduce(0) { $0 + $1.beatCount })")
        let newSessions = await newFlowSessions(flowResult)
        flowNewSessions = newSessions
        flowHRVResult = flowResult
        isImporting = false
        importStatusMessage = String(localized: "Ready to import \(newSessions.count) sessions", bundle: LanguageManager.appBundle)
    }

    /// The archive check runs once here, not on every render of the preview.
    /// The count on screen is the sessions the button will import.
    private func showEliteHRV(_ eliteResult: RRDataImporter.EliteHRVSummaryResult) async {
        log("Detected Elite HRV summary format")
        log("SUCCESS: Parsed \(eliteResult.sessions.count) sessions")
        let newSessions = await newEliteSessions(eliteResult)
        eliteNewSessions = newSessions
        eliteHRVResult = eliteResult
        isImporting = false
        importStatusMessage = String(localized: "Ready to import \(newSessions.count) sessions", bundle: LanguageManager.appBundle)
    }

    /// The Elite HRV sessions the archive holds no copy of, by the rule a
    /// single save applies (`SessionArchive.holdsCopy`: same type,
    /// overlapping span), worked out off the main actor.
    private func newEliteSessions(
        _ eliteResult: RRDataImporter.EliteHRVSummaryResult
    ) async -> [RRDataImporter.EliteHRVSummaryResult.SessionSummary] {
        let archive = collector.archive
        let importer = importer
        let fileName = eliteResult.originalFileName
        let summaries = eliteResult.sessions
        return await Task.detached(priority: .userInitiated) {
            summaries.filter { !archive.holdsCopy(of: importer.createAnalyzedSession(from: $0, originalFileName: fileName)) }
        }.value
    }

    /// A plain single-session RR file, already parsed with the read.
    private func showStandardRR(_ importedResult: RRDataImporter.ImportResult) {
        log("Detected standard RR data format")
        log("SUCCESS: Found \(importedResult.beatCount) RR intervals")
        log("Duration: \(String(format: "%.1f", locale: LanguageManager.appLocale, importedResult.durationMinutes)) minutes")
        log("Format: \(importedResult.sourceFormat.rawValue)")
        importResult = importedResult
        isImporting = false
        importStatusMessage = String(localized: "File loaded - \(importedResult.beatCount) beats", bundle: LanguageManager.appBundle)
    }

    /// Analysed by the live pipeline (`pipelineAnalysis`). A file that does
    /// not say when it was recorded is dated by the user
    /// (`importRecordingDate`, which the preview asks for before Analyze is
    /// enabled), never by the time of import.
    func analyzeImportedData() async {
        guard let result = importResult, let startDate = result.recordingDate ?? importRecordingDate else { return }
        isAnalyzing = true
        updateStatus(String(localized: "Creating session from imported data...", bundle: LanguageManager.appBundle))
        log("Source file: \(result.originalFileName), RR intervals: \(result.beatCount)")
        var session = importer.createSession(from: result, startingAt: startDate)
        log("Session created with \(session.rrSeries?.points.count ?? 0) points")
        guard let series = session.rrSeries else {
            await failAnalysis(String(localized: "Analysis failed - no RR data", bundle: LanguageManager.appBundle), log: "ERROR: No RR series in session")
            return
        }
        session.artifactFlags = await detectAndLogArtifacts(in: series)
        updateStatus(String(localized: "Running HRV analysis...", bundle: LanguageManager.appBundle))
        guard let analysisResult = await pipelineAnalysis(of: session, sleep: ImportSleepWindow.Offsets()) else {
            await failAnalysis(String(localized: "Analysis failed - insufficient clean data", bundle: LanguageManager.appBundle), log: "ERROR: analysis failed")
            return
        }
        session.analysisResult = analysisResult
        session.state = .complete
        session.recoveryScore = nil // scored when saved, against the baseline, not here
        logAnalysisSuccess(result: analysisResult)
        await presentResults(session)
    }

    /// The live recording pipeline (`HRVAnalysisPipeline`) on an imported
    /// recording, so an imported night carries what a live night of the same
    /// data would: PNS/SNS, readiness and nocturnal HR, the window's
    /// metadata (consolidation included) and the overnight HR stats.
    ///
    /// An overnight picks its window within its sleep, when known; any other
    /// reading, and an overnight with no window to pick, is analysed whole.
    /// The pipeline is not main-actor isolated, so the analysis runs off the
    /// main actor. Nil when there is not enough clean data.
    private func pipelineAnalysis(of session: HRVSession, sleep: ImportSleepWindow.Offsets) async -> HRVAnalysisResult? {
        let pipeline = collector.analysisPipeline
        let ansConfig = collector.ansConfig(for: session)
        if session.sessionType == .overnight, let windowed = await pipeline.analyzeWithAutoWindow(
            session: session, sleepStartMs: sleep.startMs, wakeTimeMs: sleep.wakeMs,
            trainingContext: nil, ansConfig: ansConfig, baselineStats: collector.scoringBaselineStats(for: session)
        ) {
            return windowed
        }
        return await pipeline.analyzeFullSession(session: session, peakCapacity: nil, trainingContext: nil, ansConfig: ansConfig)
    }

    /// Pre-load recent sessions off the main thread, then show the results
    /// sheet.
    private func presentResults(_ session: HRVSession) async {
        let recentSessions = await collector.recentSessionsAsync(
            limit: MorningResultsView.recentSessionsContextLimit, before: session.startDate)
        await MainActor.run {
            importedSession = session
            cachedRecentSessions = recentSessions
            isAnalyzing = false
            importStatusMessage = String(localized: "Analysis complete", bundle: LanguageManager.appBundle)
            showingResults = true
        }
    }

    /// Surface a batch-save failure and clear the progress UI.
    @MainActor
    private func failBatch(_ message: String) {
        isSavingBatch = false
        batchImportProgress = nil
        errorMessage = message
        importStatusMessage = String(localized: "Import failed", bundle: LanguageManager.appBundle)
    }

    /// Surface an analysis failure to the user and drop out of the spinner.
    /// The progress line is cleared, so the error card is not shown beside a
    /// stale "Running HRV analysis...".
    private func failAnalysis(_ message: String, log line: String) async {
        log(line)
        await MainActor.run {
            errorMessage = message
            isAnalyzing = false
            importStatusMessage = ""
        }
    }

    /// The artifact flags stored on an imported session, detected off the
    /// main actor.
    private static func detectArtifacts(in series: RRSeries) async -> [ArtifactFlags] {
        await Task.detached(priority: .userInitiated) { ArtifactDetector().detectArtifacts(in: series) }.value
    }

    /// Detect artifacts and report the rate — a high one is worth flagging in
    /// the import log even though it doesn't stop the analysis.
    private func detectAndLogArtifacts(in series: RRSeries) async -> [ArtifactFlags] {
        updateStatus(String(localized: "Detecting artifacts...", bundle: LanguageManager.appBundle))
        let flags = await Self.detectArtifacts(in: series)
        let artifactCount = flags.filter(\.isArtifact).count
        // `flags.count` is zero for an empty series, which would make this a
        // 0/0 Double division — NaN, formatted into the user-visible log as
        // "nan%".
        guard let artifactPct = ImportSleepWindow.artifactPercent(
            artifactCount: artifactCount, totalBeats: flags.count
        ) else {
            log("Artifacts detected: none — the series contains no beats")
            return flags
        }
        log("Artifacts detected: \(artifactCount)/\(flags.count) (\(String(format: "%.1f", locale: LanguageManager.appLocale, artifactPct))%)")
        if artifactPct > 25 {
            log("WARNING: High artifact percentage may affect analysis quality")
        }
        return flags
    }

    private func logAnalysisSuccess(result: HRVAnalysisResult) {
        log("SUCCESS: Analysis complete")
        log("RMSSD: \(String(format: "%.1f", locale: LanguageManager.appLocale, result.timeDomain.rmssd)) ms")
        log("Clean beats: \(result.cleanBeatCount)")
    }

    /// `saveImportedSession` throws `duplicateImport` for a reading at the
    /// same time as one already archived, and `importNotAnalyzed` for one the
    /// pipeline could not score; the screen shows those messages as written
    /// rather than as a generic save failure.
    func saveImportedSession() async {
        guard var session = importedSession else { return }
        if let sleep = importedSleep { applyMeasuredSleep(sleep, to: &session) }
        do {
            try await collector.saveImportedSession(session)
            await MainActor.run {
                showingResults = false
                dismiss()
            }
        } catch {
            await MainActor.run {
                errorMessage = Self.saveFailureMessage(error)
                showingResults = false
            }
        }
    }

    /// Apple Health's measured sleep, which the results screen handed over
    /// while the reading was unsaved, written onto the reading Done saves:
    /// the snapshot, and its bounds as offsets into the recording (a bound
    /// that cannot be represented is left out, as on import).
    private func applyMeasuredSleep(_ sleep: SleepData, to session: inout HRVSession) {
        let offsets = ImportSleepWindow.offsets(
            sleepStart: sleep.sleepStart, sleepEnd: sleep.sleepEnd, recordingStart: session.startDate, note: { log($0) }
        )
        session.sleepSnapshot = sleep
        session.sleepStartMs = offsets.startMs
        session.sleepEndMs = offsets.wakeMs
    }

    private static func saveFailureMessage(_ error: Error) -> String {
        if let collectorError = error as? RRCollector.CollectorError {
            switch collectorError {
            case .duplicateImport, .importNotAnalyzed: return collectorError.localizedDescription
            default: break
            }
        }
        return String(localized: "Failed to save: \(error.localizedDescription)", bundle: LanguageManager.appBundle)
    }

    /// Elite HRV summaries carry pre-computed metrics, so this path skips
    /// re-analysis entirely and just materialises + saves the sessions the
    /// archive doesn't hold yet (the ones the button counts).
    func importAllEliteHRVSessions() async {
        guard let eliteResult = eliteHRVResult else { return }
        let summaries = eliteNewSessions
        await MainActor.run {
            isSavingBatch = true
            batchImportProgress = (0, summaries.count)
        }
        updateStatus(String(localized: "Preparing batch import of \(summaries.count) sessions...", bundle: LanguageManager.appBundle))
        let startTime = Date()
        let sessions = await materialiseEliteSessions(summaries, originalFileName: eliteResult.originalFileName)
        log("Created \(sessions.count) sessions in memory")
        updateStatus(String(localized: "Saving to archive...", bundle: LanguageManager.appBundle))
        do {
            let processedCount = try await collector.saveImportedSessionsBatch(sessions)
            log("Batch import completed in \(String(format: "%.1f", locale: LanguageManager.appLocale, Date().timeIntervalSince(startTime)))s")
            log("Results: \(processedCount) processed (new + updated), \(sessions.count - processedCount) unchanged")
            await MainActor.run { reportBatchOutcome(processed: processedCount, total: sessions.count) }
        } catch {
            log("FAIL: Batch save error: \(error.localizedDescription)")
            await MainActor.run { failBatch(String(localized: "Failed to save sessions: \(error.localizedDescription)", bundle: LanguageManager.appBundle)) }
        }
    }

    /// Build every session in memory first — fast, and it keeps the archive
    /// write to a single batch.
    private func materialiseEliteSessions(
        _ summaries: [RRDataImporter.EliteHRVSummaryResult.SessionSummary],
        originalFileName: String
    ) async -> [HRVSession] {
        log("Source: \(originalFileName)")
        var sessions: [HRVSession] = []
        for (index, summary) in summaries.enumerated() {
            await MainActor.run { batchImportProgress = (index + 1, summaries.count) }
            if index % 50 == 0 {
                updateStatus(String(localized: "Creating sessions: \(index + 1)/\(summaries.count)", bundle: LanguageManager.appBundle))
            }
            sessions.append(importer.createAnalyzedSession(from: summary, originalFileName: originalFileName))
        }
        return sessions
    }

    /// Report the batch result and, on success, dismiss after a beat so the
    /// user can actually read the success log. Sessions that failed analysis
    /// are named on screen, and the screen then stays up so the user sees it.
    @MainActor
    private func reportBatchOutcome(processed: Int, total: Int, failed: Int = 0) {
        isSavingBatch = false
        batchImportProgress = nil
        let unchanged = total - processed
        if failed > 0, processed + unchanged > 0 {
            importStatusMessage = String(localized: "COMPLETE: imported or updated \(processed), could not analyze \(failed)", bundle: LanguageManager.appBundle)
            log("Note: \(failed) sessions failed analysis and were not saved")
        } else if processed > 0 {
            log("SUCCESS: Processed \(processed) sessions")
            importStatusMessage = String(localized: "COMPLETE: \(processed) sessions imported/updated", bundle: LanguageManager.appBundle)
            if unchanged > 0 { log("Note: \(unchanged) sessions were already up to date") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.dismiss() }
        } else if unchanged > 0 {
            importStatusMessage = String(localized: "All \(unchanged) sessions already up to date", bundle: LanguageManager.appBundle)
            log("All sessions were already imported with same data")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.dismiss() }
        } else {
            errorMessage = String(localized: "No valid sessions to import", bundle: LanguageManager.appBundle)
            importStatusMessage = String(localized: "Import failed", bundle: LanguageManager.appBundle)
        }
    }

    /// Run the live HRV analysis pipeline on a single imported session.
    /// Only an overnight reads Apple Health sleep: its window is chosen within
    /// it. A workout, nap or quick reading keeps its exported type and is
    /// analysed whole. Returns the analyzed session on success, nil on failure.
    func analyzeImportedSession(
        _ sessionData: RRDataImporter.FlowHRVMultiSessionResult.SessionRRData,
        originalFileName: String,
        healthKit: HealthKitManager
    ) async -> HRVSession? {
        var session = importer.createSessionFromFlowHRVData(sessionData, originalFileName: originalFileName)
        guard let series = session.rrSeries else {
            log("  FAILED: No RR series")
            return nil
        }
        var sleep = ImportSleepWindow.Offsets()
        if session.sessionType == .overnight { sleep = await sleepBounds(for: sessionData, healthKit: healthKit) }
        session.artifactFlags = await Self.detectArtifacts(in: series)
        guard let analysisResult = await pipelineAnalysis(of: session, sleep: sleep) else {
            log("  FAILED: not enough clean data to analyse")
            return nil
        }
        logWindow(analysisResult)
        session.analysisResult = analysisResult
        session.state = .complete
        session.recoveryScore = nil
        log("  SUCCESS: RMSSD=\(String(format: "%.1f", locale: LanguageManager.appLocale, analysisResult.timeDomain.rmssd))")
        return session
    }

    /// HealthKit sleep boundaries for the imported recording, as offsets into
    /// it. Both nil means we use the full recording as the sleep period.
    ///
    /// The log reads the computed `ms` directly rather than
    /// force-unwrapping the observable property after assignment.
    private func sleepBounds(
        for sessionData: RRDataImporter.FlowHRVMultiSessionResult.SessionRRData,
        healthKit: HealthKitManager
    ) async -> ImportSleepWindow.Offsets {
        let sessionStartDate = sessionData.date
        let sessionEndDate = sessionStartDate
            .addingTimeInterval(Double(sessionData.rrIntervals.reduce(0, +)) / 1000.0)
        do {
            let sleepData = try await healthKit.fetchSleepData(for: sessionStartDate, recordingEnd: sessionEndDate)
            return offsets(of: sleepData, from: sessionStartDate)
        } catch {
            log("  Apple Health ERROR: could not read sleep data (\(error.localizedDescription)) - using full recording as sleep period")
            return ImportSleepWindow.Offsets()
        }
    }

    /// Convert HealthKit's absolute sleep boundaries into offsets into the
    /// recording, logging each as it goes.
    ///
    /// The arithmetic lives in `ImportSleepWindow` so it can be tested: a
    /// bare `Int64(interval * 1000)` traps on a non-finite or out-of-range
    /// date, and its inputs come from a file the user supplied. What stays
    /// here is the logging.
    private func offsets(
        of sleepData: SleepData,
        from sessionStartDate: Date
    ) -> ImportSleepWindow.Offsets {
        let window = ImportSleepWindow.offsets(
            sleepStart: sleepData.sleepStart,
            sleepEnd: sleepData.sleepEnd,
            recordingStart: sessionStartDate,
            note: { log($0) }
        )
        if let startMs = window.startMs, let sleepStart = sleepData.sleepStart {
            log("  Apple Health sleep start: \(sleepStart) (\(startMs / 60000) min into recording)")
        }
        if let wakeMs = window.wakeMs, let sleepEnd = sleepData.sleepEnd {
            log("  Apple Health wake time: \(sleepEnd) (\(wakeMs / 60000) min into recording)")
        }
        if window.startMs == nil, window.wakeMs == nil {
            log("  Apple Health: NO SLEEP DATA for this date - using full recording as sleep period")
        }
        return window
    }

    /// Which slice the pipeline read, from the result's window metadata.
    private func logWindow(_ result: HRVAnalysisResult) {
        guard let position = result.windowRelativePosition else {
            log("  Window: \(result.windowSelectionReason ?? "whole recording")")
            return
        }
        log("  Window found: \(result.windowSelectionReason ?? ""), position: \(String(format: "%.0f", locale: LanguageManager.appLocale, position * 100))%")
    }

    /// Emuqu's own export carries raw RR, so every session is re-analysed
    /// through the full pipeline before it reaches the archive.
    func importAllFlowHRVSessions() async {
        guard let flowResult = flowHRVResult else {
            log("ERROR: flowHRVResult is nil")
            return
        }
        logImportInventory(flowResult)
        let newSessions = await newFlowSessions(flowResult)
        guard !newSessions.isEmpty else {
            log("ERROR: No new sessions to import - all filtered as duplicates")
            await MainActor.run { importStatusMessage = String(localized: "All sessions already imported", bundle: LanguageManager.appBundle) }
            return
        }
        await MainActor.run {
            isSavingBatch = true
            batchImportProgress = (0, newSessions.count)
        }
        let startTime = Date()
        let analyzed = await analyzeFlowSessions(newSessions, originalFileName: flowResult.originalFileName)
        await saveFlowSessions(analyzed.sessions, failedCount: analyzed.failedCount, startTime: startTime)
    }

    private func logImportInventory(_ flowResult: RRDataImporter.FlowHRVMultiSessionResult) {
        log("=== IMPORT START ===")
        log("Total sessions in CSV: \(flowResult.sessions.count)")
        for (i, session) in flowResult.sessions.enumerated() {
            log("CSV[\(i)]: date=\(session.sessionDate) parsed=\(session.date) beats=\(session.beatCount)")
        }
        log("Archive has \(collector.archive.entries.count) entries")
    }

    /// Filter to the sessions the archive holds no copy of, by the rule a
    /// single save applies (`SessionArchive.holdsCopy`: same type,
    /// overlapping span), so a workout or nap near an overnight never hides
    /// it. Worked out off the main actor.
    private func newFlowSessions(
        _ flowResult: RRDataImporter.FlowHRVMultiSessionResult
    ) async -> [RRDataImporter.FlowHRVMultiSessionResult.SessionRRData] {
        log("=== DUPLICATE CHECK ===")
        let archive = collector.archive
        let importer = importer
        let fileName = flowResult.originalFileName
        let sessions = flowResult.sessions
        let newSessions = await Task.detached(priority: .userInitiated) {
            sessions.filter { !archive.holdsCopy(of: importer.createSessionFromFlowHRVData($0, originalFileName: fileName)) }
        }.value
        log("New sessions after filter: \(newSessions.count) of \(sessions.count)")
        return newSessions
    }

    /// Run each new session through the analysis pipeline, yielding between
    /// them so the progress UI keeps up.
    private func analyzeFlowSessions(
        _ newSessions: [RRDataImporter.FlowHRVMultiSessionResult.SessionRRData],
        originalFileName: String
    ) async -> (sessions: [HRVSession], failedCount: Int) {
        log("=== ANALYSIS START ===")
        updateStatus(String(localized: "Preparing to import \(newSessions.count) sessions with full HRV analysis...", bundle: LanguageManager.appBundle))
        var analyzedSessions: [HRVSession] = []
        var failedCount = 0
        let healthKit = collector.healthKit
        for (index, sessionData) in newSessions.enumerated() {
            await MainActor.run { batchImportProgress = (index + 1, newSessions.count) }
            log("Analyzing[\(index)]: \(sessionData.sessionDate) with \(sessionData.beatCount) beats")
            if let analyzed = await analyzeImportedSession(
                sessionData, originalFileName: originalFileName, healthKit: healthKit
            ) {
                analyzedSessions.append(analyzed)
            } else {
                failedCount += 1
            }
            await Task.yield()
        }
        log("=== ANALYSIS COMPLETE ===")
        log("Analyzed: \(analyzedSessions.count) success, \(failedCount) failed")
        return (analyzedSessions, failedCount)
    }

    private func saveFlowSessions(
        _ analyzedSessions: [HRVSession],
        failedCount: Int,
        startTime: Date
    ) async {
        log("=== SAVING TO ARCHIVE ===")
        updateStatus(String(localized: "Saving \(analyzedSessions.count) sessions to archive...", bundle: LanguageManager.appBundle))
        do {
            log("Calling saveImportedSessionsBatch with \(analyzedSessions.count) sessions")
            let processedCount = try await collector.saveImportedSessionsBatch(analyzedSessions)
            log("=== SAVE COMPLETE ===")
            log("Time: \(String(format: "%.1f", locale: LanguageManager.appLocale, Date().timeIntervalSince(startTime)))s")
            log("Saved: \(processedCount), Unchanged: \(analyzedSessions.count - processedCount), Failed: \(failedCount)")
            log("Archive now has \(collector.archive.entries.count) entries")
            await MainActor.run {
                reportBatchOutcome(processed: processedCount, total: analyzedSessions.count, failed: failedCount)
            }
        } catch {
            log("ERROR: Save failed: \(error)")
            await MainActor.run { failBatch(String(localized: "Failed to save sessions: \(error.localizedDescription)", bundle: LanguageManager.appBundle)) }
        }
    }

    func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = LanguageManager.appLocale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
