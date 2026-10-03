import Charts
import MapKit
import SwiftUI

// The chart and detail half of the workout summary, split out of
// `WorkoutSummaryV2View.swift` to keep that struct's body under the
// 500-line limit. Everything above the α1 chart — header, hero stats,
// verdict, map, narrative, feeling rater and stat grid — stays behind.
//
// Members here are not `private`, because
// Swift's `private` does not reach across files.

extension WorkoutSummaryV2View {
    // MARK: - α1 chart

    var alpha1Chart: some View {
        ChartCard(title: String(localized: "DFA α1", bundle: LanguageManager.appBundle), unitLabel: String(localized: "AT1 = 0.75, AT2 = 0.50", bundle: LanguageManager.appBundle)) {
            let pts = buildAlpha1Series()
            alpha1ChartBody(pts)
        }
    }

    @ViewBuilder
    private func alpha1ChartBody(_ pts: [Alpha1Point]) -> some View {
        if pts.isEmpty {
            alpha1EmptyState
        } else {
            alpha1Plot(pts)
        }
    }

    private func alpha1Plot(_ pts: [Alpha1Point]) -> some View {
        Chart {
            RuleMark(y: .value("AT1", 0.75))
                .foregroundStyle(AppTheme.wongOptimal.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            RuleMark(y: .value("AT2", 0.50))
                .foregroundStyle(AppTheme.wongAttention.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            ForEach(pts) { p in
                LineMark(
                    x: .value("Time", p.offsetMin),
                    y: .value("α1", p.alpha1)
                )
                .foregroundStyle(AppTheme.primary)
            }
        }
        .chartYScale(domain: 0...1.5)
    }

    private var alpha1EmptyState: some View {
        EmptyState(
            glyph: "waveform.path.ecg",
            headline: String(localized: "No α1 series", bundle: LanguageManager.appBundle),
            message: String(localized: "α1 needs an HR strap with continuous beat-by-beat data.", bundle: LanguageManager.appBundle)
        )
    }

    struct Alpha1Point: Identifiable {
        let id = UUID()
        let offsetMin: Double
        let alpha1: Double
    }

    func buildAlpha1Series() -> [Alpha1Point] {
        guard let samples = workout.samples else { return [] }
        return samples.compactMap { s -> Alpha1Point? in
            guard let a = s.alpha1 else { return nil }
            return Alpha1Point(offsetMin: Double(s.offsetSec) / 60, alpha1: a)
        }
    }

    // MARK: - HR Recovery card

    @ViewBuilder
    var hrRecoveryCard: some View {
        if let hrr = workout.hrrSamples, !hrr.isEmpty {
            hrRecoveryBody(hrr)
        }
    }

    private func hrRecoveryBody(_ hrr: [HRRSample]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(String(localized: "Heart-rate recovery", bundle: LanguageManager.appBundle))
            hrRecoveryCells(hrr)
            Text(verbatim: hrrNarrative(samples: hrr))
                .scaledFont(size: 13)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func hrRecoveryCells(_ hrr: [HRRSample]) -> some View {
        HStack(spacing: 10) {
            if let peak = hrr.first?.peakHR {
                gridCell(label: String(localized: "Peak HR", bundle: LanguageManager.appBundle), value: "\(peak)")
            }
            // Same sample choice (provenance-preferring, ±10 s / ±15 s) as the
            // post-workout HRR card, so both screens show the same drop.
            if let oneMin = hrr.bestAtOneMinute {
                gridCell(label: String(localized: "1-min drop", bundle: LanguageManager.appBundle), value: String(localized: "\(oneMin.drop) bpm", bundle: LanguageManager.appBundle))
            }
            if let twoMin = hrr.bestAtTwoMinutes {
                gridCell(label: String(localized: "2-min drop", bundle: LanguageManager.appBundle), value: String(localized: "\(twoMin.drop) bpm", bundle: LanguageManager.appBundle))
            }
        }
    }

    /// One reading of the 1-minute drop, shared with the post-workout card.
    func hrrNarrative(samples: [HRRSample]) -> String {
        guard let oneMin = samples.bestAtOneMinute else {
            return String(localized: "Heart-rate recovery samples captured. Bigger 1-min drop = stronger parasympathetic reactivation.", bundle: LanguageManager.appBundle)
        }
        return WorkoutStatsCards.hrrNarrative(drop: oneMin.drop)
    }

    // MARK: - Live series chart (HR / Pace / Cadence)

    var liveSeriesChart: some View {
        ChartCard(title: String(localized: "Heart rate over time", bundle: LanguageManager.appBundle), unitLabel: String(localized: "bpm", bundle: LanguageManager.appBundle)) {
            let pts = buildHRSeries()
            liveSeriesBody(pts)
        }
    }

    @ViewBuilder
    private func liveSeriesBody(_ pts: [HRSeriesPoint]) -> some View {
        if pts.isEmpty {
            liveSeriesEmptyState
        } else {
            liveSeriesPlot(pts)
        }
    }

    private func liveSeriesPlot(_ pts: [HRSeriesPoint]) -> some View {
        Chart {
            ForEach(pts) { p in
                LineMark(
                    x: .value("Min", p.offsetMin),
                    y: .value("HR", p.hr)
                )
                .foregroundStyle(AppTheme.wongAttention)
            }
        }
    }

    private var liveSeriesEmptyState: some View {
        EmptyState(
            glyph: "heart.fill",
            headline: String(localized: "No HR series", bundle: LanguageManager.appBundle),
            message: String(localized: "HR data isn't available for this workout — TRIMP and zone analysis fall back to estimates.", bundle: LanguageManager.appBundle)
        )
    }

    struct HRSeriesPoint: Identifiable {
        let id = UUID()
        let offsetMin: Double
        let hr: Int
    }

    func buildHRSeries() -> [HRSeriesPoint] {
        guard let samples = workout.samples else { return [] }
        return samples.compactMap { s -> HRSeriesPoint? in
            guard let hr = s.heartRate else { return nil }
            return HRSeriesPoint(offsetMin: Double(s.offsetSec) / 60, hr: hr)
        }
    }

    // MARK: - Elevation chart

    /// Standalone elevation chart. Sourced from sample altitude
    /// (CMAltimeter when available, GPS altitude with noise gate
    /// otherwise — same series the live workout view shows). Hidden
    /// for indoor sports without altitude data.
    @ViewBuilder
    var elevationChart: some View {
        let elevPts = buildElevationSeries()
        if !elevPts.isEmpty {
            ChartCard(title: String(localized: "Elevation", bundle: LanguageManager.appBundle), unitLabel: elevationUnitLabel) {
                elevationPlot(elevPts)
            }
        }
    }

    private func elevationPlot(_ elevPts: [ElevationPoint]) -> some View {
        Chart {
            ForEach(elevPts) { p in
                AreaMark(
                    x: .value("Min", p.offsetMin),
                    y: .value("Elev", p.value)
                )
                .foregroundStyle(AppTheme.primary.opacity(0.18))
                LineMark(
                    x: .value("Min", p.offsetMin),
                    y: .value("Elev", p.value)
                )
                .foregroundStyle(AppTheme.primary)
            }
        }
    }

    struct ElevationPoint: Identifiable {
        let id = UUID()
        let offsetMin: Double
        let value: Double  // already in display unit (m or ft)
    }

    var elevationUnitLabel: String {
        LocalizedUnit.symbol(UnitsPreferenceStore.current.resolved == .imperial ? UnitLength.feet : UnitLength.meters)
    }

    func buildElevationSeries() -> [ElevationPoint] {
        guard let samples = workout.samples else { return [] }
        let toImperial = UnitsPreferenceStore.current.resolved == .imperial
        return samples.compactMap { s -> ElevationPoint? in
            guard let alt = s.altitudeMeters else { return nil }
            let display = toImperial ? alt * UnitConstants.feetPerMeter : alt
            return ElevationPoint(offsetMin: Double(s.offsetSec) / 60, value: display)
        }
    }

    // MARK: - HR zone distribution

    @ViewBuilder
    var hrZoneDistribution: some View {
        if let zones = workout.analysisSnapshot?.hrZoneSeconds, !zones.isEmpty {
            hrZoneBody(zones)
        }
    }

    private func hrZoneBody(_ zones: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(String(localized: "HR zone distribution", bundle: LanguageManager.appBundle))
            let total = max(1, zones.reduce(0, +))
            hrZoneBars(zones, total: total)
        }
    }

    private func hrZoneBars(_ zones: [Int], total: Int) -> some View {
        VStack(spacing: 6) {
            hrZoneRows(zones, total: total)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppTheme.cardBackground)
        )
    }

    private func hrZoneRows(_ zones: [Int], total: Int) -> some View {
        ForEach(0..<min(zones.count, 5), id: \.self) { i in
            let pct = Double(zones[i]) / Double(total) * 100
            hrZoneRow(zone: i + 1, seconds: zones[i], pct: pct)
        }
    }

    private func hrZoneRow(zone: Int, seconds: Int, pct: Double) -> some View {
        HStack {
            Text(verbatim: "Z\(zone)")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(zoneColor(zone: zone))
                .frame(width: 30, alignment: .leading)
            hrZoneBar(zone: zone, pct: pct)
            Text(verbatim: LocalizedDuration.minutes(seconds / 60))
                .scaledFont(size: 11, monospacedDigit: true)
                .foregroundStyle(AppTheme.textTertiary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private func hrZoneBar(zone: Int, pct: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppTheme.textTertiary.opacity(0.1))
                RoundedRectangle(cornerRadius: 4)
                    .fill(zoneColor(zone: zone))
                    .frame(width: geo.size.width * (pct / 100))
            }
        }
        .frame(height: 14)
    }

    func zoneColor(zone: Int) -> Color {
        switch zone {
        case 1: AppTheme.wongGood
        case 2: AppTheme.wongOptimal
        case 3: AppTheme.wongCaution
        case 4: AppTheme.wongAttention.opacity(0.8)
        case 5: AppTheme.wongAttention
        default: AppTheme.textTertiary
        }
    }

    // MARK: - Engine room

    var engineRoomSection: some View {
        EngineRoomDisclosure(
            title: String(localized: "Derived metrics", bundle: LanguageManager.appBundle),
            memoryKey: "engineRoom.workoutSummary.\(session.id.uuidString)"
        ) {
            engineRoomRows
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(AppTheme.sectionTint)
                )
        }
    }

    private var engineRoomRows: some View {
        let snap = workout.analysisSnapshot
        return VStack(alignment: .leading, spacing: 8) {
            detailRow(String(localized: "Moving time", bundle: LanguageManager.appBundle), value: snap?.movingTimeSec.map { formatSec($0) } ?? "—")
            detailRow(String(localized: "Moving %", bundle: LanguageManager.appBundle), value: snap?.movingTimePercent.map { "\($0)%" } ?? "—")
            detailRow(String(localized: "VAM", bundle: LanguageManager.appBundle), value: snap?.vamMetersPerHour.map { LocalizedUnit.format($0.rounded(), UnitLength.meters) + "/h" } ?? "—")
            detailRow(String(localized: "Calorie rate", bundle: LanguageManager.appBundle), value: snap?.calorieRatePerHour.map { LocalizedUnit.format($0.rounded(), UnitEnergy.kilocalories) + "/h" } ?? "—")
            detailRow(String(localized: "Stride length", bundle: LanguageManager.appBundle), value: snap?.strideLengthMeters.map { LocalizedUnit.format($0, UnitLength.meters, fractionDigits: 2) } ?? "—")
            detailRow(String(localized: "Pa:Hr decoupling", bundle: LanguageManager.appBundle), value: workout.decouplingPercent.map { String(format: "%+.1f%%", locale: LanguageManager.appLocale, $0) } ?? "—")
            detailRow(String(localized: "Efficiency factor", bundle: LanguageManager.appBundle), value: workout.efficiencyFactor.map { String(format: "%.3f", locale: LanguageManager.appLocale, $0) } ?? "—")
            detailRow(String(localized: "Grade-adj pace", bundle: LanguageManager.appBundle), value: snap?.gradeAdjustedPaceSecPerKm.map { paceFormat(secPerKm: $0) } ?? "—")
        }
    }

    func detailRow(_ label: String, value: String) -> some View {
        DetailLabelValueRow(label: label, value: value)
    }

    func formatSec(_ secs: Int) -> String {
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    func paceFormat(secPerKm: Double) -> String {
        let units = UnitsPreferenceStore.current.resolved
        let secPerUnit = units == .imperial ? secPerKm * 1.609 : secPerKm
        let min = Int(secPerUnit) / 60
        let sec = Int(secPerUnit) % 60
        return String(format: "%d:%02d", min, sec)
    }

    // MARK: - Splits

    /// Splits row format: index | pace | HR | avg α1.
    /// α1 is the third intensity dimension that pace+HR alone can't
    /// catch — a split that's "easy by HR" but α1 < 0.75 is actually
    /// crossing aerobic threshold (parasympathetic withdrawal). Show
    /// it next to HR so the user reads both at a glance.
    @ViewBuilder
    var splitsSection: some View {
        if let splits = workout.splits, splits.count > 1 {
            splitsBody(splits)
        }
    }

    private func splitsBody(_ splits: [Split]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(String(localized: "Splits", bundle: LanguageManager.appBundle))
            splitRows(splits)
        }
    }

    private func splitRows(_ splits: [Split]) -> some View {
        VStack(spacing: 6) {
            splitRowList(splits)
        }
    }

    private func splitRowList(_ splits: [Split]) -> some View {
        ForEach(splits, id: \.index) { split in
            splitRow(split)
        }
    }

    private func splitRow(_ split: Split) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: "\(split.index)")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(AppTheme.textTertiary)
                .frame(width: 24, alignment: .leading)
            Text(verbatim: split.averagePaceSecPerKm.map { paceFormat(secPerKm: $0) } ?? "—")
                .scaledFont(size: 14, weight: .medium, monospacedDigit: true)
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            splitAlphaLabel(split)
            Text(verbatim: split.averageHR.map { "\(Int($0.rounded())) bpm" } ?? "—")
                .scaledFont(size: 13, monospacedDigit: true)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.cardBackground)
        )
    }

    @ViewBuilder
    private func splitAlphaLabel(_ split: Split) -> some View {
        if let alpha = split.averageAlpha1 {
            Text(verbatim: String(format: "α1 %.2f", locale: LanguageManager.appLocale, alpha))
                .scaledFont(size: 12, weight: .medium, monospacedDigit: true)
                .foregroundStyle(alpha >= 0.75 ? AppTheme.wongOptimal : AppTheme.wongCaution)
        }
    }

    // MARK: - Action group

    /// Each control appears only when its caller wired an action: a summary
    /// opened from History passes none, and a button that does nothing (or a
    /// Refine menu with no items) is worse than no button.
    @ViewBuilder
    var actionGroup: some View {
        if onSave != nil || onShare != nil || hasRefineActions {
            HStack(spacing: 8) {
                saveActionButton
                shareActionButton
                refineMenuIfAny
            }
        }
    }

    @ViewBuilder
    private var saveActionButton: some View {
        if let onSave {
            actionButton(label: String(localized: "Save", bundle: LanguageManager.appBundle), glyph: "checkmark.circle.fill", action: onSave)
        }
    }

    @ViewBuilder
    private var shareActionButton: some View {
        if let onShare {
            actionButton(label: String(localized: "Share", bundle: LanguageManager.appBundle), glyph: "square.and.arrow.up", action: onShare)
        }
    }

    @ViewBuilder
    private var refineMenuIfAny: some View {
        if hasRefineActions { refineMenu }
    }

    private var hasRefineActions: Bool {
        onReanalyzeAlpha1 != nil || onRecomputeElevation != nil || onEditStartEnd != nil || onEmailReport != nil
    }

    func actionButton(label: String, glyph: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: glyph)
                    .scaledFont(size: 13, weight: .semibold)
                Text(verbatim: label)
                    .scaledFont(size: 14, weight: .semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Capsule().fill(AppTheme.primary.opacity(0.15)))
            .foregroundStyle(AppTheme.primary)
        }
        .buttonStyle(.plain)
    }

    var refineMenu: some View {
        Menu {
            reanalyzeAlpha1Item
            recomputeElevationItem
            editStartEndItem
            emailReportItem
        } label: {
            refineMenuLabel
        }
    }

    @ViewBuilder
    private var emailReportItem: some View {
        if let onEmailReport {
            Button { onEmailReport() } label: {
                Label(String(localized: "Email coach report", bundle: LanguageManager.appBundle), systemImage: "envelope")
            }
        }
    }

    @ViewBuilder
    private var editStartEndItem: some View {
        if let onEditStartEnd {
            Button { onEditStartEnd() } label: {
                Label(String(localized: "Edit start / end", bundle: LanguageManager.appBundle), systemImage: "scissors")
            }
        }
    }

    @ViewBuilder
    private var recomputeElevationItem: some View {
        if let onRecomputeElevation {
            Button { onRecomputeElevation() } label: {
                Label(String(localized: "Recompute elevation", bundle: LanguageManager.appBundle), systemImage: "mountain.2")
            }
        }
    }

    @ViewBuilder
    private var reanalyzeAlpha1Item: some View {
        if let onReanalyzeAlpha1 {
            Button { onReanalyzeAlpha1() } label: {
                Label(String(localized: "Re-analyse α1", bundle: LanguageManager.appBundle), systemImage: "waveform.path")
            }
        }
    }

    private var refineMenuLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "wrench.adjustable")
                .scaledFont(size: 13, weight: .semibold)
            Text(String(localized: "Refine", bundle: LanguageManager.appBundle))
                .scaledFont(size: 14, weight: .semibold)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Capsule().fill(AppTheme.primary.opacity(0.15)))
        .foregroundStyle(AppTheme.primary)
    }

    // MARK: - Trajectory contribution

    @ViewBuilder
    var trajectoryContribution: some View {
        // Use the most accurate available load number,
        // not the HR-only `luciaTRIMP`. powerTSS wins when present.
        let preferred = workout.preferredTrainingLoad
        let trimp = preferred?.value ?? 0
        let label = loadSourceLabel(preferred?.source)
        if trimp > 0 {
            HStack(spacing: 8) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundStyle(AppTheme.primary)
                Text(String(localized: "\(label) \(Int(trimp.rounded())) added to your training load.", bundle: LanguageManager.appBundle))
                    .scaledFont(size: 13)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(AppTheme.sectionTint)
            )
        }
    }

    /// Power and metabolic estimates are a load, not a TRIMP; naming them
    /// "TRIMP" was the one place the summary contradicted the coach tab.
    private func loadSourceLabel(_ source: WorkoutMetadata.TrainingLoadSource?) -> String {
        switch source {
        case .power, .hr, .mets: return String(localized: "Load", bundle: LanguageManager.appBundle)
        case .banister, .routeHistory, .none: return String(localized: "TRIMP", bundle: LanguageManager.appBundle)
        }
    }

    // MARK: - Heading

    func sectionHeading(_ text: String) -> some View {
        Text(verbatim: text)
            .scaledFont(size: 13, weight: .semibold)
            .detailSectionHeadingStyle()
    }
}
