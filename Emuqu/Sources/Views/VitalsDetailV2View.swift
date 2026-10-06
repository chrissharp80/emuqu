import Charts
import SwiftUI

/// Vitals detail: the 15% Vitals component of the Recovery Score, surfaced
/// as a first-class concept.
///
/// Layout (top to bottom):
///   1. Title "Vitals"
///   2. Status banner — Normal / Watch / Elevated + one-line summary
///   3. 4 expandable rows: Resting HR, Respiratory rate, Wrist temp, SpO₂
///   4. 30-day trend chart — overnight sleep HR and respiratory rate
///   5. "Why vitals matter" card
struct VitalsDetailV2View: View {
    let vitals: RecoveryVitals?
    let recentSessions: [HRVSession]
    let temperatureUnit: TemperatureUnit

    @Environment(RRCollector.self) private var collector
    @State private var expandedRow: Row?
    /// Late-arriving HealthKit vitals (resp rate / temp / SpO₂ are
    /// written minutes-to-hours after sleep ends — so the snapshot
    /// frozen at session acceptance is often missing them). Refreshed
    /// on appear and merged with the passed-in `vitals`.
    @State private var refreshedVitals: RecoveryVitals?

    enum Row: Hashable {
        case rhr, respRate, temp, spo2
    }

    /// Per-field merge with an authoritative override for sleep HR.
    ///
    /// **Sleep-HR priority:** ALWAYS prefer the
    /// analysis-window meanHR from the most recent session. That value
    /// is the strap's nocturnal mean during the SELECTED window — same
    /// physiology `BaselineTracker.meanHRBaseline` is built from, so
    /// the user's deviation read is apples-to-apples. Older sessions
    /// whose `vitalsSnapshot.restingHeartRate` was frozen with Apple's
    /// daytime RHR (before the strap-override path landed) MUST be
    /// overridden here at view time, otherwise the row keeps reading
    /// 66 bpm even when the real nocturnal mean is ~50.
    ///
    /// Other fields just merge fresh ↔ stored; first non-nil wins. The stored
    /// vitals come from the same night as the heart rate, so the banner
    /// never judges two nights together; the passed-in `vitals` stand in
    /// only when there is no overnight reading at all.
    private var effectiveVitals: RecoveryVitals? {
        let stored = latestOvernight.map(\.vitalsSnapshot) ?? vitals
        let fresh = refreshedVitals
        // Strap-derived nocturnal mean from the latest session's analysis
        // window. Wins over both stored and fresh (Apple) RHR samples.
        let strapHR = latestOvernight?.analysisResult?.timeDomain.meanHR
        let mergedRHR = strapHR ?? stored?.restingHeartRate ?? fresh?.restingHeartRate
        // If we have neither fresh nor stored, return nil so the
        // empty-state copy fires.
        if fresh == nil && stored == nil {
            return mergedRHR.map(Self.heartRateOnlyVitals)
        }
        return RecoveryVitals(
            respiratoryRate: fresh?.respiratoryRate ?? stored?.respiratoryRate,
            respiratoryRateBaseline: fresh?.respiratoryRateBaseline ?? stored?.respiratoryRateBaseline,
            oxygenSaturation: fresh?.oxygenSaturation ?? stored?.oxygenSaturation,
            oxygenSaturationMin: fresh?.oxygenSaturationMin ?? stored?.oxygenSaturationMin,
            wristTemperature: fresh?.wristTemperature ?? stored?.wristTemperature,
            wristTemperatureBaseline: fresh?.wristTemperatureBaseline ?? stored?.wristTemperatureBaseline,
            restingHeartRate: mergedRHR
        )
    }

    /// The strap gave us a nocturnal mean but HealthKit has nothing else —
    /// show the heart rate alone rather than an empty card.
    private static func heartRateOnlyVitals(_ restingHeartRate: Double) -> RecoveryVitals {
        RecoveryVitals(
            respiratoryRate: nil, respiratoryRateBaseline: nil,
            oxygenSaturation: nil, oxygenSaturationMin: nil,
            wristTemperature: nil, wristTemperatureBaseline: nil,
            restingHeartRate: restingHeartRate
        )
    }

    /// The newest overnight reading. `recentSessions` also holds workouts and
    /// quick readings, whose mean HR is not a sleep heart rate.
    private var latestOvernight: HRVSession? {
        DashboardSessionPolicy.latestOvernightComplete(in: recentSessions, calendar: .current)
    }

    private var status: VitalsBannerStatus {
        guard let v = effectiveVitals, !v.isEmpty else { return .noData }
        switch v.status {
        case .normal: return .normal
        case .elevated: return .watch
        case .warning: return .elevated
        }
    }

    enum VitalsBannerStatus {
        case normal, watch, elevated, noData

        var word: String {
            switch self {
            case .normal: String(localized: "Normal", bundle: LanguageManager.appBundle)
            case .watch: String(localized: "Watch", bundle: LanguageManager.appBundle)
            case .elevated: String(localized: "Elevated", bundle: LanguageManager.appBundle)
            case .noData: String(localized: "No data", bundle: LanguageManager.appBundle)
            }
        }

        var glyph: String {
            switch self {
            case .normal: "checkmark.seal.fill"
            case .watch: "exclamationmark.circle.fill"
            case .elevated: "exclamationmark.triangle.fill"
            case .noData: "circle.dashed"
            }
        }

        @MainActor var color: Color {
            switch self {
            case .normal: AppTheme.wongOptimal
            case .watch: AppTheme.wongCaution
            case .elevated: AppTheme.wongAttention
            case .noData: AppTheme.textTertiary
            }
        }

        // One line per status, shown under the banner word.
        var summary: String {
            switch self {
            case .normal: String(localized: "All vitals within your usual range.", bundle: LanguageManager.appBundle)
            // "Outside", not "above": a low SpO₂ alone also lands here.
            case .watch: String(localized: "One vital is outside your usual range. Worth noting.", bundle: LanguageManager.appBundle)
            case .elevated: String(localized: "Multiple vitals are above your baseline. Common causes are a hard week, short sleep, alcohol or a warm room, and sometimes the start of an illness.", bundle: LanguageManager.appBundle)
            case .noData: String(localized: "No vitals data yet. Apple Watch overnight gives the most signal.", bundle: LanguageManager.appBundle)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusBanner
                rowsSection
                trendChart
                whyCard
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle(Text(String(localized: "Vitals", bundle: LanguageManager.appBundle)))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: latestOvernight?.id) {
            await refreshVitals()
        }
    }

    /// Re-pull vitals from HealthKit on appear. Apple writes overnight
    /// vitals (resp rate / SpO₂ / wrist temp) minutes-to-hours AFTER
    /// sleep ends, so the snapshot frozen at acceptance frequently
    /// misses them. Doing the fetch here lets older sessions display
    /// correctly without requiring a re-acceptance pass.
    @MainActor
    private func refreshVitals() async {
        guard let latest = latestOvernight else { return }
        let referenceDate = latest.endDate ?? latest.startDate
        let strapHR = latest.analysisResult?.timeDomain.meanHR
        let fresh = await collector.healthKit
            .fetchRecoveryVitals(relativeTo: referenceDate)
            .withStrapNocturnalRHR(strapHR)
        if !fresh.isEmpty {
            refreshedVitals = fresh
        }
    }

    // MARK: - Banner

    private var statusBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status.glyph)
                .scaledFont(size: 22, weight: .semibold)
                .foregroundStyle(status.color)
                .frame(width: 28, height: 28)
            statusCopy
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusBackground)
    }

    private var statusCopy: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: status.word)
                .scaledFont(size: 18, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
            Text(verbatim: status.summary)
                .scaledFont(size: 14)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(AppTheme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(status.color.opacity(0.2), lineWidth: 1)
            )
    }

    // MARK: - Rows

    private var rowsSection: some View {
        VStack(spacing: 10) {
            row(.rhr, label: String(localized: "Sleep heart rate", bundle: LanguageManager.appBundle), value: rhrValue, deviation: rhrDeviation)
            row(.respRate, label: String(localized: "Respiratory rate", bundle: LanguageManager.appBundle), value: respRateValue, deviation: respRateDeviation)
            row(.temp, label: String(localized: "Wrist temperature", bundle: LanguageManager.appBundle), value: tempValue, deviation: tempDeviation)
            row(.spo2, label: "SpO₂", value: spo2Value, deviation: spo2Deviation)
        }
    }

    private func row(_ key: Row, label: String, value: String, deviation: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                expandedRow = expandedRow == key ? nil : key
            }
        } label: {
            rowLabel(key, label: label, value: value, deviation: deviation)
        }
        .buttonStyle(.plain)
    }

    private func rowLabel(_ key: Row, label: String, value: String, deviation: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            rowHeader(label: label, value: value)
            Text(verbatim: deviation)
                .scaledFont(size: 13)
                .foregroundStyle(AppTheme.textTertiary)
            if expandedRow == key {
                Text(verbatim: explanation(for: key))
                    .scaledFont(size: 13)
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppTheme.cardBackground)
        )
    }

    private func rowHeader(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: label)
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text(verbatim: value)
                .scaledFont(size: 18, weight: .semibold, design: .rounded, monospacedDigit: true)
                .foregroundStyle(AppTheme.textPrimary)
        }
    }

    // MARK: - Field formatters

    private var rhrValue: String {
        effectiveVitals?.restingHeartRate.map { String(localized: "\(Int($0.rounded())) bpm", bundle: LanguageManager.appBundle) } ?? "—"
    }

    private var rhrDeviation: String {
        guard effectiveVitals?.restingHeartRate != nil else { return String(localized: "No data", bundle: LanguageManager.appBundle) }
        // The label tells the user WHICH source produced the number.
        // Only the strap-meanHR path is apples-to-apples with the
        // baseline; the HK fallback is daytime-rest physiology, which
        // is a different signal and should be labeled honestly so the
        // user doesn't trust a stale comparison.
        let strapHR = latestOvernight?.analysisResult?.timeDomain.meanHR
        if let strapHR, strapHR > 0 {
            return String(localized: "Strap-derived nocturnal mean (analysis window)", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Apple Watch resting HR (daytime sample — not nocturnal)", bundle: LanguageManager.appBundle)
    }

    private var respRateValue: String {
        effectiveVitals?.respiratoryRate.map { String(format: NSLocalizedString("%.1f br/min", bundle: LanguageManager.appBundle, comment: ""), locale: LanguageManager.appLocale, $0) } ?? "—"
    }

    private var respRateDeviation: String {
        guard let dev = effectiveVitals?.respiratoryDeviation else { return String(localized: "No baseline yet", bundle: LanguageManager.appBundle) }
        let sign = dev >= 0 ? "+" : ""
        if abs(dev) < 0.5 { return String(localized: "Within range", bundle: LanguageManager.appBundle) }
        return String(localized: "\(sign)\(String(format: "%.1f", locale: LanguageManager.appLocale, dev)) vs baseline", bundle: LanguageManager.appBundle)
    }

    /// Tonight against the personal baseline; "—" without one, since the raw
    /// reading is offset from a population 36.5 °C, not from the user.
    private var tempValue: String {
        guard let t = effectiveVitals?.wristTemperatureDeviation else { return "—" }
        switch temperatureUnit {
        case .celsius:    return String(format: "%+.1f°C", locale: LanguageManager.appLocale, t)
        case .fahrenheit: return String(format: "%+.1f°F", locale: LanguageManager.appLocale, t * 9 / 5)
        }
    }

    private var tempDeviation: String {
        guard let t = effectiveVitals?.wristTemperatureDeviation else { return tempUnavailableReason }
        if abs(t) < 0.3 { return String(localized: "Within", bundle: LanguageManager.appBundle) }
        return String(localized: "Deviation from your personal baseline", bundle: LanguageManager.appBundle)
    }

    private var tempUnavailableReason: String {
        effectiveVitals?.wristTemperature == nil
            ? String(localized: "No data", bundle: LanguageManager.appBundle)
            : String(localized: "No baseline yet", bundle: LanguageManager.appBundle)
    }

    private var spo2Value: String {
        effectiveVitals?.oxygenSaturation.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    private var spo2Deviation: String {
        guard let v = effectiveVitals?.oxygenSaturation else {
            // The full Apple-Watch /
            // Masimo / Sleep-Focus explainer is three lines and would
            // dominate the row. Collapsed to a compact "Not measured
            // · Why?" line; the long-form explanation lives in
            // the expanded disclosure (see `explanation(for: .spo2)`)
            // so a user who wants the why can tap to expand without
            // it competing for the row's attention.
            return String(localized: "Not measured · tap to learn why", bundle: LanguageManager.appBundle)
        }
        if v < 95 { return String(localized: "Below 95% — flat -10 score penalty applied", bundle: LanguageManager.appBundle) }
        return String(localized: "95% or above — no penalty", bundle: LanguageManager.appBundle)
    }

    private func explanation(for key: Row) -> String {
        switch key {
        case .rhr: return rhrExplanation()
        case .respRate:
            return String(
                localized: "Overnight respiratory rate above your usual baseline most often follows hard training, alcohol, a warm room, altitude or stress, and sometimes comes with the start of a respiratory illness. On its own it is weak evidence either way.",
                bundle: LanguageManager.appBundle
            )
        case .temp:
            return String(localized: "Wrist temperature deviation > +0.5°C is worth noting. It commonly follows alcohol, a warm room or heavy bedding, a hard late workout, or the menstrual cycle, and sometimes comes with the start of an illness. Cooler-than-baseline readings (negative deviation) aren't penalized; they typically reflect bedroom temperature, lighter bedding, or deeper slow-wave sleep where core temp drops naturally.", bundle: LanguageManager.appBundle)
        case .spo2: return spo2Explanation()
        }
    }

    /// Reflects which source produced the value — see `rhrDeviation` for the
    /// source detection.
    private func rhrExplanation() -> String {
        let strapHR = latestOvernight?.analysisResult?.timeDomain.meanHR
        if let strapHR, strapHR > 0 {
            return String(localized: "Sleep HR is the strap's mean HR within the overnight analysis window selected for HRV — the same nocturnal physiology your baseline of up to 60 nights is built from. Apple's 'sleeping HR' (median across the whole sleep period) may read differently because it covers all sleep stages, including REM where HR rises briefly.", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Without a strap recording, this falls back to Apple Watch's resting HR sample — which is taken during quiet daytime windows, not overnight. It's a different signal from your strap-derived baseline, so day-to-day comparisons may run high. Wear the strap at night to get the apples-to-apples nocturnal number.", bundle: LanguageManager.appBundle)
    }

    /// Carries the long-form Apple Watch / Masimo context, kept out of the
    /// row's deviation line — a user reaches it by tapping the row when
    /// they want the "why no reading" answer.
    private func spo2Explanation() -> String {
        guard effectiveVitals?.oxygenSaturation != nil else {
            return String(localized: "Apple Watch takes overnight SpO₂ automatically when Blood Oxygen + Background Measurements + Sleep Focus are all on. The app cannot trigger a reading — that's hardware-controlled by watchOS. On US Series 9 / Ultra 2 / Series 10 sold after January 2024, Blood Oxygen is measured on the Watch and calculated on the paired iPhone after the Masimo patent ruling; if a reading never appears, update both to the latest software.", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Below 95% triggers a flat -10 penalty on your composite (separate from the 15% vitals factor). At sea level, sustained <95% is unusual for a healthy person.", bundle: LanguageManager.appBundle)
    }

    // MARK: - 30-day trend chart

    private var trendChart: some View {
        ChartCard(title: String(localized: "30-day trend", bundle: LanguageManager.appBundle), aspectRatio: 16.0 / 9.0) {
            trendContent(buildTrend())
        }
    }

    @ViewBuilder
    private func trendContent(_ series: [TrendPoint]) -> some View {
        if series.isEmpty {
            EmptyState(
                glyph: "chart.xyaxis.line",
                headline: String(localized: "No trend data yet", bundle: LanguageManager.appBundle),
                message: String(localized: "Trend appears once you've logged enough overnight sessions with vitals.", bundle: LanguageManager.appBundle)
            )
        } else {
            trendPlot(series)
        }
    }

    private func trendPlot(_ series: [TrendPoint]) -> some View {
        Chart {
            trendMarks(series)
        }
        .chartForegroundStyleScale([
            Self.rhrSeries: AppTheme.wongAttention,
            Self.respSeries: AppTheme.wongGood
        ])
        .chartYAxis { AxisMarks(position: .leading) }
        .chartLegend(position: .bottom)
        .accessibilityChartDescriptor(trendAudioDescriptor(series))
    }

    @ChartContentBuilder
    private func trendMarks(_ series: [TrendPoint]) -> some ChartContent {
        ForEach(series.filter { $0.metric == Self.rhrSeries }) { p in
            LineMark(
                x: .value("Date", p.date),
                y: .value(Self.rhrSeries, p.value)
            )
            .foregroundStyle(by: .value("Metric", p.metric))
        }
        ForEach(series.filter { $0.metric == Self.respSeries }) { p in
            LineMark(
                x: .value("Date", p.date),
                y: .value(Self.respSeries, p.value)
            )
            .foregroundStyle(by: .value("Metric", p.metric))
        }
    }

    private func trendAudioDescriptor(_ series: [TrendPoint]) -> some AXChartDescriptorRepresentable {
        AudioGraphDescriptor.line(
            title: String(localized: "Vitals 30-day trend (sleep heart rate)", bundle: LanguageManager.appBundle),
            xLabel: String(localized: "Date", bundle: LanguageManager.appBundle),
            yLabel: String(localized: "Sleep HR (bpm)", bundle: LanguageManager.appBundle),
            points: series
                .filter { $0.metric == Self.rhrSeries }
                .map { (date: $0.date, value: $0.value) }
        )
    }

    /// Series names double as the chart legend, so they are localized.
    private static var rhrSeries: String { String(localized: "RHR", bundle: LanguageManager.appBundle) }
    private static var respSeries: String { String(localized: "Resp", bundle: LanguageManager.appBundle) }

    private struct TrendPoint: Identifiable {
        let id = UUID()
        let date: Date
        let metric: String
        let value: Double
    }

    /// Overnight readings only. Each night's heart rate is the strap's
    /// nocturnal mean when there is one — the same number the Sleep heart
    /// rate row shows — and the stored snapshot's otherwise.
    private func buildTrend() -> [TrendPoint] {
        var out: [TrendPoint] = []
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        for s in recentSessions where s.startDate >= cutoff && s.sessionType == .overnight {
            let v = s.vitalsSnapshot
            if let rhr = s.analysisResult?.timeDomain.meanHR ?? v?.restingHeartRate {
                out.append(TrendPoint(date: s.startDate, metric: Self.rhrSeries, value: rhr))
            }
            if let resp = v?.respiratoryRate {
                out.append(TrendPoint(date: s.startDate, metric: Self.respSeries, value: resp))
            }
        }
        return out.sorted { $0.date < $1.date }
    }

    // MARK: - Why vitals matter

    private var whyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: String(localized: "Why vitals matter", bundle: LanguageManager.appBundle))
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
            Text(verbatim: String(localized: "Breathing rate, temperature and overnight heart rate can shift on nights when HRV does not, which is why they make up 15% of your Recovery Score.", bundle: LanguageManager.appBundle))
                .scaledFont(size: 13)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            fitnessAdaptationNote
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppTheme.sectionTint)
        )
    }

    /// A sustained DOWN trend in sleep HR over
    /// weeks is most often a fitness-adaptation signal (the heart pumps more
    /// blood per beat, so the baseline rate falls). Without this line a falling
    /// line on the chart can read as "something's wrong" when the more likely
    /// story is "you're getting fitter."
    private var fitnessAdaptationNote: some View {
        Text(verbatim: String(localized: "Falling sleep HR over weeks usually means improving aerobic fitness — the heart's stroke volume goes up so it can do the same work at a lower rate.", bundle: LanguageManager.appBundle))
            .scaledFont(size: 13)
            .foregroundStyle(AppTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }
}
