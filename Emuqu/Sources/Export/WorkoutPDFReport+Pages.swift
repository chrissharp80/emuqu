import CoreGraphics
import CoreLocation
import Foundation
import MapKit
import PDFKit
import UIKit

// The splits page, the "What this means" page and their helpers, plus the
// shared drawing primitives the other workout-report pages call. Split out
// from WorkoutPDFReport.swift to keep that file under its line budget.
// Members are internal rather than `private` so the other extensions can
// call them.

extension WorkoutPDFRenderer {
    /// The best 1-minute HRR drop for the key-metrics grid, or "—".
    func oneMinuteHRRString() -> String {
        report.session.workoutMetadata?.hrrSamples?.bestAtOneMinute.map { "\($0.drop) bpm" } ?? "—"
    }

    // MARK: - Page: Splits + derived + HRR

    /// Long sessions run over several pages: a page that fills up gets the
    /// disclaimer footer and the next one continues where it stopped, so
    /// nothing is drawn past the citation block or off the page.
    func drawSplitsAndDerivedPage(ctx: UIGraphicsPDFRendererContext) {
        PDFReadingDirection.beginPage(ctx)
        var y = report.config.margin
        let contentW = report.config.pageSize.width - 2 * report.config.margin
        let bundle = LanguageManager.appBundle
        drawText(String(localized: "Splits & Metrics", bundle: bundle), at: CGPoint(x: report.config.margin, y: y), font: report.config.sectionFont, color: report.config.textPrimary)
        y += 32
        y = drawSplitsTable(y: y, ctx: ctx, bundle: bundle)
        ensureSplitsPageSpace(70, y: &y, ctx: ctx)
        y = drawHRRBlock(y: y, contentW: contentW, bundle: bundle)
        ensureSplitsPageSpace(28 + 14 * CGFloat(hrZoneSeconds().filter { $0 > 0 }.count), y: &y, ctx: ctx)
        y = drawZoneDistribution(y: y, contentW: contentW, bundle: bundle)
        ensureSplitsPageSpace(50, y: &y, ctx: ctx)
        y = drawPhysiologyBlock(y: y, contentW: contentW, bundle: bundle)
        drawSplitsFooter(contentW: contentW, bundle: bundle)
        drawFooter()
    }

    /// Lowest y the splits page content may reach: the citation block sits
    /// below it on the last page.
    private var splitsPageContentBottom: CGFloat {
        report.config.pageSize.height - report.config.margin - 64
    }

    /// Start a new page when `needed` points no longer fit above the
    /// citation block, closing the full page with its disclaimer footer.
    @discardableResult
    private func ensureSplitsPageSpace(_ needed: CGFloat, y: inout CGFloat, ctx: UIGraphicsPDFRendererContext) -> Bool {
        guard y + needed > splitsPageContentBottom else { return false }
        drawFooter()
        PDFReadingDirection.beginPage(ctx)
        y = report.config.margin
        return true
    }

    /// Resolved splits — re-bucketed from the GPS report.track when the stored splits
    /// do not match the user's current unit preference, so an old km-recorded
    /// report.session renders as mile splits for an imperial user. A table
    /// that runs past the page continues on the next with its header row.
    private func drawSplitsTable(y: CGFloat, ctx: UIGraphicsPDFRendererContext, bundle: Bundle) -> CGFloat {
        let splits = resolvedSplitsForPDF()
        guard !splits.isEmpty else { return y }
        var y = y
        drawText(String(localized: "Splits", bundle: bundle), at: CGPoint(x: report.config.margin, y: y), font: report.config.sectionFont, color: report.config.textPrimary)
        y += 18
        let colWs: [CGFloat] = [60, 120, 120, 120]
        y = drawSplitsHeaderRow(colWs: colWs, y: y, bundle: bundle)
        let unit = splitUnitLabel(splits, bundle: bundle)
        for split in splits {
            if ensureSplitsPageSpace(16, y: &y, ctx: ctx) {
                y = drawSplitsHeaderRow(colWs: colWs, y: y, bundle: bundle)
            }
            y = drawSplitRow(split: split, unit: unit, colWs: colWs, y: y)
        }
        y += 14
        return y
    }

    /// Infer the bucket unit from the longest split in the series — a partial
    /// tail split can be < 1500 m even on a mile-bucketed session, which would
    /// mislabel if decided per-row. A session shorter than one bucket has only
    /// that partial split, which says nothing about the bucket, so the user's
    /// unit preference (the bucket it was split with) decides.
    private func splitUnitLabel(_ splits: [Split], bundle: Bundle) -> String {
        let isMile = splits.count > 1
            ? (splits.map(\.distanceMeters).max() ?? 0) > 1500
            : report.units.resolved == .imperial
        return isMile ? String(localized: "mi", bundle: bundle) : String(localized: "km", bundle: bundle)
    }

    private func drawSplitsHeaderRow(colWs: [CGFloat], y: CGFloat, bundle: Bundle) -> CGFloat {
        var y = y
        // Header row
        let headers = ["#", String(localized: "Pace", bundle: bundle), String(localized: "Avg HR", bundle: bundle), String(localized: "Elev gain", bundle: bundle)]
        var x = report.config.margin
        for (i, h) in headers.enumerated() {
            drawText(h.uppercased(with: LanguageManager.appLocale), at: CGPoint(x: x, y: y), font: report.config.captionFont, color: report.config.textTertiary)
            x += colWs[i]
        }
        y += 14
        return y + 14
    }

    private func drawSplitRow(split: Split, unit: String, colWs: [CGFloat], y: CGFloat) -> CGFloat {
        let paceStr: String = {
            guard let p = split.averagePaceSecPerKm else { return "—" }
            return report.units.formatPace(secondsPerMeter: p / 1_000) ?? "—"
        }()
        let hrStr = split.averageHR.map { String(localized: "\(Int($0)) bpm", bundle: LanguageManager.appBundle) } ?? "—"
        let elevStr = split.elevationGainMeters.map { report.units.formatElevation(meters: $0) } ?? "—"
        let values = ["\(unit) \(split.index)", paceStr, hrStr, elevStr]
        var x = report.config.margin
        for (i, v) in values.enumerated() {
            drawText(v, at: CGPoint(x: x, y: y), font: report.config.monoFont, color: report.config.textPrimary)
            x += colWs[i]
        }
        return y + 16
    }

    private func drawHRRBlock(y: CGFloat, contentW: CGFloat, bundle: Bundle) -> CGFloat {
        guard let hrr = report.session.workoutMetadata?.hrrSamples else { return y }
        var y = y
        drawText(String(localized: "Heart Rate Recovery", bundle: bundle), at: CGPoint(x: report.config.margin, y: y), font: report.config.sectionFont, color: report.config.textPrimary)
        y += 18
        if hrr.isEmpty {
            drawText(String(localized: "No HR signal captured in the 60-120 s post-stop window.", bundle: bundle), at: CGPoint(x: report.config.margin, y: y), font: report.config.bodyFont, color: report.config.textSecondary)
            y += 14
        } else {
            let one = hrr.bestAtOneMinute
            let two = hrr.bestAtTwoMinutes
            let oneStr = one.map { String(localized: "\($0.drop) bpm (\($0.hr) bpm at +60s, \(provenanceLabel($0.provenance)))", bundle: bundle) } ?? String(localized: "not captured", bundle: bundle)
            let twoStr = two.map { String(localized: "\($0.drop) bpm (\($0.hr) bpm at +120s, \(provenanceLabel($0.provenance)))", bundle: bundle) } ?? String(localized: "not captured", bundle: bundle)
            drawText(String(localized: "1 min drop: \(oneStr)", bundle: bundle), at: CGPoint(x: report.config.margin, y: y), font: report.config.bodyFont, color: report.config.textPrimary)
            y += 14
            drawText(String(localized: "2 min drop: \(twoStr)", bundle: bundle), at: CGPoint(x: report.config.margin, y: y), font: report.config.bodyFont, color: report.config.textPrimary)
            y += 20
        }
        return y
    }

    private func drawZoneDistribution(y: CGFloat, contentW: CGFloat, bundle: Bundle) -> CGFloat {
        var y = y
        // HR zone distribution summary
        let zs = hrZoneSeconds()
        let total = zs.reduce(0, +)
        if total > 0 {
            drawText(String(localized: "HR Zone Distribution", bundle: bundle), at: CGPoint(x: report.config.margin, y: y), font: report.config.sectionFont, color: report.config.textPrimary)
            y += 18
            for (idx, secs) in zs.enumerated() where secs > 0 {
                let label = "Z\(idx + 1)"
                let pct = Int((Double(secs) / Double(total)) * 100)
                drawText("\(label):  \(PDFReadingDirection.isolated(PDFDurationText.minutesSeconds(secs)))  ·  \(pct)%", at: CGPoint(x: report.config.margin, y: y), font: report.config.monoFont, color: report.config.textPrimary)
                y += 14
            }
            y += 10
        }
        return y
    }

    private func drawPhysiologyBlock(y: CGFloat, contentW: CGFloat, bundle: Bundle) -> CGFloat {
        var y = y
        // Physiology
        drawText(String(localized: "Physiology", bundle: bundle), at: CGPoint(x: report.config.margin, y: y), font: report.config.sectionFont, color: report.config.textPrimary)
        y += 18
        if let d = report.session.workoutMetadata?.decouplingPercent {
            let desc = d <= WorkoutPDFReport.decouplingDriftPercent ? String(localized: "strong aerobic efficiency", bundle: bundle) : String(localized: "efficiency drifted", bundle: bundle)
            drawText(String(localized: "Pa:Hr Decoupling: \(String(format: "%+.1f", locale: LanguageManager.appLocale, d))% (\(desc))", bundle: bundle), at: CGPoint(x: report.config.margin, y: y), font: report.config.bodyFont, color: report.config.textPrimary)
            y += 14
        }
        if let ef = report.session.workoutMetadata?.efficiencyFactor {
            drawText(String(localized: "Efficiency Factor: \(Self.efficiencyFactorText(ef))  (speed in m/min ÷ avg HR)", bundle: bundle), at: CGPoint(x: report.config.margin, y: y), font: report.config.bodyFont, color: report.config.textPrimary)
            y += 14
        }
        return y
    }

    private func drawSplitsFooter(contentW: CGFloat, bundle: Bundle) {
        // Footer with research citations
        let footer = String(localized: "Methods — TRIMP: Banister 1991 (continuous HRR-based exponential) · HRSS: session TRIMP ÷ 1-hour-at-LTHR TRIMP × 100 · α1 aerobic-threshold proxy: Rogers & Gronwald 2021 (PMC7845545) · LTHR default 0.88 × HRmax (Friel) pending field-test override. All calculations anchored to user max HR / resting HR / LTHR, not session peak — so scores are comparable across sessions.", bundle: bundle)
        drawWrappedText(footer, at: CGPoint(x: report.config.margin, y: report.config.pageSize.height - report.config.margin - 58), width: contentW, font: report.config.captionFont, color: report.config.textTertiary, lineHeight: 11)
    }

    /// Efficiency factor as stored is speed in m/s ÷ bpm (about 0.02); shown
    /// as m/min per beat (about 1–2) so two decimals carry information.
    static func efficiencyFactorText(_ ef: Double) -> String {
        String(format: "%.2f", locale: LanguageManager.appLocale, ef * 60)
    }

    /// The "strong" bar for the efficiency bullet, in m/min per beat: about
    /// Friel's 1.8 yards/min per beat for running. Speed-based EF only means
    /// anything for running, so the bullet is limited to running sports.
    static let strongRunningEfficiency = 1.65

    // MARK: - Helpers

    /// Cap per-chart point count on the printed page. 250 points is more
    /// than the human eye can resolve on a Letter-size chart width, and
    /// keeps the path-build fast with no visible quality difference. 250 × 5 charts = 1 250 total
    /// line segments, well within CoreGraphics's sub-frame budget.
    static let maxPDFPoints = 250

    /// Bucket-average a long (x, y) series down to at most `target`
    /// points. Preserves the shape of the curve — each output bucket
    /// is the time-midpoint + mean-value of the source samples that
    /// landed in it. A 3 700-point α1 series on a 63-min walk comes out
    /// to `maxPDFPoints` (250) points here, drawing far faster and visually
    /// identical on a PDF page.
    static func downsample(_ points: [(Double, Double)], target: Int) -> [(Double, Double)] {
        guard points.count > target, target > 4 else { return points }
        let bucketSize = Double(points.count) / Double(target)
        var out: [(Double, Double)] = []
        out.reserveCapacity(target)
        for i in 0 ..< target {
            let start = Int(Double(i) * bucketSize)
            let end = min(points.count, Int(Double(i + 1) * bucketSize))
            guard end > start else { continue }
            var sumX = 0.0, sumY = 0.0
            for j in start ..< end {
                sumX += points[j].0
                sumY += points[j].1
            }
            let n = Double(end - start)
            out.append((sumX / n, sumY / n))
        }
        return out
    }

    func drawText(_ text: String, at origin: CGPoint, font: UIFont, color: UIColor) {
        PDFPagePrimitives.drawText(text, at: origin, font: font, color: color)
    }

    /// Wrapped text at its full measured height (`PDFPagePrimitives`); returns
    /// the y 4 pt below it.
    @discardableResult
    func drawWrappedText(_ text: String, at origin: CGPoint, width: CGFloat, font: UIFont, color: UIColor, lineHeight: CGFloat) -> CGFloat {
        PDFPagePrimitives.drawWrappedText(text, at: origin, width: width, font: font, color: color, lineHeight: lineHeight) + 4
    }

    func formatDuration(_ sec: Int) -> String {
        PDFPagePrimitives.formatDuration(sec)
    }

    func avgPaceString() -> String {
        guard let dist = report.session.workoutMetadata?.distanceMeters, dist > 100,
              let dur = report.session.duration, dur > 10 else { return "—" }
        return report.units.formatPace(elapsedSec: Int(dur), distanceMeters: dist) ?? "—"
    }

    func peakHRString() -> String {
        let samples = report.session.workoutMetadata?.samples ?? []
        if let peak = samples.compactMap({ $0.heartRate }).max() { return "\(peak) bpm" }
        return "—"
    }

    func calorieString() -> String {
        guard let samples = report.session.workoutMetadata?.samples,
              let duration = report.session.duration else { return "—" }
        let mets = samples.compactMap(\.mets)
        guard !mets.isEmpty else { return "—" }
        let avgMETs = mets.reduce(0, +) / Double(mets.count)
        let weight = AppDependencies.current.app.settingsManager.settingsSnapshot.effectiveBodyWeightKg
        let kcal = (avgMETs * 3.5 * weight * (duration / 60.0)) / 200.0
        return String(format: "%.0f kcal", locale: LanguageManager.appLocale, kcal)
    }

    /// Fastest full split from the same splits the table shows
    /// (`resolvedSplitsForPDF`); a short last split does not count.
    func bestSplitString() -> String {
        let splits = resolvedSplitsForPDF()
        guard let fullDistance = splits.map(\.distanceMeters).max(), fullDistance > 0 else { return "—" }
        let paced = splits.compactMap { s -> Double? in
            guard s.distanceMeters >= fullDistance * 0.99, let p = s.averagePaceSecPerKm, p > 0 else { return nil }
            return p
        }
        guard let best = paced.min() else { return "—" }
        return report.units.formatPace(secondsPerMeter: best / 1_000) ?? "—"
    }

    /// The mean α1 the statistics table prints (`alpha1Stats`, beat-artifact
    /// samples left out), so page 1 and page 2 agree.
    func alphaAvgString() -> String {
        guard let avg = alpha1Stats().avgAlpha1 else { return "—" }
        return String(format: "%.2f", locale: LanguageManager.appLocale, avg)
    }

    func provenanceLabel(_ p: HRRSample.Provenance) -> String {
        switch p {
        case .strap: return String(localized: "strap", bundle: LanguageManager.appBundle)
        case .watchSamples: return "Apple Watch"
        case .healthKitComputed: return "Apple Health"
        }
    }

    /// Return the splits array the PDF should render. Same logic the
    /// on-screen summary uses: prefer stored splits when they match the
    /// user's unit preference; otherwise recompute from the GPS report.track
    /// so old km-recorded sessions display as mile splits for imperial
    /// users. Falls back to the stored values when no report.track is available.
    func resolvedSplitsForPDF() -> [Split] {
        let stored = report.session.workoutMetadata?.splits ?? []
        let wantsMile = report.units.resolved == .imperial
        let storedIsMile = (stored.first?.distanceMeters ?? 0) > 1500
        if !stored.isEmpty, storedIsMile == wantsMile {
            return stored
        }
        guard !report.track.isEmpty else { return stored }
        let bucket: Double = wantsMile ? 1609.344 : 1000.0
        let recomputed = WorkoutAnalyzer.computeSplits(
            track: report.track,
            rrPoints: report.session.rrSeries?.points ?? [],
            startDate: report.session.startDate,
            splitDistanceMeters: bucket
        )
        return recomputed.isEmpty ? stored : recomputed
    }

    func hrZoneSeconds() -> [Int] {
        Self.hrZoneSeconds(samples: report.session.workoutMetadata?.samples ?? [], maxHR: report.userMaxHR)
    }

    /// Seconds in each %HRmax zone (50-60 / 60-70 / 70-80 / 80-90 / 90+;
    /// under 50 % is not zone time). Each sample stands for the seconds since
    /// the previous one, 1 to 5 and 1 for the first
    /// (`Alpha1ReportCards.sampleSeconds`), so a pause or dropout is not
    /// credited as time in a zone — the timing the stored snapshot uses.
    nonisolated static func hrZoneSeconds(samples: [WorkoutSample], maxHR: Int) -> [Int] {
        var zs = [0, 0, 0, 0, 0]
        var prev: Int?
        for s in samples {
            let dt = Alpha1ReportCards.sampleSeconds(at: s.offsetSec, previous: prev)
            prev = s.offsetSec
            guard let hr = s.heartRate, maxHR > 0 else { continue }
            let f = Double(hr) / Double(maxHR)
            switch f {
            case ..<0.50: break
            case 0.50 ..< 0.60: zs[0] += dt
            case 0.60 ..< 0.70: zs[1] += dt
            case 0.70 ..< 0.80: zs[2] += dt
            case 0.80 ..< 0.90: zs[3] += dt
            default: zs[4] += dt
            }
        }
        return zs
    }

    // MARK: α1 analytics (shared with the SwiftUI summary card)

    struct Alpha1Stats {
        let avgAlpha1: Double?
        let maxAlpha1: Double?
        let minAlpha1: Double?
        let secondsBelowAT1: Int
        let secondsBetween: Int
        let secondsAboveAT2: Int
        var totalSec: Int { secondsBelowAT1 + secondsBetween + secondsAboveAT2 }
    }

    /// Band seconds from the calculation the on-screen α1 card and the
    /// stored snapshot use (`Alpha1ReportCards.alpha1BandTotals`), and the
    /// mean/min/max of the α1 samples outside a beat-artifact dip
    /// (`Alpha1ReportCards.ectopicShadows(in:)`).
    func alpha1Stats() -> Alpha1Stats {
        let samples = report.session.workoutMetadata?.samples ?? []
        let shadows = Alpha1ReportCards.ectopicShadows(in: samples)
        let bands = Alpha1ReportCards.alpha1BandTotals(samples: samples, shadows: shadows)
        let clean = samples.compactMap { sample -> Double? in
            guard let alpha = sample.alpha1, !Self.isBeatArtifact(sample, shadows: shadows) else { return nil }
            return alpha
        }
        return Alpha1Stats(
            avgAlpha1: clean.isEmpty ? nil : clean.reduce(0, +) / Double(clean.count),
            maxAlpha1: clean.max(),
            minAlpha1: clean.min(),
            secondsBelowAT1: bands.belowAT1,
            secondsBetween: bands.between,
            secondsAboveAT2: bands.aboveAT2
        )
    }

    /// Whether the sample falls inside a beat-artifact dip of the α1 trace.
    private static func isBeatArtifact(_ sample: WorkoutSample, shadows: [Alpha1ReportCards.EctopicShadow]) -> Bool {
        shadows.contains { $0.contains(offsetSec: sample.offsetSec) }
    }

    /// The first sustained downward AT1 crossing, from the detector the
    /// on-screen α1 card uses (`Alpha1ReportCards.AT1CrossDetector` through
    /// `alpha1BandTotals`): 120 s warmup + 180 s sustain, with the same
    /// sample timing and beat-artifact exclusion.
    /// The sustain length is deliberately > the α1 rolling-window length so
    /// a single ectopic beat (which contaminates exactly one
    /// window-length of samples) cannot satisfy the sustain check. 180 s
    /// aligns with Rogers & Gronwald's >= 3-min ramp-phase protocol.
    ///
    /// A downward crossing needs α1 to have been at or above 0.75 after the
    /// warm-up first; a session already below it at 2:00 never crossed, and
    /// reported its 2:00 heart rate as the LT1 estimate.
    func firstDownwardAT1Crossing() -> (offsetSec: Int, hr: Int?)? {
        let samples = report.session.workoutMetadata?.samples ?? []
        let shadows = Alpha1ReportCards.ectopicShadows(in: samples)
        guard let crossing = Alpha1ReportCards.alpha1BandTotals(samples: samples, shadows: shadows).firstCrossing else { return nil }
        return (offsetSec: crossing.0, hr: crossing.1)
    }

    // MARK: - Hero verdict (page 1)

    /// Status colour for a metric — drives the colored "→" arrow.
    /// Mirrors the recovery-PDF pattern (sage = good, dustyRose = mid,
    /// terracotta primary = caution).
    enum Verdict {
        case good, neutral, caution
        var color: UIColor {
            switch self {
            case .good: UIColor(red: 0.20, green: 0.55, blue: 0.35, alpha: 1.0) // deeper sage
            case .neutral: UIColor(red: 0.55, green: 0.45, blue: 0.30, alpha: 1.0) // amber
            case .caution: UIColor(red: 0.79, green: 0.33, blue: 0.25, alpha: 1.0) // terracotta
            }
        }
    }

    /// One-line plain-English report.session verdict — "easy aerobic", "tempo",
    /// "threshold work", "VO2max session", or a fatigue/freshness note.
    /// Synthesises α1 average, peak HR%, and HRR drop into a single phrase
    /// the reader can grasp in 2 seconds.
    func sessionVerdict() -> (label: String, blurb: String, kind: Verdict) {
        let bundle = LanguageManager.appBundle
        let stats = alpha1Stats()
        let peakHR = report.session.workoutMetadata?.samples?.compactMap { $0.heartRate }.max()
        let pctMax = peakHR.map { report.userMaxHR > 0 ? Double($0) / Double(report.userMaxHR) : 0 } ?? 0
        let hrr = report.session.workoutMetadata?.hrrSamples?.bestAtOneMinute?.drop ?? 0
        let durationMin = Int((report.session.duration ?? 0) / 60)
        if let verdict = alphaVerdict(stats: stats, durationMin: durationMin, bundle: bundle) {
            return verdict
        }
        return heartRateVerdict(pctMax: pctMax, hrr: hrr, durationMin: durationMin, bundle: bundle)
    }

    /// α1 is the sharper signal when it is available — it distinguishes the
    /// three training bands directly rather than inferring them from HR, so a
    /// single HR peak does not override an easy α1 (page 2's α1 reading says
    /// the same). "The whole way" is claimed only when no α1 time fell below
    /// 0.75; an easy average with some threshold minutes says it averaged above.
    private func alphaVerdict(stats: Alpha1Stats, durationMin: Int, bundle: Bundle) -> (label: String, blurb: String, kind: Verdict)? {
        if let a = stats.avgAlpha1, a >= HRVConstants.DFA.alpha1AerobicThreshold {
            let wholeWay = stats.secondsBetween == 0 && stats.secondsAboveAT2 == 0
            return (
                String(localized: "Easy aerobic — building base", bundle: bundle),
                wholeWay
                    ? String(localized: "\(durationMin)-min Z2 work, α1 stayed above 0.75 the whole way. Body absorbed the load cleanly.", bundle: bundle)
                    : String(localized: "\(durationMin)-min Z2 work, α1 averaged above 0.75. Body absorbed the load cleanly.", bundle: bundle),
                .good
            )
        }
        return hardAlphaVerdict(avgAlpha: stats.avgAlpha1, durationMin: durationMin, bundle: bundle)
    }

    /// The two bands above easy: below LT2, and between LT1 and LT2.
    private func hardAlphaVerdict(avgAlpha: Double?, durationMin: Int, bundle: Bundle) -> (label: String, blurb: String, kind: Verdict)? {
        if let a = avgAlpha, a < 0.50 {
            return (
                String(localized: "Hard intervals — VO2max territory", bundle: bundle),
                String(localized: "\(durationMin)-min session driven mostly above LT2. High-cost work — recover hard tomorrow.", bundle: bundle),
                .caution
            )
        }
        if let a = avgAlpha, a >= 0.50, a < 0.75 {
            return (
                String(localized: "Threshold work — productive load", bundle: bundle),
                String(localized: "\(durationMin)-min session in the LT1–LT2 band. Targeted lactate-clearance adaptation.", bundle: bundle),
                .good
            )
        }
        return nil
    }

    /// Fallback when α1 was not computed: peak HR share, then HRR.
    private func heartRateVerdict(pctMax: Double, hrr: Int, durationMin: Int, bundle: Bundle) -> (label: String, blurb: String, kind: Verdict) {
        if pctMax >= 0.85 {
            return (
                String(localized: "Hard effort — quality session", bundle: bundle),
                String(localized: "\(durationMin)-min session, peak HR at \(Int(pctMax*100))% max. High internal load — needs full recovery.", bundle: bundle),
                .caution
            )
        }
        if pctMax >= 0.75 {
            return (
                String(localized: "Tempo — moderate-hard", bundle: bundle),
                String(localized: "\(durationMin)-min session at sub-threshold intensity. Balanced load.", bundle: bundle),
                .good
            )
        }
        return recoveryVerdict(hrr: hrr, durationMin: durationMin, bundle: bundle)
    }

    /// Nothing in the effort signals stood out, so read the recovery drop.
    private func recoveryVerdict(hrr: Int, durationMin: Int, bundle: Bundle) -> (label: String, blurb: String, kind: Verdict) {
        if hrr < 12, hrr > 0 {
            return (
                String(localized: "Easy effort — but HRR low", bundle: bundle),
                String(localized: "Recovery drop only \(hrr) bpm — could be fatigue, dehydration, or stale baseline.", bundle: bundle),
                .neutral
            )
        }
        return (
            String(localized: "Easy effort", bundle: bundle),
            String(localized: "\(durationMin)-min session at sub-tempo intensity.", bundle: bundle),
            .good
        )
    }

    /// Draw the hero verdict block — colored bar, big label, supporting
    /// blurb. Mirrors the recovery PDF's "63 ms · Excellent" pattern but
    /// adapted to a workout's effort-classification axis.
    func drawHeroVerdict(at y: inout CGFloat, contentW: CGFloat) {
        let v = sessionVerdict()
        let boxRect = CGRect(x: report.config.margin, y: y, width: contentW, height: 76)
        fillVerdictCard(boxRect, colour: v.kind.color, tint: 0.10)
        drawText(v.label,
                 at: CGPoint(x: boxRect.minX + 18, y: boxRect.minY + 12),
                 font: UIFont.systemFont(ofSize: 18, weight: .heavy),
                 color: v.kind.color)
        _ = drawWrappedText(v.blurb,
                            at: CGPoint(x: boxRect.minX + 18, y: boxRect.minY + 38),
                            width: boxRect.width - 36,
                            font: UIFont.systemFont(ofSize: 11, weight: .regular),
                            color: report.config.textPrimary,
                            lineHeight: 14)
        y += boxRect.height + 14
    }

    // MARK: - Status arrow (deep-dive pages)

    /// "→ Plain-English status" line in colored text. Used after key
    /// metrics on the autonomic / cardiopulmonary / splits pages so the
    /// reader gets one-line interpretation without having to guess.
    func drawStatusArrow(_ text: String, kind: Verdict, at y: inout CGFloat) {
        let arrow = PDFReadingDirection.bullet + " " + text
        drawText(arrow,
                 at: CGPoint(x: report.config.margin, y: y),
                 font: UIFont.systemFont(ofSize: 10, weight: .medium),
                 color: kind.color)
        y += 14
    }

    // MARK: - "What This Means" page

    /// A plain-English bridge between the dense clinical pages and an
    /// athlete who doesn't read sports-physiology papers. Mirrors the
    /// recovery PDF's "What This Means" page layout: colored verdict
    /// callout, numbered "What's working", "Watch", and arrow-bulleted
    /// "Tomorrow" sections. Empty sections are skipped so we never pad
    /// with noise.
    func drawWhatThisMeansPage(ctx: UIGraphicsPDFRendererContext) {
        PDFReadingDirection.beginPage(ctx)
        let contentW = report.config.pageSize.width - 2 * report.config.margin
        let bundle = LanguageManager.appBundle
        var y = drawWhatThisMeansTitle(y: report.config.margin, contentW: contentW, bundle: bundle)
        y = drawPrimaryAssessmentCallout(y: y, contentW: contentW, bundle: bundle)
        y = drawWhatThisMeansBullets(y: y, contentW: contentW, bundle: bundle)
        drawWhatThisMeansDisclaimer(y: y, contentW: contentW, bundle: bundle)
        drawFooter()
    }

    private func drawWhatThisMeansTitle(y: CGFloat, contentW: CGFloat, bundle: Bundle) -> CGFloat {
        var y = y
        // Page title
        drawText(String(localized: "WHAT THIS MEANS", bundle: bundle),
                 at: CGPoint(x: report.config.margin, y: y),
                 font: UIFont.systemFont(ofSize: 22, weight: .heavy),
                 color: report.config.textPrimary)
        y += 32
        drawDivider(at: y, width: contentW, strong: true)
        y += 16
        return y
    }

    private func drawPrimaryAssessmentCallout(y: CGFloat, contentW: CGFloat, bundle: Bundle) -> CGFloat {
        // Primary assessment callout (mirrors recovery PDF's green box)
        let v = sessionVerdict()
        let callRect = CGRect(x: report.config.margin, y: y, width: contentW, height: 92)
        fillVerdictCard(callRect, colour: v.kind.color, tint: 0.12)
        drawText(v.label,
                 at: CGPoint(x: callRect.minX + 18, y: callRect.minY + 12),
                 font: UIFont.systemFont(ofSize: 16, weight: .heavy),
                 color: v.kind.color)
        drawText(String(localized: "Primary Assessment", bundle: bundle),
                 at: CGPoint(x: callRect.minX + 18, y: callRect.minY + 34),
                 font: UIFont.systemFont(ofSize: 9, weight: .regular),
                 color: report.config.textTertiary)
        _ = drawWrappedText(v.blurb,
                            at: CGPoint(x: callRect.minX + 18, y: callRect.minY + 50),
                            width: callRect.width - 36,
                            font: UIFont.systemFont(ofSize: 11, weight: .regular),
                            color: report.config.textPrimary,
                            lineHeight: 14)
        return y + callRect.height + 18
    }

    /// The three bullet runs, in reading order.
    ///
    /// One parameterised run rather than three near-identical blocks differing
    /// only in title, colour, bullet glyph and cap. The cap ("What's working"
    /// shows five points where the other two show three) is a parameter
    /// rather than a transcription, so it cannot drift.
    private func drawWhatThisMeansBullets(y: CGFloat, contentW: CGFloat, bundle: Bundle) -> CGFloat {
        var y = drawBulletSection(
            title: String(localized: "WHAT'S WORKING", bundle: bundle),
            points: whatsWorkingPoints(), limit: 5, colour: Verdict.good.color,
            glyph: nil, y: y, contentW: contentW
        )
        y = drawBulletSection(
            title: String(localized: "WATCH", bundle: bundle),
            points: whatToWatchPoints(), limit: 3, colour: Verdict.caution.color,
            glyph: nil, y: y, contentW: contentW
        )
        return drawBulletSection(
            title: String(localized: "FOR TOMORROW", bundle: bundle),
            points: forTomorrowPoints(), limit: 3, colour: Verdict.good.color,
            glyph: PDFReadingDirection.bullet, y: y, contentW: contentW
        )
    }

    private func drawWhatThisMeansDisclaimer(y: CGFloat, contentW: CGFloat, bundle: Bundle) {
        // Disclaimer (mirrors recovery PDF)
        let disclaimer = String(localized: "Note: This analysis is for informational purposes only and should not be used as a substitute for professional medical or coaching advice.", bundle: bundle)
        _ = drawWrappedText(disclaimer,
                            at: CGPoint(x: report.config.margin, y: y + 6),
                            width: contentW,
                            font: report.config.captionFont,
                            color: report.config.textTertiary,
                            lineHeight: 11)

    }

    /// One titled run of bullets. `glyph` nil draws a filled dot; a non-nil glyph
    /// (the "→" of the Tomorrow section) is drawn as text instead. Returns the y
    /// it was handed when there is nothing to say, so an empty section pads with
    /// nothing rather than a bare heading.
    private func drawBulletSection(
        title: String,
        points: [String],
        limit: Int,
        colour: UIColor,
        glyph: String?,
        y: CGFloat,
        contentW: CGFloat
    ) -> CGFloat {
        guard !points.isEmpty else { return y }
        drawText(title,
                 at: CGPoint(x: report.config.margin, y: y),
                 font: UIFont.systemFont(ofSize: 11, weight: .bold),
                 color: report.config.primary)
        var y = y + 18
        for point in points.prefix(limit) {
            y = drawBullet(point, colour: colour, glyph: glyph, y: y, contentW: contentW)
        }
        return y + 8
    }

    private func drawBullet(
        _ point: String,
        colour: UIColor,
        glyph: String?,
        y: CGFloat,
        contentW: CGFloat
    ) -> CGFloat {
        let inset: CGFloat = glyph == nil ? 16 : 20
        let markX = report.config.margin + 2
        if let glyph {
            drawText(glyph, at: CGPoint(x: markX, y: y), font: UIFont.systemFont(ofSize: 11, weight: .bold), color: colour)
        } else {
            colour.setFill()
            UIBezierPath(ovalIn: CGRect(x: markX, y: y + 6, width: 5, height: 5)).fill()
        }
        let textX = report.config.margin + inset
        return drawWrappedText(point,
                               at: CGPoint(x: textX, y: y),
                               width: contentW - inset,
                               font: UIFont.systemFont(ofSize: 11, weight: .regular),
                               color: report.config.textPrimary,
                               lineHeight: 14) + 4
    }

    /// "What's working" bullets — pull genuinely positive signals only.
    /// Order: HRR, α1, decoupling, EF.
    func whatsWorkingPoints() -> [String] {
        let bundle = LanguageManager.appBundle
        let meta = report.session.workoutMetadata
        var out: [String] = []
        if let line = hrrWorkingPoint(meta: meta, bundle: bundle) { out.append(line) }
        if let line = alphaWorkingPoint(bundle: bundle) { out.append(line) }
        if let dec = meta?.decouplingPercent, dec <= WorkoutPDFReport.decouplingDriftPercent {
            out.append(String(localized: "Pa:Hr decoupling at \(String(format: "%+.1f%%", locale: LanguageManager.appLocale, dec)) — well coupled, fitness held the workload through the whole session.", bundle: bundle))
        }
        if let ef = meta?.efficiencyFactor, ef * 60 >= Self.strongRunningEfficiency,
           let sport = meta?.sport, [Sport.run, .trailRun, .treadmill].contains(sport) {
            out.append(String(localized: "Efficiency factor \(Self.efficiencyFactorText(ef)) — strong pace-per-beat output, aerobic economy in good shape.", bundle: bundle))
        }
        return out
    }

    private func alphaWorkingPoint(bundle: Bundle) -> String? {
        var out: [String] = []
        let stats = alpha1Stats()
        if stats.totalSec > 60 {
            if stats.secondsAboveAT2 == 0, stats.secondsBetween == 0 {
                out.append(String(localized: "DFA α1 stayed above 0.75 the whole way — pure aerobic-base territory, exactly what Z2 work targets.", bundle: bundle))
            } else if stats.secondsAboveAT2 > 0 {
                let hardMin = stats.secondsAboveAT2 / 60
                out.append(String(localized: "Spent \(hardMin) min above LT2 (α1 < 0.50) — banking VO2max-stimulus minutes.", bundle: bundle))
            } else if stats.secondsBetween > 0 {
                let thrMin = stats.secondsBetween / 60
                out.append(String(localized: "\(thrMin) min in the LT1–LT2 band — productive threshold work.", bundle: bundle))
            }
        }
        return out.first
    }

    /// "Watch" bullets — only fire when there's a real concern. Empty
    /// for textbook-clean sessions. Don't pad.
    func whatToWatchPoints() -> [String] {
        let bundle = LanguageManager.appBundle
        var out: [String] = []
        let meta = report.session.workoutMetadata

        if let dec = meta?.decouplingPercent, dec > WorkoutPDFReport.decouplingDriftPercent {
            if dec >= 7 {
                out.append(String(localized: "Pa:Hr decoupling \(String(format: "%+.1f%%", locale: LanguageManager.appLocale, dec)) is past the 7% threshold — meaningful cardiac drift. Most likely cause: dehydration, heat, or under-fueling for this duration.", bundle: bundle))
            } else {
                out.append(String(localized: "Pa:Hr decoupling \(String(format: "%+.1f%%", locale: LanguageManager.appLocale, dec)) is borderline — fitness mostly held but the second half cost more cardiac output than the first. Worth checking hydration on similar efforts.", bundle: bundle))
            }
        }
        if let one = meta?.hrrSamples?.bestAtOneMinute, one.drop < 12, one.drop > 0 {
            out.append(String(localized: "HRR drop only \(one.drop) bpm — sub-threshold for normal vagal reactivation. If you see this across multiple sessions, look at sleep, hydration, or accumulated fatigue.", bundle: bundle))
        }
        if report.userMaxHR > 0,
           let peak = meta?.samples?.compactMap({ $0.heartRate }).max(),
           Double(peak) / Double(report.userMaxHR) > 1.02 {
            out.append(String(localized: "Peak HR \(peak) bpm exceeded your configured max (\(report.userMaxHR)) — consider updating HRmax in Settings. With the max set too low, TRIMP is over-counted and HRSS is distorted.", bundle: bundle))
        }
        return out
    }

    /// "For tomorrow" — specific actions only. Don't lecture. Don't
    /// give generic "rest" advice when the report.session was easy.
    func forTomorrowPoints() -> [String] {
        let bundle = LanguageManager.appBundle
        let meta = report.session.workoutMetadata
        let stats = alpha1Stats()
        var out: [String] = []
        if stats.totalSec > 60 { out.append(tomorrowEffortAdvice(stats: stats, bundle: bundle)) }
        if let dec = meta?.decouplingPercent, dec > WorkoutPDFReport.decouplingDriftPercent {
            out.append(String(localized: "Decoupling was elevated — front-load fluids and carbs earlier in the next long effort. If heat was a factor, shift the start time earlier.", bundle: bundle))
        }
        // Same gate as the "Watch" bullet: a zero or negative drop is a
        // capture problem, not a low recovery.
        if let one = meta?.hrrSamples?.bestAtOneMinute, one.drop < 12, one.drop > 0 {
            out.append(String(localized: "Low HRR worth a check — sleep, hydration, alcohol the night before? Pattern over 3+ sessions matters more than any single reading.", bundle: bundle))
        }
        return out
    }

    /// What tomorrow should look like, given how hard today actually was.
    private func tomorrowEffortAdvice(stats: Alpha1Stats, bundle: Bundle) -> String {
        if stats.secondsAboveAT2 > 300 {
            return String(localized: "Hard interval work today — tomorrow is recovery. Easy 30-45 min Z2 or full rest; let HRV reset before the next quality session.", bundle: bundle)
        }
        if stats.secondsBetween > 600 {
            return String(localized: "Threshold session today — tomorrow easy aerobic only (Z1-Z2, 30-60 min). Two consecutive threshold days rarely produces extra adaptation.", bundle: bundle)
        }
        if stats.secondsBelowAT1 > 1200 {
            return String(localized: "Long aerobic session — body's primed for either another easy day or a quality session tomorrow depending on TSB. Either is sustainable.", bundle: bundle)
        }
        return String(localized: "Light session — no recovery debt. Train as planned tomorrow.", bundle: bundle)
    }
}

// MARK: - File-scope helpers
//
// Kept out of WorkoutPDFReport. Each names no member of the
// type and calls nothing inside it, so none needs to be a member.
// `private` at file scope is fileprivate, so every call site in this
// file resolves the same way.

/// Rounded tinted card with a solid accent bar down its left edge. Shared by
/// the hero verdict and the "What This Means" primary assessment, which drew
/// the same shape at two different tints.
private func fillVerdictCard(_ rect: CGRect, colour: UIColor, tint: CGFloat) {
    colour.withAlphaComponent(tint).setFill()
    UIBezierPath(roundedRect: rect, cornerRadius: 10).fill()
    colour.setFill()
    UIBezierPath(rect: CGRect(x: rect.minX, y: rect.minY, width: 5, height: rect.height)).fill()
}

private func hrrWorkingPoint(meta: WorkoutMetadata?, bundle: Bundle) -> String? {
    var out: [String] = []
    if let one = meta?.hrrSamples?.bestAtOneMinute {
        if one.drop >= 25 {
            out.append(String(localized: "HRR drop of \(one.drop) bpm in the first minute — a fast recovery, typical of well-trained aerobic athletes.", bundle: bundle))
        } else if one.drop >= 18 {
            out.append(String(localized: "HRR drop of \(one.drop) bpm in 60 s — strong vagal reactivation, in line with a fit aerobic athlete.", bundle: bundle))
        } else if one.drop >= 12 {
            out.append(String(localized: "HRR drop of \(one.drop) bpm in 60 s — at or above the 12 bpm convention.", bundle: bundle))
        }
    }
    return out.first
}
