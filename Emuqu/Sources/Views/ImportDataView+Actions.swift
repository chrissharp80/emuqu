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
        importLogs = []
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

    /// Read the picked file and hand it to whichever parser its shape calls for.
    private func loadFile(at url: URL) async {
        do {
            updateStatus("Opening file: \(url.lastPathComponent)")
            let content = try readTextContents(of: url)
            if importer.isFlowHRVMultiSession(content) {
                try await parseFlowHRV(content, fileName: url.lastPathComponent)
            } else if importer.isEliteHRVSummary(content) {
                try await parseEliteHRV(content, fileName: url.lastPathComponent)
            } else {
                try await parseStandardRR(at: url)
            }
        } catch {
            log("ERROR: \(error.localizedDescription)")
            await MainActor.run {
                errorMessage = error.localizedDescription
                isImporting = false
                importStatusMessage = "Import failed"
            }
        }
    }

    /// The file's UTF-8 text, with the security scope held for the read.
    private func readTextContents(of url: URL) throws -> String {
        guard url.startAccessingSecurityScopedResource() else {
            log("ERROR: Cannot access file - security scope denied")
            throw RRDataImporter.ImportError.fileNotFound
        }
        defer { url.stopAccessingSecurityScopedResource() }
        log("Reading file contents...")
        guard let data = try? Data(contentsOf: url) else {
            log("ERROR: Failed to read file data")
            throw RRDataImporter.ImportError.unreadableFile
        }
        log("File size: \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
        guard let content = String(data: data, encoding: .utf8) else {
            log("ERROR: Cannot decode file as UTF-8 text")
            throw RRDataImporter.ImportError.unreadableFile
        }
        log("File has \(content.components(separatedBy: .newlines).count) lines")
        return content
    }

    /// Emuqu's own multi-session RR export.
    private func parseFlowHRV(_ content: String, fileName: String) async throws {
        log("Detected Emuqu multi-session RR export format")
        updateStatus("Parsing Emuqu sessions...")
        let flowResult = try importer.parseFlowHRVMultiSession(content, fileName: fileName)
        log("SUCCESS: Found \(flowResult.sessions.count) sessions with raw RR data")
        log("Total RR intervals: \(flowResult.sessions.reduce(0) { $0 + $1.beatCount })")
        await MainActor.run {
            flowHRVResult = flowResult
            isImporting = false
            importStatusMessage = "Ready to import \(flowResult.sessions.count) sessions"
        }
    }

    private func parseEliteHRV(_ content: String, fileName: String) async throws {
        log("Detected Elite HRV summary format")
        updateStatus("Parsing Elite HRV summary...")
        let eliteResult = try importer.parseEliteHRVSummary(content, fileName: fileName)
        log("SUCCESS: Parsed \(eliteResult.sessions.count) sessions")
        await MainActor.run {
            eliteHRVResult = eliteResult
            isImporting = false
            importStatusMessage = "Ready to import \(eliteResult.sessions.count) sessions"
        }
    }

    /// A plain single-session RR file — the importer sniffs the exact format.
    private func parseStandardRR(at url: URL) async throws {
        log("Detected standard RR data format")
        updateStatus("Parsing RR intervals...")
        let importedResult = try await importer.importFile(at: url)
        log("SUCCESS: Found \(importedResult.beatCount) RR intervals")
        log("Duration: \(String(format: "%.1f", locale: .current, importedResult.durationMinutes)) minutes")
        log("Format: \(importedResult.sourceFormat.rawValue)")
        await MainActor.run {
            importResult = importedResult
            isImporting = false
            importStatusMessage = "File loaded - \(importedResult.beatCount) beats"
        }
    }

    /// Reuses the same pipeline as live recordings.
    func analyzeImportedData() async {
        guard let result = importResult else { return }
        await MainActor.run { isAnalyzing = true }
        updateStatus("Creating session from imported data...")
        log("Source file: \(result.originalFileName), RR intervals: \(result.beatCount)")
        var session = importer.createSession(from: result)
        log("Session created with \(session.rrSeries?.points.count ?? 0) points")
        guard let series = session.rrSeries else {
            await failAnalysis("Analysis failed - no RR data", log: "ERROR: No RR series in session")
            return
        }
        let flags = detectAndLogArtifacts(in: series)
        guard let analysisResult = await runAnalysis(series: series, flags: flags) else { return }
        session.analysisResult = analysisResult
        session.state = .complete
        session.recoveryScore = WindowSelector().findBestWindow(in: series, flags: flags)?.recoveryScore
        logAnalysisSuccess(session: session, result: analysisResult)
        await presentResults(session)
    }

    /// Pre-load recent sessions off the main thread, then show the results
    /// sheet.
    private func presentResults(_ session: HRVSession) async {
        let recentSessions = await collector.recentSessionsAsync(
            limit: MorningResultsView.recentSessionsContextLimit)
        await MainActor.run {
            importedSession = session
            cachedRecentSessions = recentSessions
            isAnalyzing = false
            importStatusMessage = "Analysis complete"
            showingResults = true
        }
    }

    /// Surface a batch-save failure and clear the progress UI.
    @MainActor
    private func failBatch(_ message: String) {
        isSavingBatch = false
        batchImportProgress = nil
        errorMessage = message
        importStatusMessage = "Import failed"
    }

    /// Surface an analysis failure to the user and drop out of the spinner.
    private func failAnalysis(_ message: String, log line: String) async {
        log(line)
        await MainActor.run {
            errorMessage = message
            isAnalyzing = false
        }
    }

    /// Detect artifacts and report the rate — a high one is worth flagging in
    /// the import log even though it doesn't stop the analysis.
    private func detectAndLogArtifacts(in series: RRSeries) -> [ArtifactFlags] {
        updateStatus("Detecting artifacts...")
        let flags = ArtifactDetector().detectArtifacts(in: series)
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
        log("Artifacts detected: \(artifactCount)/\(flags.count) (\(String(format: "%.1f", locale: .current, artifactPct))%)")
        if artifactPct > 25 {
            log("WARNING: High artifact percentage may affect analysis quality")
        }
        return flags
    }

    /// The same analysis pipeline overnight recordings use. Nil (with the
    /// error already surfaced) when there isn't enough clean data.
    ///
    /// `findBestWindow` analyses all the data on a short recording, so the
    /// fallback bounds are the whole series.
    private func runAnalysis(series: RRSeries, flags: [ArtifactFlags]) async -> HRVAnalysisResult? {
        updateStatus("Running HRV analysis...")
        let window = WindowSelector().findBestWindow(in: series, flags: flags)
        let windowStart = window?.startIndex ?? 0
        let windowEnd = window?.endIndex ?? series.points.count
        let timeDomain = TimeDomainAnalyzer.computeTimeDomain(
            series, flags: flags, windowStart: windowStart, windowEnd: windowEnd)
        let nonlinear = NonlinearAnalyzer.computeNonlinear(
            series, flags: flags, windowStart: windowStart, windowEnd: windowEnd)
        guard let timeDomain, let nonlinear else {
            let which = timeDomain == nil ? "Time domain" : "Nonlinear"
            await failAnalysis("Analysis failed - insufficient clean data", log: "ERROR: \(which) analysis failed")
            return nil
        }
        return Self.assembleResult(
            series: series, flags: flags, windowStart: windowStart, windowEnd: windowEnd,
            timeDomain: timeDomain, nonlinear: nonlinear,
            frequencyDomain: FrequencyDomainAnalyzer.computeFrequencyDomain(
                series, flags: flags, windowStart: windowStart, windowEnd: windowEnd
            )
        )
    }

    /// Fold the per-domain results, stress metrics, and window artifact rate
    /// into one `HRVAnalysisResult`.
    private static func assembleResult(
        series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int,
        windowEnd: Int,
        timeDomain: TimeDomainMetrics,
        nonlinear: NonlinearMetrics,
        frequencyDomain: FrequencyDomainMetrics?
    ) -> HRVAnalysisResult {
        let cleanRR = (windowStart ..< windowEnd)
            .filter { !flags[$0].isArtifact }
            .map { Double(series.points[$0].rr_ms) }
        let windowArtifactCount = flags[windowStart ..< windowEnd].filter(\.isArtifact).count
        let artifactPercentage = Double(windowArtifactCount) / Double(windowEnd - windowStart) * 100
        return HRVAnalysisResult(
            windowStart: windowStart, windowEnd: windowEnd,
            timeDomain: timeDomain, frequencyDomain: frequencyDomain, nonlinear: nonlinear,
            ansMetrics: ANSMetrics(
                stressIndex: StressAnalyzer.computeStressIndex(cleanRR),
                pnsIndex: nil, snsIndex: nil, readinessScore: nil,
                respirationRate: RespirationAnalyzer.estimateRespirationRate(cleanRR),
                nocturnalHRDip: nil, daytimeRestingHR: nil, nocturnalMedianHR: nil
            ),
            artifactPercentage: artifactPercentage, cleanBeatCount: cleanRR.count, analysisDate: Date()
        )
    }

    private func logAnalysisSuccess(session: HRVSession, result: HRVAnalysisResult) {
        log("SUCCESS: Analysis complete")
        log("RMSSD: \(String(format: "%.1f", locale: .current, result.timeDomain.rmssd)) ms")
        log("Clean beats: \(result.cleanBeatCount)")
        if let score = session.recoveryScore {
            log("Readiness score: \(String(format: "%.1f", locale: .current, score))")
        }
    }

    func saveImportedSession() async {
        guard let session = importedSession else { return }

        do {
            try await collector.saveImportedSession(session)
            await MainActor.run {
                showingResults = false
                dismiss()
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to save: \(error.localizedDescription)"
                showingResults = false
            }
        }
    }

    /// Elite HRV summaries carry pre-computed metrics, so this path skips
    /// re-analysis entirely and just materialises + saves the sessions.
    func importAllEliteHRVSessions() async {
        guard let eliteResult = eliteHRVResult else { return }
        await MainActor.run {
            isSavingBatch = true
            batchImportProgress = (0, eliteResult.sessions.count)
        }
        updateStatus("Preparing batch import of \(eliteResult.sessions.count) sessions...")
        log("Source: \(eliteResult.originalFileName)")
        let startTime = Date()
        let sessions = await materialiseEliteSessions(eliteResult)
        log("Created \(sessions.count) sessions in memory")
        updateStatus("Saving to archive...")
        do {
            let processedCount = try await collector.saveImportedSessionsBatch(sessions)
            log("Batch import completed in \(String(format: "%.1f", locale: .current, Date().timeIntervalSince(startTime)))s")
            log("Results: \(processedCount) processed (new + updated), \(sessions.count - processedCount) unchanged")
            await MainActor.run { reportBatchOutcome(processed: processedCount, total: sessions.count) }
        } catch {
            log("FAIL: Batch save error: \(error.localizedDescription)")
            await MainActor.run { failBatch("Failed to save sessions: \(error.localizedDescription)") }
        }
    }

    /// Build every session in memory first — fast, and it keeps the archive
    /// write to a single batch.
    private func materialiseEliteSessions(
        _ eliteResult: RRDataImporter.EliteHRVSummaryResult
    ) async -> [HRVSession] {
        var sessions: [HRVSession] = []
        for (index, summary) in eliteResult.sessions.enumerated() {
            await MainActor.run { batchImportProgress = (index + 1, eliteResult.sessions.count) }
            if index % 50 == 0 {
                updateStatus("Creating sessions: \(index + 1)/\(eliteResult.sessions.count)")
            }
            sessions.append(importer.createAnalyzedSession(
                from: summary, originalFileName: eliteResult.originalFileName
            ))
        }
        return sessions
    }

    /// Report the batch result and, on success, dismiss after a beat so the
    /// user can actually read the success log.
    @MainActor
    private func reportBatchOutcome(processed: Int, total: Int) {
        isSavingBatch = false
        batchImportProgress = nil
        let unchanged = total - processed
        if processed > 0 {
            log("SUCCESS: Processed \(processed) sessions with Elite HRV metrics")
            importStatusMessage = "COMPLETE: \(processed) sessions imported/updated"
            if unchanged > 0 { log("Note: \(unchanged) sessions were already up to date") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.dismiss() }
        } else if unchanged > 0 {
            importStatusMessage = "All \(unchanged) sessions already up to date"
            log("All sessions were already imported with same data")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.dismiss() }
        } else {
            errorMessage = "No valid sessions to import"
            importStatusMessage = "Import failed"
        }
    }

    /// Run the full HRV analysis pipeline on a single imported session.
    /// Returns the analyzed session on success, nil on failure.
    func analyzeImportedSession(
        _ sessionData: RRDataImporter.FlowHRVMultiSessionResult.SessionRRData,
        originalFileName: String,
        healthKit: HealthKitManager
    ) async -> HRVSession? {
        let sleep = await sleepBounds(for: sessionData, healthKit: healthKit)
        var session = importer.createSessionFromFlowHRVData(sessionData, originalFileName: originalFileName)
        guard let series = session.rrSeries else {
            log("  FAILED: No RR series")
            return nil
        }
        let flags = ArtifactDetector().detectArtifacts(in: series)
        session.artifactFlags = flags
        let window = WindowSelector().findBestWindow(
            in: series, flags: flags, sleepStartMs: sleep.startMs, wakeTimeMs: sleep.wakeMs)
        logWindow(window)
        guard var analysisResult = importedAnalysis(series: series, flags: flags, window: window) else {
            return nil
        }
        if let w = window { Self.attachWindowMetadata(to: &analysisResult, window: w, series: series) }
        session.analysisResult = analysisResult
        session.state = .complete
        session.recoveryScore = window?.recoveryScore
        log("  SUCCESS: RMSSD=\(String(format: "%.1f", locale: .current, analysisResult.timeDomain.rmssd))")
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
    ) async -> (startMs: Int64?, wakeMs: Int64?) {
        let sessionStartDate = sessionData.date
        let sessionEndDate = sessionStartDate
            .addingTimeInterval(Double(sessionData.rrIntervals.reduce(0, +)) / 1000.0)
        guard let sleepData = try? await healthKit.fetchSleepData(
            for: sessionStartDate, recordingEnd: sessionEndDate
        ) else {
            log("  Apple Health ERROR: could not read sleep data")
            return (nil, nil)
        }
        return offsets(of: sleepData, from: sessionStartDate)
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
    ) -> (startMs: Int64?, wakeMs: Int64?) {
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
        return (window.startMs, window.wakeMs)
    }

    private func logWindow(_ window: WindowSelector.RecoveryWindow?) {
        guard let w = window else {
            log("  WARNING: No organized recovery window found - recovery score will be nil")
            return
        }
        log("  Window found: \(w.selectionReason), position: \(String(format: "%.0f", locale: .current, (w.relativePosition ?? 0) * 100))%")
    }

    /// The three analysis domains for the selected window, folded into one
    /// result. Nil (logged) when there isn't enough clean data.
    private func importedAnalysis(
        series: RRSeries,
        flags: [ArtifactFlags],
        window: WindowSelector.RecoveryWindow?
    ) -> HRVAnalysisResult? {
        let windowStart = window?.startIndex ?? 0
        let windowEnd = window?.endIndex ?? series.points.count
        let timeDomain = TimeDomainAnalyzer.computeTimeDomain(
            series, flags: flags, windowStart: windowStart, windowEnd: windowEnd)
        let nonlinear = NonlinearAnalyzer.computeNonlinear(
            series, flags: flags, windowStart: windowStart, windowEnd: windowEnd)
        guard let timeDomain, let nonlinear else {
            log("  FAILED: \(timeDomain == nil ? "Time domain" : "Nonlinear") analysis failed")
            return nil
        }
        return Self.assembleResult(
            series: series, flags: flags, windowStart: windowStart, windowEnd: windowEnd,
            timeDomain: timeDomain, nonlinear: nonlinear,
            frequencyDomain: FrequencyDomainAnalyzer.computeFrequencyDomain(
                series, flags: flags, windowStart: windowStart, windowEnd: windowEnd
            )
        )
    }

    /// Copy the selected window's provenance onto the result so the UI can
    /// explain why this slice of the night was chosen.
    private static func attachWindowMetadata(
        to result: inout HRVAnalysisResult,
        window w: WindowSelector.RecoveryWindow,
        series: RRSeries
    ) {
        result.windowStartMs = series.points[w.startIndex].t_ms
        result.windowEndMs = series.points[w.endIndex - 1].endMs
        result.windowMeanHR = w.meanHR
        result.windowHRStability = w.hrStability
        result.windowSelectionReason = w.selectionReason
        result.windowRelativePosition = w.relativePosition
        result.windowClassification = w.windowClassification.rawValue
        result.isOrganizedRecovery = w.windowClassification == .organizedRecovery
    }

    /// Emuqu's own export carries raw RR, so every session is re-analysed
    /// through the full pipeline before it reaches the archive.
    func importAllFlowHRVSessions() async {
        guard let flowResult = flowHRVResult else {
            log("ERROR: flowHRVResult is nil")
            return
        }
        logImportInventory(flowResult)
        let newSessions = newFlowSessions(flowResult)
        guard !newSessions.isEmpty else {
            log("ERROR: No new sessions to import - all filtered as duplicates")
            await MainActor.run { importStatusMessage = "All sessions already imported" }
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

    /// Filter to the sessions the archive doesn't already hold.
    private func newFlowSessions(
        _ flowResult: RRDataImporter.FlowHRVMultiSessionResult
    ) -> [RRDataImporter.FlowHRVMultiSessionResult.SessionRRData] {
        log("=== DUPLICATE CHECK ===")
        let newSessions = flowResult.sessions.filter { session in
            let exists = collector.archive.sessionExists(for: session.date)
            log("Check \(session.sessionDate): exists=\(exists)")
            return !exists
        }
        log("New sessions after filter: \(newSessions.count)")
        return newSessions
    }

    /// Run each new session through the analysis pipeline, yielding between
    /// them so the progress UI keeps up.
    private func analyzeFlowSessions(
        _ newSessions: [RRDataImporter.FlowHRVMultiSessionResult.SessionRRData],
        originalFileName: String
    ) async -> (sessions: [HRVSession], failedCount: Int) {
        log("=== ANALYSIS START ===")
        updateStatus("Preparing to import \(newSessions.count) sessions with full HRV analysis...")
        var analyzedSessions: [HRVSession] = []
        var failedCount = 0
        let healthKit = AppDependencies.current.collection.healthKitManager
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
        updateStatus("Saving \(analyzedSessions.count) sessions to archive...")
        do {
            log("Calling saveImportedSessionsBatch with \(analyzedSessions.count) sessions")
            let processedCount = try await collector.saveImportedSessionsBatch(analyzedSessions)
            log("=== SAVE COMPLETE ===")
            log("Time: \(String(format: "%.1f", locale: .current, Date().timeIntervalSince(startTime)))s")
            log("Saved: \(processedCount), Unchanged: \(analyzedSessions.count - processedCount), Failed: \(failedCount)")
            log("Archive now has \(collector.archive.entries.count) entries")
            await MainActor.run {
                reportBatchOutcome(processed: processedCount, total: analyzedSessions.count)
            }
        } catch {
            log("ERROR: Save failed: \(error)")
            await MainActor.run { failBatch("Failed to save sessions: \(error.localizedDescription)") }
        }
    }

    func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
