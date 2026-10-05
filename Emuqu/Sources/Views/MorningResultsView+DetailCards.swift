import Charts
import SwiftUI

// MARK: - MorningResultsView Detail Cards

extension MorningDetailCards {
    // MARK: - Recovery Score Card (matches Recovery Dashboard)

    /// The score is sanitized BEFORE any `Int(score)` /
    /// `.trim(score/100)`: both HARD-CRASH on NaN/Inf. A short quick reading
    /// (nil DFA-α1 / frequency-domain) or a non-finite score archived by an old
    /// build can reach here. Clamping to a finite [0,100] means the ring can
    /// NEVER trap, whatever the source. (The score's root sources are guarded
    /// too; this is the defense-in-depth at the exact crash point.)
    ///
    /// The card carries no `accessibilityIdentifier`, deliberately. An
    /// identifier on a CONTAINER propagates to every leaf inside it and
    /// overrides the identifiers those leaves set for themselves: with one
    /// here, the score ring and the explainer button both reported as
    /// "morning.scoreCard" and neither could be addressed by a UI test.
    /// Identify the parts, never the wrapper.
    func recoveryScoreCard(breakdownMessage: String) -> some View {
        let score = ScoreVerdict.clampedDisplayScore(vm.compositeRecoveryScore)
        let color = AppTheme.recoveryColor(score)
        return VStack(spacing: 8) {
            scoreCaption
            scoreRing(score: score, color: color)
            Text(breakdownMessage)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            strapSyncIndicator
            dateAndQualitySubtitle
            splitNightSection
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(AppTheme.cardBackground)
        .cornerRadius(20)
    }

    private var scoreCaption: some View {
        HStack(spacing: 6) {
            Text(String(localized: "EMUQU\u{2122}", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
                .tracking(2)
            Button { showingScoreExplainer = true } label: {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
                    .padding(10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "What does this score mean?", bundle: LanguageManager.appBundle)))
            .accessibilityIdentifier("morning.scoreExplainer")
        }
    }

    /// Caption + first-score explainer ⓘ. The info button opens
    /// the existing "Understanding Your Score" Help article so a new user can
    /// learn what the number means.

    /// The hero ring: a dimmed track, the progress arc, and the number itself.
    private func scoreRing(score: Double, color: Color) -> some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: 16)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(
                    AngularGradient(colors: [color.opacity(0.6), color], center: .center),
                    style: StrokeStyle(lineWidth: 16, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            scoreRingLabel(score: score, color: color)
        }
        .frame(width: scoreRingSize, height: scoreRingSize)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Recovery score: \(RecoveryScoreCalculator.displayScore(score)) out of 100, \(ScoreVerdict(score: score).localizedWord)", bundle: LanguageManager.appBundle))
        // The ring is one accessibility element by design — VoiceOver reads a
        // sentence, not "72" then "Good" — so the number is inside this
        // element's label and nowhere else in the tree. A UI test checking the
        // score rendered has to address the ring itself.
        .accessibilityIdentifier("morning.scoreRing")
    }

    /// The number and its word, always shown as final.
    private func scoreRingLabel(score: Double, color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(RecoveryScoreCalculator.displayScore(score))")
                // Dynamic Type via @ScaledMetric.
                .font(.system(size: heroScoreFontSize, weight: .bold))
                .foregroundColor(color)
            // The dashboard's verdict scale. Morning Results had its own
            // (80/60/40), so 72 read "Good" here and "Fair" on the dashboard.
            Text(verbatim: ScoreVerdict(score: score).localizedWord)
                .font(.subheadline.weight(.medium))
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    /// Subtle strap sync indicator. Does NOT gate score display.
    @ViewBuilder
    private var strapSyncIndicator: some View {
        if morningCoordination.isDeviceFetchInProgress {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6)
                Text(String(localized: "Syncing strap data", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
                Spacer()
            }
        }
    }

    private var dateAndQualitySubtitle: some View {
        HStack(spacing: 8) {
            Text(session.endDate ?? session.startDate, style: .date)
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
            Text(String(localized: "\u{00B7}", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textTertiary)
            qualityBadge
        }
        .padding(.top, 2)
    }

    /// Artifact rate as a one-word verdict, on the same 5 / 10 / 20% bands
    /// the Artifacts popover explains.
    private var qualityBadge: some View {
        let quality = Self.artifactQuality(vm.displayResult.artifactPercentage)
        return HStack(spacing: 3) {
            Image(systemName: quality.icon)
                .font(.caption2)
            Text(quality.word)
                .font(.caption)
        }
        .foregroundColor(quality.color)
    }

    private static func artifactQuality(_ percent: Double) -> (word: String, icon: String, color: Color) {
        switch percent {
        case ..<5: (String(localized: "Excellent", bundle: LanguageManager.appBundle), "checkmark.seal.fill", AppTheme.sage)
        case ..<10: (String(localized: "Good", bundle: LanguageManager.appBundle), "checkmark.seal", AppTheme.sage)
        case ..<20: (String(localized: "Fair", bundle: LanguageManager.appBundle), "exclamationmark.triangle.fill", AppTheme.softGold)
        default: (String(localized: "Poor", bundle: LanguageManager.appBundle), "exclamationmark.triangle.fill", AppTheme.terracotta)
        }
    }

    /// Split night indicator — only when BOTH conditions hold:
    ///   (1) ≥2 linked recording segments survive dedup/merge, and
    ///   (2) the actual sleep data (HealthKit or stored snapshot) shows
    ///       ≥2 sleep segments too.
    /// Recording-gap ≠ sleep-gap. Pause/resume of the strap or a second
    /// same-night recording produces linked sessions even though the user
    /// slept through without waking — reporting that as a "split night"
    /// is wrong.
    @ViewBuilder
    private var splitNightSection: some View {
        if let segments = normalizedSplitNightSegments, segments.count > 1 {
            splitNightCard(segments: segments)
        }
    }

    /// The merged split-night segments, or nil when this wasn't a split night.
    private var normalizedSplitNightSegments: [LinkedSegmentInfo]? {
        guard let linked = linkedSegments, sleepWasActuallySplit else { return nil }
        return SessionArchive.normalizedSplitNightSegments(
            currentSessionId: session.id,
            currentStartDate: session.startDate,
            currentEndDate: session.endDate ?? session.startDate,
            linkedSegments: linked.filter { !removedSegmentIds.contains($0.id) }
        )
    }

    // MARK: - Training Readiness Card (extracted to TrainingReadinessCard.swift)

    /// `trainingContext` always comes from the raw morning ATL/CTL (no EWMA
    /// step) — the frozen morning state, before any intra-day recovery.
    ///
    /// `frozenReadiness` makes the report show the SAME number
    /// that was computed at session acceptance, regardless of when the user
    /// opens the report (morning vs evening, ATL has decayed, etc.). Without
    /// it the card recomputes live and the displayed readiness can drift away
    /// from the frozen composite recovery score it sits beside, producing the
    /// kind of mismatched-numbers UX the user flagged. Falls back to a live
    /// recompute when frozenReadiness is nil (e.g. legacy sessions archived
    /// before frozen-readiness was introduced).
    ///
    /// Reads from `displaySession` (not `session`) so the re-analyze +
    /// sleep-refresh archive observer's reload is honoured — same routing as
    /// `compositeRecoveryScore`.
    var trainingReadinessCard: some View {
        TrainingReadinessCard(
            recoveryScore: vm.compositeRecoveryScore,
            dayTrimp: 0,
            trainingContext: vm.displaySession.trainingSnapshot ?? vm.displayResult.trainingContext,
            frozenReadiness: vm.displaySession.frozenReadiness
        )
    }

    // MARK: - Score Breakdown (extracted to ScoreBreakdownCard.swift)

    func scoreBreakdownSection(breakdown: RecoveryScoreCalculator.ScoreBreakdown) -> some View {
        ScoreBreakdownCard(breakdown: breakdown)
    }

    // recoveryBreakdown() is now on MorningResultsViewModel

    // MARK: - Tags & Notes (Combined Compact Section)

    /// Tags and notes live in `TagsAndNotesCard`. The
    /// forwarder returns the same view tree from the same position, so
    /// nothing about the rendered hierarchy changes.
    var tagsAndNotesSection: some View {
        TagsAndNotesCard(
            notes: $notes,
            selectedTags: vm.selectedTags,
            onToggleTag: { onToggleTag($0) }
        ).body
    }

    // MARK: - Training Load Card (extracted to TrainingLoadCard.swift)

    func trainingLoadCard(_ training: TrainingContext) -> some View {
        TrainingLoadCard(training: training)
    }

    // MARK: - Split Night Card

    /// True when Apple Health says the *sleep* was split into multiple
    /// segments. Uses HealthKit's raw segment list as-is — if the Watch
    /// reported one continuous block, we show one. No gap-based
    /// re-derivation. Falls back to the session's stored sleep segments
    /// (frozen at acceptance) when the live snapshot isn't in hand.
    var sleepWasActuallySplit: Bool {
        if let hk = vm.healthKitSleep, hk.segments.count > 1 {
            return true
        }
        if let stored = session.sleepSegments, stored.count > 1 {
            return true
        }
        return false
    }

    /// Compact card showing segment time ranges and gap duration for split-night recordings.
    func splitNightCard(segments: [LinkedSegmentInfo]) -> some View {
        let allSegments = segments.sorted { $0.startDate < $1.startDate }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.caption.bold())
                    .foregroundColor(AppTheme.primary)
                Text(String(localized: "Split Night — \(allSegments.count) segments", bundle: LanguageManager.appBundle))
                    .font(.caption.bold())
                    .foregroundColor(AppTheme.textPrimary)
            }
            ForEach(Array(allSegments.enumerated()), id: \.element.id) { idx, segment in
                segmentRow(segment, index: idx)
                gapRow(after: idx, in: allSegments)
            }
        }
        .padding(12)
        .background(AppTheme.primary.opacity(0.06))
        .cornerRadius(8)
    }

    /// One segment's clock range, with an unlink control on the linked ones
    /// (never on the session being viewed).
    private func segmentRow(_ segment: LinkedSegmentInfo, index idx: Int) -> some View {
        let timeStyle: Date.FormatStyle = .dateTime.hour().minute()
        return HStack(spacing: 8) {
            Text(String(localized: "Segment \(idx + 1)", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
                .frame(width: 64, alignment: .leading)
            Text("\(segment.startDate.formatted(timeStyle)) – \(segment.endDate.formatted(timeStyle))")
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
            Spacer()
            unlinkButton(for: segment)
        }
    }

    @ViewBuilder
    private func unlinkButton(for segment: LinkedSegmentInfo) -> some View {
        if segment.id != session.id, onUnlinkSegment != nil {
            Button {
                pendingUnlinkSegmentId = segment.id
                showingUnlinkConfirmation = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            // It unlinks a segment; VoiceOver said "Close".
            .accessibilityLabel(String(localized: "Unlink segment", bundle: LanguageManager.appBundle))
            .buttonStyle(.plain)
        }
    }

    /// The awake gap between this segment and the next, when there is one.
    @ViewBuilder
    private func gapRow(after idx: Int, in allSegments: [LinkedSegmentInfo]) -> some View {
        if let gap = gapAfter(idx, in: allSegments) {
            HStack(spacing: 4) {
                Rectangle()
                    .fill(AppTheme.textTertiary.opacity(0.3))
                    .frame(width: 1, height: 12)
                    .padding(.leading, 30)
                Text(String(localized: "\(formatGapDuration(gap)) awake", bundle: LanguageManager.appBundle))
                    .font(.caption2)
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
    }

    /// Seconds awake between one segment and the next, or nil at the last
    /// segment (or when the recordings abut).
    private func gapAfter(_ idx: Int, in allSegments: [LinkedSegmentInfo]) -> TimeInterval? {
        guard idx < allSegments.count - 1 else { return nil }
        let gap = allSegments[idx + 1].startDate.timeIntervalSince(allSegments[idx].endDate)
        return gap > 0 ? gap : nil
    }

    /// Format a time interval as "Xh Ym" or "Ym" for gap display.
    func formatGapDuration(_ interval: TimeInterval) -> String {
        LocalizedDuration.hoursMinutes(minutes: Int(interval / 60))
    }

    // MARK: - HRV Metric Card (matches Recovery Dashboard)

    var hrvMetricCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            hrvSection
            hrvReadout
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityElement(children: .combine)
        .padding()
        .frame(maxWidth: .infinity)
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    private var hrvReadout: some View {
        VStack(spacing: 4) {
            hrvValue
            // Against the scoring baseline, as "What This Means" rates it;
            // fixed millisecond cut-offs gave a third answer for the night.
            Text(AppTheme.hrvLabel(vm.displayResult.timeDomain.rmssd, baseline: hrvBaseline))
                .font(.caption)
                .foregroundColor(AppTheme.hrvTextColor(vm.displayResult.timeDomain.rmssd, baseline: hrvBaseline))
        }
    }

    private var hrvBaseline: Double? {
        vm.baselineStats.map { exp($0.lnRmssdMean) }
    }

    private var hrvValue: some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text(String(format: "%.0f", locale: LanguageManager.appLocale, vm.displayResult.timeDomain.rmssd))
                // Dynamic Type via @ScaledMetric.
                .font(.system(size: metricValueFontSize, weight: .bold))
            Text(String(localized: "ms", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    private var hrvSection: some View {
        HStack {
            Image(systemName: "waveform.path.ecg")
                .foregroundColor(AppTheme.primary)
            Text(String(localized: "HRV", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
                .tracking(1)
        }
    }

    // MARK: - Sleep Metric Card Compact (half-width, pairs with HRV)

    var sleepMetricCardCompact: some View {
        VStack(alignment: .leading, spacing: 8) {
            sleepSection

            sleepDurationValue
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    private var sleepSection: some View {
        HStack {
            Image(systemName: "moon.fill")
                .foregroundColor(AppTheme.primary)
            Text(String(localized: "SLEEP", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
                .tracking(1)
        }
    }

    @ViewBuilder
    private var sleepDurationValue: some View {
        if let sleep = vm.healthKitSleep {
            sleepDurationReadout(sleep)
        } else if vm.isSleepLoading {
            loadingSection
        } else {
            Text(String(localized: "--", bundle: LanguageManager.appBundle))
                .font(.system(size: metricValueFontSize, weight: .bold))
                .foregroundColor(AppTheme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func sleepDurationReadout(_ sleep: SleepData) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(String(format: "%.1f", locale: LanguageManager.appLocale, Double(sleep.totalSleepIncludingNapMinutes) / 60.0))
                    // Dynamic Type via @ScaledMetric.
                    .font(.system(size: metricValueFontSize, weight: .bold))
                Text(String(localized: "hrs", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }
            Text(sleepVerdict(sleep).localizedWord)
                .font(.caption.weight(.medium))
                .foregroundColor(sleepVerdict(sleep).color)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var loadingSection: some View {
        VStack(spacing: 6) {
            ProgressView()
                .scaleEffect(0.8)
            Text(String(localized: "Loading...", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    /// The `ScoreVerdict` ladder Sleep detail grades with, so the label and
    /// colour here match the screen this card opens.
    func sleepVerdict(_ sleep: SleepData) -> ScoreVerdict {
        ScoreVerdict(score: Double(sleepScoreForLabel(sleep)))
    }

    /// The same sleep score the recovery score uses
    /// (`RecoveryScoreCalculator.calculateSleepScore`), so the label can't
    /// disagree with the score.
    func sleepScoreForLabel(_ sleep: SleepData) -> Int {
        let settings = AppDependencies.current.app.settingsManager.settings
        let score = RecoveryScoreCalculator.calculateSleepScore(
            sleepData: sleep,
            typicalSleepHours: settings.typicalSleepHours,
            userAge: settings.age
        )
        return Int(score ?? 0)
    }

    // MARK: - Data Source Summary Card

    func dataSourceSummaryCard(_ summary: HRVSession.DataSourceSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            dataSourceHeader(summary)
            Text(summary.description)
                .font(.subheadline)
                .foregroundColor(AppTheme.textPrimary)
            beatBreakdown(summary)
            reconnectNote(summary)
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    /// Streamed / device / analyzed beat counts side by side. The device column
    /// only appears when a post-hoc device fetch contributed anything.
    private func beatBreakdown(_ summary: HRVSession.DataSourceSummary) -> some View {
        HStack(spacing: 0) {
            beatColumn(summary.streamingBeats, label: String(localized: "Streamed", bundle: LanguageManager.appBundle))
            if let db = summary.deviceBeats {
                beatColumn(db, label: String(localized: "Device", bundle: LanguageManager.appBundle))
            }
            beatColumn(
                summary.totalBeats,
                label: String(localized: "Analyzed", bundle: LanguageManager.appBundle),
                color: AppTheme.sage
            )
        }
    }

    private func beatColumn(_ count: Int, label: String, color: Color? = nil) -> some View {
        VStack(spacing: 2) {
            Text(Self.beatFormatter.string(from: NSNumber(value: count)) ?? "\(count)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundColor(color ?? AppTheme.textPrimary)
            Text(label)
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Number formatter for beat counts, in the app language.
    private static var beatFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = LanguageManager.appLocale
        return f
    }
}

// MARK: - File-scope helpers
//
// Kept outside MorningResultsView: each names no member of the
// type and calls nothing inside it, so none needs to be a member.
// `private` at file scope is fileprivate, so every call site in this
// file resolves the same way.

@MainActor
private func dataSourceHeader(_ summary: HRVSession.DataSourceSummary) -> some View {
    HStack(spacing: 6) {
        Image(systemName: "externaldrive.fill.badge.checkmark")
            .foregroundColor(AppTheme.primary)
        Text(String(localized: "DATA SOURCE", bundle: LanguageManager.appBundle))
            .font(.caption.weight(.semibold))
            .foregroundColor(AppTheme.textTertiary)
            .tracking(1)
        Spacer()
        Text(AppTheme.dataSourceLabel(summary.selectedSource))
            .font(.caption2.weight(.medium))
            .foregroundColor(AppTheme.dataSourceColor(summary.selectedSource))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(AppTheme.dataSourceColor(summary.selectedSource).opacity(0.15))
            .cornerRadius(6)
    }
}

@ViewBuilder
@MainActor
private func reconnectNote(_ summary: HRVSession.DataSourceSummary) -> some View {
    if summary.reconnectCount > 0 {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption2)
                .foregroundColor(AppTheme.softGold)
            Text(String(localized: "\(summary.reconnectCount) reconnections during recording", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
            Spacer()
        }
    }
}
