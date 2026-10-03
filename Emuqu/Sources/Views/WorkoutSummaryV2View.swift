import Charts
import MapKit
import SwiftUI

/// Workout summary. **The show.** Single biggest
/// competitive opening per the plan. The sequence the user sees right
/// after tapping End matters more than any other surface in the app.
///
/// Layout (top to bottom):
///   1. Sport + time-ago chip
///   2. Hero stats — distance huge (64pt), duration + pace below
///   3. Verdict pill (animates in)
///   4. Map polyline (16:9 or 16:7)
///   5. Crossed threshold line
///   6. AI Coach narrative card (forward-looking close)
///   7. How did that feel? — 5-emoji rater
///   8. Six-cell stat grid
///   9. DFA α1 chart with AT1 / AT2 reference lines
///   10. HR Recovery card
///   11. Collapsible HR / Pace / Cadence / Power charts
///   12. Elevation chart
///   13. HR Zone Distribution
///   14. EngineRoomDisclosure — Derived metrics
///   15. Splits with avg α1 column
///   16. Save / Share / Refine action group (only the actions the caller wired)
///   17. Trajectory contribution
struct WorkoutSummaryV2View: View {
    @Environment(\.dependencies) var dependencies
    let session: HRVSession
    let workout: WorkoutMetadata
    var onSave: (() -> Void)?
    var onShare: (() -> Void)?
    var onReanalyzeAlpha1: (() -> Void)?
    var onRecomputeElevation: (() -> Void)?
    var onEditStartEnd: (() -> Void)?
    var onEmailReport: (() -> Void)?

    @State private var perceivedFeeling: PerceivedFeeling?
    /// The last feeling write. Each new write waits for it, so rapid taps are
    /// saved in tap order and the stored rating matches the one shown.
    @State private var feelingWriteTask: Task<Void, Never>?
    /// Decoded route, cached. Calling `decodePolylineCoords()`
    /// TWICE per body render (both map cards) re-runs the full polyline
    /// decompression on every `@State` change — a per-render hitch on long
    /// routes. Decoded once, off-main, into here.
    @State private var routeCoords: [CLLocationCoordinate2D] = []

    enum PerceivedFeeling: String, CaseIterable {
        case terrible, hard, ok, good, great
        var emoji: String {
            switch self {
            case .terrible: "😩"
            case .hard: "😕"
            case .ok: "😐"
            case .good: "🙂"
            case .great: "🔥"
            }
        }
        var label: String {
            let bundle = LanguageManager.appBundle
            return switch self {
            case .terrible: String(localized: "Terrible", bundle: bundle)
            case .hard: String(localized: "Hard", bundle: bundle)
            case .ok: String(localized: "OK", bundle: bundle)
            case .good: String(localized: "Good", bundle: bundle)
            case .great: String(localized: "Great", bundle: bundle)
            }
        }
        /// 1–5, matching `WorkoutMetadata.workoutFeeling` persistence.
        var rating: Int {
            switch self {
            case .terrible: 1
            case .hard: 2
            case .ok: 3
            case .good: 4
            case .great: 5
            }
        }
        init?(rating: Int?) {
            switch rating {
            case 1: self = .terrible
            case 2: self = .hard
            case 3: self = .ok
            case 4: self = .good
            case 5: self = .great
            default: return nil
            }
        }
    }

    private var distanceText: String {
        guard let m = workout.distanceMeters, m > 0 else { return "—" }
        let units = UnitsPreferenceStore.current.resolved
        switch units {
        case .imperial:
            return String(format: "%.2f", locale: LanguageManager.appLocale, m / 1609.34)
        case .metric, .auto:
            return String(format: "%.2f", locale: LanguageManager.appLocale, m / 1000)
        }
    }

    private var distanceUnit: String {
        LocalizedUnit.symbol(UnitsPreferenceStore.current.resolved == .imperial ? UnitLength.miles : UnitLength.kilometers)
    }

    /// Un-paused time (see `WorkoutActiveTime`): the duration, pace and
    /// narrative all leave paused stretches out, as the recorder's clock does.
    private var activeSeconds: TimeInterval {
        let wall = (session.endDate ?? Date()).timeIntervalSince(session.startDate)
        return WorkoutActiveTime.seconds(samples: workout.samples, wallClock: wall) ?? wall
    }

    private var durationText: String {
        let secs = Int(activeSeconds)
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private var paceText: String {
        guard let m = workout.distanceMeters, m > 0 else { return "—" }
        let secs = activeSeconds
        let units = UnitsPreferenceStore.current.resolved
        let secPerUnit: Double
        switch units {
        case .imperial: secPerUnit = secs / (m / 1609.34)
        case .metric, .auto: secPerUnit = secs / (m / 1000)
        }
        let minutes = Int(secPerUnit) / 60
        let seconds = Int(secPerUnit) % 60
        return String(format: "%d:%02d / %@", minutes, seconds, distanceUnit)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                headlineSections
                routeSections
                chartSections
                detailSections
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle(Text(String(localized: "Workout summary", bundle: LanguageManager.appBundle)))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var headlineSections: some View {
        sportHeader
        heroStats
        verdictPill
        // "How did that feel?" promoted to
        // top, directly under the verdict pill, per
        // research note: this is the most important capture
        // and asking it post-scroll fails. User sees it
        // first, fills once, value persists for the rest of
        // the screen.
        feelingRater
    }

    @ViewBuilder
    private var routeSections: some View {
        mapCard
        routeByAlpha1Map
        crossedThresholdLine
        coachNarrativeCard
    }

    @ViewBuilder
    private var chartSections: some View {
        sixStatGrid
        alpha1Chart
        hrRecoveryCard
        liveSeriesChart
        elevationChart
        hrZoneDistribution
    }

    @ViewBuilder
    private var detailSections: some View {
        engineRoomSection
        splitsSection
        actionGroup
        trajectoryContribution
    }

    // MARK: - Header

    private var sportHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: workout.sport.icon)
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(AppTheme.primary)
            Text(verbatim: workout.sport.localizedName)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
            Text(verbatim: "·")
                .foregroundStyle(AppTheme.textTertiary)
            Text(verbatim: timeAgo(session.startDate))
                .scaledFont(size: 13)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private func timeAgo(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    // MARK: - Hero stats

    private var heroStats: some View {
        VStack(alignment: .leading, spacing: 6) {
            heroDistance
            heroInlineStats
        }
    }

    private var heroDistance: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: distanceText)
                .scaledFont(size: 64, weight: .bold, design: .rounded, monospacedDigit: true)
                .foregroundStyle(AppTheme.textPrimary)
                .contentTransition(.numericText())
            Text(verbatim: distanceUnit)
                .scaledFont(size: 22, weight: .medium)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var heroInlineStats: some View {
        HStack(spacing: 18) {
            statInline(label: String(localized: "Duration", bundle: LanguageManager.appBundle), value: durationText)
            statInline(label: String(localized: "Pace", bundle: LanguageManager.appBundle), value: paceText)
            // The hero row carries average HR. Pace
            // tells you "how fast"; avg HR tells you "how hard" —
            // the two complementary efforts. Computed from the
            // per-second sample stream (same source as Peak HR in
            // the grid below) so consistent.
            if let value = avgHRText() {
                statInline(label: String(localized: "Avg HR", bundle: LanguageManager.appBundle), value: value)
            }
        }
    }

    /// Workout-level average HR. Computed from the
    /// per-second sample stream — same source the Peak HR grid cell
    /// uses, so the two never disagree about which session they refer
    /// to. Returns nil when no HR samples landed (indoor session with
    /// no strap, or pre-sample-stream sessions).
    private func avgHRText() -> String? {
        guard let samples = workout.samples else { return nil }
        let hrs = samples.compactMap(\.heartRate)
        guard !hrs.isEmpty else { return nil }
        let avg = Double(hrs.reduce(0, +)) / Double(hrs.count)
        return String(localized: "\(Int(avg.rounded())) bpm", bundle: LanguageManager.appBundle)
    }

    private func statInline(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: label)
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(AppTheme.textTertiary)
            Text(verbatim: value)
                .scaledFont(size: 16, weight: .semibold, design: .rounded, monospacedDigit: true)
                .foregroundStyle(AppTheme.textPrimary)
        }
    }

    // MARK: - Verdict pill

    private var verdictPill: some View {
        let v = computeVerdict()
        return Text(verbatim: v.text)
            .scaledFont(size: 13, weight: .semibold)
            .tracking(1.5)
            .foregroundStyle(v.color)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().strokeBorder(v.color.opacity(0.6), lineWidth: 1))
    }

    private struct Verdict {
        let text: String
        let color: Color
    }

    private func computeVerdict() -> Verdict {
        let snap = workout.analysisSnapshot
        let band = snap?.dominantAlpha1BandRaw
        let dominantHRZone = snap?.dominantHRZone ?? 0
        if band == "easy" || (snap?.alpha1Mean ?? 0) >= 0.75 {
            return easyVerdict(snap)
        }
        if band == "threshold" || dominantHRZone == 4 {
            return Verdict(text: String(localized: "THRESHOLD WORK", bundle: LanguageManager.appBundle), color: AppTheme.wongCaution)
        }
        if band == "hard" || dominantHRZone >= 5 {
            return Verdict(text: String(localized: "HARD · ABOVE LACTATE THRESHOLD", bundle: LanguageManager.appBundle), color: AppTheme.wongAttention)
        }
        return Verdict(text: String(localized: "MIXED · MOSTLY EASY", bundle: LanguageManager.appBundle), color: AppTheme.wongGood)
    }

    /// Mean α1 ≥ 0.75 alone stamps "BELOW AEROBIC THRESHOLD" on a session
    /// whose own narrative says "crossed aerobic threshold … 2 min above
    /// anaerobic threshold", so the pill checks the time the session
    /// actually spent past AT1 and downgrades to "mostly easy".
    private func easyVerdict(_ snap: WorkoutAnalysisSnapshot?) -> Verdict {
        let pastAT1 = (snap?.secondsBetweenAT1AT2 ?? 0) + (snap?.secondsAboveAT2 ?? 0)
        if pastAT1 >= 60 {
            return Verdict(text: String(localized: "MIXED · MOSTLY EASY", bundle: LanguageManager.appBundle), color: AppTheme.wongGood)
        }
        if workout.sport == .walk || workout.sport == .hike {
            return Verdict(text: String(localized: "RECOVERY · ACTIVE WALK", bundle: LanguageManager.appBundle), color: AppTheme.wongOptimal)
        }
        return Verdict(text: String(localized: "EASY · BELOW AEROBIC THRESHOLD", bundle: LanguageManager.appBundle), color: AppTheme.wongOptimal)
    }

    // MARK: - Map

    @ViewBuilder
    private var mapCard: some View {
        let coords = routeCoords
        if !coords.isEmpty {
            MapPolylineView(coords: coords)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    /// Route by α1 band. Second map below the main
    /// polyline showing the same route colored by aerobic intensity:
    /// green (α1 ≥ 0.75 — below aerobic threshold), amber (0.5–0.75),
    /// red (< 0.5 — above lactate threshold). Hidden when no α1
    /// samples landed (e.g. quick walks, indoor sports without strap).
    @ViewBuilder
    private var routeByAlpha1Map: some View {
        let coords = routeCoords
        let alphaPoints = sampleAlpha1Series()
        if !coords.isEmpty, !alphaPoints.isEmpty {
            routeAlpha1Card(coords: coords, alphaPoints: alphaPoints)
        }
    }

    private func routeAlpha1Card(
        coords: [CLLocationCoordinate2D],
        alphaPoints: [(progress: Double, alpha: Double)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading(String(localized: "Route by α1 zone", bundle: LanguageManager.appBundle))
            ColoredRouteMapView(coords: coords, alpha1Series: alphaPoints)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            routeAlpha1Legend
        }
    }

    private var routeAlpha1Legend: some View {
        HStack(spacing: 14) {
            legendDot(color: AppTheme.wongOptimal, label: String(localized: "Easy (α1 ≥ 0.75)", bundle: LanguageManager.appBundle))
            legendDot(color: AppTheme.wongCaution, label: String(localized: "Threshold", bundle: LanguageManager.appBundle))
            legendDot(color: AppTheme.wongAttention, label: String(localized: "Hard", bundle: LanguageManager.appBundle))
            Spacer()
        }
        .scaledFont(size: 11, weight: .medium)
        .foregroundStyle(AppTheme.textSecondary)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(verbatim: label)
        }
    }

    /// Returns α1 samples paired with their fractional offset along
    /// the workout (0.0 = start, 1.0 = end) so the colored polyline
    /// renderer can spatially-align α1 with route coords without
    /// re-deriving timestamps.
    private func sampleAlpha1Series() -> [(progress: Double, alpha: Double)] {
        guard let samples = workout.samples, !samples.isEmpty else { return [] }
        let totalSec = max(1, samples.last?.offsetSec ?? 1)
        return samples.compactMap { s -> (Double, Double)? in
            guard let a = s.alpha1 else { return nil }
            return (Double(s.offsetSec) / Double(totalSec), a)
        }
    }

    // MARK: - Crossed threshold line

    @ViewBuilder
    private var crossedThresholdLine: some View {
        if let crossingSec = workout.analysisSnapshot?.firstAT1CrossingOffsetSec,
           let crossingHR = workout.analysisSnapshot?.firstAT1CrossingHR {
            let easyMin = (workout.analysisSnapshot?.secondsBelowAT1 ?? 0) / 60
            let thresholdMin = (workout.analysisSnapshot?.secondsBetweenAT1AT2 ?? 0) / 60
            let mins = crossingSec / 60
            let secs = crossingSec % 60
            Text(String(localized: "Crossed aerobic threshold at \(mins):\(String(format: "%02d", secs)) at \(crossingHR) bpm. \(thresholdMin) min at threshold, \(easyMin) min easy.", bundle: LanguageManager.appBundle))
                .scaledFont(size: 13)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(AppTheme.sectionTint)
                )
        }
    }

    // MARK: - AI Coach narrative

    private var coachNarrativeCard: some View {
        let narrative = workout.analysisSnapshot?.howYouDidNarrative
            ?? workout.analysisSnapshot?.heroNarrative
            ?? defaultNarrative()
        return VStack(alignment: .leading, spacing: 10) {
            sectionHeading(String(localized: "How you did", bundle: LanguageManager.appBundle))
            NarrativeCard(text: narrative, accent: computeVerdict().color)
        }
    }

    private func defaultNarrative() -> String {
        let snap = workout.analysisSnapshot
        let durationMin = Int(activeSeconds) / 60
        let easyPct: Int = {
            guard let easy = snap?.secondsBelowAT1, durationMin > 0 else { return 0 }
            return Int(Double(easy) / Double(durationMin * 60) * 100)
        }()
        return String(localized: "You spent \(durationMin) minutes on this \(workout.sport.localizedName.lowercased()), \(easyPct)% of it below the aerobic threshold. Tomorrow's recovery score will tell you how much this session cost.", bundle: LanguageManager.appBundle)
    }

    // MARK: - Feeling rater

    private var feelingRater: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(String(localized: "How did that feel?", bundle: LanguageManager.appBundle))
            feelingButtons
        }
        .onAppear { seedPerceivedFeeling() }
        .task { await decodeRouteCoords() }
    }

    private var feelingButtons: some View {
        HStack(spacing: 10) {
            ForEach(PerceivedFeeling.allCases, id: \.self) { feeling in
                feelingButton(feeling)
            }
        }
    }

    private func feelingButton(_ feeling: PerceivedFeeling) -> some View {
        Button {
            rate(feeling)
        } label: {
            feelingButtonLabel(feeling)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(feeling.label)
        .accessibilityAddTraits(perceivedFeeling == feeling ? .isSelected : [])
    }

    private func feelingButtonLabel(_ feeling: PerceivedFeeling) -> some View {
        VStack(spacing: 4) {
            Text(verbatim: feeling.emoji)
                .scaledFont(size: 28)
            Text(verbatim: feeling.label)
                .scaledFont(size: 11)
                .foregroundStyle(perceivedFeeling == feeling ? AppTheme.textPrimary : AppTheme.textTertiary)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(perceivedFeeling == feeling ? AppTheme.primary.opacity(0.15) : Color.clear)
        )
    }

    private func rate(_ feeling: PerceivedFeeling) {
        perceivedFeeling = feeling
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Actually PERSIST the rating: writing only to @State
        // silently discards it on dismiss (data loss). Mirrors
        // FitnessPostSummaryView.saveWorkoutFeeling.
        persistFeeling(feeling)
    }

    private func seedPerceivedFeeling() {
        // Seed from the already-saved rating so re-opening the detail
        // shows the user's prior choice instead of an empty rater.
        if perceivedFeeling == nil {
            perceivedFeeling = PerceivedFeeling(rating: workout.workoutFeeling)
        }
    }

    private func decodeRouteCoords() async {
        // Decode the route polyline once, off-main, instead of twice per
        // body render on the main thread.
        guard routeCoords.isEmpty, let data = workout.gpsPolyline else { return }
        let start = session.startDate
        let duration = (session.endDate ?? Date()).timeIntervalSince(session.startDate)
        let decoded = await Task.detached {
            GPXExporter.decode(polyline: data, startDate: start, duration: duration).map(\.coordinate)
        }.value
        routeCoords = decoded
    }

    /// Persist the workout feeling to the archived session (off-main, like
    /// FitnessPostSummaryView.saveWorkoutFeeling). The detail rater is the
    /// only place a past workout's feeling can be set/changed.
    private func persistFeeling(_ feeling: PerceivedFeeling) {
        var archive: SessionArchive { dependencies.storage.sessionArchive }
        let id = session.id
        let rating = feeling.rating
        let previous = feelingWriteTask
        feelingWriteTask = Task.detached(priority: .userInitiated) {
            await previous?.value
            Self.writeFeeling(rating, to: id, archive: archive)
        }
    }

    nonisolated private static func writeFeeling(_ rating: Int, to id: UUID, archive: SessionArchive) {
        do {
            guard var s = try archive.retrieve(id) else { return }
            s.workoutMetadata?.workoutFeeling = rating
            _ = try archive.archive(s, skipSameNightMerge: false, requestingReupload: true)
        } catch {
            debugLog("[WorkoutSummaryV2] feeling save failed: \(error)", level: .warning)
        }
    }

    // MARK: - Six-cell grid

    private var sixStatGrid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Array(statCells.enumerated()), id: \.offset) { _, cell in
                gridCell(label: cell.0, value: cell.1)
            }
        }
    }

    // Primary load tile leads with powerTSS when a
    // power meter contributed, else falls back through hrTSS /
    // luciaTRIMP via `preferredTrainingLoad`. Cell label flips
    // between "LOAD" (TSS scale) and "TRIMP" (Banister scale)
    // so the number's units are unambiguous.
    private var statCells: [(String, String)] {
        let snap = workout.analysisSnapshot
        let preferred = workout.preferredTrainingLoad
        let loadLabel: String = {
            switch preferred?.source {
            case .power, .hr, .mets: return String(localized: "LOAD", bundle: LanguageManager.appBundle)
            case .banister, .routeHistory, .none: return String(localized: "TRIMP", bundle: LanguageManager.appBundle)
            }
        }()
        let loadValue = preferred.map { String(Int($0.value.rounded())) } ?? "—"
        return [
            (String(localized: "Peak HR", bundle: LanguageManager.appBundle), peakHRText()),
            (String(localized: "Elev gain", bundle: LanguageManager.appBundle), elevGainText()),
            (loadLabel, loadValue),
            (String(localized: "hrTSS", bundle: LanguageManager.appBundle), workout.hrTSS.map { String(Int($0.rounded())) } ?? "—"),
            (String(localized: "α1 mean", bundle: LanguageManager.appBundle), snap?.alpha1Mean.map { String(format: "%.2f", locale: LanguageManager.appLocale, $0) } ?? "—"),
            (String(localized: "Calories", bundle: LanguageManager.appBundle), snap?.estimatedTotalCalories.map { String(Int($0.rounded())) } ?? "—")
        ]
    }

    func gridCell(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(verbatim: label)
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(AppTheme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            Text(verbatim: value)
                .scaledFont(size: 18, weight: .semibold, design: .rounded, monospacedDigit: true)
                .foregroundStyle(AppTheme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.cardBackground)
        )
    }

    private func peakHRText() -> String {
        guard let samples = workout.samples else { return "—" }
        let peak = samples.compactMap(\.heartRate).max()
        return peak.map { "\($0)" } ?? "—"
    }

    private func elevGainText() -> String {
        guard let m = workout.elevationGainMeters else { return "—" }
        let units = UnitsPreferenceStore.current.resolved
        if units == .imperial {
            return LocalizedUnit.format((m * UnitConstants.feetPerMeter).rounded(), UnitLength.feet)
        }
        return LocalizedUnit.format(m.rounded(), UnitLength.meters)
    }
}
