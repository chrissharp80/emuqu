import SwiftUI

// LT1 estimation, threshold crossings, the derived-metrics block, HR-zone
// distribution and the settings bridge — split out of
// `FitnessPostSummaryView+EpicReport.swift`. What stays behind is
// the α1 report itself, ectopic-shadow detection, and the α1-banded route.

// There is deliberately no LTHR update suggestion here.
//
// It invited the user to replace their configured LTHR with this session's
// α1-estimated LT1. Those are different anchors: LT1 is the aerobic threshold
// α1 ≈ 0.75 proxies, while LTHR follows Friel's much harder time-trial
// protocol and is the denominator `WorkoutAnalyzer` divides by for hrTSS.
// LT1 sits well below LTHR, so taking the advice shrank the denominator and
// inflated every later training-load figure. The estimate is still shown,
// correctly labelled; only the recommendation is gone. See docs/ARCHITECTURE.md.

extension ThresholdCards {
    // MARK: - α1-derived aerobic threshold (LT1) estimate

    /// Uses the first sustained downward α1 = 0.75 crossing to estimate
    /// the user's aerobic threshold (LT1 / VT1) in HR terms.
    ///
    /// Validity: Rogers & Gronwald 2021 found α1 crossing 0.75 lands within
    /// ~2 bpm of gas-exchange VT1 on average (15 men, ICC 0.96 for HR, limits
    /// −12 to +8 bpm). Later cohorts agree less tightly — about ±10 bpm for
    /// an individual, and not at all once fatigued (Van Hooren 2023). This
    /// card surfaces that information without
    /// injecting it into TRIMP / hrTSS (which use published, validated
    /// formulas anchored to the user's configured LTHR). If the estimated
    /// LT1 consistently differs from the configured LTHR, the user can
    /// update their setting and future hrTSS scaling becomes more
    /// individualised — the validated anchor replacing the 0.88 × HRmax
    /// heuristic.
    ///
    /// Sources: Rogers & Gronwald 2021 (PMC7845545); Schaffarczyk 2022
    /// (PMC9894976); Van Hooren 2023 (PMID 37916488); Sempere-Ruiz 2024
    /// (10.3389/fphys.2024.1329360).
    @ViewBuilder
    var alpha1LT1EstimateCard: some View {
        let crossings = detectAlpha1Crossings(samples: session.workoutMetadata?.samples ?? [])
        // Use the first clean downward AT1 crossing as this session's LT1
        // estimate. Requires HR data; otherwise we can't report a bpm value.
        if let firstDown = crossings.first(where: { $0.kind == .downAT1 && $0.hr != nil }),
           let lt1HR = firstDown.hr {
            VStack(alignment: .leading, spacing: 8) {
                lt1CardHeader
                lt1Readout(lt1HR: lt1HR, offsetSec: firstDown.offsetSec)
                Text(String(localized: "HR at which your α1 crossed 0.75. In lab comparisons this lands within about ±10 bpm of the gas-exchange aerobic threshold (Rogers & Gronwald 2021; Schaffarczyk 2022; Van Hooren 2023).", bundle: LanguageManager.appBundle))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var lt1CardHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(String(localized: "α1-estimated aerobic threshold (LT1)", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text(String(localized: "estimate", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    // MARK: - Threshold crossings

    /// Surfaces moments when α1 crossed AT1 (0.75) or AT2 (0.50) — each row
    /// shows time, HR, pace, and grade at the crossing. This is what a
    /// physiology-minded coach actually looks at: not "your avg α1 was
    /// 0.64", but "your α1 dropped through AT1 at minute 18 on that hill".
    @ViewBuilder
    var alpha1CrossingsCard: some View {
        let samples = session.workoutMetadata?.samples ?? []
        let crossings = detectAlpha1Crossings(samples: samples)
        if crossings.isEmpty {
            EmptyView()
        } else {
            crossingsList(crossings)
        }
    }

    private func crossingsList(_ crossings: [Alpha1Crossing]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Threshold crossings", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            ForEach(Array(crossings.enumerated()), id: \.offset) { _, c in
                alpha1CrossingRow(c)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    struct Alpha1Crossing {
        enum Kind: String { case downAT1, upAT1, downAT2, upAT2 }
        let kind: Kind
        let offsetSec: Int
        let alpha1: Double
        let hr: Int?
        let paceSecPerKm: Double?
    }

    /// Detect α1 threshold crossings, skipping the first `alpha1WarmupSec` of
    /// the session (buffer fill) and requiring a downward crossing to
    /// persist for `alpha1SustainSec` before it commits.
    ///
    /// Sustain is 180 s — deliberately longer than α1's 120 s rolling
    /// window. A single ectopic beat contaminates the window for the
    /// window's length, so any sub-0.75 dip caused by an isolated
    /// ectopic maxes out at ~120 s. Requiring 180 s of continuous
    /// sub-0.75 means only efforts where the user is genuinely at or
    /// above LT1 for multiple consecutive α1 windows can commit a
    /// crossing. Matches the ≥ 3-min ramp-phase length Rogers &
    /// Gronwald's validation protocol uses.
    ///
    /// Closes the 2026-04 user complaint: "my α1 LT1 says 121 bpm on a
    /// 120 bpm walk because I had one ectopic beat." One ectopic can no
    /// longer drive a crossing event — the dip expires before the
    /// sustain counter matures.
    func detectAlpha1Crossings(samples: [WorkoutSample]) -> [Alpha1Crossing] {
        var out: [Alpha1Crossing] = []
        var last: Double?
        var prevOff = 0
        var at1 = BandTracker(threshold: HRVConstants.DFA.alpha1AerobicThreshold, downKind: .downAT1, upKind: .upAT1)
        var at2 = BandTracker(threshold: HRVConstants.DFA.alpha1AnaerobicThreshold, downKind: .downAT2, upKind: .upAT2)
        for s in samples {
            guard let current = s.alpha1 else { continue }
            let dt = max(1, s.offsetSec - prevOff)
            prevOff = s.offsetSec
            defer { last = current }
            // Anything before warmup is sample priming — never a crossing.
            guard s.offsetSec >= Self.alpha1WarmupSec, let prev = last else { continue }
            advance(&at1, prev: prev, current: current, sample: s, dt: dt, into: &out)
            advance(&at2, prev: prev, current: current, sample: s, dt: dt, into: &out)
        }
        // Cap at 6 events so the card doesn't turn into a log
        return Array(out.prefix(6))
    }

    private static let alpha1WarmupSec = 120
    private static let alpha1SustainSec = 180

    /// Pending/sustain state for one α1 band. AT1 (0.75) and AT2 (0.50) run the
    /// same machine against different thresholds and event kinds.
    struct BandTracker {
        let threshold: Double
        let downKind: Alpha1Crossing.Kind
        let upKind: Alpha1Crossing.Kind
        var pending: Alpha1Crossing?
        var sustained = 0
    }

    /// Feed one sample to one band.
    private func advance(_ tracker: inout BandTracker, prev: Double, current: Double,
                         sample s: WorkoutSample, dt: Int, into out: inout [Alpha1Crossing]) {
        if current < tracker.threshold {
            arm(&tracker, current: current, sample: s, dt: dt, crossedNow: prev >= tracker.threshold)
        } else {
            // Back above the threshold — emit an up-crossing if we'd committed a
            // sustained down-crossing, and clear pending state either way.
            release(&tracker, current: current, sample: s, into: &out)
        }
        commitIfSustained(&tracker, into: &out)
    }

    private func release(_ tracker: inout BandTracker, current: Double,
                         sample s: WorkoutSample, into out: inout [Alpha1Crossing]) {
        if let committed = tracker.pending, tracker.sustained >= Self.alpha1SustainSec {
            out.append(committed)
            out.append(Alpha1Crossing(kind: tracker.upKind, offsetSec: s.offsetSec,
                                      alpha1: current, hr: s.heartRate,
                                      paceSecPerKm: s.paceSecPerKm))
        }
        tracker.pending = nil
        tracker.sustained = 0
    }

    /// Commit a pending down-cross once it's been sustained long enough.
    private func commitIfSustained(_ tracker: inout BandTracker, into out: inout [Alpha1Crossing]) {
        guard let committed = tracker.pending, tracker.sustained >= Self.alpha1SustainSec,
              !out.contains(where: { $0.kind == tracker.downKind && $0.offsetSec == committed.offsetSec })
        else { return }
        out.append(committed)
    }

    var unitsPref: UnitsPreference { UnitsPreferenceStore.current }

    @ViewBuilder
    func alpha1CrossingRow(_ c: Alpha1Crossing) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Self.crossingColor(c.kind)).frame(width: 8, height: 8)
            Text(Self.crossingLabel(c.kind))
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(c.offsetSec / 60):\(String(format: "%02d", c.offsetSec % 60))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.textSecondary)
            crossingDetail(c)
        }
        .padding(.vertical, 2)
    }

    /// HR and pace at the crossing, when the sample carried them.
    @ViewBuilder
    private func crossingDetail(_ c: Alpha1Crossing) -> some View {
        if let hr = c.hr {
            Text(String(localized: "\(hr) bpm", bundle: LanguageManager.appBundle))
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.textSecondary)
        }
        if let pace = c.paceSecPerKm,
           let formatted = unitsPref.formatPace(secondsPerMeter: pace / 1_000) {
            Text(formatted)
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private static func crossingLabel(_ kind: Alpha1Crossing.Kind) -> String {
        switch kind {
        case .downAT1: String(localized: "Through AT1 ↓", bundle: LanguageManager.appBundle)
        case .upAT1: String(localized: "Back above AT1 ↑", bundle: LanguageManager.appBundle)
        case .downAT2: String(localized: "Through AT2 ↓ (hard)", bundle: LanguageManager.appBundle)
        case .upAT2: String(localized: "Back above AT2 ↑", bundle: LanguageManager.appBundle)
        }
    }

    private static func crossingColor(_ kind: Alpha1Crossing.Kind) -> Color {
        switch kind {
        case .downAT1: .yellow
        case .upAT1: AppTheme.sage
        case .downAT2: .orange
        case .upAT2: .yellow
        }
    }

    // MARK: - Derived metrics block

    /// A scalar-readouts card that surfaces every useful derivation we have
    /// the inputs for — moving time, VAM, grade-adjusted pace, calories/hr,
    /// stride length, power:HR ratio. Each row renders only when the source
    /// data is present, so an indoor walk doesn't see "VAM: —" rows.
    @ViewBuilder
    var derivedMetricsCard: some View {
        let samples = session.workoutMetadata?.samples ?? []
        let bodyRows = samples.isEmpty ? [] : derivedMetricRows(samples: samples)
        if !bodyRows.isEmpty {
            derivedMetricsList(bodyRows)
        }
    }

    struct DerivedRow {
        let label: String
        let value: String
        let sub: String?
    }

    func derivedMetricRows(samples: [WorkoutSample]) -> [DerivedRow] {
        let duration = session.duration ?? 0
        let meta = session.workoutMetadata
        return [
            movingTimeRow(samples: samples, duration: duration),
            vamRow(meta: meta, duration: duration),
            gradeAdjustedPaceRow(samples: samples, meta: meta, duration: duration),
            calorieRateRow(samples: samples, duration: duration),
            strideLengthRow(samples: samples, meta: meta, duration: duration),
            powerToHRRow(meta: meta)
        ].compactMap { $0 }
    }

    /// VAM (vertical ascent metres per hour). Classic uphill cycling metric but
    /// useful for hill walks / trail runs. gain ÷ duration-hours. Units render
    /// as m/h or ft/h per preference.
    private func vamRow(meta: WorkoutMetadata?, duration: Double) -> DerivedRow? {
        guard let gain = meta?.elevationGainMeters, gain > 10, duration > 60 else { return nil }
        let vam = gain / (duration / 3600.0)
        let display: String
        switch unitsPref.resolved {
        case .imperial:
            display = String(format: "%.0f ft/h", locale: .current, vam * UnitConstants.feetPerMeter)
        case .metric, .auto:
            display = String(format: "%.0f m/h", locale: .current, vam)
        }
        return .init(label: "VAM", value: display, sub: String(localized: "vertical ascent rate", bundle: LanguageManager.appBundle))
    }

    /// Grade-adjusted pace. Weight each sample's pace by its instantaneous grade
    /// penalty (roughly 3 s/km per 1 % grade is the accepted heuristic for
    /// running, half that for walking; we split the difference at 2 s/km/%).
    private func gradeAdjustedPaceRow(samples: [WorkoutSample], meta: WorkoutMetadata?, duration: Double) -> DerivedRow? {
        let gapSamples = samples.compactMap { s -> Double? in
            guard let pace = s.paceSecPerKm, pace > 0 else { return nil }
            return pace  // adjustment requires grade per sample which we don't store; simple avg for now
        }
        guard gapSamples.count >= 30, duration > 300, let dist = meta?.distanceMeters, dist > 500 else { return nil }
        let adjusted = gradeAdjustedSecondsPerMetre(distanceMetres: dist, duration: duration, meta: meta)
        guard let formatted = unitsPref.formatPace(secondsPerMeter: adjusted) else { return nil }
        return .init(
            label: String(localized: "Grade-adj pace", bundle: LanguageManager.appBundle),
            value: formatted,
            sub: String(localized: "flatland-equivalent", bundle: LanguageManager.appBundle)
        )
    }

    /// 1 MET = 1 kcal/kg/hr, so kcal/hr = METs × weight.
    private func calorieRateRow(samples: [WorkoutSample], duration: Double) -> DerivedRow? {
        guard duration > 60 else { return nil }
        let metsValues = samples.compactMap { $0.mets }
        guard !metsValues.isEmpty else { return nil }
        let avgMETs = metsValues.reduce(0, +) / Double(metsValues.count)
        let kcalPerHour = avgMETs * UserSettingsBridge.snapshot().weightKg
        return .init(
            label: String(localized: "Calorie rate", bundle: LanguageManager.appBundle),
            value: String(format: "%.0f kcal/h", locale: .current, kcalPerHour),
            sub: nil
        )
    }

    /// Stride length = distance ÷ step count. Distance / (steps/2) gives metres
    /// per stride (two footfalls). Meaningful only for foot-based sports with a
    /// cadence signal.
    private func strideLengthRow(samples: [WorkoutSample], meta: WorkoutMetadata?, duration: Double) -> DerivedRow? {
        guard let dist = meta?.distanceMeters, dist > 100, duration > 60 else { return nil }
        let cadValues = samples.compactMap { $0.cadenceStepsPerMin }.filter { $0 > 0 }
        guard !cadValues.isEmpty else { return nil }
        let avgCad = cadValues.reduce(0, +) / Double(cadValues.count)
        let totalSteps = avgCad * (duration / 60.0)
        guard totalSteps > 0 else { return nil }
        let metresPerStride = dist / (totalSteps / 2.0)
        let display: String
        switch unitsPref.resolved {
        case .imperial:
            display = String(format: "%.1f ft", locale: .current, metresPerStride * UnitConstants.feetPerMeter)
        case .metric, .auto:
            display = String(format: "%.2f m", locale: .current, metresPerStride)
        }
        return .init(label: String(localized: "Stride length", bundle: LanguageManager.appBundle), value: display, sub: String(localized: "avg", bundle: LanguageManager.appBundle))
    }

    /// Running aerobic-efficiency metric: watts produced per bpm of effort.
    /// Higher is more economical. Only meaningful when power AND HR are present,
    /// over a long-enough steady block.
    private func powerToHRRow(meta: WorkoutMetadata?) -> DerivedRow? {
        guard let avgPower = meta?.averagePowerWatts, avgPower > 0, let avgHR = session.meanHR, avgHR > 0 else { return nil }
        return .init(
            label: String(localized: "Power : HR", bundle: LanguageManager.appBundle),
            value: String(format: "%.2f W/bpm", locale: .current, avgPower / avgHR),
            sub: String(localized: "running economy proxy", bundle: LanguageManager.appBundle)
        )
    }

    // MARK: - HR zone distribution

    /// Time spent in each of Zones 1-5 as a stacked horizontal bar. Uses the
    /// USER's max HR (not session peak) so the same walk gives a consistent
    /// zone readout across sessions.
    @ViewBuilder
    var hrZoneDistributionCard: some View {
        let zoneSecs = hrZoneSeconds(samples: session.workoutMetadata?.samples ?? [],
                                     maxHR: UserSettingsBridge.snapshot().userMaxHR)
        let total = zoneSecs.reduce(0, +)
        if total > 0 {
            zoneDistributionBody(zoneSecs: zoneSecs, total: total)
        }
    }

    private func zoneDistributionBody(zoneSecs: [Int], total: Int) -> some View {
        let dominantZone = (zoneSecs.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0) + 1
        return VStack(alignment: .leading, spacing: 10) {
            zoneCardHeader(dominantZone: dominantZone,
                           dominantPct: Int(Double(zoneSecs[dominantZone - 1]) / Double(total) * 100))
            zoneStackedBar(zoneSecs: zoneSecs, total: total)
            zoneLegend(zoneSecs: zoneSecs)
            // Narrative: what the zone distribution means
            Text(zoneNarrative(zoneSecs: zoneSecs, dominant: dominantZone))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    private func zoneStackedBar(zoneSecs: [Int], total: Int) -> some View {
        GeometryReader { geo in
            zoneBarSegments(zoneSecs: zoneSecs, total: total, width: geo.size.width)
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func zoneBarSegments(zoneSecs: [Int], total: Int, width: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(0 ..< 5, id: \.self) { idx in
                Rectangle()
                    .fill(zoneColor(idx: idx))
                    .frame(width: max(2, width * Double(zoneSecs[idx]) / Double(total)))
            }
        }
    }

    /// Per-zone labels — zones with no time in them are omitted.
    private func zoneLegend(zoneSecs: [Int]) -> some View {
        let maxHR = UserSettingsBridge.snapshot().userMaxHR
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(0 ..< 5, id: \.self) { idx in
                zoneLegendRow(idx: idx, secs: zoneSecs[idx], maxHR: maxHR)
            }
        }
    }

    @ViewBuilder
    private func zoneLegendRow(idx: Int, secs: Int, maxHR: Int) -> some View {
        if secs > 0 {
            HStack(spacing: 6) {
                Circle().fill(zoneColor(idx: idx)).frame(width: 8, height: 8)
                Text("Z\(idx + 1)")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                Text(zoneRangeLabel(idx: idx, maxHR: maxHR))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
                Spacer()
                Text(String(localized: "\(secs / 60)m \(secs % 60)s", bundle: LanguageManager.appBundle))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    /// Plain-English interpretation of the zone distribution — matches
    /// the morning cards' pattern of "big number + what it means".
    func zoneNarrative(zoneSecs: [Int], dominant: Int) -> String {
        switch dominant {
        case 1: return String(localized: "Recovery or warm-up effort. Zone 1 builds aerobic base without fatigue cost.", bundle: LanguageManager.appBundle)
        case 2: return String(localized: "Zone-2 base endurance work — improves mitochondrial density and fat oxidation.", bundle: LanguageManager.appBundle)
        case 3: return String(localized: "Tempo work. Sits between aerobic and anaerobic thresholds.", bundle: LanguageManager.appBundle)
        case 4: return String(localized: "Threshold intensity. Develops lactate clearance at race-pace efforts.", bundle: LanguageManager.appBundle)
        case 5: return String(localized: "VO₂max territory. High physiological cost — short efforts only.", bundle: LanguageManager.appBundle)
        default: return ""
        }
    }

    func hrZoneSeconds(samples: [WorkoutSample], maxHR: Int) -> [Int] {
        // Index: 0 = Z1, 4 = Z5. Zones follow 50-60/60-70/70-80/80-90/90+ of
        // userMaxHR — same bins TRIMP uses.
        var zs = [0, 0, 0, 0, 0]
        var prev = 0
        for s in samples {
            let dt = max(1, s.offsetSec - prev)
            prev = s.offsetSec
            guard let hr = s.heartRate, maxHR > 0 else { continue }
            let frac = Double(hr) / Double(maxHR)
            switch frac {
            case ..<0.50: break              // below Z1 — don't count
            case 0.50 ..< 0.60: zs[0] += dt
            case 0.60 ..< 0.70: zs[1] += dt
            case 0.70 ..< 0.80: zs[2] += dt
            case 0.80 ..< 0.90: zs[3] += dt
            default: zs[4] += dt
            }
        }
        return zs
    }

    func zoneColor(idx: Int) -> Color {
        switch idx {
        case 0: Color(red: 0.40, green: 0.80, blue: 0.55)   // green
        case 1: Color(red: 0.55, green: 0.85, blue: 0.45)   // lime
        case 2: Color(red: 0.95, green: 0.80, blue: 0.30)   // yellow
        case 3: Color(red: 0.95, green: 0.55, blue: 0.25)   // orange
        default: Color(red: 0.90, green: 0.35, blue: 0.35)  // red
        }
    }

    func zoneRangeLabel(idx: Int, maxHR: Int) -> String {
        let lows = [0.50, 0.60, 0.70, 0.80, 0.90]
        let highs = [0.60, 0.70, 0.80, 0.90, 1.05]
        let lo = Int((lows[idx] * Double(maxHR)).rounded())
        let hi = Int((highs[idx] * Double(maxHR)).rounded())
        return "\(lo)–\(hi) bpm"
    }
}

// MARK: - Settings bridge
//
// Thin snapshot accessor so the extension file doesn't have to import
// everything SettingsManager depends on. A plain value type, intentionally
// NOT a singleton — the earlier `.shared` computed accessor looked like a
// new view-layer singleton but was actually a fresh snapshot each call.
// Renamed to `snapshot()` so the semantics match the name.
struct UserSettingsBridge {
    let userMaxHR: Int
    let weightKg: Double
    /// Resolved LTHR. Either the user's override (set in Settings → Fitness)
    /// or the 0.88 × max-HR default. Surfaced to the post-summary so the
    /// α1-LT1 card can compare against the *current anchor* and advise the
    /// user only when the delta is material.
    let lactateThresholdHR: Int
    /// Whether the user has explicitly set an LTHR override vs. we're
    /// falling back to the %HRmax heuristic. Used for the "update your
    /// LTHR" prompt wording.
    let lthrIsUserSet: Bool

    /// Snapshot the current `SettingsManager` state. Use instead of the
    /// old `UserSettingsBridge.snapshot()`.
    static func snapshot() -> UserSettingsBridge {
        let s = AppDependencies.current.app.settingsManager.settingsSnapshot
        return UserSettingsBridge(
            userMaxHR: s.effectiveMaxHR,
            weightKg: s.effectiveBodyWeightKg,
            lactateThresholdHR: s.effectiveLTHR,
            lthrIsUserSet: (s.lactateThresholdHR ?? 0) > 0
        )
    }
}

/// Process-wide LRU(1) cache for `alpha1Stats` results.
/// SwiftUI re-renders the post-summary's alpha1 card 50+ times per
/// second on a slow scroll; the underlying compute walks every sample
/// in the workout (1975 in the user's report). With this cache the
/// second through 50th re-renders return in O(1) instead of repeating
/// the MAD outlier pass every time.
///
/// Single-slot cache is intentional — only the currently-displayed
/// summary needs caching; switching workouts swaps the slot. Larger
/// caches just keep stale entries around. Thread-safe via
/// `@MainActor` (the post-summary is main-actor only).
@MainActor
final class Alpha1StatsCache {
    static let shared = Alpha1StatsCache()

    struct Key: Equatable {
        let count: Int
        let firstAlphaOffset: Int?
        let lastAlphaOffset: Int?
        let alphaSampleCount: Int
    }

    var cachedKey: Key?
    var cachedValue: FitnessPostSummaryView.Alpha1Stats?

    func lookup(key: Key) -> FitnessPostSummaryView.Alpha1Stats? {
        cachedKey == key ? cachedValue : nil
    }

    func store(key: Key, value: FitnessPostSummaryView.Alpha1Stats) {
        cachedKey = key
        cachedValue = value
    }
}

/// Average pace with net climb treated as an uphill penalty of +2 s/km per
/// percent of average grade, expressed in seconds per metre.
///
/// Every value is annotated. Written inline as four chained expressions of
/// untyped `Double` arithmetic with optional coalescing, this cost 2,171 ms to
/// type-check on a CI runner (run 33200086130) while measuring under 120 ms on
/// the developer Mac — the local number does not predict the runner's.
///
/// File scope rather than a method, because `FitnessPostSummaryView` is already
/// over the aggregate-type-size threshold and `check_aggregate_type_size.sh`
/// counts any growth in a type that is already over. This function needs no
/// part of the view, so it does not have to live inside it.
private func gradeAdjustedSecondsPerMetre(
    distanceMetres dist: Double,
    duration: Double,
    meta: WorkoutMetadata?
) -> Double {
    let kilometres: Double = dist / 1_000
    let avgPace: Double = duration / kilometres
    let gain: Double = meta?.elevationGainMeters ?? 0
    let loss: Double = meta?.elevationLossMeters ?? 0
    let netGainRatio: Double = (gain - loss) / dist
    let elevAdjSecPerKm: Double = 2.0 * (netGainRatio * 100.0)
    return (avgPace - elevAdjSecPerKm) / 1_000
}

// MARK: - File-scope helpers
//
// Moved out of the view. Each touches none of the view's 165
// members — including its private statics —
// and calls nothing that stayed behind. `private` at file scope is
// fileprivate, so every call site in this file resolves as before.

@MainActor
private func lt1Readout(lt1HR: Int, offsetSec: Int) -> some View {
    HStack(alignment: .lastTextBaseline) {
        Text("\(lt1HR)")
            .scaledFont(size: 32, weight: .semibold)
            .foregroundStyle(AppTheme.sage)
        Text(String(localized: "bpm", bundle: LanguageManager.appBundle))
            .font(.caption)
            .foregroundStyle(AppTheme.textSecondary)
        Spacer()
        Text(String(localized: "at \(offsetSec / 60):\(String(format: "%02d", offsetSec % 60))", bundle: LanguageManager.appBundle))
            .font(.caption.monospacedDigit())
            .foregroundStyle(AppTheme.textSecondary)
    }
}

/// Arm a pending down-crossing on the sample that crosses, then keep
/// accumulating time below the threshold on every sample after it.
private func arm(_ tracker: inout ThresholdCards.BandTracker, current: Double,
                 sample s: WorkoutSample, dt: Int, crossedNow: Bool) {
    if crossedNow, tracker.pending == nil {
        tracker.pending = ThresholdCards.Alpha1Crossing(kind: tracker.downKind, offsetSec: s.offsetSec,
                                         alpha1: current, hr: s.heartRate,
                                         paceSecPerKm: s.paceSecPerKm)
    }
    tracker.sustained += dt
}

@MainActor
private func derivedMetricsList(_ rows: [ThresholdCards.DerivedRow]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(String(localized: "Derived metrics", bundle: LanguageManager.appBundle))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.textSecondary)
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            derivedMetricRow(row)
        }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AppTheme.cardBackground)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
}

@MainActor
private func derivedMetricRow(_ row: ThresholdCards.DerivedRow) -> some View {
    HStack {
        Text(row.label)
            .font(.caption)
            .foregroundStyle(AppTheme.textSecondary)
        Spacer()
        Text(row.value)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(AppTheme.textPrimary)
        derivedMetricSublabel(row.sub)
    }
    .padding(.vertical, 2)
}

@ViewBuilder
@MainActor
private func derivedMetricSublabel(_ sub: String?) -> some View {
    if let sub {
        Text(sub)
            .font(.caption2)
            .foregroundStyle(AppTheme.textTertiary)
    }
}

/// OR-of-three-signals "moving" detector matching the snapshot builder.
///
/// Pace alone was too strict at walk speeds (upstream GPS pace requires a
/// 2.5-m-per-1-s distance delta, which a casual 3 mph walk can't hit) →
/// "Moving time 32 %" on a 100 %-active 71-minute walk. Cadence ≥ 50 spm is
/// the most reliable "you are walking" signal at slow speed; HR+α1/METs
/// presence is the belt-and-braces fallback. Accumulated in seconds via `dt`
/// then normalised against duration — sample-count normalisation drifts when
/// samples arrive at irregular intervals.
private func movingTimeRow(samples: [WorkoutSample], duration: Double) -> ThresholdCards.DerivedRow? {
    guard samples.count >= 10, duration > 10 else { return nil }
    let movingSec = movingSeconds(samples: samples)
    let pct = Int(min(100, max(0, Double(movingSec) / duration * 100.0)))
    return .init(
        label: String(localized: "Moving time", bundle: LanguageManager.appBundle),
        value: "\(pct)%",
        sub: String(localized: "\(movingSec / 60) min active", bundle: LanguageManager.appBundle)
    )
}

private func movingSeconds(samples: [WorkoutSample]) -> Int {
    var movingSec = 0
    var lastOff = 0
    for s in samples {
        let dt = max(1, s.offsetSec - lastOff)
        lastOff = s.offsetSec
        let movingFromPace = (s.paceSecPerKm ?? 0) > 0
        let movingFromCadence = (s.cadenceStepsPerMin ?? 0) >= 50
        let movingFromHR = (s.heartRate ?? 0) > 0 && (s.alpha1 != nil || s.mets != nil)
        if movingFromPace || movingFromCadence || movingFromHR {
            movingSec += dt
        }
    }
    return movingSec
}

/// Morning-parity header: all-caps tracked label + trailing badge.
@MainActor
private func zoneCardHeader(dominantZone: Int, dominantPct: Int) -> some View {
    HStack {
        Image(systemName: "chart.bar.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.terracotta)
        Text(String(localized: "HR ZONE DISTRIBUTION", bundle: LanguageManager.appBundle))
            .font(.caption.weight(.bold))
            .tracking(1.2)
            .foregroundStyle(AppTheme.textTertiary)
        Spacer()
        Text(String(localized: "mostly Z\(dominantZone) · \(dominantPct)%", bundle: LanguageManager.appBundle))
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.textSecondary)
    }
}
