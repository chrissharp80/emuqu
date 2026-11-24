import SwiftUI

// Window-selection method switching and the overnight strap re-merge. Both
// re-run analysis on an existing session; the summary generation and
// narrative translation in `MorningResultsView+Actions.swift` describe a
// session as it already stands.

extension MorningReanalysisControls {
    // MARK: - Window Selection Method

    var windowSelectionMethodSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            windowMethodHeader

            windowMethodPicker
            windowMethodTooltip
            manualComparisonBanner
            manualPickRejection
            // Persistent auto-vs-chosen comparison — survives applying the pick.
            // (The live `manualComparisonBanner` above only exists during the
            // pre-apply preview; this shows every time you open a session whose
            // window you adjusted, WITH the recovery scores.)
            persistentWindowComparisonBanner()
            // HRV provenance: which time window and segment the analysis comes from
            provenanceView
        }
        .padding(12)
        .background(AppTheme.sectionTint)
        .cornerRadius(10)
    }

    /// Tooltip for the current selection.
    private var windowMethodTooltip: some View {
        Text(isManualWindowMode ? WindowSelectionMethod.custom.tooltip : vm.selectedMethod.tooltip)
            .font(.caption)
            .foregroundColor(AppTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var windowMethodHeader: some View {
        HStack {
            Image(systemName: "scope")
                .foregroundColor(AppTheme.primary)
            Text(String(localized: "Analysis Window", bundle: LanguageManager.appBundle))
                .font(.headline)
                .foregroundColor(AppTheme.textPrimary)
            Spacer()
        }
    }

    /// Dropdown method picker
    private var windowMethodPicker: some View {
        HStack(spacing: 12) {
            windowMethodMenu

            chooseYourOwnButton
        }
    }

    private var windowMethodMenu: some View {
        Menu {
            windowMethodOptions
        } label: {
            windowMethodMenuLabel
        }
    }

    @ViewBuilder
    private var windowMethodOptions: some View {
        ForEach(WindowSelectionMethod.automaticMethods, id: \.self) { method in
            Button {
                selectWindowMethod(method)
            } label: {
                Label(method.displayName, systemImage: method.icon)
            }
        }
    }

    /// Picking a method re-scores and re-saves the reading, so the pick only
    /// asks: the view's confirmation runs `applyWindowMethod`.
    private func selectWindowMethod(_ method: WindowSelectionMethod) {
        guard vm.selectedMethod != method else { return }
        pendingWindowMethod = method
    }

    /// The confirmed pick. Re-scores the reading with `method`. Once that
    /// lands, a reading that is not a past night also makes `method` the
    /// default, so the next session opens with the user's most recent choice;
    /// a past night's pick re-scores that night only. A declined re-analysis
    /// puts the previous method back and raises `reanalysisDeclined`.
    func applyWindowMethod(_ method: WindowSelectionMethod) {
        guard let onReanalyze else { return }
        let previous = vm.selectedMethod
        let becomesDefault = !vm.isHistoricalSession
        vm.selectedMethod = method
        isManualWindowMode = false
        manualResult = nil
        vm.isReanalyzing = true
        Task {
            let updatedSession = await onReanalyze(vm.displaySession, method)
            await MainActor.run {
                finishWindowMethod(updatedSession, method: method, previous: previous, becomesDefault: becomesDefault)
            }
        }
    }

    /// A declined re-analysis puts the previous method back; one that landed
    /// makes `method` the default when the reading is not a past night.
    @MainActor
    private func finishWindowMethod(
        _ updatedSession: HRVSession?, method: WindowSelectionMethod, previous: WindowSelectionMethod, becomesDefault: Bool
    ) {
        if updatedSession == nil {
            vm.selectedMethod = previous
        } else if becomesDefault {
            AppDependencies.current.app.settingsManager.settings.defaultWindowSelectionMethod = method
        }
        applyReanalyzedSession(updatedSession)
    }

    /// A bigger chevron and a bordered, button-like surface make the
    /// affordance obvious: with a passive badge-style label users could
    /// not find the RMSSD / SDNN / Total Power options in this Menu.
    private var windowMethodMenuLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: isManualWindowMode ? WindowSelectionMethod.custom.icon : vm.selectedMethod.icon)
                .font(.subheadline)
            Text(isManualWindowMode ? String(localized: "Custom Window", bundle: LanguageManager.appBundle) : vm.selectedMethod.shortName)
                .font(.subheadline.bold())
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.subheadline.weight(.semibold))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppTheme.sectionTint)
        .foregroundColor(AppTheme.textPrimary)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(AppTheme.primary.opacity(0.35), lineWidth: 1)
        )
        .cornerRadius(10)
        .accessibilityLabel(String(localized: "Analysis method: \(isManualWindowMode ? String(localized: "Custom Window", bundle: LanguageManager.appBundle) : vm.selectedMethod.shortName). Tap to change.", bundle: LanguageManager.appBundle))
    }

    /// "Choose your own" button
    @ViewBuilder
    private var chooseYourOwnButton: some View {
        if onReanalyzeAt != nil {
            Button {
                toggleManualWindowMode()
            } label: {
                chooseYourOwnLabel
            }
            .buttonStyle(.plain)
        }
    }

    private func toggleManualWindowMode() {
        isManualWindowMode.toggle()
        if !isManualWindowMode { manualResult = nil }
    }

    private var chooseYourOwnLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "hand.draw.fill")
                .font(.caption)
            Text(isManualWindowMode ? String(localized: "Exit", bundle: LanguageManager.appBundle) : String(localized: "Choose Window", bundle: LanguageManager.appBundle))
                .font(.subheadline.bold())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isManualWindowMode ? AppTheme.primary : AppTheme.sectionTint)
        .foregroundColor(isManualWindowMode ? .white : AppTheme.textPrimary)
        .cornerRadius(10)
    }

    /// Comparison banner when manual result exists
    @ViewBuilder
    private var manualComparisonBanner: some View {
        if isManualWindowMode, let manual = manualResult {
            manualComparisonBanner(manual: manual)
        }
    }

    /// Pick-rejection and apply-failure feedback, so a tapped position that
    /// can't produce a usable window, or an Apply that fails, doesn't fail
    /// silently. Shown alongside the comparison banner when one is up.
    @ViewBuilder
    private var manualPickRejection: some View {
        if isManualWindowMode, let message = manualPickMessage {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(AppTheme.softGold)
                    .font(.subheadline)
                Text(message)
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(AppTheme.softGold.opacity(0.1))
            .cornerRadius(8)
        }
    }

    // MARK: - Overnight Strap Re-Merge

    /// Shown on a streaming-only overnight (e.g. Bluetooth dropped overnight so
    /// the morning device fetch was skipped). Pulls the H10's full-night file —
    /// still on the strap until a successful pull — merges it with the stream,
    /// and re-scores. Overnight sibling of the workout "Recover session" card.
    var overnightStrapMergeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            strapMergeHeader
            Text(String(localized: "This night was scored from the live stream only. Connect your strap to pull its complete overnight recording, merge it in, and re-score.", bundle: LanguageManager.appBundle))
                .font(.footnote)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            strapMergeStatus
            strapMergeButton
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.sage.opacity(0.08))
        .cornerRadius(10)
    }

    private var strapMergeHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.heart.fill")
                .foregroundStyle(AppTheme.sage)
            Text(String(localized: "Merge full night from strap", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
        }
    }

    @ViewBuilder
    private var strapMergeStatus: some View {
        if let strapMergeMessage {
            Text(strapMergeMessage)
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var strapMergeButton: some View {
        Button {
            mergeOvernightFromStrap()
        } label: {
            overnightStrapMergeCardLabel
        }
        .buttonStyle(.plain)
        .disabled(strapMergeWorking)
    }

    private func mergeOvernightFromStrap() {
        strapMergeWorking = true
        strapMergeMessage = nil
        let sessionId = vm.displaySession.id
        Task {
            let result = await collector.recovery.augmentOvernightFromStrap(
                sessionId: sessionId, rescoringWith: sessionReanalysis
            )
            if case .merged = result { await showMergedSession(sessionId) }
            strapMergeWorking = false
            strapMergeMessage = Self.mergeOutcomeMessage(for: result)
        }
    }

    /// The archive observer skips a reload when the score and snapshots are
    /// unchanged, which a merge can leave as they were; the merged beats and
    /// data-source summary must still replace the old ones on screen.
    private func showMergedSession(_ sessionId: UUID) async {
        guard let merged = await collector.retrieveFullSessionAsync(sessionId) else { return }
        vm.reanalyzedSession = merged
    }

    private static func mergeOutcomeMessage(for result: SessionRecoveryCoordinator.OvernightAugmentResult) -> String {
        switch result {
        case let .merged(_, beats, score):
            guard let score else {
                return String(format: String(localized: "Merged — %d beats.", bundle: LanguageManager.appBundle), beats)
            }
            return String(format: String(localized: "Merged — %d beats, recovery %d.", bundle: LanguageManager.appBundle), beats, ScoreVerdict.safeDisplayScore(score * 10))
        case .notReachable:
            return String(localized: "Couldn't reach the strap — bring it close, make sure it's on, then try again.", bundle: LanguageManager.appBundle)
        case .noStrapData:
            return String(localized: "No overnight recording found on the strap for this night.", bundle: LanguageManager.appBundle)
        case .alreadyMerged:
            return String(localized: "This night already includes the strap recording.", bundle: LanguageManager.appBundle)
        case .failed:
            return String(localized: "Couldn't merge — try again.", bundle: LanguageManager.appBundle)
        }
    }

    private var overnightStrapMergeCardLabel: some View {
        HStack(spacing: 6) {
            if strapMergeWorking { ProgressView().scaleEffect(0.7) }
            Text(strapMergeWorking
                ? String(localized: "Pulling from strap…", bundle: LanguageManager.appBundle)
                : String(localized: "Pull from strap & merge", bundle: LanguageManager.appBundle))
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(AppTheme.sage)
        .foregroundColor(.white)
        .cornerRadius(10)
    }

    // MARK: - Manual Window Comparison

    /// Persistent comparison of the user's chosen window vs the window the app
    /// auto-selected, shown after a manual pick is applied. Uses the auto result
    /// + score preserved on the session at apply time (see ReanalysisService).
    /// Answers "you chose X (score N) vs auto picked Y (score M)" — including the
    /// recovery score, which the live preview banner cannot show.
    @ViewBuilder
    func persistentWindowComparisonBanner() -> some View {
        if vm.displaySession.windowUserAdjusted == true,
           let auto = vm.displaySession.autoWindowResult {
            VStack(alignment: .leading, spacing: 8) {
                persistentBannerHeader
                persistentBannerColumns(auto: auto)
            }
            .padding(10)
            .background(AppTheme.primary.opacity(0.08))
            .cornerRadius(8)
        }
    }

    private var persistentBannerHeader: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.caption2)
                .foregroundColor(AppTheme.primary)
            Text(String(localized: "Your Window vs Auto", bundle: LanguageManager.appBundle))
                .font(.caption.bold())
                .foregroundColor(AppTheme.textPrimary)
        }
    }

    private func persistentBannerColumns(auto: HRVAnalysisResult) -> some View {
        let autoScore = vm.displaySession.autoWindowScore
        let yoursScore = vm.displaySession.recoveryScore
        return HStack(spacing: 0) {
            windowStatColumn(
                title: String(localized: "Auto", bundle: LanguageManager.appBundle),
                score: autoScore, rmssd: auto.timeDomain.rmssd, tint: AppTheme.primary)
            comparisonDivider(height: 56)
            windowStatColumn(
                title: String(localized: "Yours", bundle: LanguageManager.appBundle),
                score: yoursScore, rmssd: vm.displayResult.timeDomain.rmssd, tint: AppTheme.sage)
            comparisonDivider(height: 56)
            persistentScoreDiffColumn(autoScore: autoScore, yoursScore: yoursScore)
        }
    }

    @ViewBuilder
    func windowStatColumn(title: String, score: Double?, rmssd: Double, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2.bold())
                .foregroundColor(AppTheme.textSecondary)
            Text(score.map { String(format: "%d", locale: LanguageManager.appLocale, ScoreVerdict.safeDisplayScore($0 * 10)) } ?? "—")
                .font(.title3.bold().monospacedDigit())
                .foregroundColor(tint)
            Text(String(localized: "Score", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
            Text(String(localized: "\(Int(rmssd.rounded())) ms RMSSD", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    func manualComparisonBanner(manual: HRVAnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption2)
                    .foregroundColor(AppTheme.primary)
                Text(String(localized: "Comparing Windows", bundle: LanguageManager.appBundle))
                    .font(.caption.bold())
                    .foregroundColor(AppTheme.textPrimary)
            }
            comparisonColumns(manual: manual)
            manualWindowActions(manual)
        }
        .padding(12)
        .background(AppTheme.sage.opacity(0.08))
        .cornerRadius(10)
    }

    /// The automatic window to compare against: while the night carries a
    /// manual pick (`windowUserAdjusted`), the auto window kept from before
    /// that pick; otherwise the current result, which follows a method
    /// switch. A method switch clears `windowUserAdjusted` but leaves the old
    /// `autoWindowResult` on the session, so that field alone is stale then.
    /// The `result` the sheet opened with is neither once the night was
    /// adjusted or re-analysed.
    private var autoComparisonResult: HRVAnalysisResult {
        guard vm.displaySession.windowUserAdjusted == true,
              let kept = vm.displaySession.autoWindowResult else { return vm.displayResult }
        return kept
    }

    /// Auto | Yours | Diff, side by side.
    private func comparisonColumns(manual: HRVAnalysisResult) -> some View {
        HStack(spacing: 0) {
            rmssdColumn(titleKey: "Auto", from: autoComparisonResult, tint: AppTheme.primary)
            comparisonDivider(height: 50)
            rmssdColumn(titleKey: "Yours", from: manual, tint: AppTheme.sage)
            comparisonDivider(height: 50)
            diffColumn(manual: manual)
        }
    }

    /// Signed RMSSD delta, footnoted with how the manual window classified.
    private func diffColumn(manual: HRVAnalysisResult) -> some View {
        let delta = manual.timeDomain.rmssd - autoComparisonResult.timeDomain.rmssd
        return comparisonColumn(
            title: String(localized: "Diff", bundle: LanguageManager.appBundle),
            value: String(format: "%+.1f", locale: LanguageManager.appLocale, delta),
            color: delta >= 0 ? AppTheme.sage : AppTheme.terracotta,
            footnote: manual.windowClassification.flatMap {
                WindowSelector.RecoveryWindow.WindowClassification(rawValue: $0)?.shortLabel
            } ?? manual.displayWindowClassification
        )
    }

    /// Apply / Cancel actions. Without these, the user's chosen
    /// window lives in @State only — dropped on sheet close, recovery score
    /// never recomputed. Apply calls `onApplyManualResult`, which persists the
    /// new window via `ReanalysisService.applyManualAnalysis` (sets
    /// windowUserAdjusted = true, recomputes recoveryScore / scoreBreakdown /
    /// frozenReadiness, re-archives) and returns the updated session that
    /// drives `vm.displaySession` — so the score card on this screen refreshes
    /// immediately.
    @ViewBuilder
    private func manualWindowActions(_ manual: HRVAnalysisResult) -> some View {
        if onApplyManualResult != nil {
            manualWindowButtons(manual)
        }
    }

    private func manualWindowButtons(_ manual: HRVAnalysisResult) -> some View {
        HStack(spacing: 8) {
            Button {
                manualResult = nil
                manualPickMessage = nil
            } label: { cancelManualLabel }
                .buttonStyle(.plain)
                .disabled(vm.isReanalyzing)
            Button { applyManualWindowChoice(manual) } label: { applyManualLabel }
                .buttonStyle(.plain)
                .disabled(vm.isReanalyzing)
        }
        .padding(.top, 4)
    }

    private var cancelManualLabel: some View {
        Text(String(localized: "Cancel", bundle: LanguageManager.appBundle))
            .font(.subheadline.bold())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(AppTheme.sectionTint)
            .foregroundColor(AppTheme.textPrimary)
            .cornerRadius(8)
    }

    private var applyManualLabel: some View {
        HStack(spacing: 6) {
            if vm.isReanalyzing {
                ProgressView().scaleEffect(0.7).tint(.white)
            } else {
                Image(systemName: "checkmark.circle.fill").font(.caption)
            }
            Text(String(localized: "Apply", bundle: LanguageManager.appBundle))
                .font(.subheadline.bold())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(AppTheme.sage)
        .foregroundColor(.white)
        .cornerRadius(8)
    }

    // MARK: - Apply Manual Window

    /// Apply the previewed manual window: persist via ReanalysisService,
    /// then update vm.reanalyzedSession so the score / breakdown card on
    /// this screen reflects the new window without waiting for the
    /// archive-signal round-trip.
    func applyManualWindowChoice(_ manual: HRVAnalysisResult) {
        guard let onApplyManualResult else { return }
        let oldScore = vm.displaySession.recoveryScore
        let oldRMSSD = vm.displayResult.timeDomain.rmssd
        debugLog("[MorningResultsView] Apply tapped — RMSSD \(String(format: "%.1f", oldRMSSD))→\(String(format: "%.1f", manual.timeDomain.rmssd)), score \(oldScore.map { String(format: "%.2f", $0) } ?? "nil")")
        vm.isReanalyzing = true
        Task {
            let updated = await onApplyManualResult(manual)
            await MainActor.run { finishManualApply(updated) }
        }
    }

    /// Force the score to refresh by assigning `reanalyzedSession` before we
    /// touch any other state, so the new value is in place before the flags that
    /// close manual-window mode change and re-render the screen.
    @MainActor
    private func finishManualApply(_ updated: HRVSession?) {
        if let updated {
            vm.reanalyzedSession = updated
            manualResult = nil
            isManualWindowMode = false
            debugLog("[MorningResultsView] Apply DONE — new score=\(updated.recoveryScore.map { String(format: "%.2f", $0) } ?? "nil") new RMSSD=\(String(format: "%.1f", updated.analysisResult?.timeDomain.rmssd ?? 0))ms windowUserAdjusted=\(updated.windowUserAdjusted ?? false)")
        } else {
            manualPickMessage = String(localized: "Couldn't apply this window — the saved data was incomplete. Try a different position.", bundle: LanguageManager.appBundle)
            debugLog("[MorningResultsView] Apply FAILED — applyManualAnalysis returned nil")
        }
        vm.isReanalyzing = false
    }

    // MARK: - PDF Loading Overlay

    var pdfLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                Text(String(localized: "Generating PDF...", bundle: LanguageManager.appBundle))
                    .font(.headline)
                    .foregroundColor(.white)
            }
            .padding(40)
            .background(AppTheme.cardBackground.opacity(0.95))
            .cornerRadius(16)
        }
    }

    // MARK: - Provenance

    @ViewBuilder
    var provenanceView: some View {
        VStack(alignment: .leading, spacing: 4) {
            windowProvenanceRow
            segmentProvenanceRow
        }
    }

    /// Wall-clock times, so data gaps don't shift the displayed window.
    @ViewBuilder
    private var windowProvenanceRow: some View {
        let result = vm.displayResult
        if let startTime = result.windowStartMs, let endTime = result.windowEndMs,
           let series = vm.displaySession.rrSeries {
            let startDate = series.wallClockTime(forTMs: startTime)
            let endDate = series.wallClockTime(forTMs: endTime)
            provenanceRow(
                glyph: "waveform.path.ecg",
                text: String(localized: "Window: \(Self.clockTime(startDate)) – \(Self.clockTime(endDate))", bundle: LanguageManager.appBundle)
            )
        }
    }

    @ViewBuilder
    private var segmentProvenanceRow: some View {
        if let segmentLabel = vm.displayResult.analysisSegmentLabel {
            provenanceRow(
                glyph: "moon.stars",
                text: String(localized: "From: \(segmentLabel)", bundle: LanguageManager.appBundle)
            )
        }
    }

    /// A time of day in the app language.
    private static func clockTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(LanguageManager.appLocale))
    }

    // MARK: - Re-analysis

    func performReanalysis() {
        guard let onReanalyze else { return }
        vm.isReanalyzing = true
        Task {
            let updatedSession = await onReanalyze(vm.displaySession, vm.selectedMethod)
            await MainActor.run { applyReanalyzedSession(updatedSession) }
        }
    }

    /// A nil result means the reanalysis declined (no RR data, in-flight
    /// duplicate); the displayed session stays as it was and
    /// `reanalysisDeclined` tells the user so.
    @MainActor
    private func applyReanalyzedSession(_ updatedSession: HRVSession?) {
        if let updatedSession {
            vm.reanalyzedSession = updatedSession
        } else {
            reanalysisDeclined = true
        }
        vm.isReanalyzing = false
    }

    // MARK: - Manual Window Reanalysis

    func handleManualReanalysis(timestampMs: Int64) {
        guard let onReanalyzeAt else { return }
        vm.isReanalyzing = true
        manualPickMessage = nil
        Task {
            let newResult = await onReanalyzeAt(timestampMs)
            await MainActor.run { finishManualPreview(newResult, timestampMs: timestampMs) }
        }
    }

    /// Surface a reason instead of failing silently. The two common
    /// rejections are:
    ///   • the position lands in a high-artifact stretch (>10% bad beats inside
    ///     the 400-beat window)
    ///   • the raw RR series isn't available on disk (some older sessions
    ///     were archived without it).
    @MainActor
    private func finishManualPreview(_ newResult: HRVAnalysisResult?, timestampMs: Int64) {
        if let newResult {
            manualResult = newResult
            manualPickMessage = nil
            debugLog("[MorningResultsView] Manual pick OK at \(timestampMs)ms — RMSSD \(String(format: "%.1f", newResult.timeDomain.rmssd))ms")
        } else {
            manualPickMessage = String(localized: "Couldn't analyze that spot — too many irregular beats nearby. Try a calmer point on the chart.", bundle: LanguageManager.appBundle)
            debugLog("[MorningResultsView] Manual pick FAILED at \(timestampMs)ms")
        }
        vm.isReanalyzing = false
    }

}

// MARK: - File-scope helpers
//
// Kept outside MorningResultsView. Each names no member of the type and
// calls nothing inside it, so none needs to be a member. `private` at
// file scope is fileprivate, so every call site in this file resolves.

/// The score delta between the two windows, in display points (raw x10).
@MainActor
private func persistentScoreDiffColumn(autoScore: Double?, yoursScore: Double?) -> some View {
    VStack(spacing: 4) {
        Text(String(localized: "Diff", bundle: LanguageManager.appBundle))
            .font(.caption2.bold())
            .foregroundColor(AppTheme.textSecondary)
        if let a = autoScore, let y = yoursScore {
            // The difference of the two displayed (clamped) scores.
            let d = ScoreVerdict.safeDisplayScore(y * 10) - ScoreVerdict.safeDisplayScore(a * 10)
            Text(String(format: "%+d", locale: LanguageManager.appLocale, d))
                .font(.title3.bold().monospacedDigit())
                .foregroundColor(d >= 0 ? AppTheme.sage : AppTheme.terracotta)
            Text(String(localized: "Score", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        } else {
            Text(verbatim: "—")
                .font(.title3.bold())
                .foregroundColor(AppTheme.textTertiary)
        }
    }
    .frame(maxWidth: .infinity)
}

/// One side of the comparison: RMSSD headline plus the window's mean HR.
@MainActor
private func rmssdColumn(titleKey: String.LocalizationValue, from source: HRVAnalysisResult, tint: Color) -> some View {
    comparisonColumn(
        title: String(localized: titleKey, bundle: LanguageManager.appBundle),
        value: String(format: "%.1f", locale: LanguageManager.appLocale, source.timeDomain.rmssd),
        color: tint,
        footnote: source.windowMeanHR.map { String(localized: "\(Int($0.rounded())) bpm", bundle: LanguageManager.appBundle) }
    )
}

/// One column: a label, the RMSSD figure, the "RMSSD" unit, and an
/// optional footnote (mean HR, or the window's classification).
@MainActor
private func comparisonColumn(
    title: String,
    value: String,
    color: Color,
    footnote: String?
) -> some View {
    VStack(spacing: 4) {
        Text(title)
            .font(.caption2.bold())
            .foregroundColor(AppTheme.textSecondary)
        Text(value)
            .font(.title3.bold().monospacedDigit())
            .foregroundColor(color)
        Text(String(localized: "RMSSD", bundle: LanguageManager.appBundle))
            .font(.caption2)
            .foregroundColor(AppTheme.textTertiary)
        if let footnote {
            Text(footnote).font(.caption2).foregroundColor(AppTheme.textTertiary)
        }
    }
    .frame(maxWidth: .infinity)
}

/// The thin rule between comparison columns.
@MainActor
private func comparisonDivider(height: CGFloat) -> some View {
    Rectangle()
        .fill(AppTheme.textTertiary.opacity(0.3))
        .frame(width: 1, height: height)
}

@MainActor
private func provenanceRow(glyph: String, text: String) -> some View {
    HStack(spacing: 4) {
        Image(systemName: glyph)
            .font(.caption2)
            .foregroundColor(AppTheme.textTertiary)
        Text(text)
            .font(.caption)
            .foregroundColor(AppTheme.textTertiary)
    }
}
