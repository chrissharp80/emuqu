import Charts
import SwiftUI

// The analysis-window picker, engine room and share sheet.

extension RecoveryScoreDetailView {
    // MARK: - Analysis Window picker

    /// Three-segment window picker.
    enum AnalysisWindowSegment: String, CaseIterable, Identifiable {
        case bestRecovery
        case pickWindow
        case lastFiveMin
        var id: String { rawValue }
        var shortName: String {
            switch self {
            case .bestRecovery: String(localized: "Best Recovery", bundle: LanguageManager.appBundle)
            case .pickWindow: String(localized: "Pick Window", bundle: LanguageManager.appBundle)
            case .lastFiveMin: String(localized: "Last 5 min", bundle: LanguageManager.appBundle)
            }
        }
    }

    var analysisWindowPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(String(localized: "Analysis window", bundle: LanguageManager.appBundle))
            windowSegmentPicker
            reAnalyzingSection
        }
    }

    private var windowSegmentPicker: some View {
        Picker(String(localized: "Window method", bundle: LanguageManager.appBundle), selection: $selectedWindowSegment) {
            ForEach(AnalysisWindowSegment.allCases) { seg in
                Text(seg.shortName).tag(seg)
            }
        }
        .pickerStyle(.segmented)
        .disabled(isReanalyzing)
        .onChange(of: selectedWindowSegment) { oldSegment, newSegment in
            if newSegment == .pickWindow { segmentBeforePick = oldSegment }
            guard !restoringSegment else {
                restoringSegment = false
                return
            }
            guard newSegment == .bestRecovery || recordingMidpointMs != nil else {
                return restoreSegment(oldSegment)
            }
            handleWindowSegmentChange(newSegment)
        }
    }

    /// Pick Window and Last 5 min place a window on the beat stream; a
    /// session without one (pruned or legacy) cannot, so the control
    /// returns to where it was rather than appearing to choose.
    private func restoreSegment(_ segment: AnalysisWindowSegment) {
        restoringSegment = true
        selectedWindowSegment = segment
    }

    @ViewBuilder
    private var reAnalyzingSection: some View {
        if isReanalyzing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Re-analyzing…", bundle: LanguageManager.appBundle))
                    .scaledFont(size: 12)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
    }

    func handleWindowSegmentChange(_ segment: AnalysisWindowSegment) {
        switch segment {
        case .bestRecovery:
            previewWindowMs = nil
            windowChangedHere = true
            reanalyzeBestRecovery()
        case .pickWindow:
            // Inline picker, no modal sheet. The slider shows up
            // beneath the HRV chart and the user sees the preview band move
            // live as they drag. Initialize at the recording midpoint.
            previewWindowMs = recordingMidpointMs
        case .lastFiveMin:
            previewWindowMs = nil
            windowChangedHere = true
            reanalyzeLastFiveMinutes()
        }
    }

    private func reanalyzeBestRecovery() {
        // Reanalyses this session only; the default method in Settings is
        // left alone.
        guard let onReanalyze else { return }
        Task {
            isReanalyzing = true
            await onReanalyze(.consolidatedRecovery)
            isReanalyzing = false
        }
    }

    /// Centre a 5-minute window 2.5 min before recording end so the analyzer's
    /// window selector has data on both sides of the target.
    private func reanalyzeLastFiveMinutes() {
        guard let onReanalyzeAt, let lastMs = recordingEndMs else { return }
        let targetMs = max(0, lastMs - 150_000)
        Task {
            isReanalyzing = true
            await onReanalyzeAt(targetMs)
            isReanalyzing = false
        }
    }

    /// Recording end (ms relative to session start) for "Last 5 min" centering.
    var recordingEndMs: Int64? {
        effectiveRRSeries?.points.last?.t_ms
    }

    /// Recording start (ms relative to session start) for the Pick Window slider.
    var recordingStartMs: Int64? {
        effectiveRRSeries?.points.first?.t_ms
    }

    /// Middle of the recording, where the Pick Window slider starts; nil
    /// without a beat stream to place a window on.
    var recordingMidpointMs: Int64? {
        guard let startMs = recordingStartMs, let endMs = recordingEndMs, endMs > startMs else { return nil }
        return startMs + (endMs - startMs) / 2
    }

    /// The selected analysis window's clock-time range — displayed in the
    /// engine room and used to draw the band on the HRV chart so the user
    /// can see which slice of the night produced the headline RMSSD.
    var analysisWindowDateRange: (start: Date, end: Date)? {
        guard let startMs = result.windowStartMs,
              let endMs = result.windowEndMs,
              endMs > startMs else { return nil }
        let start = session.startDate.addingTimeInterval(Double(startMs) / 1000)
        let end = session.startDate.addingTimeInterval(Double(endMs) / 1000)
        return (start, end)
    }

    var analysisWindowRangeText: String? {
        guard let range = analysisWindowDateRange else { return nil }
        let f = LocalizedDateFormat.formatter(template: "jmm")
        return "\(f.string(from: range.start)) – \(f.string(from: range.end))"
    }

    // MARK: - Engine Room

    var engineRoomSection: some View {
        EngineRoomDisclosure(
            title: String(localized: "Recording details", bundle: LanguageManager.appBundle),
            memoryKey: "engineRoom.recoveryDetail"
        ) {
            engineRoomDetails
        }
    }

    private var engineRoomDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            captureRows
            windowRows
            nadirRows
            nadirAtRow
            hrRangeRow
            dataSourceRows
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.sectionTint)
        )
    }

    /// When the session ran, and how much of it survived artifact rejection.
    @ViewBuilder
    private var captureRows: some View {
        detailRow(String(localized: "Session start", bundle: LanguageManager.appBundle), value: formattedDate(session.startDate))
        if let end = session.endDate {
            detailRow(String(localized: "Session end", bundle: LanguageManager.appBundle), value: formattedDate(end))
        }
        // `effectiveRRSeries`: a lightweight session opened from the dashboard
        // has `rrSeries` stripped until the full reload lands.
        if let series = effectiveRRSeries {
            detailRow(String(localized: "Beats recorded", bundle: LanguageManager.appBundle), value: "\(series.points.count)")
        }
        detailRow(String(localized: "Beats analysed", bundle: LanguageManager.appBundle), value: result.cleanBeatCountText)
        detailRow(String(localized: "Artifact rate", bundle: LanguageManager.appBundle), value: String(format: "%.1f%%", locale: LanguageManager.appLocale, result.artifactPercentage))
        dataLossRow
    }

    /// Surface estimated data-loss % from the RR series so
    /// the user sees how much the strap missed (gaps, dropouts) — it explains
    /// why a soft HRV result might not be them, it's the signal.
    @ViewBuilder
    private var dataLossRow: some View {
        if let series = effectiveRRSeries,
           let dataLoss = series.estimatedDataLossPercent,
           dataLoss > 0.5 {
            detailRow(
                String(localized: "Data loss", bundle: LanguageManager.appBundle),
                value: String(format: "%.1f%%", locale: LanguageManager.appLocale, dataLoss)
            )
        }
    }

    /// The method the shown result was selected by, read from its stored
    /// reason (a re-analysis elsewhere may have used Highest RMSSD, SDNN or
    /// Total Power; no recognised reason is the default selection). A custom
    /// window chosen here is named by its segment, Pick Window or Last 5 min.
    /// Read from the result, not from the request, so an analysis that
    /// failed or never ran leaves the row naming what is on screen.
    private var windowMethodText: String {
        guard let stored = RecoveryDetailCopy.storedWindowMethod(result.windowSelectionReason) else {
            return WindowSelectionMethod.consolidatedRecovery.shortName
        }
        guard stored == .custom, windowChangedHere, selectedWindowSegment != .bestRecovery else {
            return stored.shortName
        }
        return selectedWindowSegment.shortName
    }

    @ViewBuilder
    private var windowRows: some View {
        detailRow(String(localized: "Window method", bundle: LanguageManager.appBundle), value: windowMethodText)
        if let windowRange = analysisWindowRangeText {
            detailRow(String(localized: "Window time", bundle: LanguageManager.appBundle), value: windowRange)
        }
    }

    @ViewBuilder
    private var nadirAtRow: some View {
        if let nadirText = nadirAtText {
            detailRow(String(localized: "Nadir at", bundle: LanguageManager.appBundle), value: nadirText)
        }
    }

    @ViewBuilder
    private var nadirRows: some View {
        if let nadir = result.overnightNadirHR {
            detailRow(
                String(localized: "Sleep HR nadir", bundle: LanguageManager.appBundle),
                value: String(localized: "\(Int(nadir.rounded())) bpm", bundle: LanguageManager.appBundle)
            )
        }
    }

    @ViewBuilder
    private var hrRangeRow: some View {
        if let minHR = result.overnightMinHR, let maxHR = result.overnightMaxHR {
            detailRow(
                String(localized: "HR range", bundle: LanguageManager.appBundle),
                value: String(localized: "\(Int(minHR.rounded())) – \(Int(maxHR.rounded())) bpm", bundle: LanguageManager.appBundle)
            )
        }
    }

    @ViewBuilder
    private var dataSourceRows: some View {
        if let dataSource = session.dataSourceSummary {
            detailRow(String(localized: "Streaming beats", bundle: LanguageManager.appBundle), value: "\(dataSource.streamingBeats)")
            if let deviceBeats = dataSource.deviceBeats {
                detailRow(String(localized: "Device beats", bundle: LanguageManager.appBundle), value: "\(deviceBeats)")
            }
            detailRow(String(localized: "Source", bundle: LanguageManager.appBundle), value: RecoveryDetailCopy.dataSourceLabel(dataSource.selectedSource))
        }
    }

    // Overnight HR summary fields are computed by the analyzer
    // and stored on the result; surface them here so the user
    // has the canonical "what happened to my HR all night" numbers
    // (especially the nadir time, which is one of the
    // cleanest recovery signals).

    func detailRow(_ label: String, value: String) -> some View {
        DetailLabelValueRow(label: label, value: value)
    }

    /// Nadir clock time pre-formatted so the engine-room
    /// view-builder doesn't have to construct a DateFormatter inline.
    var nadirAtText: String? {
        guard let nadirMs = result.overnightNadirTimeMs else { return nil }
        let date = session.startDate.addingTimeInterval(Double(nadirMs) / 1000)
        return LocalizedDateFormat.string(from: date, template: "jmm")
    }

    func formattedDate(_ d: Date) -> String {
        LocalizedDateFormat.string(from: d, template: "yMMMdjmm")
    }

    // MARK: - Misc

    var isInsufficient: Bool {
        session.hrvDataQuality == .insufficient
    }

    // Banner with link to retry. The retry action
    // re-runs the analysis pipeline against the current RR data; if
    // the underlying issue was an analysis bug rather than truly
    // insufficient data, retry can recover the reading.
    var insufficientBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.wongCaution)
            insufficientBannerBody
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.wongCaution.opacity(0.12))
        )
    }

    private var insufficientBannerBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Reading was incomplete — analysis based on partial data.", bundle: LanguageManager.appBundle))
                .scaledFont(size: 13)
                .foregroundStyle(AppTheme.textPrimary)
            retryAnalysisButton
        }
    }

    /// Hidden when this screen was opened without a reanalysis hook, where it
    /// would do nothing.
    @ViewBuilder
    private var retryAnalysisButton: some View {
        if onReanalyze != nil { retryAnalysisButtonBody }
    }

    /// Runs as Best Recovery does, so it shows it is running and cannot be
    /// tapped twice; the banner goes once the new analysis is sufficient.
    private var retryAnalysisButtonBody: some View {
        Button(action: reanalyzeBestRecovery) {
            Text(isReanalyzing
                ? String(localized: "Re-analyzing…", bundle: LanguageManager.appBundle)
                : String(localized: "Retry analysis", bundle: LanguageManager.appBundle))
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(AppTheme.primary)
        }
        .buttonStyle(.plain)
        .disabled(isReanalyzing)
    }

    var isBuildingBaseline: Bool { !ScoreAppearancePolicy.showsScore(baselineNights: totalSessionCount) }

    var buildingBaselineBlock: some View {
        VStack(spacing: 16) {
            ScoreRing(
                state: .buildingBaseline(day: totalSessionCount, target: ScoreAppearancePolicy.scoreShownNights), size: .card
            )
                .frame(width: 140, height: 140)
            Text(String(localized: "Building your baseline (Day \(totalSessionCount) of \(ScoreAppearancePolicy.scoreShownNights))", bundle: LanguageManager.appBundle))
                .scaledFont(size: 17, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
            Text(String(localized: "Today's reading is saved. Verdict appears once we have enough history.", bundle: LanguageManager.appBundle))
                .scaledFont(size: 14)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    func sectionHeading(_ text: String) -> some View {
        Text(verbatim: text)
            .scaledFont(size: 13, weight: .semibold)
            .detailSectionHeadingStyle()
    }

    // MARK: - Share

    var shareButton: some View {
        Button {
            shareRecapCard()
        } label: {
            Image(systemName: "square.and.arrow.up")
                .scaledFont(size: 14, weight: .semibold)
        }
        .accessibilityLabel(String(localized: "Share recovery card", bundle: LanguageManager.appBundle))
    }

    /// Not while the score is held back for the building baseline (the
    /// toolbar hides the button then too).
    func shareRecapCard() {
        guard !isBuildingBaseline else { return }
        let score = ScoreVerdict.safeDisplayScore(compositeScore)
        let date = session.startDate
        let card = RecapCard(variant: .recovery(score: score, verdict: verdict, date: date))
        guard let image = card.renderImage(), let presenter = topmostPresenter() else { return }
        presentShareSheet(activityItem: recapActivityItem(image: image, score: score, date: date), from: presenter)
    }
}
