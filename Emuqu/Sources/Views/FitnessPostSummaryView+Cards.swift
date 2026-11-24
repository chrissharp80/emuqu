import Charts
import CoreLocation
import MapKit
import MessageUI
import SwiftUI

// Physiology, splits, route history, coach report, save route, export
// and recap-share cards. The two cards that rewrite the archived workout
// (re-smooth elevation, re-analyze α1) are in
// FitnessPostSummaryView+Rewrites.swift.

extension FitnessSummaryCards {

    /// Pa:Hr decoupling + EF, a secondary "Physiology" group. HRR has its
    /// own card.
    var physiologyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Physiology", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            decouplingRow
            efficiencyFactorRow
            // Nothing to show? A one-line note says why, under the header.
            physiologyEmptyNote
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var physiologyEmptyNote: some View {
        if session.workoutMetadata?.decouplingPercent == nil,
           session.workoutMetadata?.efficiencyFactor == nil {
            Text(String(localized: "Needs more time + distance to compute drift metrics.", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    @ViewBuilder
    private var efficiencyFactorRow: some View {
        if let ef = session.workoutMetadata?.efficiencyFactor {
            headlineRow(
                String(localized: "Efficiency Factor", bundle: LanguageManager.appBundle),
                value: String(format: "%.2f", locale: LanguageManager.appLocale, ef),
                caption: String(localized: "normalized pace ÷ avg HR", bundle: LanguageManager.appBundle)
            )
        }
    }

    @ViewBuilder
    private var decouplingRow: some View {
        if let decoupling = session.workoutMetadata?.decouplingPercent {
            headlineRow(
                String(localized: "Pa:Hr Decoupling", bundle: LanguageManager.appBundle),
                value: String(format: "%+.1f%%", locale: LanguageManager.appLocale, decoupling),
                caption: decoupling < 5 ? String(localized: "strong aerobic efficiency", bundle: LanguageManager.appBundle) : String(localized: "efficiency drifted", bundle: LanguageManager.appBundle)
            )
        }
    }

    /// Environment card — the weather this session was run in and what it
    /// did for heat acclimatization. Self-hiding: renders nothing unless
    /// the session captured (or was backfilled with) weather.
    @ViewBuilder
    var environmentCard: some View {
        if let weather = session.workoutMetadata?.weatherSnapshot {
            let unit = settingsManager.settings.temperatureUnit
            let exposure = HeatAcclimationCache.exposure(from: session, weather: weather)
            let stimulus = HeatAcclimation.sessionStimulus(exposure)
            environmentBody(weather, unit: unit, stimulus: stimulus)
        }
    }

    private func environmentBody(_ weather: WorkoutWeatherSnapshot, unit: TemperatureUnit, stimulus: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Conditions", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            headlineRow(
                String(localized: "Temperature", bundle: LanguageManager.appBundle),
                value: formatTemp(weather.temperatureC, unit: unit),
                caption: Self.conditionsCaption(weather)
            )
            Text(verbatim: heatContributionLine(stimulus: stimulus))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            weatherAttribution(weather)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private static func conditionsCaption(_ weather: WorkoutWeatherSnapshot) -> String {
        let humidity = Int(weather.relativeHumidityPercent.rounded())
        guard let conditions = weather.conditions else {
            return String(localized: "\(humidity)% humidity", bundle: LanguageManager.appBundle)
        }
        return String(localized: "\(WeatherService.localizedConditions(conditions)), \(humidity)% humidity", bundle: LanguageManager.appBundle)
    }

    /// The credit MET Norway's licence asks for. A fetched forecast carries
    /// wind; weather read from Apple Health carries none and isn't MET
    /// Norway's, so it gets no credit line.
    @ViewBuilder
    private func weatherAttribution(_ weather: WorkoutWeatherSnapshot) -> some View {
        if weather.windKMH != nil {
            Text("Weather data: MET Norway (CC BY 4.0)", bundle: LanguageManager.appBundle)
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    /// `splits` is already resolved to the user's unit, so the unit label is
    /// worked out once here rather than per row.
    func splitsCard(_ resolved: ResolvedSplits) -> some View {
        let unitLabel = resolved.isMile
            ? String(localized: "mi", bundle: LanguageManager.appBundle)
            : String(localized: "km", bundle: LanguageManager.appBundle)
        return VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Splits", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            ForEach(resolved.splits, id: \.index) { split in
                splitRow(split, unitLabel: unitLabel)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Route history baseline card. Shows today's
    /// pace + HR side-by-side with the average of past sessions on
    /// the same saved route, plus deltas. Reads
    /// `workoutMetadata.recognizedRouteName` (set on finalize) and
    /// walks the archive for prior sessions tagged with the same
    /// route. Renders nothing when (a) no route was bound, (b) this
    /// is the first run on the route, or (c) there's no usable
    /// pace/HR data on the prior sessions.
    ///
    /// Reads the `routeHistory` @State populated by
    /// `FitnessPostSummaryView.loadRouteHistorySummary()` instead of running the archive walk
    /// inline. While the async load is in flight `routeHistory` is nil,
    /// which renders the same nothing-at-all as the nil-summary cases
    /// above — no separate loading UI.
    @ViewBuilder
    var routeHistoryBaselineCard: some View {
        if let routeName = session.workoutMetadata?.recognizedRouteName,
           !routeName.isEmpty,
           let summary = routeHistory {
            routeHistoryBody(routeName, summary: summary)
        }
    }

    private func routeHistoryBody(_ routeName: String, summary: RouteHistorySummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            routeHistoryHeader(routeName, priorCount: summary.priorCount)
            if let row = summary.paceRow {
                routeHistoryRow(label: String(localized: "Pace", bundle: LanguageManager.appBundle), today: row.today, baseline: row.baseline, deltaCaption: row.deltaCaption)
            }
            if let row = summary.hrRow {
                routeHistoryRow(label: String(localized: "Avg HR", bundle: LanguageManager.appBundle), today: row.today, baseline: row.baseline, deltaCaption: row.deltaCaption)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    func routeHistoryRow(label: String, today: String, baseline: String, deltaCaption: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                routeHistoryValues(today: today, baseline: baseline)
                Text(deltaCaption)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
    }

    struct RouteHistorySummary {
        let priorCount: Int
        let paceRow: ComparisonRow?
        let hrRow: ComparisonRow?

        struct ComparisonRow {
            let today: String
            let baseline: String
            let deltaCaption: String
        }
    }

    /// Pure summary walk — static with explicit
    /// inputs so `FitnessPostSummaryView.loadRouteHistorySummary()` can run it off the main
    /// thread without capturing the view.
    nonisolated static func routeHistorySummary(
        routeName: String,
        session: HRVSession,
        unitsResolved: UnitsPreference
    ) -> RouteHistorySummary? {
        let candidates = priorRuns(ofRoute: routeName, excluding: session.id)
        guard !candidates.isEmpty else { return nil }
        let baseline = RouteBaseline(priorRuns: candidates)
        return RouteHistorySummary(
            priorCount: candidates.count,
            paceRow: paceComparisonRow(session: session, baseline: baseline, unitsResolved: unitsResolved),
            hrRow: hrComparisonRow(session: session, baseline: baseline)
        )
    }

    /// The most recent 20 other workouts the route recogniser matched to the
    /// same named route. `entries` is newest first and the walk is lazy, so
    /// decoding stops once 20 matches are found.
    nonisolated private static func priorRuns(ofRoute routeName: String, excluding sessionId: UUID) -> [HRVSession] {
        let archive = AppDependencies.current.storage.sessionArchive
        return archive.store.entries.lazy
            .filter { $0.sessionType == .workout && $0.sessionId != sessionId }
            .compactMap { try? archive.retrieveLightweight($0.sessionId) }
            .filter { $0.workoutMetadata?.recognizedRouteName == routeName }
            .prefix(20)
            .sorted { $0.startDate > $1.startDate }
    }

    /// Today's pace from this session's metadata, against the weighted baseline.
    nonisolated private static func paceComparisonRow(session: HRVSession, baseline: RouteBaseline, unitsResolved: UnitsPreference) -> RouteHistorySummary.ComparisonRow? {
        guard baseline.totalDistance > 100,
              let todayDist = session.workoutMetadata?.distanceMeters, todayDist > 100,
              let todayDur = session.duration, todayDur > 60
        else { return nil }
        let todayPaceSecPerKm = todayDur * 1_000.0 / todayDist
        let priorPaceSecPerKm = baseline.totalDuration * 1_000.0 / baseline.totalDistance
        return .init(
            today: unitsResolved.formatPace(secondsPerMeter: todayPaceSecPerKm / 1_000) ?? "—",
            baseline: unitsResolved.formatPace(secondsPerMeter: priorPaceSecPerKm / 1_000) ?? "—",
            deltaCaption: paceDeltaCaption(secPerKmDelta: todayPaceSecPerKm - priorPaceSecPerKm, unitsResolved: unitsResolved)
        )
    }

    /// Convert the per-km delta to the user's own pace unit before wording it.
    nonisolated private static func paceDeltaCaption(secPerKmDelta delta: Double, unitsResolved: UnitsPreference) -> String {
        let bundle = LanguageManager.appBundle
        let displayDelta = unitsResolved == .imperial ? delta * 1.609344 : delta
        let sec = abs(Int(displayDelta.rounded()))
        switch (unitsResolved == .imperial, displayDelta < 0) {
        case (true, true): return String(localized: "\(sec) s/mi faster than usual", bundle: bundle)
        case (true, false): return String(localized: "\(sec) s/mi slower than usual", bundle: bundle)
        case (false, true): return String(localized: "\(sec) s/km faster than usual", bundle: bundle)
        case (false, false): return String(localized: "\(sec) s/km slower than usual", bundle: bundle)
        }
    }

    /// Today's avg HR from samples, falling back to the session's mean HR.
    /// Zero readings (strap dropouts) are left out, as the baseline does.
    nonisolated private static func hrComparisonRow(session: HRVSession, baseline: RouteBaseline) -> RouteHistorySummary.ComparisonRow? {
        guard baseline.hrCount > 0 else { return nil }
        let todayHRSamples = (session.workoutMetadata?.samples ?? []).compactMap(\.heartRate).filter { $0 > 0 }
        let todayAvgHR = todayHRSamples.isEmpty
            ? session.meanHR
            : Double(todayHRSamples.reduce(0, +)) / Double(todayHRSamples.count)
        guard let todayAvgHR else { return nil }
        let priorAvgHR = baseline.hrSum / Double(baseline.hrCount)
        return .init(
            today: bpmText(todayAvgHR),
            baseline: bpmText(priorAvgHR),
            deltaCaption: hrDeltaCaption(todayAvgHR - priorAvgHR)
        )
    }

    nonisolated private static func bpmText(_ bpm: Double) -> String {
        String(localized: "\(Int(bpm.rounded())) bpm", bundle: LanguageManager.appBundle)
    }

    nonisolated private static func hrDeltaCaption(_ delta: Double) -> String {
        let bpm = abs(Int(delta.rounded()))
        return delta < 0
            ? String(localized: "\(bpm) bpm lower than usual", bundle: LanguageManager.appBundle)
            : String(localized: "\(bpm) bpm higher than usual", bundle: LanguageManager.appBundle)
    }

    /// On-demand Coach Report button. Generates a
    /// fresh comprehensive report from the current session and stages
    /// the email composer (app-root sheet picks it up). Always
    /// available regardless of the auto-toggle in Settings — the
    /// toggle controls AUTO behavior; the manual button is forever-on.
    @ViewBuilder
    var coachReportCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(String(localized: "Coach Report", bundle: LanguageManager.appBundle), systemImage: "doc.text.magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            Text(String(localized: "Comprehensive coach-style breakdown of this workout — every metric, comparisons against your history, and recommendations for tomorrow. Built from this session's data, so it stays current if you re-tag or fix anything.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textTertiary)
            CoachReportButton(session: session, progress: $reportShare.coachReport)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// "Add this walk to my route library" card. Shown only when the
    /// session has a GPS polyline (saving an indoor session as a route
    /// is meaningless) and the route hasn't already been saved this
    /// session. After save, swap to a "Saved as "Run 3"…" confirmation row
    /// so the user knows it stuck.
    @ViewBuilder
    var saveRouteCard: some View {
        if session.workoutMetadata?.gpsPolyline != nil {
            saveRouteBody
        }
    }

    @ViewBuilder
    private var saveRouteBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            saveRouteHeader
            saveRouteState
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .alert(String(localized: "Name this route", bundle: LanguageManager.appBundle), isPresented: $showSaveRouteSheet) {
            TextField(String(localized: "Route name", bundle: LanguageManager.appBundle), text: $newRouteName)
            Button(String(localized: "Save", bundle: LanguageManager.appBundle)) { commitSavedRoute() }
            Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
        } message: {
            Text(String(localized: "This name is what the coach will say when it recognises the route — \"Following Daily 1\".", bundle: LanguageManager.appBundle))
        }
    }

    @ViewBuilder
    private var saveRouteState: some View {
        if let savedID = savedRouteIDForThisSession,
           let saved = savedRouteStore.routes.first(where: { $0.id == savedID }) {
            Text(String(localized: "Saved as \"\(saved.name)\". The coach will recognise this on future workouts — same direction or reversed.", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(String(localized: "Save this walk so the coach recognises it next time. The whole route — including any out-and-back you did mid-walk — is saved verbatim. Match is direction-agnostic.", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            addToLibraryButton
        }
    }

    private var addToLibraryButton: some View {
        Button {
            // Pre-fill a sensible default ("<sport> N", e.g. "Run 3")
            // so the common case is one tap. User can edit before
            // confirming.
            newRouteName = defaultSavedRouteName()
            showSaveRouteSheet = true
        } label: {
            HStack {
                Image(systemName: "plus.circle.fill")
                Text(String(localized: "Add to my route library", bundle: LanguageManager.appBundle))
                    .font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(AppTheme.fitnessAccent)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var saveRouteHeader: some View {
        HStack {
            Image(systemName: "map.circle.fill")
                .foregroundStyle(AppTheme.fitnessAccent)
            Text(String(localized: "Route library", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
        }
    }

    func defaultSavedRouteName() -> String {
        let sportName = session.workoutMetadata?.sport.localizedName ?? String(localized: "Workout", bundle: LanguageManager.appBundle)
        // Count how many already-saved routes for this sport exist; new
        // route gets the next ordinal as a placeholder. User can edit.
        let existingForSport = savedRouteStore.routes.filter {
            $0.sport == session.workoutMetadata?.sport
        }.count
        return "\(sportName) \(existingForSport + 1)"
    }

    /// A name left blank saves under the default "<sport> N" name rather than
    /// closing the alert with nothing saved.
    func commitSavedRoute() {
        let trimmed = newRouteName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? defaultSavedRouteName() : trimmed
        guard let saved = SavedRoute.from(session: session, name: name) else { return }
        savedRouteStore.add(saved)
        savedRouteIDForThisSession = saved.id
        // Kick off the road-name enrichment in the background. The user
        // doesn't wait on this — the route is immediately usable; road
        // names will appear within ~5–15 s as CLGeocoder responds. Once
        // enriched, the AI coach will say "the climb on Elm Street" on
        // the next workout, without any extra tap.
        savedRouteStore.enrichWithRoadNames(routeID: saved.id, geocoder: roadGeocoder)
    }

    /// `recapCardShareButton` is the Recap Card: a
    /// 1080×1920 social artifact built from the workout's distance / duration /
    /// pace + route polyline. Designed to be screenshot-worthy out of the box;
    /// this is the app's primary growth vector. Renders on tap (lazy because
    /// MKMapSnapshotter is async).
    ///
    /// `pdfShareButton` is the full visual PDF report — rendered on demand (the
    /// async MKMapSnapshotter call can take 1–2 s and would stall the
    /// export-file pre-generation path). Lives in +Share.swift.
    var exportCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            exportHeader
            recapCardShareButton
            pdfShareButton
            gpxShareRow
            csvShareRow
            tcxShareRow
            exportErrorNote
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var exportErrorNote: some View {
        if let err = exportError {
            Text(err)
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }

    private var tcxShareRow: some View {
        shareRow(
            icon: "doc.text",
            title: "TCX",
            subtitle: "TrainingPeaks, Final Surge, Garmin Connect",
            export: tcxExport
        )
    }

    private var csvShareRow: some View {
        shareRow(
            icon: "tablecells",
            title: "CSV",
            subtitle: "Numbers, Excel, Google Sheets",
            export: csvExport
        )
    }

    private var gpxShareRow: some View {
        shareRow(
            icon: "map",
            title: "GPX",
            subtitle: "Strava, Garmin Connect, WorkOutDoors, Dropbox",
            export: gpxExport
        )
    }

    private var exportHeader: some View {
        HStack {
            Text(String(localized: "Export", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            if !exportsReady {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
    }

    /// Recap Card share button. Tap to render the
    /// 1080×1920 social artifact (recovery card + workout polyline) and present
    /// the system share sheet. The image generation is detached so the UI stays
    /// responsive; the route-map snapshotter is async by nature.
    @ViewBuilder
    var recapCardShareButton: some View {
        Button {
            Task { await generateRecapCard() }
        } label: {
            recapShareLabel
        }
        .buttonStyle(.plain)
        .disabled(recapGenerating)
        .sheet(isPresented: $recapSharePresented) {
            // Share filename: prefer the file URL so the
            // attachment shows as "emuqu-{sport}-{date}.png" in
            // Photos / Files / Mail / Strava rather than the iOS
            // auto-generated "Image" / "IMG_XXXX.png".
            if let url = recapImageURL {
                ShareSheet(activityItems: [url])
            } else if let img = recapImage {
                ShareSheet(activityItems: [img])
            }
        }
    }

    private var recapShareLabel: some View {
        HStack(spacing: 12) {
            if recapGenerating {
                ProgressView().scaleEffect(0.9)
            } else {
                Image(systemName: "rectangle.stack.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.dustyRose)
                    .frame(width: 28)
            }
            recapShareText
            Spacer()
            if !recapGenerating {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
    }

    private var recapShareText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(recapGenerating
                ? String(localized: "Building card…", bundle: LanguageManager.appBundle)
                : String(localized: "Share Recap Card", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(String(localized: "Vertical 9:16 — Instagram Story / Reels ready", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }
}

// MARK: - File-scope helpers
//
// Kept outside the view. Each touches none of the view's members —
// including its private statics — and calls nothing inside it. `private`
// at file scope is fileprivate, so every call site in this file resolves.

@MainActor
private func routeHistoryHeader(_ routeName: String, priorCount: Int) -> some View {
    HStack {
        Image(systemName: "arrow.triangle.2.circlepath")
            .foregroundStyle(AppTheme.primary)
        Text(String(localized: "On \(routeName)", bundle: LanguageManager.appBundle))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.textSecondary)
        Spacer()
        Text(String(localized: "vs your last \(priorCount)", bundle: LanguageManager.appBundle))
            .font(.caption)
            .foregroundStyle(AppTheme.textTertiary)
    }
}

@MainActor
private func routeHistoryValues(today: String, baseline: String) -> some View {
    HStack(spacing: 6) {
        Text(today)
            .font(.subheadline.weight(.semibold))
        Text(String(localized: "/", bundle: LanguageManager.appBundle))
            .font(.caption)
            .foregroundStyle(AppTheme.textTertiary)
        Text(baseline)
            .font(.subheadline)
            .foregroundStyle(AppTheme.textSecondary)
    }
}

// MARK: - File-scope helpers (no FitnessSummaryCards state)

private func formatTemp(_ tempC: Double, unit: TemperatureUnit) -> String {
    let shown = unit == .fahrenheit ? tempC * 9 / 5 + 32 : tempC
    let symbol = unit == .fahrenheit ? "°F" : "°C"
    return "\(Int(shown.rounded()))\(symbol)"
}

private func heatContributionLine(stimulus: Double) -> String {
    if stimulus <= 0 {
        return String(localized: "Cool enough that this session didn't add heat-acclimatization stress — that's about the effort, not the weather.", bundle: LanguageManager.appBundle)
    }
    let pct = Int((stimulus * 100).rounded())
    if stimulus >= 0.85 {
        return String(localized: "A strong heat stimulus — this run pushed your heat acclimatization hard. Sessions like this are how you adapt to summer racing.", bundle: LanguageManager.appBundle)
    }
    if stimulus >= 0.5 {
        return String(localized: "A solid heat stimulus (\(pct)% of a full dose) — this run moved your heat acclimatization forward.", bundle: LanguageManager.appBundle)
    }
    return String(localized: "A mild heat stimulus (\(pct)% of a full dose) — every hot session adds up toward heat acclimatization.", bundle: LanguageManager.appBundle)
}

/// The post-summary coach report button's state, kept in
/// `FitnessSummaryCards.ReportShareState.coachReport`.
enum CoachReportProgress: Equatable {
    case idle
    case preparing
    /// The email draft was staged; `withPDF` is false when the PDF render
    /// failed and the draft carries only the summary.
    case staged(withPDF: Bool)
}

/// "Generate & Email Coach Report". The render takes seconds and stages an
/// email draft when done. While it runs the button says the report is being
/// prepared and is disabled, so repeated taps cannot stage several drafts;
/// once the draft is staged the button works again and the line under it
/// says whether the PDF made it in, so a failed render can be retried.
private struct CoachReportButton: View {
    let session: HRVSession
    @Binding var progress: CoachReportProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: request) {
                label
            }
            .disabled(progress == .preparing)
            if let outcome {
                Text(outcome)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    /// Stages the draft once per tap and waits for the render: the button
    /// comes back when the draft is staged, so a report whose PDF failed can
    /// be asked for again.
    private func request() {
        guard progress != .preparing else { return }
        progress = .preparing
        let render = WorkoutRecorder.scheduleCoachReportEmail(for: session)
        Task {
            progress = .staged(withPDF: await render.value)
        }
    }

    private var outcome: String? {
        switch progress {
        case .idle, .preparing: nil
        case .staged(withPDF: true):
            String(localized: "The coach report email is ready.", bundle: LanguageManager.appBundle)
        case .staged(withPDF: false):
            String(localized: "The PDF couldn't be made, so the email has the summary only. Tap to try again.", bundle: LanguageManager.appBundle)
        }
    }

    private var label: some View {
        HStack {
            if progress == .preparing {
                ProgressView()
                Text(String(localized: "Preparing the coach report…", bundle: LanguageManager.appBundle))
            } else {
                Image(systemName: "envelope.fill")
                Text(String(localized: "Generate & Email Coach Report", bundle: LanguageManager.appBundle))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.15))
        .foregroundStyle(Color.accentColor)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
