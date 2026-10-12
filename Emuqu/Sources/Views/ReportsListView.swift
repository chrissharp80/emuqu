import CoreLocation
import SwiftUI

// MARK: - Reports List View
//
// "All Reports" surface. Lists every shareable report the app can
// produce, one row per source session:
//
//   • Recovery / HRV report — every overnight HRV session (the
//     morning-after analysis). Tap → PDFReportGenerator runs and
//     produces the recovery PDF.
//   • Workout report — every workout session WITHOUT a reliable
//     overnight in the 36 h before it. Tap → WorkoutPDFReport.generate produces the
//     workout-only PDF.
//   • Daily / holistic report — every workout session WITH one (the
//     night before the workout). Tap → HolisticDailyReport combines the
//     workout + the overnight into one PDF.
//
// Days that have both a workout and an overnight produce TWO rows:
// the standalone HRV report (mornings stand on their own — users
// share a recovery snapshot independent of any workout) AND the
// holistic combined report (which folds the workout in for the
// "what did training do to my HRV today" view). They're different
// stories told from different angles; both are legitimate.
//
// Not workout-only. A user reported "no HRV reports
// anywhere," correctly: deferring
// recovery-only PDFs to Dashboard's Export / Email buttons left
// those entry points buried and undiscoverable for everyday
// use. This view hosts every report the app can make.
//
// Section headers ("Today" / "Last 7 days" / "Earlier") give the
// chronological framing without losing per-session granularity.

struct ReportsListView: View {
    @Environment(\.dependencies) var dependencies
    @Environment(RRCollector.self) private var collector
    @Environment(ArchiveSignal.self) private var archiveSignal
    @State private var rows: [ReportRow] = []
    @State private var loading = true
    /// In-flight decode; cancelled + replaced on re-appear.
    @State private var loadTask: Task<Void, Never>?
    @State private var presentedPDF: URLWrapper?
    /// The generated PDF on screen; deleted from tmp when its sheet closes.
    @State private var shownPDF: URL?
    @State private var isGenerating = false
    @State private var generationError: String?
    @State private var generatingRowID: UUID?

    var body: some View {
        Group { content }
            .navigationTitle(String(localized: "Reports", bundle: LanguageManager.appBundle))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: load)
            .onChange(of: archiveSignal.version) { load() }
            .sheet(item: $presentedPDF, onDismiss: removeShownPDF) { wrapper in
                PDFPreviewView(url: wrapper.url)
            }
            .alert(String(localized: "Couldn't generate report", bundle: LanguageManager.appBundle), isPresented: errorAlertShown) {
                Button(String(localized: "OK", bundle: LanguageManager.appBundle)) { generationError = nil }
            } message: {
                Text(generationError ?? "")
            }
    }

    /// Any dismissal clears the error, not only the OK button.
    private var errorAlertShown: Binding<Bool> {
        Binding(get: { generationError != nil }, set: { if !$0 { generationError = nil } })
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            emptyState
        } else {
            reportsList
        }
    }

    private var reportsList: some View {
        List {
            ForEach(sectionedRows, id: \.section) { group in
                reportSection(group)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func reportSection(_ group: SectionedGroup) -> some View {
        Section(group.section) {
            ForEach(group.rows) { row in
                rowView(row)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(AppTheme.textTertiary)
            Text(String(localized: "No reports yet", bundle: LanguageManager.appBundle))
                .font(.headline)
                .foregroundStyle(AppTheme.textPrimary)
            Text(String(localized: "Finish a workout or an overnight recording to generate your first report. Reports stay here so you can revisit them later.", bundle: LanguageManager.appBundle))
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Row

    private func rowView(_ row: ReportRow) -> some View {
        Button {
            generate(row)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: row.iconName)
                    .font(.title3)
                    .foregroundStyle(row.iconTint)
                    .frame(width: 30)
                rowCaption(row)
                Spacer()
                rowAccessory(row)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isGenerating)
    }

    private func rowCaption(_ row: ReportRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(row.subtitle)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func rowAccessory(_ row: ReportRow) -> some View {
        if generatingRowID == row.id {
            ProgressView().scaleEffect(0.7)
        } else {
            Image(systemName: "chevron.forward")
                .accessibilityHidden(true)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    // MARK: - Sectioning

    private struct SectionedGroup {
        let section: String
        let rows: [ReportRow]
    }

    private var sectionedRows: [SectionedGroup] {
        let now = Date()
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        let weekAgo = cal.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart

        var today: [ReportRow] = []
        var lastWeek: [ReportRow] = []
        var earlier: [ReportRow] = []
        for r in rows {
            if r.date >= todayStart { today.append(r) } else if r.date >= weekAgo { lastWeek.append(r) } else { earlier.append(r) }
        }
        var groups: [SectionedGroup] = []
        if !today.isEmpty { groups.append(.init(section: String(localized: "Today", bundle: LanguageManager.appBundle), rows: today)) }
        if !lastWeek.isEmpty { groups.append(.init(section: String(localized: "Last 7 days", bundle: LanguageManager.appBundle), rows: lastWeek)) }
        if !earlier.isEmpty { groups.append(.init(section: String(localized: "Earlier", bundle: LanguageManager.appBundle), rows: earlier)) }
        return groups
    }

    // MARK: - Data load

    /// Decodes up to 90 days of workout + overnight sessions (file read +
    /// JSON decode + decrypt). Ran synchronously on the main
    /// thread in onAppear — froze the UI when opening Reports for anyone
    /// with real history. Off-main now; SessionArchive reads are lock-safe.
    /// Runs on appear and on every archive change while the list is up; a
    /// newer load cancels the older one's decode too, which stops between
    /// sessions.
    private func load() {
        loadTask?.cancel()
        loadTask = Task {
            let build = Task.detached { Self.buildRows() }
            let built = await withTaskCancellationHandler { await build.value } onCancel: { build.cancel() }
            guard !Task.isCancelled else { return }
            await MainActor.run { publishRows(built) }
        }
    }

    @MainActor
    private func publishRows(_ built: [ReportRow]) {
        guard !Task.isCancelled else { return }
        rows = built
        loading = false
    }

    nonisolated private static func buildRows() -> [ReportRow] {
        var archive: SessionArchive { AppDependencies.current.storage.sessionArchive }
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date.distantPast
        let workoutEntries = archive.entries
            .filter { $0.sessionType == .workout && $0.date >= cutoff }
            .sorted { $0.date > $1.date }
        let overnightEntries = archive.entries
            .filter { $0.sessionType == .overnight && $0.date >= cutoff }
            .sorted { $0.date > $1.date }
        let overnights = lightweightSessions(overnightEntries, archive: archive)
        let nights = overnights.filter(\.isReliableForHRVAggregates)
        let rows = workoutRows(workoutEntries, archive: archive, nights: nights)
            + recoveryRows(overnights)
        return rows.sorted { $0.date > $1.date }
    }

    /// The overnight sessions, decoded once for both the recovery rows and
    /// the workout pairing. Stops early when the load is superseded.
    nonisolated private static func lightweightSessions(_ entries: [SessionArchiveEntry], archive: SessionArchive) -> [HRVSession] {
        entries.compactMap { entry -> HRVSession? in
            guard !Task.isCancelled else { return nil }
            return try? archive.retrieveLightweight(entry.sessionId)
        }
    }

    /// The night before a workout: the latest reliable overnight that started
    /// within the 36 h before it, the rule the Daily menu item
    /// (`mostRecentDailyPair`) uses, so a 23:00 bedtime pairs with the next
    /// day's training and a workout is never paired with the night after it.
    nonisolated private static func nightBefore(_ workout: HRVSession, in nights: [HRVSession]) -> HRVSession? {
        let earliest = workout.startDate.addingTimeInterval(-36 * 3600)
        return nights
            .filter { $0.startDate >= earliest && $0.startDate < workout.startDate }
            .max { $0.startDate < $1.startDate }
    }

    /// One row per workout session. Night before available → holistic
    /// kind; absent → workout-only.
    nonisolated private static func workoutRows(_ entries: [SessionArchiveEntry], archive: SessionArchive, nights: [HRVSession]) -> [ReportRow] {
        entries.compactMap { entry -> ReportRow? in
            guard !Task.isCancelled, let session = try? archive.retrieveLightweight(entry.sessionId) else { return nil }
            let overnight = nightBefore(session, in: nights)
            return ReportRow(
                id: session.id,
                date: session.startDate,
                kind: overnight != nil ? .holistic : .workoutOnly,
                workoutSession: session,
                overnightSession: overnight
            )
        }
    }

    /// Recovery / HRV rows — one per overnight HRV session. Always
    /// emitted, even when a workout follows it (in which case the workout
    /// row above is .holistic — combined view — and this row is the standalone
    /// HRV view; they're different stories from different angles). Source
    /// session is the overnight; workoutSession is required by the ReportRow
    /// shape so we use the same overnight session as a placeholder — generation
    /// code branches on `.recovery` and never reads workoutSession in that path.
    nonisolated private static func recoveryRows(_ overnights: [HRVSession]) -> [ReportRow] {
        overnights.map { session in
            ReportRow(
                id: session.id,
                date: session.startDate,
                kind: .recovery,
                workoutSession: session, // unused for .recovery
                overnightSession: session
            )
        }
    }

    // MARK: - Generation

    private func generate(_ row: ReportRow) {
        guard !isGenerating else { return }
        isGenerating = true
        generatingRowID = row.id
        generationError = nil
        let inputs = generationInputs(for: row)
        Task.detached(priority: .userInitiated) { await renderAndPublish(inputs) }
    }

    /// A render that fails may have left a partial PDF behind; it goes.
    private func renderAndPublish(_ inputs: GenerationInputs) async {
        do {
            try await Self.renderReport(inputs)
            await MainActor.run { finishGeneration(url: inputs.pdfURL, error: nil) }
        } catch {
            Self.removeTemporaryPDF(inputs.pdfURL)
            await MainActor.run { finishGeneration(url: nil, error: error.localizedDescription) }
        }
    }

    @MainActor
    private func finishGeneration(url: URL?, error: String?) {
        if let url {
            presentedPDF = URLWrapper(url: url)
            shownPDF = url
        }
        generationError = error
        isGenerating = false
        generatingRowID = nil
    }

    /// The PDF holds health data and each tap writes a new one, so it is
    /// deleted once its preview (and any share from it) is closed.
    private func removeShownPDF() {
        guard let url = shownPDF else { return }
        shownPDF = nil
        Self.removeTemporaryPDF(url)
    }

    nonisolated private static func removeTemporaryPDF(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        attempt("ReportsListView.removeTemporaryPDF") { try FileManager.default.removeItem(at: url) }
    }

    /// Everything the detached render needs, captured on the main actor before
    /// it starts so the task never reaches back into view state.
    private struct GenerationInputs {
        let kind: ReportRow.Kind
        var workout: HRVSession
        var overnight: HRVSession?
        /// Filled by `withFullSessions`, off the main actor.
        var recentOvernight: [HRVSession] = []
        let baselineStats: BaselineTracker.RecoveryBaselineStats?
        let polyline: Data?
        let startDate: Date
        let duration: TimeInterval?
        let pdfURL: URL
        let units: UnitsPreference
        let maxHR: Int
        let restingHR: Int
        let lthr: Int
        var temperatureUnit: TemperatureUnit = .regionDefault
    }

    private func generationInputs(for row: ReportRow) -> GenerationInputs {
        let settings = dependencies.app.settingsManager.settings
        let workout = row.workoutSession
        let name = "emuqu-report-\(row.id.uuidString.prefix(8))-\(Int(Date().timeIntervalSince1970)).pdf"
        return GenerationInputs(
            kind: row.kind,
            workout: workout,
            overnight: row.overnightSession,
            baselineStats: baselineStats(for: row.overnightSession, settings: settings),
            polyline: workout.workoutMetadata?.gpsPolyline,
            startDate: workout.startDate,
            duration: workout.duration,
            pdfURL: FileManager.default.temporaryDirectory.appendingPathComponent(name),
            units: UnitsPreferenceStore.current.resolved,
            maxHR: settings.effectiveMaxHR,
            restingHR: settings.effectiveRestingHR,
            lthr: settings.effectiveLTHR,
            temperatureUnit: settings.temperatureUnit
        )
    }

    /// The baseline as it stood for the reported night: the nights before
    /// it (`recoveryBaselineStats(excludingNightOf:)`), not every stored
    /// night, later ones included. With no night, the current baseline.
    private func baselineStats(for night: HRVSession?, settings: UserSettings) -> BaselineTracker.RecoveryBaselineStats? {
        let tracker = collector.baselineTracker
        guard let night else { return tracker.recoveryBaselineStats }
        return tracker.recoveryBaselineStats(excludingNightOf: night, sleepSchedule: settings.sleepSchedule)
    }

    /// Refresh + capture training load inside the task so the
    /// report reflects archive writes since the last cache refresh (plain
    /// `live()` could freeze a stale TSB/ACWR). See
    /// `TrainingLoadRegistry.liveRefreshed()`. The PDF uses that live load
    /// only for a session from today; an older one shows its frozen load.
    /// Nonisolated, with the render steps below, so the polyline decode, the
    /// drawing and the file move run off the main actor.
    nonisolated private static func renderReport(_ lightweightInputs: GenerationInputs) async throws {
        let inputs = await Task.detached { withFullSessions(lightweightInputs) }.value
        let liveLoadSnapshot = await TrainingLoadRegistry.liveRefreshed()
        let track: [CLLocation] = inputs.polyline.map {
            GPXExporter.decode(polyline: $0, startDate: inputs.startDate, duration: inputs.duration)
        } ?? []
        switch inputs.kind {
        case .holistic:
            try await renderHolistic(inputs, track: track, load: liveLoadSnapshot)
        case .workoutOnly:
            try await renderWorkoutOnly(inputs, track: track)
        case .recovery:
            try await renderRecovery(inputs, load: liveLoadSnapshot)
        }
    }

    /// The list holds lightweight sessions (RR series stripped); the PDFs need
    /// the full ones, or every raw-RR section drops out. Runs inside the
    /// detached task, so the decrypt stays off the main actor. Falls back to
    /// the lightweight copy if a full read fails. Also loads the overnights
    /// before the reported night.
    nonisolated private static func withFullSessions(_ inputs: GenerationInputs) -> GenerationInputs {
        let archive = AppDependencies.current.storage.sessionArchive
        var full = inputs
        // A recovery row's workout is its overnight, which the render does not
        // read as a workout: one full read, not two.
        if inputs.kind != .recovery {
            full.workout = archive.retrieveOrLog(inputs.workout.id) ?? inputs.workout
        }
        full.overnight = inputs.overnight.map { archive.retrieveOrLog($0.id) ?? $0 }
        full.recentOvernight = ReportBaselineNights.before(inputs.overnight?.startDate ?? inputs.workout.startDate, archive: archive)
        return full
    }

    /// The renders themselves are `ReportRenderer`'s, shared with the
    /// Send-Report menu.
    nonisolated private static func renderHolistic(_ inputs: GenerationInputs, track: [CLLocation], load: TrainingLoadRegistry.TrainingLoad?) async throws {
        try await ReportRenderer.renderDaily(
            workout: inputs.workout, track: track, overnight: inputs.overnight, recentOvernight: inputs.recentOvernight,
            profile: profile(inputs), load: load, to: inputs.pdfURL
        )
    }

    nonisolated private static func renderWorkoutOnly(_ inputs: GenerationInputs, track: [CLLocation]) async throws {
        try await ReportRenderer.renderWorkout(inputs.workout, track: track, profile: profile(inputs), to: inputs.pdfURL)
    }

    nonisolated private static func profile(_ inputs: GenerationInputs) -> ReportRenderer.Profile {
        ReportRenderer.Profile(
            maxHR: inputs.maxHR, restingHR: inputs.restingHR, lthr: inputs.lthr,
            units: inputs.units, temperatureUnit: inputs.temperatureUnit
        )
    }

    /// Recovery / HRV-only report. Source session is the overnight
    /// HRV (held in `overnight` for this kind). The same comprehensive
    /// PDF that MorningResultsView's "Email PDF" path produces, with
    /// frozen-snapshot data only — no live HealthKit query — so a tap from the
    /// Reports list never blocks on background HK auth or async sleep fetches.
    /// The frozen snapshot is what was true at the time of the morning
    /// analysis, which is exactly what a user revisiting an old report wants
    /// to see; the baseline is the one before that night (`baselineStats`).
    nonisolated private static func renderRecovery(_ inputs: GenerationInputs, load: TrainingLoadRegistry.TrainingLoad?) async throws {
        guard let overnightSession = inputs.overnight else {
            throw ReportsListError.recoverySessionMissing
        }
        let rendered = try await ReportRenderer.renderRecovery(
            overnightSession, recentOvernight: inputs.recentOvernight,
            baselineStats: inputs.baselineStats, load: load, to: inputs.pdfURL
        )
        guard rendered else { throw ReportsListError.recoveryGenerationFailed }
    }
}

// MARK: - Row model

struct ReportRow: Identifiable {
    /// `.recovery` gives HRV-only overnight sessions
    /// their own row (appearing only bundled into a
    /// `.holistic` row when a workout followed the night is
    /// why a user reported "no HRV reports anywhere").
    enum Kind { case holistic, workoutOnly, recovery }

    let id: UUID
    let date: Date
    let kind: Kind
    let workoutSession: HRVSession
    let overnightSession: HRVSession?

    var title: String {
        let sport = workoutSession.workoutMetadata?.sport.localizedName ?? String(localized: "Workout", bundle: LanguageManager.appBundle)
        switch kind {
        case .holistic: return String(localized: "Daily Report — \(sport)", bundle: LanguageManager.appBundle)
        case .workoutOnly: return String(localized: "\(sport) Report", bundle: LanguageManager.appBundle)
        case .recovery: return String(localized: "Recovery / HRV Report", bundle: LanguageManager.appBundle)
        }
    }

    var subtitle: String {
        let stamp = LocalizedDateFormat.string(from: date, template: "yMMMdjmm")
        return ([stamp] + detailBits).joined(separator: " · ")
    }

    private var detailBits: [String] {
        switch kind {
        case .holistic:
            distanceBit + [String(localized: "with morning recovery", bundle: LanguageManager.appBundle)]
        case .workoutOnly:
            distanceBit
        case .recovery:
            recoveryScoreBit
        }
    }

    private var distanceBit: [String] {
        guard let dist = workoutSession.workoutMetadata?.distanceMeters else { return [] }
        return [UnitsPreferenceStore.current.resolved.formatDistance(meters: dist)]
    }

    private var recoveryScoreBit: [String] {
        guard let composite = overnightSession?.scoreBreakdown?.compositeScore else { return [] }
        return [String(localized: "score \(ScoreVerdict.safeDisplayScore(composite))", bundle: LanguageManager.appBundle)]
    }

    var iconName: String {
        switch kind {
        case .holistic: return "doc.text.image.fill"
        case .workoutOnly: return "doc.text.fill"
        case .recovery: return "moon.stars.fill"
        }
    }

    @MainActor var iconTint: Color {
        switch kind {
        case .holistic: return AppTheme.primary
        case .workoutOnly: return AppTheme.sage
        case .recovery: return AppTheme.terracotta
        }
    }
}

/// Typed errors for the recovery branch of `generate()`.
/// Surfaced through the existing `generationError` alert so the user
/// gets a real message ("This recovery session doesn't have data to
/// report on") instead of a silent failure.
private enum ReportsListError: LocalizedError {
    case recoverySessionMissing
    case recoveryGenerationFailed

    var errorDescription: String? {
        switch self {
        case .recoverySessionMissing:
            return String(localized: "Recovery session data is missing — try reanalysing the session.", bundle: LanguageManager.appBundle)
        case .recoveryGenerationFailed:
            return String(localized: "Couldn't generate the recovery PDF. The session may not have enough data.", bundle: LanguageManager.appBundle)
        }
    }
}

// Sheet presentation needs Identifiable wrapper — URL doesn't conform
private struct URLWrapper: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
