import SwiftUI

// The metric chips row, recent strip, footer and recap-card share, split out of
// `DashboardV2View.swift`. What stays behind is the hero score,
// today's loop, the feedback chip and the two banners — the top of the screen.

extension DashboardV2View {
    // MARK: - Chips row (HRV / Sleep / Vitals / Load)

    var chipsRow: some View {
        HStack(spacing: 8) {
            hrvChip
            sleepChip
            vitalsChip
            loadChip
        }
    }

    private var hrvChip: some View {
        ContributorChip(variant: hrvVariant, state: hrvState, compact: true, recordedAgo: nightAgeLabel(for: latestOvernightComplete)) {
            dependencies.services.validationTelemetry.recordChipTap(.hrv)
            navTarget = .hrv
        }
    }

    private var sleepChip: some View {
        ContributorChip(variant: sleepVariant, state: sleepState, compact: true, recordedAgo: nightAgeLabel(for: sleepChipSession)) {
            dependencies.services.validationTelemetry.recordChipTap(.sleep)
            navTarget = .sleep
        }
    }

    private var vitalsChip: some View {
        ContributorChip(variant: vitalsVariant, state: vitalsState, compact: true) {
            dependencies.services.validationTelemetry.recordChipTap(.vitals)
            navTarget = .vitals
        }
    }

    /// Load chip is workout-derived (TRIMP / CTL /
    /// ATL / TSB). Hide it for users who flipped on "Hide
    /// Fitness tab" — that setting's own footer says it's for
    /// "recovery-only / HRV-only users who don't record
    /// workouts." Showing a chip that opens an empty Load &
    /// Trajectory contradicts the intent. User report (Sachie):
    /// "Why is Load showing up when I have fitness disabled?" Hidden too while training load is paused.
    @ViewBuilder
    private var loadChip: some View {
        if !settingsManager.settings.hideFitnessTab, !TrainingLoadVisibility.isPaused(settingsManager.settings) {
            ContributorChip(variant: loadVariant, state: loadState, compact: true) {
                dependencies.services.validationTelemetry.recordChipTap(.load)
                navTarget = .load
            }
        }
    }

    var hrvVariant: ContributorChip.Variant {
        // Overnight-only. A quick streaming HRV
        // taken during exercise is a different signal entirely (mid-
        // effort RMSSD ≪ resting RMSSD); rendering it on the
        // recovery-context dashboard misleads the user into thinking
        // their day's recovery has changed when really it's just an
        // exercise capture. The overnight reading is the canonical
        // "today's recovery HRV" and stays put until tomorrow's
        // overnight lands.
        guard let r = latestOvernightComplete?.analysisResult else {
            // Cold-start seed: full sessions not decrypted yet — show the
            // latest overnight's RMSSD straight from the index.
            if sessions.isEmpty,
               let ms = cachedDashboard?.hrvRmssdMs ?? seedSummary?.hrvRmssdMs {
                return .hrv(value: "\(ms) ms", trend: nil)
            }
            return .hrv(value: "—", trend: nil)
        }
        let rmssd = r.timeDomain.rmssd
        return .hrv(value: "\(Int(rmssd.rounded())) ms", trend: nil)
    }

    var hrvState: ContributorChip.DisplayState {
        if latestOvernightComplete != nil { return .default }
        if sessions.isEmpty,
           (cachedDashboard?.hrvRmssdMs ?? seedSummary?.hrvRmssdMs) != nil { return .default }
        return .noData
    }

    /// Not read from `latest`: that is the most-recent session of any
    /// kind, including a quick reading taken AFTER last night's
    /// overnight session. A daytime quick reading carries no
    /// sleepSnapshot, so the chip would render "—" even though last
    /// night's overnight session has full sleep data. Same pattern as
    /// `latestOvernightComplete` for the HRV chip — surface the
    /// canonical morning value, not whatever incidental capture
    /// happened most recently.
    ///
    /// Prefers the SAME session the Sleep detail screen opens
    /// (`latestOvernightComplete`), falling back to `latestWithSleep`.
    /// A sleepSnapshot can be frozen onto a non-overnight session, so
    /// the newest snapshot-bearing session (`latestWithSleep`) is not
    /// always the overnight session the detail screen shows — chip and
    /// detail would disagree, and timeline edits (which write to
    /// `latestOvernightComplete.id`) would never reach the chip. User
    /// report: "sleep looks fine in the sleep section but the
    /// dashboard doesn't reflect that."
    var sleepVariant: ContributorChip.Variant {
        if let snap = sleepChipSession?.sleepSnapshot, snap.totalSleepIncludingNapMinutes > 0 {
            return .sleep(duration: LocalizedDuration.hoursMinutes(minutes: snap.totalSleepIncludingNapMinutes), efficiency: nil)
        }
        // Cold-start seed: full sessions not decrypted yet — show the latest
        // overnight's sleep duration from the index (stage-sum; nil → "—").
        if sessions.isEmpty,
           let mins = cachedDashboard?.sleepMinutes ?? seedSummary?.sleepMinutes {
            return .sleep(duration: LocalizedDuration.hoursMinutes(minutes: mins), efficiency: nil)
        }
        return .sleep(duration: "—", efficiency: nil)
    }

    /// The session whose sleep the chip shows: the morning overnight when it
    /// carries a sleep snapshot, else the newest session that does.
    var sleepChipSession: HRVSession? {
        if let overnight = latestOvernightComplete, overnight.sleepSnapshot != nil { return overnight }
        return latestWithSleep
    }

    var sleepState: ContributorChip.DisplayState {
        // Same rule as `sleepVariant` above: a snapshot with no sleep minutes
        // renders "—", so it is the no-data state, not a default-styled dash.
        if let snap = sleepChipSession?.sleepSnapshot, snap.totalSleepIncludingNapMinutes > 0 { return .default }
        if sessions.isEmpty,
           (cachedDashboard?.sleepMinutes ?? seedSummary?.sleepMinutes) != nil { return .default }
        return .noData
    }

    var vitalsVariant: ContributorChip.Variant {
        // Same pattern as sleepVariant: read
        // from `latestWithVitals` so a quick mid-day reading without
        // a vitals snapshot doesn't blank this chip when last
        // night's overnight session HAS vitals data.
        // Cold-start: fall back to the cached vitals so the chip isn't "No
        // data" on first paint. Same `vitalsVariant` logic runs on it, so the
        // cached chip is identical to the live one.
        guard let v = latestWithVitals?.vitalsSnapshot ?? cachedDashboard?.vitals, !v.isEmpty else {
            return .vitals(status: .normal, leadVital: String(localized: "No data", bundle: LanguageManager.appBundle))
        }
        let status: ContributorChip.VitalsStatus
        switch v.status {
        case .normal: status = .normal
        case .elevated: status = .watch
        case .warning: status = .elevated
        }
        return .vitals(status: status, leadVital: leadVitalSubline(v))
    }

    /// Display-sensitivity thresholds for the chip's lead-vital subline.
    /// DELIBERATELY more sensitive than `RecoveryVitals`' clinical status
    /// cutoffs (resp >2, temp >0.5) — the subline surfaces the most
    /// notable vital before it is status-flagged. Named so they are not
    /// bare literals indistinguishable from the clinical cutoffs.
    private enum LeadVitalDisplay {
        static let respDeviationNoteworthy = 1.0   // breaths/min vs baseline
        static let tempDeviationNoteworthy = 0.3   // °C vs baseline
    }

    /// "Label value" subline. The thresholds compare the stored °C / breaths
    /// deviation; the temperature is shown in the user's chosen unit.
    func leadVitalSubline(_ v: RecoveryVitals) -> String? {
        let bundle = LanguageManager.appBundle
        if let dev = v.respiratoryDeviation, abs(dev) > LeadVitalDisplay.respDeviationNoteworthy {
            return "\(String(localized: "Resp", bundle: bundle)) \(Self.signedOneDecimal(dev))"
        }
        if let t = v.wristTemperatureDeviation, abs(t) > LeadVitalDisplay.tempDeviationNoteworthy {
            let unit = settingsManager.settings.temperatureUnit
            return "\(String(localized: "Temp", bundle: bundle)) \(Self.signedOneDecimal(unit.convert(t)))\(unit.symbol)"
        }
        if v.isSpO2Concerning, let spo2 = v.oxygenSaturation {
            return "\(String(localized: "SpO₂", bundle: bundle)) \(Int(spo2))%"
        }
        return nil
    }

    static func signedOneDecimal(_ value: Double) -> String {
        (value >= 0 ? "+" : "") + String(format: "%.1f", locale: LanguageManager.appLocale, value)
    }

    var vitalsState: ContributorChip.DisplayState {
        guard let v = latestWithVitals?.vitalsSnapshot ?? cachedDashboard?.vitals, !v.isEmpty else { return .noData }
        return .default
    }

    /// Routes through `TrajectoryVerdict.compute(...)` so this chip
    /// and the full Load & Trajectory surface share one canonical
    /// implementation. A chip-local heuristic (".detraining" any
    /// time TSB < -10 AND CTL < 30) made every user with a low
    /// chronic load (early in their training history) read as
    /// "detraining" even when they were pushing daily. Detraining
    /// requires the proper condition: CTL FALLING over the past week
    /// (delta < -1), not just CTL being numerically low.
    var loadVariant: ContributorChip.Variant {
        let cache = dependencies.analysis.trainingMetricsCache
        guard let metrics = cache.current else {
            return .load(verdict: .buildingBaseline, subline: "—")
        }
        // No load at all is "building baseline", not "→ Maintaining" over zeros.
        guard metrics.ctl > 0 || metrics.atl > 0 || metrics.todayTrimp > 0 else { return .load(verdict: .buildingBaseline, subline: "—") }
        let verdict = loadVerdict(series: trajectorySeries(cache, live: metrics))
        // todayTrimp = today's summed effectiveLoad
        // (power/HR TSS-preferred), the same metric shown as "LOAD" on the
        // workout summary and trajectory — not raw Banister TRIMP. Label "LOAD".
        let trimpInt = Int(metrics.todayTrimp.rounded())
        return .load(verdict: verdict, subline: String(localized: "LOAD \(trimpInt) today", bundle: LanguageManager.appBundle))
    }

    /// One day of the trajectory the verdict reads.
    typealias TrajectoryDay = (ctl: Double, atl: Double, tsb: Double)

    /// The series the Load & Trajectory screen plots
    /// (`LoadTrajectoryLoader.makeSamples`): the last 90 days, oldest first,
    /// with today's bucket read live from `TrainingMetricsCache.current`.
    /// The chip's verdict is computed from exactly what that screen shows.
    private func trajectorySeries(_ cache: TrainingMetricsCache, live: TrainingMetrics) -> [TrajectoryDay] {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        return cache.samplesSince(cutoff).reversed().map { day -> TrajectoryDay in
            calendar.isDateInToday(day.date) ? (live.ctl, live.atl, live.tsb) : (day.ctl, day.atl, day.tsb)
        }
    }

    /// The Load & Trajectory screen's verdict inputs, taken from the same
    /// series: current CTL and TSB from its newest day, week-ago CTL from
    /// `count - 8`, the regression ramp rate over its CTL, and the peaking
    /// heuristic over its last four days.
    private func loadVerdict(series: [TrajectoryDay]) -> TrajectoryVerdict {
        TrajectoryVerdict.compute(.init(
            currentCTL: series.last?.ctl ?? 0,
            ctlOneWeekAgo: series.count >= 8 ? series[series.count - 8].ctl : nil,
            sampleCount: series.count,
            comebackActive: settingsManager.settings.isComebackModeActive,
            overreachActive: settingsManager.settings.isIntentionalOverreachInEffect,
            peakingDetected: peakingDetected(series),
            rampRate: TrajectoryVerdict.ctlSlopePerWeek(series.map { $0.ctl }),
            currentTSB: series.last?.tsb
        ))
    }

    /// Peaking heuristic: ATL < CTL by >10% sustained 4+ days. Only
    /// fires when the user has opted into peaking detection.
    private func peakingDetected(_ series: [TrajectoryDay]) -> Bool {
        guard settingsManager.settings.peakingDetectionEnabled else { return false }
        let last4 = series.suffix(4)
        guard last4.count == 4 else { return false }
        return last4.allSatisfy { $0.ctl > 0 && ($0.ctl - $0.atl) / $0.ctl > 0.10 }
    }

    var loadState: ContributorChip.DisplayState {
        dependencies.analysis.trainingMetricsCache.current == nil ? .buildingBaseline : .default
    }

    // MARK: - Recent strip

    var recentStripSection: some View {
        let days = buildRecentDays()
        return RecentStrip(
            days: days,
            showVerdicts: baselineNights >= ScoreAppearancePolicy.fullBaselineNights,
            onTapDay: { openDay($0) },
            onViewAll: { navTarget = .history }
        )
    }

    /// Past empty days are tappable for visual feedback — the press animation
    /// shows the affordance is real — but intentionally have no destination:
    /// there is no reading to open, and starting one would not be tied to that
    /// date.
    private func openDay(_ day: RecentStrip.Day) {
        let cal = Calendar.current
        // Single shared rule with `buildRecentDays` so a cell that
        // renders as filled always has a session to push into,
        // regardless of session type (overnight, quick, etc).
        if let session = sessionForDay(day.date) {
            // Day with a reading → same destination as tapping
            // the hero medallion: Recovery Score detail.
            onViewReport(session)
        } else if cal.isDateInToday(day.date) {
            // Today's empty card → start a reading. This makes
            // the strip's today slot match the hero's
            // empty-state behavior ("Take a reading" CTA).
            onStartRecording()
        }
    }

    /// Pick the day's representative reading. The wake-date attribution,
    /// exclude-`.workout`, and duration tie-break rules live in
    /// `DashboardSessionPolicy.sessionForDay`.
    func sessionForDay(_ date: Date) -> HRVSession? {
        DashboardSessionPolicy.sessionForDay(date, in: sessions, calendar: .current)
    }

    /// Last 7 readings for the Recent strip (see
    /// `DashboardSessionPolicy.recentDays` for the rule and its audit
    /// history). This just maps the policy's view-agnostic days onto
    /// `RecentStrip.Day`.
    func buildRecentDays() -> [RecentStrip.Day] {
        recentDaySource().map {
            RecentStrip.Day(id: $0.date, date: $0.date, score: $0.score, verdict: $0.verdict)
        }
    }

    /// Cold-start seed: while `sessions` is still decrypting, the strip is built
    /// from the index (per-day recoveryScore). Replaced by the session-based
    /// strip the moment they load.
    private func recentDaySource() -> [DashboardSessionPolicy.RecentDay] {
        guard sessions.isEmpty else {
            return DashboardSessionPolicy.recentDays(from: sessions, today: Date(), calendar: .current)
        }
        if let cachedDays = cachedDashboard?.recentDays {
            return cachedDays.map(Self.recentDay(fromCached:))
        }
        if let seed = seedSummary { return seed.recentDays }
        return DashboardSessionPolicy.recentDays(from: sessions, today: Date(), calendar: .current)
    }

    private static func recentDay(fromCached cached: UIStateCache.RecentDaySnapshot) -> DashboardSessionPolicy.RecentDay {
        DashboardSessionPolicy.RecentDay(
            date: cached.date,
            score: cached.score,
            verdict: cached.score.map { ScoreVerdict(score: Double($0)) }
        )
    }

    // MARK: - Footer
    //
    // There is deliberately no "View full report ▸" link under the Recent
    // strip. The hero ring already drills into the same destination, every
    // chip drills into its own detail surface, and Recent rows drill in too —
    // a fifth "everything" link adds a decision the joystick test can't
    // afford. With zero sessions the Get started checklist's "Take your first
    // reading" row is the call to action.

    func ageFromBirthday(_ birthday: Date?) -> Int? {
        guard let birthday else { return nil }
        return Calendar.current.dateComponents([.year], from: birthday, to: Date()).year
    }

    func shareRecapCard() {
        guard let score = displayedScore, let v = verdict else { return }
        // Date the card from the same overnight session the score comes from.
        let date = latestOvernightComplete?.startDate ?? Date()
        guard let image = renderRecapImage(score: score, verdict: v, date: date) else {
            toast = ToastPayload(glyph: "exclamationmark.triangle", message: String(localized: "Couldn't build recap card. Try again.", bundle: LanguageManager.appBundle))
            return
        }
        guard let presenter = topmostPresenter() else { return }
        presentShareSheet(activityItem: recapActivityItem(image: image, score: score, date: date), from: presenter)
    }

    /// Bug list #16: presenting the share sheet inline fired before
    /// `ImageRenderer.uiImage` had a fully-rendered output AND attached a
    /// nil-or-blank image (the "missing attachment" the user reported).
    /// So: render synchronously here on @MainActor (the
    /// renderer requires it) and let the caller bail loudly via toast if
    /// rendering fails, so the share sheet never opens with a stale or missing
    /// payload.
    private func renderRecapImage(score: Int, verdict v: ScoreVerdict, date: Date) -> UIImage? {
        RecapCard(variant: .recovery(score: score, verdict: v, date: date)).renderImage()
    }

    /// Pull-to-refresh re-runs the analysis
    /// pipeline against today's data and surfaces a "Re-analyzed." toast.
    ///
    /// No timeout race. Reanalysis is
    /// LOCAL CPU work (artifact detection + window selection + HRV
    /// math + archive write). No network, no HK fetch, no BLE. A
    /// 30s race-to-timeout reported "Re-analyze took too
    /// long. Try again" while the actual work continued in the
    /// background and eventually completed — so the user saw a failure
    /// toast for a job that succeeded. Tapping "Try again" then got
    /// suppressed by the `inFlightReanalyses` re-entrancy guard in
    /// `RRCollector+Reanalysis.swift:73`, so the second tap did
    /// nothing. From the user's perspective: timeout, retry, silent
    /// nothing, repeat.
    ///
    /// Instead: just await the result. If it takes 60 s on an
    /// old phone, that's the truth; the toast reports what actually
    /// happened. If the call genuinely hangs (programmer bug, not a
    /// slow phone) the user can navigate away and the spinner ends
    /// when the view leaves the screen.
    func refreshDashboard() async {
        guard let session = latestOvernightComplete, let onReanalyze = onReanalyzeSession else {
            toast = ToastPayload(glyph: "info.circle", message: String(localized: "Nothing to re-analyze yet.", bundle: LanguageManager.appBundle))
            return
        }
        // The user's chosen method (set from Morning Results), not the
        // factory default, so a refresh does not re-window the night
        // differently and move the stored score.
        let updated = await onReanalyze(session, settingsManager.settings.defaultWindowSelectionMethod)
        if updated != nil {
            toast = ToastPayload(glyph: "checkmark.circle.fill", message: String(localized: "Re-analyzed.", bundle: LanguageManager.appBundle))
        } else {
            // Reanalyzer returned nil — the session has no rrSeries on disk
            // to re-window, or a re-analysis of it is already running (the
            // re-entrancy guard returns nil for duplicate requests). The
            // message covers both instead of claiming "Re-analyzed."
            toast = ToastPayload(
                glyph: "exclamationmark.triangle",
                message: String(localized: "Couldn't re-analyze this session right now.", bundle: LanguageManager.appBundle)
            )
        }
    }

    /// Long-press hero context menu "Re-analyze" action. Same pipeline and
    /// the same honest toasts as pull-to-refresh, just initiated from the
    /// menu instead of a swipe gesture.
    func reanalyzeFromHero() async {
        await refreshDashboard()
    }

    /// Long-press hero context menu "Copy data"
    /// action. Plain-text snapshot of today's headline numbers so the
    /// user can paste into Notes / a journal / a message to their coach.
    func copyHeroDataToClipboard() {
        guard let session = latestOvernightComplete,
              let result = session.analysisResult else { return }
        let date = session.startDate.formatted(date: .abbreviated, time: .omitted)
        var lines: [String] = [String(localized: "Emuqu — \(date)", bundle: LanguageManager.appBundle)]
        if let score = displayedScore { lines.append(String(localized: "Recovery: \(score)", bundle: LanguageManager.appBundle)) }
        lines.append(String(localized: "RMSSD: \(Int(result.timeDomain.rmssd.rounded())) ms", bundle: LanguageManager.appBundle))
        lines.append(String(localized: "Mean HR: \(Int(result.timeDomain.meanHR.rounded())) bpm", bundle: LanguageManager.appBundle))
        if let alpha1 = result.nonlinear.dfaAlpha1 {
            lines.append(String(format: "DFA α1: %.2f", locale: .current, alpha1))
        }
        // Not `UIPasteboard.general.string = …`: that puts overnight HRV
        // values on the Universal Clipboard, where they sync to the user's
        // other Apple devices over iCloud and never expire. Same hardening
        // as the app's other pasteboard writes (`AssistantChatView+Sections`,
        // `VoiceConversationController+Control`, the debug-log export) for
        // the same data class.
        PasteboardWriter.copy(lines.joined(separator: "\n"))
        toast = ToastPayload(glyph: "doc.on.doc.fill", message: String(localized: "Copied.", bundle: LanguageManager.appBundle))
    }
}

/// Day-14 transition: "Subtle radial particle
/// bloom in verdict color (800ms, fading)." Twelve dots radiate from
/// center, scaling outward and fading to zero opacity. Reduce-Motion
/// short-circuits to a no-op (just returns clear). Self-contained so
/// the bloom can be reused on the Recovery Score detail's hero card.
struct Day14ParticleBloom: View {
    let active: Bool
    let tint: Color
    @State private var animProgress: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(0..<12, id: \.self) { spark($0) }
        }
        .onChange(of: active) { _, isActive in restartBurst(isActive) }
    }

    private func spark(_ index: Int) -> some View {
        let angle = Double(index) / 12 * 2 * .pi
        let radius = 110 * animProgress
        return Circle()
            .fill(tint)
            .frame(width: 6, height: 6)
            // at progress 0 all twelve sparks sit on the ring's
            // centre at 80 % opacity, i.e. a green dot between the score's
            // digits. "81" read as "8.1" in a real screenshot. Invisible
            // until the burst is actually running.
            .opacity(animProgress > 0 ? (1 - animProgress) * 0.8 : 0)
            .offset(x: cos(angle) * radius, y: sin(angle) * radius)
    }

    /// Turning off resets the progress, so the sparks' invisibility does not
    /// rest on the opacity factor at progress 1.
    private func restartBurst(_ isActive: Bool) {
        guard isActive, !reduceMotion else {
            animProgress = 0
            return
        }
        animProgress = 0
        withAnimation(.easeOut(duration: 0.8)) {
            animProgress = 1
        }
    }
}
