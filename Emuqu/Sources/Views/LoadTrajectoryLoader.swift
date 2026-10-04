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
    /// The long-pressed day's workouts; nil while they load.
    @State private var contextSheetWorkouts: [LoadTrajectoryView.RecentWorkout]?
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
            rampRate: TrajectoryVerdict.ctlSlopePerWeek(samples.map(\.ctl)),
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
            onChartLongPress: { openContextSheet(for: $0) },
            peakingDetectionEnabled: settingsManager.settings.peakingDetectionEnabled
        )
    }

    /// Long-pressing a chart day opens "what was happening" for that day. Its
    /// workouts are read from the archive, not the 20-row recent list, because
    /// the chart spans 90 days.
    private func openContextSheet(for date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        contextSheetWorkouts = nil
        contextSheetDate = day
        Task {
            let rows = await workoutRows(on: day)
            if contextSheetDate == day { contextSheetWorkouts = rows }
        }
    }

    @MainActor
    private func workoutRows(on day: Date) async -> [LoadTrajectoryView.RecentWorkout] {
        let entries = collector.archive.entries
            .filter { $0.sessionType == .workout && Calendar.current.isDate($0.date, inSameDayAs: day) }
            .sorted { $0.date < $1.date }
        return await workoutRows(for: entries)
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
                if ident == nil { contextSheetWorkouts = nil }
            }
        )
    }

    private struct ContextSheetIdentity: Identifiable {
        let date: Date
        var id: Date { date }
    }

    @ViewBuilder
    private func whatWasHappeningSheet(date: Date, workouts: [LoadTrajectoryView.RecentWorkout]?) -> some View {
        NavigationStack {
            ScrollView { whatWasHappeningBody(date: date, workouts: workouts) }
                .navigationTitle(Text(String(localized: "What was happening", bundle: LanguageManager.appBundle)))
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func whatWasHappeningBody(date: Date, workouts: [LoadTrajectoryView.RecentWorkout]?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: date.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(LanguageManager.appLocale)))
                .scaledFont(size: 22, weight: .semibold)
            whatWasHappeningRows(workouts)
        }
        .padding(20)
    }

    @ViewBuilder
    private func whatWasHappeningRows(_ workouts: [LoadTrajectoryView.RecentWorkout]?) -> some View {
        if let workouts, !workouts.isEmpty {
            ForEach(workouts) { whatWasHappeningRow($0) }
        } else if workouts == nil {
            ProgressView()
        } else {
            Text(String(localized: "No workouts logged that day.", bundle: LanguageManager.appBundle))
                .scaledFont(size: 14)
                .foregroundStyle(AppTheme.textSecondary)
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
        recentWorkouts = await workoutRows(for: entrySnapshot)
    }

    /// Lightweight decode off the main thread, then the MainActor row mapping.
    @MainActor
    private func workoutRows(for entries: [SessionArchiveEntry]) async -> [LoadTrajectoryView.RecentWorkout] {
        let archive = collector.archive
        let decoded: [(SessionArchiveEntry, HRVSession)] = await Task.detached(priority: .userInitiated) {
            entries.compactMap { Self.pairWithSession($0, archive: archive) }
        }.value
        return decoded.compactMap { Self.recentWorkoutRow(entry: $0, session: $1) }
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

    /// `preferredTrainingLoad` picks the session's load by the precedence in
    /// `WorkoutMetadata.preferredTrainingLoad` (power TSS; the route estimate
    /// when it replaces HR load; HR TSS; METs load; TRIMP; then the route
    /// estimate), so power-equipped users see the right
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
    /// Every day, today included, is a discrete daily value.
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

    /// Foster's monotony over the last seven days, from the same calculation
    /// the Training detail uses (seven calendar days, rest days as zero,
    /// identical days capped rather than read as zero).
    private func computeMonotony(_ samples: [LoadTrajectoryView.DailySample]) -> Double {
        let calendar = Calendar.current
        let daily = Dictionary(
            samples.suffix(7).map { (calendar.startOfDay(for: $0.date), $0.trimp) },
            uniquingKeysWith: +
        )
        return RecoveryScoreCalculator.fosterMonotonyStrain(dailyTrimp: daily)?.monotony ?? 0
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
