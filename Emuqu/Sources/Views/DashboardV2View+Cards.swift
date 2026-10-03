import SwiftUI

// The dashboard banner and card sections. Members are internal rather than
// `private` because Swift's `private` does not reach across files.

extension DashboardV2View {
    // MARK: - Score-changed-while-away banner

    @ViewBuilder
    func scoreChangedBanner(_ change: PendingScoreChange.Entry) -> some View {
        let delta = change.newScore - change.priorScore
        let tint: Color = delta >= 0 ? AppTheme.primary : .orange
        HStack(spacing: 12) {
            Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(tint)
            scoreChangeCaption(change)
            Spacer()
            dismissScoreChangeButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .modifier(ScoreBannerChrome(tint: tint, opaque: reduceTransparency))
    }

    /// Reduce Transparency: fall back to the solid card background
    /// so the translucent tint wash doesn't compromise legibility for users who
    /// need opaque surfaces.
    struct ScoreBannerChrome: ViewModifier {
        let tint: Color
        let opaque: Bool

        func body(content: Content) -> some View {
            content
                .background(
                    opaque ? AppTheme.cardBackground : tint.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(tint.opacity(0.25), lineWidth: 1)
                )
        }
    }

    /// The stored scores are on the 0–10 scale; the ring shows ×10, so the
    /// banner does too ("67 → 74", not "7 → 7").
    func scoreChangeCaption(_ change: PendingScoreChange.Entry) -> some View {
        let priorInt = ScoreVerdict.safeDisplayScore(change.priorScore * 10)
        let newInt = ScoreVerdict.safeDisplayScore(change.newScore * 10)
        return VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "\(Self.scoreChangeReason(change.reason)) — score updated", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text("\(priorInt) → \(newInt)")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    static func scoreChangeReason(_ reason: String) -> String {
        switch reason {
        case "sleep": return String(localized: "Sleep data finished syncing", bundle: LanguageManager.appBundle)
        case "training": return String(localized: "Training context refreshed", bundle: LanguageManager.appBundle)
        default: return String(localized: "New data arrived", bundle: LanguageManager.appBundle)
        }
    }

    /// 44pt min tap target + VoiceOver label for the icon-only
    /// dismiss button.
    var dismissScoreChangeButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                pendingScoreChange = nil
            }
            PendingScoreChange.clear()
        } label: {
            Image(systemName: "xmark")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(AppTheme.textSecondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "Dismiss", bundle: LanguageManager.appBundle)))
    }

    // MARK: - HealthKit-denied banner
    // Surfaces HealthKitManager.inferredAuthorizationDenied
    // (published for this view alone). Deep-links to
    // Settings → the app's Health permissions, then clears the inferred
    // flag so the banner doesn't linger after the user has been sent to
    // fix it. Dismissible without leaving the app.

    @ViewBuilder
    var healthKitDeniedBanner: some View {
        healthKitDeniedRow
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            // Reduce Transparency solid fallback.
            .background(
                reduceTransparency ? AppTheme.cardBackground : Color.orange.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.orange.opacity(0.30), lineWidth: 1)
            )
    }

    private var healthKitDeniedRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "heart.text.square")
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(.orange)
            healthKitDeniedCopy
            Spacer()
            healthKitDismissButton
        }
    }

    private var healthKitDeniedCopy: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Said as what is known: no sleep or HRV arrived. Denied access
            // and no data look the same from inside the app.
            Text(String(localized: "No sleep or HRV from Apple Health", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(String(localized: "None in the last two weeks. That's normal without an Apple Watch or a sleep schedule; if you expected some, check access in Settings.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            openSettingsButton
                .buttonStyle(.plain)
                .padding(.top, 2)
        }
    }

    private var healthKitDismissButton: some View {
        Button {
            healthNoDataNoticeDismissed = true
            collector.healthKit.clearInferredDenial()
        } label: {
            Image(systemName: "xmark")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(AppTheme.textSecondary)
                // 44pt min tap target for the icon-only dismiss.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "Dismiss", bundle: LanguageManager.appBundle)))
    }

    private var openSettingsButton: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            // Clear the inferred flag — the user is now en route to
            // fix it; if they come back still denied, the next probe
            // re-sets it.
            collector.healthKit.clearInferredDenial()
        } label: {
            Text(String(localized: "Open Settings", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Hero

    var heroSection: some View {
        VStack(spacing: 10) {
            heroRing
                .overlay(
                    // Day-14 radial particle bloom.
                    // Twelve small dots radiate from the ring center over
                    // 800ms while fading. Color matches the verdict tint
                    // so the moment reads as "this is YOUR first verdict."
                    Day14ParticleBloom(active: day14BloomActive, tint: verdict?.color ?? AppTheme.primary)
                        .allowsHitTesting(false)
                )
            verdictRow
        }
    }

    /// Day-1 dashboard state. Three-item checklist
    /// replaces chips / Today's Loop / Recent strip until the user has
    /// completed their first reading. Each row shows: glyph + title +
    /// subtle subtitle + state (✓ done / ◯ pending). Tap-to-act on each.
    @ViewBuilder
    var day1Checklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            day1Header
            pairDeviceRow
            connectHealthRow
            firstReadingRow
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppTheme.cardBackground)
        )
    }

    @ViewBuilder
    private var day1Header: some View {
        Text(String(localized: "Get started", bundle: LanguageManager.appBundle))
            // Dynamic Type via @ScaledMetric.
            .font(.system(size: headingFontSize, weight: .semibold))
            .foregroundStyle(AppTheme.textPrimary)
        Text(String(localized: "Three quick steps to your first recovery score.", bundle: LanguageManager.appBundle))
            .font(.system(size: subheadingFontSize))
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.bottom, 4)
    }

    private var pairDeviceRow: some View {
        let strapPaired = !collector.polarManager.knownDevices.isEmpty
        return day1Row(
            done: strapPaired,
            glyph: "antenna.radiowaves.left.and.right",
            title: String(localized: "Pair device", bundle: LanguageManager.appBundle),
            subtitle: strapPaired ? String(localized: "Paired", bundle: LanguageManager.appBundle) : String(localized: "Polar H10 or Verity Sense", bundle: LanguageManager.appBundle),
            // Pairing lives on the Record tab's sensor panel.
            action: { onStartRecording() }
        )
    }

    private var connectHealthRow: some View {
        // HealthKit never reveals whether read access was granted, only that
        // the prompt was shown; the subtitle says exactly that.
        let healthRequested = collector.healthKit.authorizationRequested
        return day1Row(
            done: healthRequested,
            glyph: "heart.text.square",
            title: String(localized: "Connect Apple Health", bundle: LanguageManager.appBundle),
            subtitle: healthRequested ? String(localized: "Access requested", bundle: LanguageManager.appBundle) : String(localized: "For sleep + vitals", bundle: LanguageManager.appBundle),
            action: {
                Task { try? await collector.healthKit.requestAuthorization() }
            }
        )
    }

    private var firstReadingRow: some View {
        day1Row(
            done: false,
            glyph: "waveform.path.ecg",
            title: String(localized: "Take your first reading", bundle: LanguageManager.appBundle),
            subtitle: String(localized: "5-min spot check or overnight", bundle: LanguageManager.appBundle),
            action: { onStartRecording() }
        )
    }

    func day1Row(done: Bool, glyph: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { day1RowContent(done: done, glyph: glyph, title: title, subtitle: subtitle) }
            .buttonStyle(.plain)
            .disabled(done)
    }

    func day1RowContent(done: Bool, glyph: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .scaledFont(size: 22)
                .foregroundStyle(done ? AppTheme.wongOptimal : AppTheme.textTertiary)
            Image(systemName: glyph)
                .scaledFont(size: 16)
                .foregroundStyle(AppTheme.primary)
                .frame(width: 24)
            day1RowCaption(title: title, subtitle: subtitle)
            Spacer()
            day1RowChevron(done: done)
        }
    }

    @ViewBuilder
    func day1RowChevron(done: Bool) -> some View {
        if !done {
            Image(systemName: "chevron.forward")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    /// Dynamic Type via @ScaledMetric.
    func day1RowCaption(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
                .font(.system(size: rowTitleFontSize, weight: .medium))
                .foregroundStyle(AppTheme.textPrimary)
            Text(verbatim: subtitle)
                .font(.system(size: rowSubtitleFontSize))
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    @ViewBuilder
    var heroRing: some View {
        if daysCollected == 0 {
            ScoreRing(state: .noData, size: .hero)
        } else if !ScoreAppearancePolicy.showsScore(baselineNights: baselineNights) {
            ScoreRing(state: .buildingBaseline(day: baselineNights, target: ScoreAppearancePolicy.scoreShownNights), size: .hero)
        } else if let score = displayedScore, let verdict {
            ScoreRing(state: .default(score: score, verdict: verdict), size: .hero, snappy: ScoreAppearancePolicy.stage(baselineNights: baselineNights) == .full)
                .onTapGesture { openMorningReport() }
                // Tapping opens the morning report; VoiceOver has to know
                // it is a button to offer it.
                .accessibilityAddTraits(.isButton)
                // Long-press hero ring → context
                // menu with Share recovery card / Re-analyze / Copy data.
                .contextMenu { heroContextMenu }
        } else {
            ScoreRing(state: .loading, size: .hero)
        }
    }

    /// Tap on the morning hero opens the morning report — matches the strip
    /// rows below and the "tap the hero, push to detail" rule.
    /// The "why is readiness here" panel is reachable through the narrative
    /// card when there's a drift story.
    private func openMorningReport() {
        if let session = latestOvernightComplete {
            onViewReport(session)
        }
    }

    @ViewBuilder
    private var heroContextMenu: some View {
        shareRecoveryCardButton
        reAnalyzeButton
        copyDataButton
    }

    private var shareRecoveryCardButton: some View {
        Button {
            shareRecapCard()
        } label: {
            Label(String(localized: "Share recovery card", bundle: LanguageManager.appBundle), systemImage: "square.and.arrow.up")
        }
    }

    private var reAnalyzeButton: some View {
        Button {
            Task { await reanalyzeFromHero() }
        } label: {
            Label(String(localized: "Re-analyze", bundle: LanguageManager.appBundle), systemImage: "arrow.clockwise.circle")
        }
    }

    private var copyDataButton: some View {
        Button {
            copyHeroDataToClipboard()
        } label: {
            Label(String(localized: "Copy data", bundle: LanguageManager.appBundle), systemImage: "doc.on.doc")
        }
    }

    @ViewBuilder
    var verdictRow: some View {
        if let verdict, ScoreAppearancePolicy.showsScore(baselineNights: baselineNights) {
            HStack(spacing: 8) {
                Text(verbatim: verdict.localizedWord)
                    // Dynamic Type via @ScaledMetric.
                    .font(.system(size: verdictFontSize, weight: .semibold))
                    .foregroundStyle(verdict.textColor)
                ConfidencePip(daysCollected: baselineNights)
            }
        } else if !ScoreAppearancePolicy.showsScore(baselineNights: baselineNights) {
            VStack(spacing: 4) {
                Text(String(localized: "Building your baseline", bundle: LanguageManager.appBundle))
                    .font(.system(size: baselineFontSize, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                baselineProgressOrSampleOffer
            }
        }
    }

    /// At zero nights a "0 of 14" pip says nothing the line above does not,
    /// so that slot carries the sample-data offer instead. Taking an existing
    /// slot rather than adding a row keeps the Get started checklist where it
    /// was; one row lower, its last lines sat in the fade above the floating
    /// tab bar on a 402pt screen and failed the contrast audit.
    @ViewBuilder
    private var baselineProgressOrSampleOffer: some View {
        if daysCollected == 0 {
            SampleDataOfferRow()
                .padding(.top, 8)
        } else {
            ConfidencePip(daysCollected: baselineNights)
        }
    }

    // MARK: - Today's Loop

    @ViewBuilder
    var todaysLoopSection: some View {
        if ScoreAppearancePolicy.showsScore(baselineNights: baselineNights), let verdict {
            mainLoopCard(accent: verdict.color)
        } else if daysCollected > 0 && !ScoreAppearancePolicy.showsScore(baselineNights: baselineNights) {
            NarrativeCard(
                text: String(localized: "Day \(baselineNights) of 14. Keep recording — your baseline is forming.", bundle: LanguageManager.appBundle),
                accent: AppTheme.wongGood
            )
        }
    }

    /// When the loop card is carrying a readiness drift story, make it tappable
    /// into the "why readiness is here" panel — that's the breakdown of the
    /// day's signals (morning recovery, today's training, acute fatigue, time
    /// of day). On ordinary days the card is just the verdict's stock
    /// subverdict and stays static so we don't promise depth that isn't there.
    @ViewBuilder
    private func mainLoopCard(accent: Color) -> some View {
        if liveReadiness?.loopCardText != nil {
            Button {
                navTarget = .readiness
            } label: {
                loopCard(accent: accent)
            }
            .buttonStyle(.plain)
            .accessibilityHint(String(localized: "Opens the readiness breakdown", bundle: LanguageManager.appBundle))
        } else {
            loopCard(accent: accent)
        }
    }

    private func loopCard(accent: Color) -> some View {
        NarrativeCard(
            text: todaysLoopText(),
            accent: accent,
            feedbackChipsEnabled: false
        )
    }

    func todaysLoopText() -> String {
        // When today has a story to tell — a workout that pulled readiness
        // down, fatigue that's lifting it through the day — prefer that
        // sentence. The verdict ladder's stock subverdicts are written for
        // the morning physiology check; once readiness has drifted, the
        // body's narrative is no longer "what your night gave you."
        if let contextual = liveReadiness?.loopCardText {
            translator.prepare([contextual])
            return translator.t(contextual)
        }
        guard let v = verdict else { return "" }
        return v.localizedSubverdict
    }

    // MARK: - Feedback chip
    // Small inline pill: 😊 "Felt good · Edit", or "Tap how you feel" when
    // unset. Reads / writes the same `morningFeeling` field on the overnight
    // session that the pre-score prompt captures, so the heatmap on Trends,
    // the assistant and the dashboard chip all read the same answer.

    @ViewBuilder
    var feedbackChipSection: some View {
        if let session = latestOvernightComplete {
            DashboardMorningFeelingChip(session: session) { value, tags in
                applyMorningFeeling(value: value, tags: tags, session: session)
            }
        }
    }

    /// Only the feeling is written, onto the archived copy: the dashboard's
    /// copy can predate a score or sleep update.
    /// The archive write runs off the main actor; a failure shows a toast so
    /// the user knows to answer again.
    func applyMorningFeeling(value: Int, tags: [MorningFeelingTag], session: HRVSession) {
        let feelingTags = tags.isEmpty ? nil : tags
        let id = session.id
        let archive = collector.archive
        Task {
            let saved = await Task.detached {
                Self.storeMorningFeeling(value, tags: feelingTags, id: id, archive: archive)
            }.value
            guard !saved else { return }
            toast = ToastPayload(
                glyph: "exclamationmark.triangle",
                message: String(localized: "Couldn't save how you felt. Try again.", bundle: LanguageManager.appBundle),
                tint: AppTheme.alert
            )
        }
    }

    /// Returns false when the write failed.
    nonisolated private static func storeMorningFeeling(_ value: Int, tags: [MorningFeelingTag]?, id: UUID, archive: SessionArchive) -> Bool {
        do {
            try archive.update(id) { stored in
                stored.morningFeeling = value
                stored.morningFeelingTags = tags
            }
            return true
        } catch {
            debugLog("[Dashboard] Morning feeling not persisted for \(id.uuidString.prefix(8)): \(error.localizedDescription)", level: .warning)
            return false
        }
    }
}
