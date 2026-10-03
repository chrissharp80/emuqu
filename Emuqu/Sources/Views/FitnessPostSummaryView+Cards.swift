import Charts
import CoreLocation
import MapKit
import MessageUI
import SwiftUI

// Split out from FitnessPostSummaryView.swift to keep the primary
// file under the 1500-line tech-debt budget. Holds
// physiology, splits, route history, coach report, save route, export,
// and re-smooth-elevation cards.

extension FitnessSummaryCards {

    /// Pa:Hr decoupling + EF live here now — HRR moved into its own card.
    /// Kept as a secondary "Physiology" group so existing layout stays
    /// familiar but the signature numbers are promoted.
    var physiologyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Physiology", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            decouplingRow
            efficiencyFactorRow
            // Nothing to show? Hide the whole card instead of an empty header.
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
                value: String(format: "%.2f", locale: .current, ef),
                caption: String(localized: "normalized pace ÷ avg HR", bundle: LanguageManager.appBundle)
            )
        }
    }

    @ViewBuilder
    private var decouplingRow: some View {
        if let decoupling = session.workoutMetadata?.decouplingPercent {
            headlineRow(
                String(localized: "Pa:Hr Decoupling", bundle: LanguageManager.appBundle),
                value: String(format: "%+.1f%%", locale: .current, decoupling),
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
            let unit = AppDependencies.current.app.settingsManager.settings.temperatureUnit
            let exposure = HeatAcclimationCache.exposure(from: session, weather: weather)
            let stimulus = HeatAcclimation.sessionStimulus(exposure)
            let wbgt = HeatAcclimation.wbgtEstimate(
                tempC: weather.temperatureC,
                relativeHumidity: weather.relativeHumidityPercent
            )
            environmentBody(weather, unit: unit, stimulus: stimulus, wbgt: wbgt)
        }
    }

    private func environmentBody(_ weather: WorkoutWeatherSnapshot, unit: TemperatureUnit, stimulus: Double, wbgt: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Conditions", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            headlineRow(
                String(localized: "Temperature", bundle: LanguageManager.appBundle),
                value: Self.formatTemp(weather.temperatureC, unit: unit),
                caption: weather.conditions.map { String(localized: "\(WeatherService.localizedConditions($0)), \(Int(weather.relativeHumidityPercent.rounded()))% humidity", bundle: LanguageManager.appBundle) }
                    ?? String(localized: "\(Int(weather.relativeHumidityPercent.rounded()))% humidity", bundle: LanguageManager.appBundle)
            )
            Text(verbatim: Self.heatContributionLine(stimulus: stimulus, wbgt: wbgt))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private static func formatTemp(_ tempC: Double, unit: TemperatureUnit) -> String {
        let shown = unit == .fahrenheit ? tempC * 9 / 5 + 32 : tempC
        let symbol = unit == .fahrenheit ? "°F" : "°C"
        return "\(Int(shown.rounded()))\(symbol)"
    }

    private static func heatContributionLine(stimulus: Double, wbgt: Double) -> String {
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

    /// `splits` is already resolved to the user's unit, so the unit label is
    /// worked out once here rather than per row.
    func splitsCard(splits: [Split]) -> some View {
        let unitLabel = Self.splitUnitLabel(for: splits)
        return VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Splits", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            ForEach(splits, id: \.index) { split in
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
    /// `loadRouteHistorySummary()` instead of running the archive walk
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
                routeHistoryRow(label: String(localized: "Pace", bundle: LanguageManager.appBundle), today: row.today, baseline: row.baseline, deltaCaption: row.deltaCaption, lowerIsBetter: true)
            }
            if let row = summary.hrRow {
                routeHistoryRow(label: String(localized: "Avg HR", bundle: LanguageManager.appBundle), today: row.today, baseline: row.baseline, deltaCaption: row.deltaCaption, lowerIsBetter: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    func routeHistoryRow(label: String, today: String, baseline: String, deltaCaption: String, lowerIsBetter _: Bool) -> some View {
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

    /// Async loader for the route-history card. Snapshots
    /// the session + resolved units on the MainActor, runs the archive
    /// walk (disk reads + decodes) on a detached task, and lands the
    /// result in the `routeHistory` @State the card reads. Called from
    /// the `.task(id: session.id)` block on open and again from
    /// `reloadFromArchive()` whenever the archive-change signal fires.
    func loadRouteHistorySummary() async {
        guard let routeName = session.workoutMetadata?.recognizedRouteName,
              !routeName.isEmpty
        else {
            routeHistory = nil
            return
        }
        let sessionSnapshot = session
        let unitsResolved = units.resolved
        routeHistory = await Task.detached(priority: .userInitiated) {
            Self.routeHistorySummary(
                routeName: routeName,
                session: sessionSnapshot,
                unitsResolved: unitsResolved
            )
        }.value
    }

    /// Pure summary walk — static with explicit
    /// inputs so `loadRouteHistorySummary()` can run it off the main
    /// thread without capturing the view.
    nonisolated static func routeHistorySummary(
        routeName: String,
        session: HRVSession,
        unitsResolved: UnitsPreference
    ) -> RouteHistorySummary? {
        let candidates = priorRuns(ofRoute: routeName, excluding: session.id)
        guard !candidates.isEmpty else { return nil }
        let baseline = routeBaseline(candidates)
        return RouteHistorySummary(
            priorCount: candidates.count,
            paceRow: paceComparisonRow(session: session, baseline: baseline, unitsResolved: unitsResolved),
            hrRow: hrComparisonRow(session: session, baseline: baseline)
        )
    }

    /// The most recent 20 other workouts the route recogniser matched to the
    /// same named route.
    nonisolated private static func priorRuns(ofRoute routeName: String, excluding sessionId: UUID) -> [HRVSession] {
        let archive = AppDependencies.current.storage.sessionArchive
        return archive.entries
            .filter { $0.sessionType == .workout && $0.sessionId != sessionId }
            .compactMap { try? archive.retrieveLightweight($0.sessionId) }
            .filter { $0.workoutMetadata?.recognizedRouteName == routeName }
            .sorted { $0.startDate > $1.startDate }
            .prefix(20)
            .map { $0 }
    }

    /// Distance-weighted pace baseline plus a sample-weighted mean HR.
    nonisolated private static func routeBaseline(_ candidates: [HRVSession]) -> RouteBaseline {
        var baseline = RouteBaseline()
        for prior in candidates {
            accumulatePace(&baseline, from: prior)
            accumulateHR(&baseline, from: prior)
        }
        return baseline
    }

    /// Only efforts long enough to be a real repeat of the route contribute
    /// (>100 m and >60 s).
    nonisolated private static func accumulatePace(_ baseline: inout RouteBaseline, from prior: HRVSession) {
        guard let dist = prior.workoutMetadata?.distanceMeters, dist > 100,
              let dur = prior.duration, dur > 60
        else { return }
        baseline.totalDistance += dist
        baseline.totalDuration += dur
    }

    nonisolated private static func accumulateHR(_ baseline: inout RouteBaseline, from prior: HRVSession) {
        for hr in (prior.workoutMetadata?.samples ?? []).compactMap(\.heartRate) where hr > 0 {
            baseline.hrSum += Double(hr)
            baseline.hrCount += 1
        }
    }

    struct RouteBaseline {
        var totalDistance: Double = 0
        var totalDuration: Double = 0
        var hrSum: Double = 0
        var hrCount: Int = 0
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
            generateEmailCoachReportSection
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var generateEmailCoachReportSection: some View {
        Button {
            WorkoutRecorder.scheduleCoachReportEmail(for: session)
        } label: {
            HStack {
                Image(systemName: "envelope.fill")
                Text(String(localized: "Generate & Email Coach Report", bundle: LanguageManager.appBundle))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.15))
            .foregroundStyle(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// "Add this walk to my route library" card. Shown only when the
    /// session has a GPS polyline (saving an indoor session as a route
    /// is meaningless) and the route hasn't already been saved this
    /// session. After save, swap to a "Saved as 'Daily 1' — view library"
    /// confirmation row so the user knows it stuck.
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
            // Pre-fill a sensible default ("Daily N") so the
            // common case is one tap. User can edit before
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
        let sportName = session.workoutMetadata?.sport.localizedName ?? "Workout"
        // Count how many already-saved routes for this sport exist; new
        // route gets the next ordinal as a placeholder. User can edit.
        let existingForSport = savedRouteStore.routes.filter {
            $0.sport == session.workoutMetadata?.sport
        }.count
        return "\(sportName) \(existingForSport + 1)"
    }

    func commitSavedRoute() {
        let trimmed = newRouteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let saved = SavedRoute.from(session: session, name: trimmed) else { return }
        savedRouteStore.add(saved)
        savedRouteIDForThisSession = saved.id
        // Kick off the road-name enrichment in the background. The user
        // doesn't wait on this — the route is immediately usable; road
        // names will appear within ~5–15 s as CLGeocoder responds. Once
        // enriched, the AI coach will say "the climb on Elm Street" on
        // the next workout, without any extra tap.
        savedRouteStore.enrichWithRoadNames(routeID: saved.id)
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
            url: tcxURL
        )
    }

    private var csvShareRow: some View {
        shareRow(
            icon: "tablecells",
            title: "CSV",
            subtitle: "Numbers, Excel, Google Sheets",
            url: csvURL
        )
    }

    private var gpxShareRow: some View {
        shareRow(
            icon: "map",
            title: "GPX",
            subtitle: "Strava, Garmin Connect, WorkOutDoors, Dropbox",
            url: gpxURL
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

    /// Action card offering to recompute elevation using real terrain data
    /// from a DEM (Digital Elevation Model) lookup service — the same
    /// approach Strava and Garmin use when barometer data is missing.
    /// Replaces the previous GPS-altitude smoothing heuristics (which
    /// either inflated gain or undercounted it depending on threshold;
    /// no amount of smoothing the noise gives the right answer).
    ///
    /// Service: OpenTopoData NED 10 m for US routes, SRTM 30 m elsewhere,
    /// Open-Meteo GLO-90 as the fallback. Threshold: `TopoElevationService`'s
    /// default 15 m sustained climb. The copy says the route points leave
    /// the device.
    @ViewBuilder
    var resmoothElevationCard: some View {
        if !track.isEmpty {
            resmoothElevationBody
        }
    }

    private var resmoothElevationBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            resmoothElevationHeader
            let storedGain = session.workoutMetadata?.elevationGainMeters ?? 0
            Text(String(localized: "Current: \(units.formatElevation(meters: storedGain)). Looks up real terrain elevation along your route from a public elevation map — OpenTopoData (10 m data in the US, 30 m elsewhere), or Open-Meteo if that fails — and counts only sustained climbs of 15 m or more. Up to 100 of your route's points, rounded to about 11 m, are sent to those services. Requires network.", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            resmoothPreviewNote
            resmoothErrorNote
            resmoothElevationButton
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var resmoothElevationButton: some View {
        Button {
            Task { await runResmoothElevation() }
        } label: {
            Text(elevResmoothing
                ? String(localized: "Querying map & saving…", bundle: LanguageManager.appBundle)
                : String(localized: "Look up and save real elevation", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(AppTheme.fitnessAccent.opacity(elevResmoothing ? 0.35 : 1))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(elevResmoothing)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var resmoothErrorNote: some View {
        if let err = elevResmoothError {
            Text(err)
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var resmoothPreviewNote: some View {
        if let preview = elevResmoothPreview {
            Text(String(localized: "Map-derived: \(units.formatElevation(meters: preview.gain)) gain · \(units.formatElevation(meters: preview.loss)) loss", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.sageText)
        }
    }

    private var resmoothElevationHeader: some View {
        HStack {
            Text(String(localized: "Recompute elevation (topo map)", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            if elevResmoothing { ProgressView().scaleEffect(0.7) }
        }
    }

    /// Single atomic action: fetch DEM + save. No preview / second-tap dance.
    /// The previous two-phase flow kept tripping up the user — they saw the
    /// right number in the preview but thought "why hasn't it saved?" and
    /// didn't realise a second tap was needed.
    ///
    /// Default 15 m sustained-climb threshold (calibrated against iSmoothRun /
    /// Apple Fitness / FITIV — all barometer-based on iPhone, all agreed at
    /// ~395 ft on a Riverton loop). Retroactive DEM-based recomputes will
    /// never match a barometer-recorded session exactly, but with NED 10 m +
    /// 15 m threshold the numbers land within ~5 %.
    func runResmoothElevation() async {
        elevResmoothing = true
        elevResmoothError = nil
        defer { elevResmoothing = false }
        do {
            let result = try await TopoElevationService.elevations(for: track, maxSamples: 100)
            elevResmoothPreview = (gain: result.gainMeters, loss: result.lossMeters)
            await saveResmoothedElevation(gain: result.gainMeters, loss: result.lossMeters)
        } catch let error as TopoElevationService.ServiceError {
            elevResmoothError = String(localized: "Elevation lookup failed — \(describe(error))", bundle: LanguageManager.appBundle)
        } catch {
            elevResmoothError = String(localized: "Elevation lookup failed — \(error.localizedDescription)", bundle: LanguageManager.appBundle)
        }
    }

    /// Read-modify-write of the archived copy under the archive lock, so a
    /// concurrent writer can't be overwritten, with an iCloud re-upload
    /// requested. Returns the stored result, or nil when the session isn't
    /// in the archive.
    nonisolated static func updateArchived(
        _ id: UUID,
        in archive: SessionArchive,
        _ change: (inout HRVSession) -> Void
    ) throws -> HRVSession? {
        var saved: HRVSession?
        do {
            try archive.update(id) { stored in
                change(&stored)
                saved = stored
            }
        } catch SessionArchive.ArchiveError.fileNotFound {
            return nil
        }
        return saved
    }

    func describe(_ error: TopoElevationService.ServiceError) -> String {
        switch error {
        case .badResponse(let msg):
            // The service's own message is technical English; it goes to the
            // log, and the user gets a translated summary.
            debugLog("[ResmoothElevation] bad response: \(msg)", level: .warning)
            return String(localized: "unexpected response from the elevation service", bundle: LanguageManager.appBundle)
        case .emptyTrack: return String(localized: "no GPS track", bundle: LanguageManager.appBundle)
        case .networkError(let inner): return inner.localizedDescription
        }
    }

    /// Directly updates our own @State so the UI refreshes unconditionally, and
    /// also bumps the archive-change signal so the fitness tab's hero reloads
    /// behind us. Relying solely on the archive observer to close the loop is
    /// fragile — if it doesn't fire (timing quirks, view-lifecycle edge cases)
    /// the user sees "saved" but the number doesn't change on screen — so
    /// both paths run.
    func saveResmoothedElevation(gain: Double, loss: Double) async {
        elevResmoothing = true
        defer { elevResmoothing = false }
        do {
            let archive = AppDependencies.current.storage.sessionArchive
            guard let updated = try Self.updateArchived(session.id, in: archive, { stored in
                stored.workoutMetadata?.elevationGainMeters = gain
                stored.workoutMetadata?.elevationLossMeters = loss
            }) else {
                elevResmoothError = String(localized: "Session not found in archive.", bundle: LanguageManager.appBundle)
                return
            }
            refreshedSession = updated
            collector.notifyArchiveChanged()
            elevResmoothPreview = nil
            debugLog("[ResmoothElevation] rewrote gain=\(Int(gain)) loss=\(Int(loss)) for session \(session.id)")
        } catch {
            elevResmoothError = String(localized: "Couldn't save: \(error.localizedDescription)", bundle: LanguageManager.appBundle)
        }
    }

    /// Action card offering to re-run α1 analysis with the current
    /// artifact filter. Sessions recorded before `LiveDFAAnalyzer.cleanRRForDFA`
    /// shipped had unfiltered RR fed into DFA — producing α1 values
    /// stuck at 1.5-2.0 (Brownian range) regardless of effort. This
    /// button regenerates α1 from the stored RRSeries using the current
    /// filter + DFA and writes it back to the archive; the open sheet
    /// refreshes in place with the new values.
    @ViewBuilder
    var reanalyzeAlpha1Card: some View {
        // Shown whenever the session has α1 samples and enough stored RR
        // (64+ beats) to recompute them.
        let samples = session.workoutMetadata?.samples ?? []
        let hasAlpha1 = samples.contains { $0.alpha1 != nil }
        let hasRR = (session.rrSeries?.points.count ?? 0) >= 64
        if hasAlpha1, hasRR {
            reanalyzeAlpha1Body
        }
    }

    private var reanalyzeAlpha1Body: some View {
        VStack(alignment: .leading, spacing: 8) {
            reanalyzeAlpha1Header
            Text(String(
                localized: "Old sessions may carry inflated α1 readings (values stuck near 1.6) because the raw RR stream wasn't filtered for ectopic beats before DFA. Tap below to regenerate α1 using the current Kubios-style filter — your HR / pace / TRIMP stay unchanged.",
                bundle: LanguageManager.appBundle
            ))
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            reanalyzeErrorNote
            reanalyzeAlpha1Button
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var reanalyzeAlpha1Button: some View {
        Button {
            Task { await runReanalyze() }
        } label: {
            Text(reanalyzing
                ? String(localized: "Re-analysing…", bundle: LanguageManager.appBundle)
                : String(localized: "Re-analyze α1 for this session", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(AppTheme.fitnessAccent.opacity(reanalyzing ? 0.35 : 1))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(reanalyzing)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var reanalyzeErrorNote: some View {
        if let err = reanalyzeError {
            Text(err)
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }

    private var reanalyzeAlpha1Header: some View {
        HStack {
            Text(String(localized: "Re-analyze α1", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            if reanalyzing {
                ProgressView().scaleEffect(0.7)
            }
        }
    }

    func runReanalyze() async {
        reanalyzing = true
        reanalyzeError = nil
        defer { reanalyzing = false }
        let (refreshedSamples, readings) = await recomputeAlpha1()
        guard let refreshedSamples else {
            reanalyzeError = String(localized: "Not enough RR data to re-analyze.", bundle: LanguageManager.appBundle)
            return
        }
        persistReanalyzedSamples(refreshedSamples, readingCount: readings.count)
    }

    /// Off-thread: the DFA pass over a ~60-min RR series is a few hundred
    /// log-log regressions; fast enough that we don't need chunking but
    /// definitely shouldn't block the main thread.
    ///
    /// The `HRVSession` snapshot is captured here on the MainActor so the
    /// detached task doesn't reach back into main-isolated state (Swift 6
    /// strict concurrency flagged that as an error). `HRVSession` is Codable +
    /// value-semantic, so the copy is cheap and safe to move across isolation.
    private func recomputeAlpha1() async -> ([WorkoutSample]?, [WorkoutAlpha1Reanalyzer.Reading]) {
        let sessionSnapshot = session
        return await Task.detached(priority: .userInitiated) { () -> ([WorkoutSample]?, [WorkoutAlpha1Reanalyzer.Reading]) in
            let rs = WorkoutAlpha1Reanalyzer.reanalyze(session: sessionSnapshot)
            guard !rs.isEmpty, let samples = sessionSnapshot.workoutMetadata?.samples else {
                return (nil, rs)
            }
            return (WorkoutAlpha1Reanalyzer.applyReadings(rs, to: samples), rs)
        }.value
    }

    /// Write back through the shared archive, then update our own @State AND
    /// bump the archive signal — both paths, so the open sheet refreshes
    /// unconditionally and the fitness tab behind us reloads too.
    private func persistReanalyzedSamples(_ refreshedSamples: [WorkoutSample], readingCount: Int) {
        do {
            let archive = AppDependencies.current.storage.sessionArchive
            guard let updated = try Self.updateArchived(session.id, in: archive, { stored in
                stored.workoutMetadata?.samples = refreshedSamples
            }) else {
                reanalyzeError = String(localized: "Session not found in archive.", bundle: LanguageManager.appBundle)
                return
            }
            refreshedSession = updated
            collector.notifyArchiveChanged()
            debugLog("[Alpha1Reanalyze] rewrote \(readingCount) α1 readings for session \(session.id)")
        } catch {
            reanalyzeError = String(localized: "Couldn't save re-analyzed α1: \(error.localizedDescription)", bundle: LanguageManager.appBundle)
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
            // attachment shows as "flow-recovery-{sport}-{date}.png" in
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
