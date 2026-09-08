import CoreLocation
import SwiftUI

// MARK: - Today's Loop Card
//
// Dashboard widget that fuses today's morning recovery state with
// today's most recent workout into a one-glance loop verdict. Same
// content as Page 1 of the HolisticDailyReport PDF — both pull from
// the shared `DailyLoopAnalysis` model so they cannot drift.
//
// Three states:
//   • Workout + overnight present → full loop story (verdict, recovery
//     × workout summary, tomorrow line, "View full report" button).
//   • Overnight only → recovery snapshot, "no workout yet today" CTA.
//   • Neither → nudge ("Start an overnight session to enable the loop").
//
// Data is pulled from SessionArchive on appear and refreshed when the
// archive signal fires. No live recompute — DailyLoopAnalysis is a
// pure value type.

struct TodaysLoopCard: View {
    @Environment(\.dependencies) var dependencies
    @State private var todayWorkout: HRVSession?
    @State private var todayOvernight: HRVSession?
    /// In-flight archive decode. Cancelled + replaced on each `refresh()` so
    /// rapid re-appears (foreground churn) don't stack decodes.
    @State private var refreshTask: Task<Void, Never>?
    @State private var recentOvernight: [HRVSession] = []
    /// `.sheet(item:)` rather than a `(showReport: Bool, generatedPDFURL: URL?)`
    /// pair, because the pair pattern occasionally
    /// presents an empty sheet (URL hasn't propagated yet) and gets
    /// SwiftUI's presentation queue stuck. Same pattern as the
    /// MorningResultsView email path.
    @State private var presentedPDF: TodaysLoopURLWrapper?
    @State private var isGenerating = false
    @State private var generationError: String?

    @ViewBuilder
    var body: some View {
        stack
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onAppear(perform: refresh)
            .sheet(item: $presentedPDF) { PDFPreviewView(url: $0.url) }
            .alert(
                String(localized: "Couldn't generate report", bundle: LanguageManager.appBundle),
                isPresented: .constant(generationError != nil)
            ) {
                reportErrorActions
            } message: {
                Text(generationError ?? "")
            }
    }

    @ViewBuilder
    private var stack: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            heroVerdict
            if todayWorkout != nil || todayOvernight != nil {
                splitRow
                tomorrowLine
                viewReportButton
            } else {
                emptyStateCTA
            }
        }
    }

    private var reportErrorActions: some View {
        Button(String(localized: "OK", bundle: LanguageManager.appBundle)) { generationError = nil }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text(String(localized: "TODAY'S LOOP", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.textTertiary)
                .tracking(0.6)
            Spacer()
            if isGenerating {
                ProgressView().scaleEffect(0.7)
            }
        }
    }

    private var heroVerdict: some View {
        let analysis = currentAnalysis
        return heroVerdictRow(verdict: analysis.verdict, color: toneColor(analysis.verdictTone))
    }

    private func heroVerdictRow(verdict v: (label: String, blurb: String), color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(v.label)
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(color)
                Text(v.blurb)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var splitRow: some View {
        HStack(alignment: .top, spacing: 16) {
            recoveryColumn
            Divider()
            workoutColumn
        }
        .frame(maxWidth: .infinity)
    }

    private var recoveryColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "THIS MORNING", bundle: LanguageManager.appBundle))
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppTheme.textTertiary)
                .tracking(0.5)
            if let overnight = todayOvernight, let rmssd = overnight.rmssd {
                overnightSummary(overnight, rmssd: rmssd)
            } else {
                noReadingYet
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Route metric labels through
    /// LanguageManager so the app-language override is honoured
    /// even when the OS locale differs.
    /// 24h total (night + any nap) — matches the score and the
    /// Sleep detail hero. The nap breakdown lives on the detail view.
    @ViewBuilder
    private func overnightSummary(_ overnight: HRVSession, rmssd: Double) -> some View {
        Text(String(localized: "\(Int(rmssd.rounded())) ms HRV", bundle: LanguageManager.appBundle))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.textPrimary)
        if let pct = currentAnalysis.hrvPercentVsBaseline {
            let dir = pct >= 0 ? "+" : ""
            Text(String(localized: "\(dir)\(Int(pct.rounded()))% vs baseline", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(pctColor(pct))
        }
        if let sleep = overnight.sleepSnapshot {
            let h = sleep.totalSleepIncludingNapMinutes / 60
            let m = sleep.totalSleepIncludingNapMinutes % 60
            Text(String(localized: "Sleep \(h)h \(m)m · \(Int(sleep.sleepEfficiency.rounded()))%", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var noReadingYet: some View {
        Text(String(localized: "No reading yet", bundle: LanguageManager.appBundle))
            .font(.subheadline)
            .foregroundStyle(AppTheme.textTertiary)
    }

    private var workoutColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "TODAY'S WORKOUT", bundle: LanguageManager.appBundle))
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppTheme.textTertiary)
                .tracking(0.5)
            if let workout = todayWorkout, let meta = workout.workoutMetadata {
                workoutSummary(workout, meta: meta)
            } else {
                noWorkoutYet
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Power and metabolic estimates are a load, not a TRIMP.
    /// Use the preferred (power-first) load
    /// resolver so power-equipped users see the more accurate
    /// number on the daily-loop card.
    private static func loadLabel(_ source: WorkoutMetadata.TrainingLoadSource) -> String {
        switch source {
        case .power, .hr, .mets: "Load"
        case .banister, .routeHistory: "TRIMP"
        }
    }

    @ViewBuilder
    private func workoutSummary(_ workout: HRVSession, meta: WorkoutMetadata) -> some View {
        let sport = meta.sport.displayName
        Text(sport)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.textPrimary)
        if let load = meta.preferredTrainingLoad {
            let label = Self.loadLabel(load.source)
            Text(String(localized: "\(label) \(Int(load.value.rounded()))", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
        }
        if let snap = workout.trainingSnapshot {
            Text(String(localized: "TSB \(String(format: "%+.1f", locale: .current, snap.tsb))", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var noWorkoutYet: some View {
        Text(String(localized: "None yet", bundle: LanguageManager.appBundle))
            .font(.subheadline)
            .foregroundStyle(AppTheme.textTertiary)
    }

    private var tomorrowLine: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(String(localized: "→", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppTheme.sage)
            Text(currentAnalysis.tomorrowAction)
                .font(.footnote)
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var viewReportButton: some View {
        Button {
            generateReport()
        } label: {
            viewReportLabel
        }
        .buttonStyle(.plain)
        .disabled(isGenerating)
    }

    private var viewReportLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text.fill")
            Text(todayWorkout != nil
                ? String(localized: "View full report", bundle: LanguageManager.appBundle)
                : String(localized: "Generate recovery report", bundle: LanguageManager.appBundle))
            Spacer()
            Image(systemName: "chevron.right")
                .accessibilityHidden(true)
                .font(.caption.weight(.bold))
        }
        .font(.subheadline.weight(.semibold))
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(AppTheme.primary.opacity(0.12))
        .foregroundStyle(AppTheme.primary)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var emptyStateCTA: some View {
        Text(String(localized: "Start an overnight session and finish a workout today to see your loop story.", bundle: LanguageManager.appBundle))
            .font(.footnote)
            .foregroundStyle(AppTheme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private var currentAnalysis: DailyLoopAnalysis {
        let settings = dependencies.app.settingsManager.settings
        return DailyLoopAnalysis(
            workoutSession: todayWorkout,
            overnightSession: todayOvernight,
            recentOvernightSessions: recentOvernight,
            userMaxHR: settings.effectiveMaxHR
        )
    }

    private func toneColor(_ tone: DailyLoopAnalysis.VerdictTone) -> Color {
        switch tone {
        case .positive: AppTheme.sage
        case .neutral: Color.orange
        case .caution: Color.red
        }
    }

    private func pctColor(_ pct: Double) -> Color {
        if pct >= 5 { return AppTheme.sage }
        if pct <= -5 { return Color.red }
        return AppTheme.textSecondary
    }

    // MARK: - Data load

    /// The decode below reads + JSON-decodes + decrypts up to ~30 nights of
    /// overnight sessions. Run synchronously inside onAppear it blocks the
    /// main thread on every dashboard appear (i.e. every app
    /// foreground) — a real "the app freezes when I reopen it" stall for
    /// anyone with a month of data. So run it off the main thread and publish
    /// the result back. SessionArchive's reads are lock-protected, so
    /// calling them from a detached task is safe.
    ///
    /// 60-day window to match the recovery score's baseline
    /// (BaselineTracker uses the last ~60 sessions), so the Loop's HRV
    /// baseline and the score's baseline are computed over the same span.
    @MainActor
    private func refresh() {
        refreshTask?.cancel()
        var archive: SessionArchive { dependencies.storage.sessionArchive }
        let dayCutoff = Calendar.current.date(byAdding: .hour, value: -36, to: Date()) ?? Date.distantPast
        let baselineCutoff = Calendar.current.date(byAdding: .day, value: -60, to: Date()) ?? Date.distantPast
        refreshTask = Task {
            let (overnight, workout) = await Task.detached {
                Self.loadLoopSessions(archive: archive, dayCutoff: dayCutoff, baselineCutoff: baselineCutoff)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run { publishLoopSessions(overnight, workout: workout, dayCutoff: dayCutoff) }
        }
    }

    @MainActor
    private func publishLoopSessions(_ overnight: [HRVSession], workout: HRVSession?, dayCutoff: Date) {
        guard !Task.isCancelled else { return }
        recentOvernight = overnight
        todayOvernight = overnight.first(where: { $0.startDate >= dayCutoff })
        todayWorkout = workout
    }

    /// Exclude untrustworthy-HRV sessions from the loop card's
    /// HRV-vs-baseline (see `isReliableForHRVAggregates`).
    nonisolated private static func loadLoopSessions(archive: SessionArchive, dayCutoff: Date, baselineCutoff: Date) -> ([HRVSession], HRVSession?) {
        let overnight = archive.entries
            .filter { $0.sessionType == .overnight && $0.date >= baselineCutoff }
            .sorted { $0.date > $1.date }
            .compactMap { try? archive.retrieveLightweight($0.sessionId) }
            .filter { $0.isReliableForHRVAggregates }
        let workout = archive.entries
            .filter { $0.sessionType == .workout && $0.date >= dayCutoff }
            .sorted { $0.date > $1.date }
            .first
            .flatMap { try? archive.retrieveLightweight($0.sessionId) }
        return (overnight, workout)
    }

    // MARK: - Report generation

    private func generateReport() {
        guard !isGenerating else { return }
        isGenerating = true
        generationError = nil
        guard let workout = todayWorkout else {
            // No workout yet today — surface a message rather than generating a
            // workout-less Holistic PDF (which would be mostly empty pages).
            generationError = String(localized: "No workout recorded today yet. The full report unlocks once you finish a session.", bundle: LanguageManager.appBundle)
            isGenerating = false
            return
        }
        let inputs = loopReportInputs(workout: workout)
        Task.detached(priority: .userInitiated) { await renderAndPublishLoopReport(inputs) }
    }

    private func renderAndPublishLoopReport(_ inputs: LoopReportInputs) async {
        do {
            try await Self.renderLoopReport(inputs)
            await MainActor.run { finishLoopReport(url: inputs.pdfURL, error: nil) }
        } catch {
            await MainActor.run { finishLoopReport(url: nil, error: error.localizedDescription) }
        }
    }

    /// Single state mutation — `.sheet(item:)` fires atomically when the URL
    /// is set.
    @MainActor
    private func finishLoopReport(url: URL?, error: String?) {
        if let url { presentedPDF = TodaysLoopURLWrapper(url: url) }
        generationError = error
        isGenerating = false
    }

    /// Everything the detached render needs, captured on the main actor first.
    private struct LoopReportInputs {
        let workout: HRVSession
        let overnight: HRVSession?
        let recent: [HRVSession]
        let polyline: Data?
        let startDate: Date
        let duration: TimeInterval?
        let pdfURL: URL
        let maxHR: Int
        let restingHR: Int
        let lthr: Int
        let units: UnitsPreference
    }

    private func loopReportInputs(workout: HRVSession) -> LoopReportInputs {
        let settings = dependencies.app.settingsManager.settings
        let name = "emuqu-todays-loop-\(Int(Date().timeIntervalSince1970)).pdf"
        return LoopReportInputs(
            workout: workout,
            overnight: todayOvernight,
            recent: recentOvernight,
            polyline: workout.workoutMetadata?.gpsPolyline,
            startDate: workout.startDate,
            duration: workout.duration,
            pdfURL: FileManager.default.temporaryDirectory.appendingPathComponent(name),
            maxHR: settings.effectiveMaxHR,
            restingHR: settings.effectiveRestingHR,
            lthr: settings.effectiveLTHR,
            units: UnitsPreferenceStore.current.resolved
        )
    }

    /// Refresh + capture training load inside the task so the loop
    /// report reflects archive writes since the last cache refresh (plain
    /// `live()` could freeze a stale TSB/ACWR). See
    /// `TrainingLoadRegistry.liveRefreshed()`.
    private static func renderLoopReport(_ inputs: LoopReportInputs) async throws {
        let liveLoadSnapshot = await TrainingLoadRegistry.liveRefreshed()
        let track: [CLLocation] = inputs.polyline.map {
            GPXExporter.decode(polyline: $0, startDate: inputs.startDate, duration: inputs.duration)
        } ?? []
        let report = HolisticDailyReport(
            workoutSession: inputs.workout,
            workoutTrack: track,
            overnightSession: inputs.overnight,
            recentOvernightSessions: inputs.recent,
            userMaxHR: inputs.maxHR,
            userRestingHR: inputs.restingHR,
            userLTHR: inputs.lthr,
            units: inputs.units,
            liveLoadSnapshot: liveLoadSnapshot
        )
        try await report.generate(to: inputs.pdfURL)
    }
}

private struct TodaysLoopURLWrapper: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
