import SwiftUI

// The report's exports: the PDF report (preview, share and email, rendered
// off the main actor) and the RR CSV.

extension MorningReanalysisControls {
    // MARK: - PDF report

    /// Determines which report sections have data for this session,
    /// so the picker can disable unavailable toggles.
    var availableReportSections: PDFReportGenerator.ReportSections {
        var available: PDFReportGenerator.ReportSections = [.hrvSummary]
        // "Overnight Summary" is overnight-only; a quick reading with
        // raw RR data would otherwise render the heading mislabeled.
        if vm.hasRawData, vm.displaySession.sessionType == .overnight { available.insert(.overnightStats) }
        if let sleep = vm.healthKitSleep, sleep.nightSleepMinutes > 0 { available.insert(.sleep) }
        if vm.displayResult.trainingContext != nil || vm.displaySession.trainingSnapshot != nil { available.insert(.trainingLoad) }
        if reportVitals != nil { available.insert(.vitals) }
        if vm.compositeRecoveryScore > 0 { available.insert(.scoreBreakdown) }
        if vm.hasRawData { available.insert(.charts) }
        if vm.hasRawData { available.insert(.deepDive) }
        return available
    }

    /// Vitals for the report: the frozen snapshot for a historical session
    /// (live vitals when it has none), live vitals for today's. Shared by the
    /// section picker and the report inputs so the two cannot drift.
    private var reportVitals: RecoveryVitals? {
        vm.isHistoricalSession ? (session.vitalsSnapshot ?? vm.recoveryVitals) : vm.recoveryVitals
    }

    /// The report compares the night with the nights before it, which the
    /// archive's index lists: nil while that index did not load, so no report
    /// is drawn against a history it never saw (`HistoryExportGate`).
    private var historyRefusal: String? {
        HistoryExportGate.refusal(indexComplete: collector.archive.hasCompleteIndex)
    }

    /// `onFailure` receives the user-facing reason when no PDF was produced.
    func exportPDF(
        style: PDFReportGenerator.ReportStyle = .comprehensive,
        sections: PDFReportGenerator.ReportSections = .all,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        if let historyRefusal { return onFailure(historyRefusal) }
        vm.isGeneratingPDF = true
        Task {
            let url = await renderPDFAsync(style: style, sections: sections)
            await MainActor.run { finishExportPDF(url, onFailure: onFailure) }
        }
    }

    @MainActor
    private func finishExportPDF(_ url: URL?, onFailure: @MainActor (String) -> Void) {
        vm.isGeneratingPDF = false
        guard let url else { return onFailure(reportFailureMessage) }
        exportURL = IdentifiableURL(url: url)
    }

    private var reportFailureMessage: String {
        String(localized: "Couldn't generate the recovery PDF. The session may not have enough data.", bundle: LanguageManager.appBundle)
    }

    /// `renderPDFAsync` returns the URL and only the targeted state
    /// (`exportURL` OR `emailURL`) gets set — never both, never with
    /// intermediate values. Setting `exportURL` first (firing the
    /// PDFPreview sheet) and then
    /// swapping to `emailURL` mid-flight gets SwiftUI's sheet pipeline
    /// stuck so subsequent taps do nothing.
    func emailReport(
        style: PDFReportGenerator.ReportStyle = .comprehensive,
        sections: PDFReportGenerator.ReportSections = .all,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        if let historyRefusal { return onFailure(historyRefusal) }
        vm.isGeneratingEmailPDF = true
        Task {
            let url = await renderPDFAsync(style: style, sections: sections)
            await MainActor.run { finishEmailPDF(url, onFailure: onFailure) }
        }
    }

    @MainActor
    private func finishEmailPDF(_ url: URL?, onFailure: @MainActor (String) -> Void) {
        vm.isGeneratingEmailPDF = false
        guard let url else { return onFailure(reportFailureMessage) }
        emailURL = IdentifiableURL(url: url)
    }

    /// Renders the PDF and returns the URL. Pure return-style, no
    /// side-effect on `exportURL` (that side-effect leaves the email button
    /// stuck); callers are responsible for routing to
    /// either `exportURL` (preview) or `emailURL` (mail composer).
    ///
    /// Timing breadcrumbs: the wait between tapping the email-report button
    /// and the mail composer appearing can be long. Without per-step timing
    /// the path is opaque: HealthKit
    /// cold-query, sleep/vitals conversion, and the multi-page comprehensive
    /// PDF render all run here, and any of them could be the bottleneck.
    /// Per-step elapsed makes the next slow run self-explanatory.
    @discardableResult
    func renderPDFAsync(style: PDFReportGenerator.ReportStyle = .comprehensive, sections: PDFReportGenerator.ReportSections = .all) async -> URL? {
        let sessionForExport = exportSession()
        let renderStartedAt = Date()
        debugLog("[MorningResultsView] Generating PDF... session.id=\(sessionForExport.id.uuidString.prefix(8)) hasAnalysis=\(sessionForExport.analysisResult != nil) hasRR=\(sessionForExport.rrSeries != nil) hkSleepMin=\(vm.healthKitSleep?.nightSleepMinutes ?? 0)")
        let healthKitHR = await fetchHealthKitHRForReport()
        let inputs = await reportInputs(healthKitHR: healthKitHR)
        let renderStartedAt2 = Date()
        let url = await renderReport(session: sessionForExport, inputs: inputs, style: style, sections: sections)
        guard let url else {
            debugLog("[MorningResultsView] PDF generation failed - check session data")
            return nil
        }
        let renderElapsed = Date().timeIntervalSince(renderStartedAt2)
        let totalElapsed = Date().timeIntervalSince(renderStartedAt)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        debugLog("[MorningResultsView] PDF rendered in \(String(format: "%.2f", renderElapsed))s (total \(String(format: "%.2f", totalElapsed))s), \(size) bytes — \(url.lastPathComponent)")
        return url
    }

    /// A session copy with the analysis result attached. Uses
    /// `vm.displaySession` / `vm.displayResult` so any reanalyzed data is
    /// included, and falls back to the session's frozen training snapshot when
    /// the result carries no training context.
    private func exportSession() -> HRVSession {
        var sessionForExport = vm.displaySession
        var resultForExport = vm.displayResult
        if resultForExport.trainingContext == nil {
            resultForExport.trainingContext = vm.displaySession.trainingSnapshot
        }
        sessionForExport.analysisResult = resultForExport
        return sessionForExport
    }

    /// HealthKit HR samples for an accurate nadir. Nil (logged) on failure —
    /// the report degrades rather than blocking on the health store.
    private func fetchHealthKitHRForReport() async -> HeartRateStats? {
        let startedAt = Date()
        let recordingEnd = session.endDate ?? session.startDate.addingTimeInterval(session.duration ?? 28800)
        do {
            let stats = try await vm.healthKit.heartRate.calculateHRStats(from: session.startDate, to: recordingEnd)
            debugLog("[MorningResultsView] HealthKit HR fetched in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s: nadir=\(stats?.min ?? 0), max=\(stats?.max ?? 0)")
            return stats
        } catch {
            debugLog("[MorningResultsView] HealthKit HR failed in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s: \(error)", level: .warning)
            return nil
        }
    }

    /// Everything the generator needs beyond the session itself, all value
    /// types so the render can detach.
    private struct ReportInputs {
        let sleepData: PDFReportGenerator.SleepData?
        let sleepTrend: PDFReportGenerator.SleepTrendData?
        let healthKitHR: HeartRateStats?
        let vitals: PDFReportGenerator.VitalsData?
        let compositeScore: Double
        let breakdown: RecoveryScoreCalculator.ScoreBreakdown?
        let baselineStats: BaselineTracker.RecoveryBaselineStats?
        let liveLoadSnapshot: TrainingLoadRegistry.TrainingLoad?
        let recentSessions: [HRVSession]
    }

    /// Gather the report inputs on the MainActor.
    ///
    /// Vitals prefer the frozen snapshot for historical sessions.
    ///
    /// The canonical live training-load is captured here so the
    /// report's PMC section shows the SAME ATL/CTL/TSB the Load & Trajectory
    /// page shows. Reading the frozen `result.trainingContext` (captured at
    /// session-acceptance, pre-workout) instead makes reports disagree with
    /// the dashboard by ~6 CTL points. See `PDFReportGenerator.generateReport`.
    ///
    /// `liveRefreshed()` recomputes the cache before capture so
    /// the PMC section can't freeze a stale TSB/ACWR left behind by an
    /// archive-write invalidation.
    private func reportInputs(healthKitHR: HeartRateStats?) async -> ReportInputs {
        let effectiveVitals = reportVitals
        let hkSleep = vm.healthKitSleep
        let hkTrend = vm.sleepTrendStats
        return await ReportInputs(
            sleepData: (hkSleep?.nightSleepMinutes ?? 0) > 0 ? hkSleep.map(PDFReportGenerator.SleepData.init(from:)) : nil,
            sleepTrend: (hkTrend?.nightsAnalyzed ?? 0) > 0 ? hkTrend.map(PDFReportGenerator.SleepTrendData.init(from:)) : nil,
            healthKitHR: healthKitHR,
            vitals: effectiveVitals.map(PDFReportGenerator.VitalsData.init(from:)),
            compositeScore: vm.compositeRecoveryScore,
            breakdown: MainActor.run { vm.recoveryBreakdown() },
            baselineStats: vm.baselineStats,
            liveLoadSnapshot: TrainingLoadRegistry.liveRefreshed(from: trainingMetricsCache),
            recentSessions: recentSessions
        )
    }

    /// Render the multi-page PDF (drawing + data.write) OFF the
    /// main actor. This is a MainActor view method reached from a bare
    /// `Task {}`, so an inline render freezes the UI for multiple seconds
    /// on the Email/Export tap — the "super super long wait" the timing
    /// breadcrumbs exist for. PDFReportGenerator isn't @MainActor and
    /// every input is a value type, so it's safe to detach.
    private func renderReport(
        session sessionForExport: HRVSession,
        inputs: ReportInputs,
        style: PDFReportGenerator.ReportStyle,
        sections: PDFReportGenerator.ReportSections
    ) async -> URL? {
        let settingsManager = settingsManager
        return await Task.detached {
            let generator = PDFReportGenerator { settingsManager.settingsSnapshot }
            return generator.generateReportURL(
                for: sessionForExport,
                sleepData: inputs.sleepData,
                sleepTrend: inputs.sleepTrend,
                recentSessions: inputs.recentSessions,
                healthKitHR: inputs.healthKitHR,
                vitals: inputs.vitals,
                compositeRecoveryScore: inputs.compositeScore,
                scoreBreakdown: inputs.breakdown,
                baselineStats: inputs.baselineStats,
                liveLoadSnapshot: inputs.liveLoadSnapshot,
                style: style,
                sections: sections
            )
        }.value
    }

    // MARK: - Export RR Data

    /// Writes the CSV to tmp and opens it; `onFailure` receives the
    /// user-facing reason when there is no series or the write fails.
    /// The rows of a full night (tens of thousands of beats) are built and
    /// written on a detached task; the header and file name, which read the
    /// view model, are made here first.
    func exportRRData(onFailure: @escaping @MainActor (String) -> Void) {
        let failure = String(localized: "Couldn't create the CSV file.", bundle: LanguageManager.appBundle)
        guard let series = vm.displaySession.rrSeries else {
            debugLog("[MorningResultsView] ERROR: No rrSeries in vm.displaySession")
            return onFailure(failure)
        }
        debugLog("[MorningResultsView] Exporting RR data: \(series.points.count) points")
        let header = rrExportHeader(series: series)
        let points = series.points
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(rrExportFilename())
        Task {
            let written = await Task.detached(priority: .userInitiated) {
                writeRRCSV(header: header, points: points, to: tempURL)
            }.value
            if written {
                exportURL = IdentifiableURL(url: tempURL)
            } else {
                onFailure(failure)
            }
        }
    }

    /// Comment block carrying the session + analysis-window provenance, so an
    /// exported CSV can be matched back to the numbers the app displayed.
    private func rrExportHeader(series: RRSeries) -> String {
        var csv = "# Emuqu RR Export\n"
        csv += "# Session Date: \(vm.displaySession.startDate)\n"
        csv += "# Series Start: \(series.startDate)\n"
        csv += "# Total Points: \(series.points.count)\n"
        csv += "# Duration (ms): \(series.durationMs)\n"
        if let result = vm.displaySession.analysisResult {
            csv += "# Window Start Index: \(result.windowStart)\n"
            csv += "# Window End Index: \(result.windowEnd)\n"
            csv += "# Window Start Ms: \(result.windowStartMs ?? -1)\n"
            csv += "# Window End Ms: \(result.windowEndMs ?? -1)\n"
            csv += "# RMSSD: \(result.timeDomain.rmssd)\n"
        }
        csv += "#\n"
        return csv
    }

    private func rrExportFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return "Emuqu_RR_\(formatter.string(from: vm.displaySession.startDate)).csv"
    }
}

// MARK: - File-scope helpers

/// Writes the header and the rows to `url`; false (logged) when the write
/// throws. Off the main actor.
private func writeRRCSV(header: String, points: [RRPoint], to url: URL) -> Bool {
    do {
        try (header + rrCSVRows(points: points)).write(to: url, atomically: true, encoding: .utf8)
        debugLog("[MorningResultsView] RR data exported to: \(url.path)")
        return true
    } catch {
        debugLog("[MorningResultsView] Failed to write RR data: \(error)")
        return false
    }
}

/// The `timestamp_ms,rr_ms,hr_bpm` header and one row per beat. The hr cell
/// is empty for a non-positive interval rather than a made-up bpm.
/// Internal so every RR CSV export can share one row format.
func rrCSVRows(points: [RRPoint]) -> String {
    var csv = "timestamp_ms,rr_ms,hr_bpm\n"
    for point in points {
        // POSIX locale: a decimal comma would split the value into two CSV fields.
        let hr = point.rr_ms > 0 ? String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), 60000.0 / Double(point.rr_ms)) : ""
        csv += "\(point.t_ms),\(point.rr_ms),\(hr)\n"
    }
    return csv
}
