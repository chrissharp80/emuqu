import Charts
import CoreLocation
import MapKit
import SwiftUI

// MARK: - Epic Report: correlated α1 + derived metrics
//
// The post-summary is where the workout *becomes* a story. A row of numbers
// (distance, pace, HR) doesn't answer the questions the user actually has:
//   • Where on the route did my effort spike?
//   • Which hills pushed me above aerobic threshold?
//   • How much of the session was in each zone?
//   • What does my α1 curve look like vs HR vs grade?
//
// This file adds those correlated cards. They share the session's per-tick
// sample series (WorkoutMetadata.samples) with the existing chart cards but
// overlay threshold markers, colour the map by physiological band, and
// surface derivations that need multiple inputs (VAM, stride length,
// grade-adjusted pace, power:HR ratio).
//
// Design contract: every card degrades gracefully. If the source data is
// missing, the card returns an empty view — so a short indoor walk doesn't
// get peppered with "— — —" placeholders.
extension Alpha1ReportCards {
    // MARK: - α1 Report

    /// The α1 timeline is the physiological centerpiece of this report.
    /// Renders:
    ///   • A HERO line: this session's aerobic-threshold story in plain
    ///     English ("all easy" / LT1 reached at minute 14 / above AT2 for
    ///     12 min) so the meaning is immediate, no physiology lookup needed.
    ///   • The α1 curve over time with AT1 (0.75, aerobic threshold) and
    ///     AT2 (0.50, anaerobic threshold) reference lines. Y domain
    ///     auto-scales to the actual data range — a hardcoded 0.2-1.3
    ///     silently clips any α1 reading above 1.3 (very common for easy
    ///     walks where α1 runs 1.5-2.0+).
    ///   • Average / max / min α1 stats so the reader can see not just
    ///     distribution but variability.
    ///
    /// Band interpretation validated against lab lactate by
    /// Rogers & Gronwald 2021 (PMC7845545): α1 ≈ 0.75 ≈ LT1; α1 ≈ 0.50
    /// ≈ LT2. We surface α1 as the primary fitness-tab readout because
    /// it's the single number that captures "what was the physiological
    /// cost of this effort" — HR tells you "how hard did it feel in
    /// bpm terms," α1 tells you "which metabolic regime were you in."
    @ViewBuilder
    var alpha1ReportCard: some View {
        let samples = session.workoutMetadata?.samples ?? []
        let alphaPoints = alpha1Points(samples)
        if alphaPoints.count >= 3 {
            alpha1ReportBody(samples: samples, alphaPoints: alphaPoints)
        }
    }

    private func alpha1ReportBody(
        samples: [WorkoutSample],
        alphaPoints: [(x: Double, y: Double)]
    ) -> some View {
        let stats = alpha1Stats(samples: samples)
        let ectopicShadows = detectEctopicShadows(samples: samples)
        return VStack(alignment: .leading, spacing: 10) {
            alpha1Hero(stats: stats)
            alpha1StatsRow(stats: stats, sampleCount: alphaPoints.count)
            alpha1Chart(alphaPoints: alphaPoints, stats: stats, ectopicShadows: ectopicShadows)
            // Time-distribution summary.
            Text(stats.distributionLabel)
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
            ectopicShadowFooter(ectopicShadows)
            alpha1Explainer
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func alpha1Hero(stats: Alpha1Stats) -> some View {
        let plain = alpha1PlainEnglishSummary(stats: stats)
        return VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "DFA α1 — aerobic-threshold story", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            Text(plain)
                .font(.body.weight(.medium))
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Auto-scale the Y domain to include the data range PLUS headroom for the
    /// AT1 line at 0.75 and the AT2 line at 0.50 even if the user never crossed
    /// them. Lower bound clamps at 0.3 (well below AT2), upper at 1.3 (so the
    /// AT1 annotation has space), growing as needed.
    ///
    /// X is clamped to the session duration — otherwise Chart auto-scales to
    /// round-number ticks (75 min on a 63 min walk) and the curve floats in dead
    /// space on the right.
    private func alpha1Chart(
        alphaPoints: [(x: Double, y: Double)],
        stats: Alpha1Stats,
        ectopicShadows: [EctopicShadow]
    ) -> some View {
        let minY = min(0.3, (stats.minAlpha1 ?? 0.5) - 0.1)
        let maxY = max(1.3, (stats.maxAlpha1 ?? 1.0) + 0.15)
        return Chart {
            thresholdRules
            alpha1Line(alphaPoints)
            ectopicShadowMarks(ectopicShadows)
        }
        .chartYScale(domain: minY ... maxY)
        .chartXScale(domain: 0 ... max(1, alphaPoints.last?.x ?? 1))
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .frame(height: 150)
    }

    @ChartContentBuilder
private var thresholdRules: some ChartContent {
        RuleMark(y: .value("AT1", HRVConstants.DFA.alpha1AerobicThreshold))
            .foregroundStyle(AppTheme.sage.opacity(0.9))
            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .annotation(position: .top, alignment: .leading) {
                Text(String(localized: "AT1 · aerobic threshold", bundle: LanguageManager.appBundle))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.sageText)
            }
        RuleMark(y: .value("AT2", HRVConstants.DFA.alpha1AnaerobicThreshold))
            .foregroundStyle(.orange.opacity(0.9))
            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .annotation(position: .top, alignment: .leading) {
                Text(String(localized: "AT2 · anaerobic threshold", bundle: LanguageManager.appBundle))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
}

    /// Beat-artifact markers. Previous iteration put a
    /// PointMark at the deepest point of the dip with a
    /// `.bottom` annotation, which collided with the AT2
    /// threshold line and rendered the label unreadable.
    /// Put the mark at the TOP of the chart with a thin
    /// neutral rule dropping to the dip value — visually
    /// unambiguous ("this dip is labelled"), no collision
    /// with the threshold lines.
    ///
    /// Neutral grey and a plain word, not an orange warning triangle: the
    /// mark is a data-cleaning note (one beat the analysis set aside), and a
    /// timestamped warning glyph reads as heart-rhythm event detection, which
    /// this app does not do.
    private func ectopicShadowMarks(_ ectopicShadows: [EctopicShadow]) -> some ChartContent {
        ForEach(Array(ectopicShadows.enumerated()), id: \.offset) { _, event in
            RuleMark(x: .value("Beat artifact", Double(event.offsetSec) / 60.0))
                .foregroundStyle(AppTheme.textTertiary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .annotation(position: .top, alignment: .center, spacing: 2) { ectopicTag }
        }
    }

    private var ectopicTag: some View {
        Text(String(localized: "beat artifact", bundle: LanguageManager.appBundle))
            .font(.caption2.weight(.medium))
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(AppTheme.sectionTint)
            )
    }

    /// What α1 is and why it matters — right on the card, so the user doesn't
    /// have to hunt through the Help Center.
    private var alpha1Explainer: some View {
        Text(String(localized: "α1 reflects how organised your heartbeat variability is during exercise. Higher = more parasympathetic / below aerobic threshold; lower = more sympathetic / above threshold. The 0.75 crossing closely matches lab-measured LT1 (Rogers & Gronwald 2021).", bundle: LanguageManager.appBundle))
            .font(.caption2)
            .foregroundStyle(AppTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Ectopic-shadow detection

    /// One short-lived α1 dip caused by a single ectopic / missed / extra
    /// beat contaminating the rolling DFA window. Not a physiological
    /// threshold event; labelled on the chart and excluded from AVG /
    /// MAX / MIN / band stats so the summary describes real physiology,
    /// not artifact.
    struct EctopicShadow {
        /// Session-relative second the dip started (first sample < 0.75).
        let startSec: Int
        /// Session-relative second the dip ended (first sample back ≥ 0.75).
        let endSec: Int
        /// Session-relative second at the DEEPEST point of the dip.
        let offsetSec: Int
        /// α1 value at that deepest point.
        let alpha1: Double

        /// Does this shadow contain the given session offset?
        func contains(offsetSec s: Int) -> Bool {
            s >= startSec && s < endSec
        }
    }

    /// Detect ectopic-shadow events: sub-0.75 α1 excursions that recover
    /// above 0.75 within the α1 window length (~120 s). A real threshold
    /// crossing sustains longer because the user is genuinely at effort;
    /// an ectopic's shadow can't persist longer than the window that
    /// contains it, because once the ectopic rolls out the α1 fit
    /// recovers.
    ///
    /// Philosophy: don't hide these dips — they really happened to your
    /// RR stream. Label them so the user understands the chart; also
    /// exclude them from AVG / MAX / MIN / band stats so numeric claims
    /// describe real physiology, not single-beat artifacts (a
    /// user report: "MIN 0.75 is a fabrication — it came from an ectopic,
    /// not my actual α1 low").
    ///
    /// If the session ended while still in a dip, we don't know whether
    /// it was ectopic or a real sustained effort that wasn't given time
    /// to recover — it isn't labelled, leaving the chart neutral.
    private func detectEctopicShadows(samples: [WorkoutSample]) -> [EctopicShadow] {
        var out: [EctopicShadow] = []
        var dip: Alpha1Dip?
        for s in samples {
            guard let a = s.alpha1 else { continue }
            guard a < HRVConstants.DFA.alpha1AerobicThreshold else {
                Self.closeDip(&dip, recoveredAt: s.offsetSec, into: &out)
                continue
            }
            Self.extendDip(&dip, offsetSec: s.offsetSec, alpha1: a)
        }
        return out
    }

    /// α1 came back above threshold: record the shadow if the dip was short
    /// enough to be one, and clear the run either way.
    private static func closeDip(_ dip: inout Alpha1Dip?, recoveredAt: Int, into out: inout [EctopicShadow]) {
        if let shadow = dip?.shadow(recoveredAt: recoveredAt) { out.append(shadow) }
        dip = nil
    }

    /// Open a new dip at this sample, or deepen the one already running.
    private static func extendDip(_ dip: inout Alpha1Dip?, offsetSec: Int, alpha1: Double) {
        guard dip != nil else {
            dip = Alpha1Dip(startSec: offsetSec, deepestOffset: offsetSec, deepestAlpha: alpha1)
            return
        }
        dip?.deepen(offsetSec: offsetSec, alpha1: alpha1)
    }

    /// An open sub-0.75 α1 excursion, tracked until α1 recovers above 0.75.
    struct Alpha1Dip {
        let startSec: Int
        var deepestOffset: Int
        var deepestAlpha: Double

        mutating func deepen(offsetSec: Int, alpha1: Double) {
            guard alpha1 < deepestAlpha else { return }
            deepestOffset = offsetSec
            deepestAlpha = alpha1
        }

        /// The dip has closed (α1 rose back above 0.75). If the sub-0.75 span was
        /// shorter than one α1 window, this is an ectopic shadow.
        ///
        /// Critical: the shadow range covers the FULL α1 window length around the
        /// ectopic, not just the sub-0.75 portion. The physics: one ectopic lives
        /// inside the 120 s rolling window for 120 s. Every α1 sample emitted
        /// during that 120 s is contaminated — the sub-0.75 dip is only the severe
        /// middle of it; values like 0.87, 0.96 on the recovery shoulder are still
        /// artifact. Approach phase is shorter (α1 drops fast once the ectopic hits
        /// the window) so 60 s is enough there; recovery needs the full 120 s
        /// because α1 doesn't snap back until the ectopic exits the window
        /// entirely.
        ///
        /// User report trail:
        ///   • 30 s pad → reported "LT1 121 at 4:00" (fake cross)
        ///   • 60 s pad → MIN=0.87 (recovery-shoulder)
        ///   • 120 s pad → first sample whose window is genuinely ectopic-free.
        func shadow(recoveredAt endSec: Int) -> EctopicShadow? {
            let span = endSec - startSec
            guard span > 0, span <= Self.windowSec else { return nil }
            return EctopicShadow(
                startSec: max(0, startSec - Self.approachPad),
                endSec: endSec + Self.recoveryPad,
                offsetSec: deepestOffset,
                alpha1: deepestAlpha
            )
        }

        private static let windowSec = 120
        private static let approachPad = 60
        private static let recoveryPad = 120
    }

    /// Everything we need to summarise an α1 session in one struct.
    struct Alpha1Stats {
        let avgAlpha1: Double?
        let maxAlpha1: Double?
        let minAlpha1: Double?
        let secondsBelowAT1: Int     // α1 ≥ 0.75 (EASY — below aerobic threshold)
        let secondsBetween: Int      // 0.50 ≤ α1 < 0.75 (THRESHOLD — LT1-LT2 band)
        let secondsAboveAT2: Int     // α1 < 0.50 (HARD — above anaerobic threshold)
        let firstAT1Crossing: (offsetSec: Int, hr: Int?)?
        var totalSec: Int { secondsBelowAT1 + secondsBetween + secondsAboveAT2 }
        var distributionLabel: String {
            guard totalSec > 0 else { return "" }
            let easy = LocalizedDuration.minutes(secondsBelowAT1 / 60)
            let threshold = LocalizedDuration.minutes(secondsBetween / 60)
            let hard = LocalizedDuration.minutes(secondsAboveAT2 / 60)
            return String(
                localized: "Easy (α1 ≥ 0.75): \(easy) · Threshold (0.50–0.75): \(threshold) · Above AT2: \(hard)",
                bundle: LanguageManager.appBundle
            )
        }
    }

    /// Walk the sample series once to extract all α1 statistics the hero
    /// card and report need.
    ///
    /// First-AT1-crossing detector matches the snapshot builder: 120 s
    /// warmup window + 180 s sustain requirement. The sustain MUST be
    /// longer than α1's 120 s rolling window — that's what keeps an
    /// ectopic-induced dip (which contaminates the window for exactly
    /// one window-length) from ever satisfying the sustain check. 180 s
    /// also matches the ≥ 3-min ramp-phase length Rogers & Gronwald's
    /// validation protocol uses to identify LT1. A shorter sustain (30 s
    /// in an earlier fix) still let single-ectopic shadows through.
    ///
    /// Memoized. SwiftUI body re-renders run this from
    /// `alpha1ReportCard`, which a user's debug log shows firing
    /// 50+ times per second on the post-summary screen — same input, same
    /// output every time. Without a cache the export log was 2700+ duplicate
    /// `[α1Stats]` lines and the screen visibly stuttered when other views
    /// were composing alongside.
    private func alpha1Stats(samples: [WorkoutSample]) -> Alpha1Stats {
        let cacheKey = alpha1CacheKey(sessionId: session.id, samples: samples)
        if let cached = AppDependencies.current.app.alpha1StatsCache.lookup(key: cacheKey) {
            return cached
        }
        let shadows = detectEctopicShadows(samples: samples)
        let bands = alpha1BandTotals(samples: samples, shadows: shadows)
        let cleanValues = collectCleanAlpha1Values(samples: samples, shadows: shadows)
        let robustStats = robustMinMaxAvg(values: cleanValues)
        logAlpha1MinProvenance(min: robustStats.min, samples: samples, shadows: shadows, cleanCount: cleanValues.count)
        let result = Alpha1Stats(
            avgAlpha1: robustStats.avg,
            maxAlpha1: robustStats.max,
            minAlpha1: robustStats.min,
            secondsBelowAT1: bands.belowAT1,
            secondsBetween: bands.between,
            secondsAboveAT2: bands.aboveAT2,
            firstAT1Crossing: bands.firstCrossing
        )
        AppDependencies.current.app.alpha1StatsCache.store(key: cacheKey, value: result)
        return result
    }

    /// Time spent in each α1 band, plus the first sustained AT1 crossing.
    struct Alpha1Bands {
        var belowAT1 = 0
        var between = 0
        var aboveAT2 = 0
        var firstCrossing: (Int, Int?)?

        mutating func add(alpha1 a: Double, dt: Int) {
            if a >= HRVConstants.DFA.alpha1AerobicThreshold {
                belowAT1 += dt
            } else if a >= HRVConstants.DFA.alpha1AnaerobicThreshold {
                between += dt
            } else {
                aboveAT2 += dt
            }
        }
    }

    /// Warmup + sustained-cross guard. Only arm the pending cross after
    /// `warmupSec`; only commit once sub-0.75 persists for at least
    /// `sustainSec`. Anything sub-warmup is discarded.
    struct AT1CrossDetector {
        let warmupSec = 120
        let sustainSec = 180
        private var pendingOffset: Int?
        private var pendingHR: Int?
        private var sustainedBelowSec = 0

        /// The crossing, once this sample makes it mature. Nil until then.
        mutating func step(alpha1 a: Double, sample s: WorkoutSample, dt: Int) -> (Int, Int?)? {
            guard a < HRVConstants.DFA.alpha1AerobicThreshold else {
                sustainedBelowSec = 0
                pendingOffset = nil
                pendingHR = nil
                return nil
            }
            if pendingOffset == nil {
                pendingOffset = s.offsetSec
                pendingHR = s.heartRate
            }
            sustainedBelowSec += dt
            guard sustainedBelowSec >= sustainSec, let off = pendingOffset else { return nil }
            return (off, pendingHR)
        }
    }

    /// Ectopic-shadow samples don't reflect real physiology. Skip them so the
    /// easy/threshold/above-AT2 band counts describe the session MINUS the
    /// artifacts. (The chart still renders them — with a neutral "beat artifact"
    /// marker — so the user can see the artefact in situ.)
    ///
    /// Each α1 sample counts the time since the previous one, capped at
    /// `maxSampleGapSec`. Uncapped, the first sample took every second from
    /// the session start (α1 needs about 2 minutes of beats first), and the
    /// first sample after a strap dropout took the whole gap, which inflated
    /// the band minutes and could satisfy the crossing's sustain rule alone.
    private func alpha1BandTotals(samples: [WorkoutSample], shadows: [EctopicShadow]) -> Alpha1Bands {
        var bands = Alpha1Bands()
        var cross = AT1CrossDetector()
        var prevOffset: Int?
        for s in samples {
            guard let a = s.alpha1 else { continue }
            let dt = prevOffset.map { min(max(1, s.offsetSec - $0), Self.maxSampleGapSec) } ?? 1
            prevOffset = s.offsetSec
            if shadows.contains(where: { $0.contains(offsetSec: s.offsetSec) }) { continue }
            bands.add(alpha1: a, dt: dt)
            if bands.firstCrossing == nil, s.offsetSec >= cross.warmupSec {
                bands.firstCrossing = cross.step(alpha1: a, sample: s, dt: dt)
            }
        }
        return bands
    }

    /// The longest stretch one α1 sample may stand for. Samples arrive about
    /// once a second; a longer gap is missing data, not time in a band.
    private static let maxSampleGapSec = 5

    /// Turn the raw stats into a sentence a non-physiologist understands.
    private func alpha1PlainEnglishSummary(stats: Alpha1Stats) -> String {
        let totalMin = stats.totalSec / 60
        guard stats.totalSec >= 60 else {
            return String(localized: "Not enough clean RR data to characterise your α1 this session.", bundle: LanguageManager.appBundle)
        }
        let easyMin = stats.secondsBelowAT1 / 60
        let threshMin = stats.secondsBetween / 60
        let hardMin = stats.secondsAboveAT2 / 60
        // Purely easy (α1 stayed ≥ 0.75 the whole time) — most likely for a walk.
        if stats.secondsBetween == 0, stats.secondsAboveAT2 == 0 {
            return String(localized: "You stayed below aerobic threshold for the full \(totalMin) min — pure Zone-2 base work, α1 never crossed 0.75. Ideal aerobic-base session.", bundle: LanguageManager.appBundle)
        }
        // Purely hard (α1 never recovered above AT2).
        if stats.secondsBelowAT1 == 0, stats.secondsBetween == 0 {
            return String(localized: "You were above anaerobic threshold the entire session (\(totalMin) min at α1 < 0.50). Very hard physiological cost — short, intense efforts only.", bundle: LanguageManager.appBundle)
        }
        // First AT1 crossing tells the transition story.
        if let cross = stats.firstAT1Crossing {
            return alpha1CrossingSentence(cross: cross, easyMin: easyMin, threshMin: threshMin, hardMin: hardMin)
        }
        return String(localized: "Easy \(easyMin)m · Threshold \(threshMin)m · Above AT2 \(hardMin)m.", bundle: LanguageManager.appBundle)
    }

    /// The transition story, told from the first sustained AT1 crossing.
    private func alpha1CrossingSentence(cross: (offsetSec: Int, hr: Int?), easyMin: Int, threshMin: Int, hardMin: Int) -> String {
        let mm = cross.offsetSec / 60, ss = cross.offsetSec % 60
        let hrPhrase = cross.hr.map { String(localized: " at HR \($0) bpm", bundle: LanguageManager.appBundle) } ?? ""
        if hardMin > 0 {
            return String(localized: "You crossed aerobic threshold at \(mm):\(String(format: "%02d", ss))\(hrPhrase), stayed in threshold/above for \(threshMin + hardMin) min, and spent \(hardMin) min above anaerobic threshold. Mixed-intensity session.", bundle: LanguageManager.appBundle)
        }
        return String(localized: "You crossed aerobic threshold at \(mm):\(String(format: "%02d", ss))\(hrPhrase) and stayed at threshold for \(threshMin) min. \(easyMin) min easy, \(threshMin) min at threshold.", bundle: LanguageManager.appBundle)
    }

    // MARK: - Route colored by α1 band

    /// Second map — the route colored by α1 band so the user can see
    /// WHERE on the walk they crossed thresholds. Requires both GPS track
    /// and α1 samples. Uses multiple `MapPolyline`s (one per band segment)
    /// since SwiftUI Map doesn't support gradient strokes.
    @ViewBuilder
    func alpha1RouteColoredCard(track: [CLLocation]) -> some View {
        let samples = session.workoutMetadata?.samples ?? []
        let segments = alpha1RouteSegments(track: track, samples: samples, startDate: session.startDate)
        if segments.count >= 2 {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Route by α1 band", bundle: LanguageManager.appBundle))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                alpha1RouteMap(segments: segments, coords: track.map(\.coordinate))
                alpha1BandLegend
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func alpha1RouteMap(segments: [Alpha1Segment], coords allCoords: [CLLocationCoordinate2D]) -> some View {
        Map(initialPosition: .region(alpha1RegionForTrack(allCoords))) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                MapPolyline(coordinates: seg.coordinates)
                    .stroke(seg.color, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if let start = allCoords.first {
                Marker(String(localized: "Start", bundle: LanguageManager.appBundle), coordinate: start).tint(AppTheme.sage)
            }
            if let end = allCoords.last {
                Marker(String(localized: "End", bundle: LanguageManager.appBundle), coordinate: end).tint(AppTheme.terracotta)
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var alpha1BandLegend: some View {
        HStack(spacing: 14) {
            bandLegend(color: AppTheme.sage, label: String(localized: "Easy (≥0.75)", bundle: LanguageManager.appBundle))
            bandLegend(color: .yellow, label: String(localized: "Threshold", bundle: LanguageManager.appBundle))
            bandLegend(color: .orange, label: String(localized: "Hard (<0.50)", bundle: LanguageManager.appBundle))
        }
        .font(.caption2)
        .foregroundStyle(AppTheme.textSecondary)
    }

    /// Group consecutive track points into segments of the same α1 band.
    /// Each segment carries its coordinate list and rendering colour.
    private struct Alpha1Segment {
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
    }

    private func alpha1RouteSegments(
        track: [CLLocation],
        samples: [WorkoutSample],
        startDate: Date
    ) -> [Alpha1Segment] {
        guard !track.isEmpty, !samples.isEmpty else { return [] }
        // Sample lookup: map offsetSec to α1. Only samples that have α1.
        let alphaByOffset: [Int: Double] = samples.reduce(into: [:]) { acc, s in
            if let a = s.alpha1 { acc[s.offsetSec] = a }
        }
        guard !alphaByOffset.isEmpty else { return [] }
        let sortedOffsets = alphaByOffset.keys.sorted()
        var builder = Alpha1SegmentBuilder()
        for fix in track {
            let offset = Int(fix.timestamp.timeIntervalSince(startDate).rounded())
            let color = Self.bandColor(atOffset: offset, alphaByOffset: alphaByOffset, sortedOffsets: sortedOffsets)
            builder.add(fix.coordinate, color: color)
        }
        return builder.finish()
    }

    /// Band colour from the nearest-earlier α1 sample to this track offset.
    private static func bandColor(atOffset offsetSec: Int, alphaByOffset: [Int: Double], sortedOffsets: [Int]) -> Color {
        var nearest: Double?
        for off in sortedOffsets {
            if off <= offsetSec { nearest = alphaByOffset[off] } else { break }
        }
        guard let a = nearest else { return AppTheme.textTertiary }
        if a >= HRVConstants.DFA.alpha1AerobicThreshold { return AppTheme.sage }
        if a >= HRVConstants.DFA.alpha1AnaerobicThreshold { return .yellow }
        return .orange
    }

    /// Accumulates coordinates into runs of one colour. Each boundary fix is
    /// added to BOTH the closing and the opening segment so the polylines meet
    /// without a visible gap.
    private struct Alpha1SegmentBuilder {
        private var segments: [Alpha1Segment] = []
        private var coords: [CLLocationCoordinate2D] = []
        private var color: Color = .clear

        mutating func add(_ coord: CLLocationCoordinate2D, color newColor: Color) {
            if coords.isEmpty {
                color = newColor
            } else if newColor != color {
                coords.append(coord)
                segments.append(Alpha1Segment(coordinates: coords, color: color))
                coords = []
                color = newColor
            }
            coords.append(coord)
        }

        mutating func finish() -> [Alpha1Segment] {
            if !coords.isEmpty {
                segments.append(Alpha1Segment(coordinates: coords, color: color))
            }
            return segments
        }
    }

    /// Local helper: compute a bounding region for a track. Named distinctly
    /// from the main file's `regionForTrack` so the extension compiles
    /// without a redeclaration collision.
    fileprivate func alpha1RegionForTrack(_ coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        MapBoundsHelper.region(for: coordinates)
    }
}

// MARK: - File-scope helpers
//
// Kept out of the view. Each touches none of the view's
// members — including its private statics —
// and calls nothing that stayed behind. `private` at file scope is
// fileprivate, so every call site in this file resolves as before.

/// Don't hide the first ~2 minutes of α1
/// even though the rolling DFA buffer is still filling — it's real
/// data, the user lived through it, hiding it was dishonest. Instead
/// we LABEL the short-lived dips as beat-artifact events (a neutral
/// "beat artifact" tag on the chart,
/// plus a one-line footer explaining what that means). The
/// threshold-crossing detectors (LT1 card, narrative, band stats)
/// already have a warmup + 180 s sustain guard so those dips can
/// never drive a lie like "you crossed LT1 at 4:00 on a 120 bpm
/// walk." The chart shows the truth; the analysis is still robust.
private func alpha1Points(_ samples: [WorkoutSample]) -> [(x: Double, y: Double)] {
    samples.compactMap { s in
        guard let a = s.alpha1 else { return nil }
        return (Double(s.offsetSec) / 60.0, a)
    }
}

@MainActor
private func alpha1StatsRow(stats: Alpha1ReportCards.Alpha1Stats, sampleCount: Int) -> some View {
    HStack(spacing: 18) {
        alpha1StatBlock(
            label: String(localized: "avg", bundle: LanguageManager.appBundle),
            value: stats.avgAlpha1.map { String(format: "%.2f", locale: .current, $0) } ?? "—"
        )
        alpha1StatBlock(
            label: String(localized: "max", bundle: LanguageManager.appBundle),
            value: stats.maxAlpha1.map { String(format: "%.2f", locale: .current, $0) } ?? "—"
        )
        alpha1StatBlock(
            label: String(localized: "min", bundle: LanguageManager.appBundle),
            value: stats.minAlpha1.map { String(format: "%.2f", locale: .current, $0) } ?? "—"
        )
        alpha1StatBlock(
            label: String(localized: "samples", bundle: LanguageManager.appBundle),
            value: "\(sampleCount)"
        )
    }
}

private func alpha1Line(_ alphaPoints: [(x: Double, y: Double)]) -> some ChartContent {
    ForEach(Array(alphaPoints.enumerated()), id: \.offset) { _, pt in
        LineMark(
            x: .value("Minutes", pt.x),
            y: .value("α1", pt.y)
        )
        .foregroundStyle(AppTheme.dustyRose)
        .interpolationMethod(.monotone)
    }
}

/// Beat-artifact footer — tells the user what the grey
/// marks on the chart mean, in plain English, without burying
/// the info in a help article.
@ViewBuilder
@MainActor
private func ectopicShadowFooter(_ ectopicShadows: [Alpha1ReportCards.EctopicShadow]) -> some View {
    if !ectopicShadows.isEmpty {
        let count = ectopicShadows.count
        let timeList = ectopicShadows
            .prefix(3)
            .map { String(format: "%d:%02d", $0.offsetSec / 60, $0.offsetSec % 60) }
            .joined(separator: ", ")
        let countLabel = count == 1
            ? String(localized: "1 beat-artifact dip", bundle: LanguageManager.appBundle)
            : String(localized: "\(count) beat-artifact dips", bundle: LanguageManager.appBundle)
        let timeLabel = count <= 3 ? timeList : "\(timeList)…"
        Text(String(localized: "\(countLabel) at \(timeLabel). One irregular or mis-detected beat left in the data pulls α1's 120-second rolling window down for about the window's length, producing a short dip that isn't a real threshold crossing. These dips are a data-cleaning note, not a heart-rhythm finding: they are excluded from LT1 / threshold detection and marked here so you can see where they were.", bundle: LanguageManager.appBundle))
            .font(.caption2)
            .foregroundStyle(AppTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
private func alpha1StatBlock(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
        Text(label.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AppTheme.textTertiary)
        Text(value)
            .font(.title3.monospacedDigit().weight(.semibold))
            .foregroundStyle(AppTheme.textPrimary)
    }
}

private func alpha1CacheKey(sessionId: UUID, samples: [WorkoutSample]) -> Alpha1StatsCache.Key {
    Alpha1StatsCache.Key(
        sessionId: sessionId,
        count: samples.count,
        firstAlphaOffset: samples.first(where: { $0.alpha1 != nil })?.offsetSec,
        lastAlphaOffset: samples.last(where: { $0.alpha1 != nil })?.offsetSec,
        alphaSampleCount: samples.lazy.compactMap { $0.alpha1 }.count
    )
}

/// Log MIN's provenance so we can verify the outlier rejection is actually
/// working on a real device without guessing. If the logged offset lands
/// inside a shadow range or near an ectopic dip, the filter's doing its job;
/// if it lands somewhere the chart looks clean, that's the next thing to
/// investigate.
///
/// Gated to DEBUG. The compute is memoized so this only
/// fires once per unique input, but DEBUG-only is the right baseline for
/// "MIN provenance" diagnostics — release builds shouldn't be exporting
/// per-render compute logs.
private func logAlpha1MinProvenance(min minVal: Double?, samples: [WorkoutSample], shadows: [Alpha1ReportCards.EctopicShadow], cleanCount: Int) {
    #if DEBUG
        guard let minVal else { return }
        let minSample = samples.first { ($0.alpha1 ?? .infinity) == minVal }
        let offset = minSample?.offsetSec ?? -1
        let shadowsDesc = shadows.map { "[\($0.startSec)-\($0.endSec)]" }.joined(separator: ",")
        debugLog("[α1Stats] MIN=\(String(format: "%.3f", minVal)) @ offset=\(offset)s · shadows=\(shadowsDesc) · clean-sample-count=\(cleanCount)/\(samples.compactMap(\.alpha1).count)")
    #endif
}

/// Collect α1 values that aren't inside an ectopic-shadow range.
/// Separated from `alpha1Stats` so the MAD-based outlier pass has a
/// clean input to work on without having to re-filter by shadow
/// inside the robust-stats helper.
private func collectCleanAlpha1Values(
    samples: [WorkoutSample],
    shadows: [Alpha1ReportCards.EctopicShadow]
) -> [Double] {
    samples.compactMap { s in
        guard let a = s.alpha1 else { return nil }
        if shadows.contains(where: { $0.contains(offsetSec: s.offsetSec) }) {
            return nil
        }
        return a
    }
}

/// MIN/MAX/AVG with Median-Absolute-Deviation outlier rejection. Any
/// α1 value more than 3×MAD below the median is treated as artifact
/// (ectopic-shadow recovery tail, single-sample fit quality blip) and
/// excluded from the summary stats. Chart still shows all samples —
/// only the numeric hero row gets the cleaned numbers. Returns `nil`
/// for each stat when the clean-sample count is too small to be
/// meaningful (< 30 samples).
private func robustMinMaxAvg(values: [Double]) -> (min: Double?, max: Double?, avg: Double?) {
    guard values.count >= 30 else {
        if values.isEmpty { return (nil, nil, nil) }
        let avg = values.reduce(0, +) / Double(values.count)
        return (values.min(), values.max(), avg)
    }
    let sorted = values.sorted()
    let median = sorted[sorted.count / 2]
    let deviations = values.map { abs($0 - median) }.sorted()
    let mad = deviations[deviations.count / 2]
    // Floor MAD at 0.05 so extremely tight α1 distributions (very
    // even effort) don't shrink the rejection band to nothing and
    // reject normal natural variation.
    let effectiveMAD = max(mad, 0.05)
    let lowerBound = median - 3.0 * effectiveMAD
    let upperBound = median + 3.0 * effectiveMAD
    let clean = values.filter { $0 >= lowerBound && $0 <= upperBound }
    guard !clean.isEmpty else { return (values.min(), values.max(), nil) }
    let avg = clean.reduce(0, +) / Double(clean.count)
    return (clean.min(), clean.max(), avg)
}

private func bandLegend(color: Color, label: String) -> some View {
    HStack(spacing: 4) {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 14, height: 4)
        Text(label)
    }
}
