import SwiftUI

/// Glue between `TrainingMetricsCache.dailySeries` and `LoadTrajectoryView`.
/// LoadTrajectoryView is intentionally state-less — it takes a list of
/// `DailySample` and renders. This loader pulls the last 90 days from the
/// shared cache, maps them onto the view's input shape, and wires up the
/// three Mode toggle actions to UserSettings.
///
/// Entry points: tapped via the Load chip on Dashboard
/// or via "Trajectory" link in More / Fitness.
struct LoadTrajectoryLoader: View {
    @Environment(\.dependencies) var dependencies
    /// Materials go opaque when the user asks for reduced transparency —
    /// iOS does not substitute for you. See `AdaptiveMaterial`.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @Environment(RRCollector.self) private var collector
    private var cache: TrainingMetricsCache { dependencies.analysis.trainingMetricsCache }
    private var settingsManager: SettingsManager { dependencies.app.settingsManager }
    @State private var contextSheetWorkouts: [LoadTrajectoryView.RecentWorkout] = []
    @State private var contextSheetDate: Date?
    /// Not rebuilt inline inside `body`: that would mean up to 20
    /// synchronous full-session `retrieve` calls on every recompute
    /// (each: archiveLock + SHA256 + decrypt + full JSON decode including
    /// rrSeries). Populated once via `.task` using `retrieveLightweight` (no
    /// rrSeries, no hash check) so the view paints immediately and the
    /// archive work happens off the main thread.
    @State private var recentWorkouts: [LoadTrajectoryView.RecentWorkout] = []
    @State private var archiveVersionSnapshot: Int = -1
    @Environment(ArchiveSignal.self) var archiveSignal

    var body: some View {
        trajectoryOrPaused
            .task { await loadTrajectory() }
            .onChange(of: archiveSignal.version) { _, _ in
                Task { await loadRecentWorkouts() }
            }
            .sheet(item: contextSheetBinding) { ident in
                whatWasHappeningSheet(date: ident.date, workouts: contextSheetWorkouts)
                    .presentationDetents([.medium, .large])
            }
    }

    @ViewBuilder
    private var trajectoryOrPaused: some View {
        if TrainingLoadVisibility.isPaused(settingsManager.settings) {
            ScrollView { TrainingLoadPausedCard().padding() }
                .background(AppTheme.background)
        } else {
            trajectoryView(samples: makeSamples(), recents: recentWorkouts)
        }
    }

    private func trajectoryView(samples: [LoadTrajectoryView.DailySample], recents: [LoadTrajectoryView.RecentWorkout]) -> some View {
        let weeklyTrimp = samples.suffix(7).map(\.trimp).reduce(0, +)
        let lastWeekTrimp = samples.dropLast(7).suffix(7).map(\.trimp).reduce(0, +)
        return LoadTrajectoryView(
            samples: samples,
            weeklyTrimp: weeklyTrimp,
            weeklyTrimpDelta: weeklyTrimp - lastWeekTrimp,
            rampRate: computeRampRate(samples),
            comebackActive: settingsManager.settings.isComebackModeActive,
            peakingDetected: settingsManager.settings.peakingDetectionEnabled && peakingHeuristic(samples),
            overreachActive: settingsManager.settings.isIntentionalOverreachInEffect,
            // Same Foster threshold as the Training detail and Help.
            monotonyFlagged: computeMonotony(samples) > RecoveryScoreConstants.Training.monotonyThreshold && weeklyTrimp > 200,
            recentWorkouts: recents,
            onComebackTap: toggleComeback,
            onPeakingTap: togglePeakingDetection,
            onOverreachTap: toggleOverreach,
            onWorkoutTap: nil,
            onChartLongPress: { openContextSheet(for: $0, workouts: recents) },
            peakingDetectionEnabled: settingsManager.settings.peakingDetectionEnabled
        )
    }

    /// Long-pressing a chart day opens "what was happening" for that day, with
    /// whatever workouts fall inside it.
    private func openContextSheet(for date: Date, workouts: [LoadTrajectoryView.RecentWorkout]) {
        let day = Calendar.current.startOfDay(for: date)
        contextSheetWorkouts = workouts.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
        contextSheetDate = day
    }

    private func loadTrajectory() async {
        await cache.refresh()
        dependencies.services.validationTelemetry.recordTrajectoryVisit()
        await loadRecentWorkouts()
    }

    private var contextSheetBinding: Binding<ContextSheetIdentity?> {
        Binding(
            get: { contextSheetDate.map { ContextSheetIdentity(date: $0) } },
            set: { ident in
                contextSheetDate = ident?.date
                if ident == nil { contextSheetWorkouts = [] }
            }
        )
    }

    private struct ContextSheetIdentity: Identifiable {
        let date: Date
        var id: Date { date }
    }

    @ViewBuilder
    private func whatWasHappeningSheet(date: Date, workouts: [LoadTrajectoryView.RecentWorkout]) -> some View {
        NavigationStack {
            ScrollView { whatWasHappeningBody(date: date, workouts: workouts) }
                .navigationTitle(Text(String(localized: "What was happening", bundle: LanguageManager.appBundle)))
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func whatWasHappeningBody(date: Date, workouts: [LoadTrajectoryView.RecentWorkout]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: date.formatted(date: .complete, time: .omitted))
                .scaledFont(size: 22, weight: .semibold)
            whatWasHappeningRows(workouts)
        }
        .padding(20)
    }

    @ViewBuilder
    private func whatWasHappeningRows(_ workouts: [LoadTrajectoryView.RecentWorkout]) -> some View {
        if workouts.isEmpty {
            Text(String(localized: "No workouts logged that day.", bundle: LanguageManager.appBundle))
                .scaledFont(size: 14)
                .foregroundStyle(AppTheme.textSecondary)
        } else {
            ForEach(workouts) { whatWasHappeningRow($0) }
        }
    }

    private func whatWasHappeningRow(_ w: LoadTrajectoryView.RecentWorkout) -> some View {
        HStack(spacing: 12) {
            Image(systemName: w.sportSymbolName)
            Text(verbatim: w.sportLabel).scaledFont(size: 15, weight: .semibold)
            Spacer()
            Text(String(localized: "\(w.durationMinutes) min", bundle: LanguageManager.appBundle))
                .scaledFont(size: 13, monospacedDigit: true)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(AdaptiveMaterial.thin(reduceTransparency))
        )
    }

    /// Recent-workouts list. Pulls workout
    /// sessions out of the archive and maps to display rows.
    ///
    /// Runs off the main thread via `Task.detached`
    /// and uses `retrieveLightweightOrLog` (skips rrSeries + hash check)
    /// instead of the full `retrieve`. The result is paired with its entry for
    /// the MainActor mapping, which reads `preferredTrainingLoad`
    /// (MainActor-isolated because of the UserSettings backing).
    @MainActor
    private func loadRecentWorkouts() async {
        let entrySnapshot = collector.archive.entries
            .filter { $0.sessionType == .workout }
            .sorted { $0.date > $1.date }
            .prefix(20)
            .map(\.self)
        let archive = collector.archive
        let decoded: [(SessionArchiveEntry, HRVSession)] = await Task.detached(priority: .userInitiated) {
            entrySnapshot.compactMap { Self.pairWithSession($0, archive: archive) }
        }.value
        recentWorkouts = decoded.compactMap { Self.recentWorkoutRow(entry: $0, session: $1) }
    }

    /// Nil when the session can't be decoded — the row is simply skipped.
    nonisolated private static func pairWithSession(
        _ entry: SessionArchiveEntry,
        archive: SessionArchive
    ) -> (SessionArchiveEntry, HRVSession)? {
        guard let session = archive.retrieveLightweightOrLog(entry.sessionId, caller: "LoadTrajectoryLoader")
        else { return nil }
        return (entry, session)
    }

    /// `preferredTrainingLoad` resolves powerTSS → hrTSS →
    /// luciaTRIMP → extrapolatedTRIMP so power-equipped users see the right
    /// load on every historical row without any data migration.
    ///
    /// Carry the source too so the row can label the
    /// value correctly (LOAD vs TRIMP) instead of hard-coding "TRIMP" on what
    /// is usually a power/HR TSS.
    @MainActor
    private static func recentWorkoutRow(entry: SessionArchiveEntry, session: HRVSession) -> LoadTrajectoryView.RecentWorkout? {
        guard let meta = session.workoutMetadata else { return nil }
        let durationSeconds = (session.endDate ?? session.startDate).timeIntervalSince(session.startDate)
        return LoadTrajectoryView.RecentWorkout(
            id: entry.sessionId,
            sportSymbolName: meta.sport.icon,
            sportLabel: meta.sport.localizedName,
            date: session.startDate,
            durationMinutes: max(0, Int(durationSeconds.rounded() / 60)),
            trimp: meta.preferredTrainingLoad?.value,
            loadSource: meta.preferredTrainingLoad?.source
        )
    }

    // MARK: - Sample assembly

    /// Today's point reads the SAME live value the DASHBOARD
    /// shows (`TrainingMetricsCache.current`), so the Dashboard and this
    /// Load & Trajectory tab can NEVER display different CTL/ATL/TSB.
    /// (The continuous-time projection decays today's value intra-day and
    /// so drifts from the dashboard's discrete daily value — the "dashboard
    /// doesn't match the load tab" report. `continuousProjection` stays
    /// available but is not wired to the display; consistency wins.)
    private func makeSamples() -> [LoadTrajectoryView.DailySample] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        let today = Calendar.current.startOfDay(for: Date())
        let liveToday = cache.current
        return cache.samplesSince(cutoff).reversed().map { day in
            // Only override the most-recent (today) bucket with the live value;
            // historical days stay on the standard Banister daily EWMA.
            let isToday = Calendar.current.isDate(day.date, inSameDayAs: today)
            guard isToday, let m = liveToday else { return Self.sample(day) }
            return Self.sample(day, ctl: m.ctl, atl: m.atl, tsb: m.tsb)
        }
    }

    private static func sample(
        _ day: TrainingMetricsCache.DaySample,
        ctl: Double? = nil,
        atl: Double? = nil,
        tsb: Double? = nil
    ) -> LoadTrajectoryView.DailySample {
        LoadTrajectoryView.DailySample(
            id: day.date,
            date: day.date,
            ctl: ctl ?? day.ctl,
            atl: atl ?? day.atl,
            tsb: tsb ?? day.tsb,
            trimp: day.trimp
        )
    }

    // MARK: - Heuristics

    /// TrainingPeaks-standard trailing window for the CTL trend. TP offers
    /// 7/28/90-day ramp views; the 7-day is the noisy one, so we regress over
    /// ~2 weeks — long enough that a negative slope means a *sustained*
    /// decline (Friel's definition of losing fitness), short enough to stay
    /// responsive.
    private static let rampTrendWindowDays = 14

    /// CTL trend, expressed as CTL points per week.
    ///
    /// The value is an ordinary-least-squares slope of the DISCRETE daily CTL
    /// over the trailing `rampTrendWindowDays`, ×7 to read as "per week" — the
    /// same units the RampBand thresholds use (TP: ~5–8/wk building, >8 rapid),
    /// so those thresholds don't need re-tuning. A 2-point
    /// `CTL_today − CTL_7-days-ago` delta oscillates day-to-day for
    /// intermittent training (the lone "7-days-ago" anchor lands on a workout
    /// or a rest day as the calendar advances) and flips the verdict. A
    /// regression over the window is the robust trend and only reads negative
    /// once fitness has actually fallen for a sustained stretch.
    private func computeRampRate(_ samples: [LoadTrajectoryView.DailySample]) -> Double {
        guard samples.count >= 8 else { return 0 }
        // samples are oldest→newest; regress the most-recent window (at least
        // 8 points, given the guard above).
        return Self.ctlSlopePerWeek(Array(samples.suffix(Self.rampTrendWindowDays)))
    }

    private static func ctlSlopePerWeek(_ window: [LoadTrajectoryView.DailySample]) -> Double {
        let n = Double(window.count)
        let xMean = (n - 1) / 2 // mean of 0..<count
        let yMean = window.reduce(0.0) { $0 + $1.ctl } / n
        var num = 0.0, den = 0.0
        for (i, s) in window.enumerated() {
            let dx = Double(i) - xMean
            num += dx * (s.ctl - yMean)
            den += dx * dx
        }
        guard den > 0 else { return 0 }
        return (num / den) * 7.0 // slope-per-day → CTL points per week
    }

    private func computeMonotony(_ samples: [LoadTrajectoryView.DailySample]) -> Double {
        let last7 = samples.suffix(7).map(\.trimp)
        guard last7.count >= 4 else { return 0 }
        let mean = last7.reduce(0, +) / Double(last7.count)
        guard mean > 0 else { return 0 }
        let variance = last7.map { pow($0 - mean, 2) }.reduce(0, +) / Double(last7.count)
        let sd = sqrt(variance)
        guard sd > 0 else { return 0 }
        return mean / sd  // Foster's monotony
    }

    private func peakingHeuristic(_ samples: [LoadTrajectoryView.DailySample]) -> Bool {
        // ATL < CTL by >10% sustained for 4+ days.
        let last4 = samples.suffix(4)
        guard last4.count == 4 else { return false }
        return last4.allSatisfy { $0.ctl > 0 && ($0.ctl - $0.atl) / $0.ctl > 0.10 }
    }

    // MARK: - Mode toggles

    private func toggleComeback() {
        if settingsManager.settings.isComebackModeActive {
            settingsManager.settings.comebackModeStartDate = nil
        } else {
            settingsManager.settings.comebackModeStartDate = Date()
        }
    }

    private func togglePeakingDetection() {
        settingsManager.settings.peakingDetectionEnabled.toggle()
    }

    /// Follows what the screen shows: a block whose end date has passed reads
    /// as off, so a tap switches it on again, open-ended. Either way the old
    /// end date is cleared.
    private func toggleOverreach() {
        let turnOn = !settingsManager.settings.isIntentionalOverreachInEffect
        settingsManager.settings.intentionalOverreachActive = turnOn
        settingsManager.settings.intentionalOverreachEndDate = nil
    }
}
