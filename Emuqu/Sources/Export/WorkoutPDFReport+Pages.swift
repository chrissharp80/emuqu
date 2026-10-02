import CoreGraphics
import CoreLocation
import Foundation
import MapKit
import PDFKit
import UIKit

// Split out from WorkoutPDFReport.swift to keep
// the primary file under the 1500-line tech-debt budget. Holds page-3+
// renderers and chart helpers; head file keeps cover, summary,
// autonomic, cardio, terrain and methodology pages plus generate().
// Methods on WorkoutPDFReport are internal rather than `private`
// so this extension can call them.

extension WorkoutPDFRenderer {
    func hrrDropString(minute: Int) -> String {
        let hrr = report.session.workoutMetadata?.hrrSamples
        if minute == 1, let s = hrr?.bestAtOneMinute { return "\(s.drop) bpm" }
        if minute == 2, let s = hrr?.bestAtTwoMinutes { return "\(s.drop) bpm" }
        return "—"
    }

    // MARK: - Page: Splits + derived + HRR

    func drawSplitsAndDerivedPage(ctx: UIGraphicsPDFRendererContext) {
        ctx.beginPage()
        var y = report.config.margin
        let contentW = report.config.pageSize.width - 2 * report.config.margin
        let bundle = LanguageManager.appBundle
        drawText(String(localized: "Splits & Metrics", bundle: bundle), at: CGPoint(x: report.config.margin, y: y), font: report.config.sectionFont, color: report.config.textPrimary)
        y += 32
        y = drawSplitsTable(y: y, bundle: bundle)
        y = drawHRRBlock(y: y, contentW: contentW, bundle: bundle)
        y = drawZoneDistribution(y: y, contentW: contentW, bundle: bundle)
        y = drawPhysiologyBlock(y: y, contentW: contentW, bundle: bundle)
        drawSplitsFooter(y: y, contentW: contentW, bundle: bundle)
    }

    /// Resolved splits — re-bucketed from the GPS report.track when the stored splits
    /// do not match the user's current unit preference, so an old km-recorded
    /// report.session renders as mile splits for an imperial user.
    private func drawSplitsTable(y: CGFloat, bundle: Bundle) -> CGFloat {
        let splits = resolvedSplitsForPDF()
        guard !splits.isEmpty else { return y }
        var y = y
        drawText(String(localized: "Splits", bundle: bundle), at: CGPoint(x: report.config.margin, y: y), font: report.config.sectionFont, color: report.config.textPrimary)
        y += 18
        let colWs: [CGFloat] = [60, 120, 120, 120]
        y = drawSplitsHeaderRow(colWs: colWs, y: y, bundle: bundle)
        // Rows
        // Infer bucket unit from the longest split in the series — a
        // partial tail split can be < 1500 m even on a mile-bucketed
        // report.session, which would mislabel if decided per-row.
        let bucketLongest = splits.map(\.distanceMeters).max() ?? 0
        let isMileSeries = bucketLongest > 1500
        let unit = isMileSeries ? "mi" : "km"
        for split in splits {
            y = drawSplitRow(split: split, unit: unit, colWs: colWs, y: y)
            if y > report.config.pageSize.height - report.config.margin - 120 { break }
        }
        y += 14
        return y
    }

    private func drawSplitsHeaderRow(colWs: [CGFloat], y: CGFloat, bundle: Bundle) -> CGFloat {
        var y = y
        // Header row
        let headers = ["#", String(localized: "Pace", bundle: bundle), String(localized: "Avg HR", bundle: bundle), String(localized: "Elev gain", bundle: bundle)]
        var x = report.config.margin
        for (i, h) in headers.enumerated() {
            drawText(h.uppercased(), at: CGPoint(x: x, y: y), font: report.config.captionFont, color: report.config.textTertiary)
            x += colWs[i]
        }
        y += 14
        return y + 14
    }

    private func drawSplitRow(split: Split, unit: String, colWs: [CGFloat], y: CGFloat) -> CGFloat {
        var x = report.config.margin
            let paceStr: String = {
                guard let p = split.averagePaceSecPerKm else { return "—" }
                return report.units.formatPace(secondsPerMeter: p / 1_000) ?? "—"
            }()
            let hrStr = split.averageHR.map { "\(Int($0)) bpm" } ?? "—"
            let elevStr = split.elevationGainMeters.map { report.units.formatElevation(meters: $0) } ?? "—"
            let values = ["\(unit) \(split.index)", paceStr, hrStr, elevStr]
            x = report.config.margin
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
                drawText("\(label):  \(secs / 60)m \(secs % 60)s  ·  \(pct)%", at: CGPoint(x: report.config.margin, y: y), font: report.config.monoFont, color: report.config.textPrimary)
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
            let desc = d < 5 ? String(localized: "strong aerobic efficiency", bundle: bundle) : String(localized: "efficiency drifted", bundle: bundle)
            drawText(String(localized: "Pa:Hr Decoupling: \(String(format: "%+.1f", locale: .current, d))% (\(desc))", bundle: bundle), at: CGPoint(x: report.config.margin, y: y), font: report.config.bodyFont, color: report.config.textPrimary)
            y += 14
        }
        if let ef = report.session.workoutMetadata?.efficiencyFactor {
            drawText(String(localized: "Efficiency Factor: \(String(format: "%.2f", locale: .current, ef))  (normalized pace ÷ avg HR)", bundle: bundle), at: CGPoint(x: report.config.margin, y: y), font: report.config.bodyFont, color: report.config.textPrimary)
            y += 14
        }
        return y
    }

    private func drawSplitsFooter(y: CGFloat, contentW: CGFloat, bundle: Bundle) {
        let y = y
        // Footer with research citations
        let footer = String(localized: "Methods — TRIMP: Banister 1991 (continuous HRR-based exponential) · hrTSS: HRSS (session TRIMP ÷ 1-hour-at-LTHR TRIMP × 100) · α1 aerobic-threshold proxy: Rogers & Gronwald 2021 (PMC7845545) · LTHR default 0.88 × HRmax (Friel) pending field-test override. All calculations anchored to user max HR / resting HR / LTHR, not session peak — so scores are comparable across sessions.", bundle: bundle)
        drawWrappedText(footer, at: CGPoint(x: report.config.margin, y: report.config.pageSize.height - report.config.margin - 58), width: contentW, font: report.config.captionFont, color: report.config.textTertiary, lineHeight: 11)
        _ = y
    }

    // MARK: - Helpers

    /// Cap per-chart point count on the printed page. 250 points is more
    /// than the human eye can resolve on a Letter-size chart width —
    /// dropping from 400 → 250 is another ~40 % faster path-build with
    /// zero visible quality difference. 250 × 5 charts = 1 250 total
    /// line segments, well within CoreGraphics's sub-frame budget.
    static let maxPDFPoints = 250

    /// Bucket-average a long (x, y) series down to at most `target`
    /// points. Preserves the shape of the curve — each output bucket
    /// is the time-midpoint + mean-value of the source samples that
    /// landed in it. A 3 700-point α1 series on a 63-min walk comes out
    /// to 400 points here, drawing ~9× faster and visually identical on
    /// a PDF page.
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
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        text.draw(at: origin, withAttributes: attrs)
    }

    @discardableResult
    func drawWrappedText(_ text: String, at origin: CGPoint, width: CGFloat, font: UIFont, color: UIColor, lineHeight: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = max(0, lineHeight - font.lineHeight)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let rect = CGRect(x: origin.x, y: origin.y, width: width, height: 400)
        let bounding = attr.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil)
        attr.draw(with: rect, options: [.usesLineFragmentOrigin], context: nil)
        return origin.y + bounding.height + 4
    }

    func formatDuration(_ sec: Int) -> String {
        let h = sec / 3600, m = (sec % 3600) / 60, s = sec % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
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
        return String(format: "%.0f kcal", locale: .current, kcal)
    }

    func bestSplitString() -> String {
        guard let splits = report.session.workoutMetadata?.splits, !splits.isEmpty else { return "—" }
        let paced = splits.compactMap { s -> Double? in
            guard let p = s.averagePaceSecPerKm, p > 0 else { return nil }
            return p
        }
        guard let best = paced.min() else { return "—" }
        return report.units.formatPace(secondsPerMeter: best / 1_000) ?? "—"
    }

    func alphaAvgString() -> String {
        let samples = report.session.workoutMetadata?.samples ?? []
        let vals = samples.compactMap(\.alpha1)
        guard !vals.isEmpty else { return "—" }
        let avg = vals.reduce(0, +) / Double(vals.count)
        return String(format: "%.2f", locale: .current, avg)
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
        let samples = report.session.workoutMetadata?.samples ?? []
        var zs = [0, 0, 0, 0, 0]
        var prev = 0
        for s in samples {
            let dt = max(1, s.offsetSec - prev)
            prev = s.offsetSec
            guard let hr = s.heartRate, report.userMaxHR > 0 else { continue }
            let f = Double(hr) / Double(report.userMaxHR)
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

    func alpha1Stats() -> Alpha1Stats {
        let samples = report.session.workoutMetadata?.samples ?? []
        var acc = Alpha1Accumulator()
        var previousOffset = 0
        for sample in samples {
            guard let alpha = sample.alpha1 else { continue }
            acc.add(alpha, seconds: max(1, sample.offsetSec - previousOffset))
            previousOffset = sample.offsetSec
        }
        return acc.result
    }

    /// Running totals for `alpha1Stats`. A struct rather than six locals so the
    /// banding rule lives in one place next to the counters it moves.
    private struct Alpha1Accumulator {
        private var below = 0, between = 0, above = 0
        private var sum = 0.0, count = 0
        private var lo = Double.infinity, hi = -Double.infinity

        mutating func add(_ alpha: Double, seconds: Int) {
            sum += alpha
            count += 1
            lo = min(lo, alpha)
            hi = max(hi, alpha)
            if alpha >= 0.75 {
                below += seconds
            } else if alpha >= 0.50 {
                between += seconds
            } else {
                above += seconds
            }
        }

        var result: Alpha1Stats {
            Alpha1Stats(
                avgAlpha1: count > 0 ? sum / Double(count) : nil,
                maxAlpha1: count > 0 ? hi : nil,
                minAlpha1: count > 0 ? lo : nil,
                secondsBelowAT1: below,
                secondsBetween: between,
                secondsAboveAT2: above
            )
        }
    }

    /// Warmup + sustained-cross α1 detector — matches the snapshot
    /// builder and the Epic Report. 120 s warmup + 180 s sustain. The
    /// sustain length is deliberately > the α1 rolling-window length so
    /// a single ectopic beat (which contaminates exactly one
    /// window-length of samples) cannot satisfy the sustain check. 180 s
    /// aligns with Rogers & Gronwald's >= 3-min ramp-phase protocol.
    func firstDownwardAT1Crossing() -> (offsetSec: Int, hr: Int?)? {
        var run = AT1CrossingRun()
        var previousOffset = 0
        for sample in report.session.workoutMetadata?.samples ?? [] {
            guard let alpha = sample.alpha1 else { continue }
            let dt = max(1, sample.offsetSec - previousOffset)
            previousOffset = sample.offsetSec
            guard sample.offsetSec >= AT1CrossingRun.warmupSec else { continue }
            if let hit = run.observe(alpha: alpha, sample: sample, seconds: dt) { return hit }
        }
        return nil
    }

    /// The candidate crossing being timed. Isolated so the reset-on-recovery rule
    /// sits next to the counters it clears, rather than three lines below them.
    private struct AT1CrossingRun {
        static let warmupSec = 120
        static let sustainSec = 180

        private var pendingOffset: Int?
        private var pendingHR: Int?
        private var sustained = 0

        /// Non-nil once a below-AT1 run has lasted `sustainSec`.
        mutating func observe(alpha: Double, sample: WorkoutSample, seconds: Int) -> (offsetSec: Int, hr: Int?)? {
            guard alpha < 0.75 else {
                sustained = 0
                pendingOffset = nil
                pendingHR = nil
                return nil
            }
            if pendingOffset == nil {
                pendingOffset = sample.offsetSec
                pendingHR = sample.heartRate
            }
            sustained += seconds
            guard sustained >= Self.sustainSec, let offset = pendingOffset else { return nil }
            return (offset, pendingHR)
        }
    }

    func alpha1PlainEnglish(stats: Alpha1Stats) -> String {
        let bundle = LanguageManager.appBundle
        guard stats.totalSec >= 60 else {
            return String(localized: "Not enough clean RR data to characterise α1 this session.", bundle: bundle)
        }
        if let single = alpha1SingleBandSummary(stats: stats, bundle: bundle) { return single }
        if let crossing = alpha1CrossingSummary(stats: stats, bundle: bundle) { return crossing }
        let easy = stats.secondsBelowAT1 / 60, thr = stats.secondsBetween / 60, hard = stats.secondsAboveAT2 / 60
        return String(localized: "Easy \(easy)m · Threshold \(thr)m · Above AT2 \(hard)m.", bundle: bundle)
    }

    /// The two sessions that never changed band: all easy, or all hard.
    private func alpha1SingleBandSummary(stats: Alpha1Stats, bundle: Bundle) -> String? {
        let total = stats.totalSec / 60
        if stats.secondsBetween == 0, stats.secondsAboveAT2 == 0 {
            return String(localized: "You stayed below aerobic threshold for the full \(total) min — pure Zone-2 base work, α1 never crossed 0.75. Ideal aerobic-base session.", bundle: bundle)
        }
        if stats.secondsBelowAT1 == 0, stats.secondsBetween == 0 {
            return String(localized: "You were above anaerobic threshold the entire session (\(total) min at α1 < 0.50). Very hard physiological cost — short, intense efforts only.", bundle: bundle)
        }
        return nil
    }

    /// Narrated around the moment α1 first fell through AT1, when there was one.
    private func alpha1CrossingSummary(stats: Alpha1Stats, bundle: Bundle) -> String? {
        guard let cross = firstDownwardAT1Crossing() else { return nil }
        let easy = stats.secondsBelowAT1 / 60, thr = stats.secondsBetween / 60, hard = stats.secondsAboveAT2 / 60
        let mm = cross.offsetSec / 60, ss = cross.offsetSec % 60
        let hrPart = cross.hr.map { String(localized: " at HR \($0) bpm", bundle: bundle) } ?? ""
        if hard > 0 {
            return String(localized: "You crossed aerobic threshold at \(mm):\(String(format: "%02d", ss))\(hrPart), stayed at threshold / above for \(thr + hard) min, and spent \(hard) min above anaerobic threshold. Mixed-intensity session.", bundle: bundle)
        }
        return String(localized: "You crossed aerobic threshold at \(mm):\(String(format: "%02d", ss))\(hrPart) and stayed at threshold for \(thr) min. \(easy) min easy, \(thr) min at threshold.", bundle: bundle)
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
        if let verdict = alphaVerdict(avgAlpha: stats.avgAlpha1, pctMax: pctMax, durationMin: durationMin, bundle: bundle) {
            return verdict
        }
        return heartRateVerdict(pctMax: pctMax, hrr: hrr, durationMin: durationMin, bundle: bundle)
    }

    /// α1 is the sharper signal when it is available — it distinguishes the
    /// three training bands directly rather than inferring them from HR.
    private func alphaVerdict(avgAlpha: Double?, pctMax: Double, durationMin: Int, bundle: Bundle) -> (label: String, blurb: String, kind: Verdict)? {
        // Effort-level classification
        if let a = avgAlpha, a >= 0.75, pctMax < 0.75 {
            return (
                String(localized: "Easy aerobic — building base", bundle: bundle),
                String(localized: "\(durationMin)-min Z2 work, α1 stayed above 0.75 the whole way. Body absorbed the load cleanly.", bundle: bundle),
                .good
            )
        }
        return hardAlphaVerdict(avgAlpha: avgAlpha, durationMin: durationMin, bundle: bundle)
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
        let arrow = "→ " + text
        drawText(arrow,
                 at: CGPoint(x: report.config.margin, y: y),
                 font: UIFont.systemFont(ofSize: 10, weight: .medium),
                 color: kind.color)
        y += 14
    }

    // MARK: - "What This Means" page

    /// The single page DeepSeek's review highlighted as missing — a
    /// plain-English bridge between the dense clinical pages and an
    /// athlete who doesn't read sports-physiology papers. Mirrors the
    /// recovery PDF's "What This Means" page layout: colored verdict
    /// callout, numbered "What's working", "Watch", and arrow-bulleted
    /// "Tomorrow" sections. Empty sections are skipped so we never pad
    /// with noise.
    func drawWhatThisMeansPage(ctx: UIGraphicsPDFRendererContext) {
        ctx.beginPage()
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
            glyph: "→", y: y, contentW: contentW
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
        let inset: CGFloat
        if let glyph {
            drawText(glyph,
                     at: CGPoint(x: report.config.margin + 2, y: y),
                     font: UIFont.systemFont(ofSize: 11, weight: .bold),
                     color: colour)
            inset = 20
        } else {
            colour.setFill()
            UIBezierPath(ovalIn: CGRect(x: report.config.margin + 2, y: y + 6, width: 5, height: 5)).fill()
            inset = 16
        }
        return drawWrappedText(point,
                               at: CGPoint(x: report.config.margin + inset, y: y),
                               width: contentW - inset,
                               font: UIFont.systemFont(ofSize: 11, weight: .regular),
                               color: report.config.textPrimary,
                               lineHeight: 14) + 4
    }

    /// "What's working" bullets — pull genuinely positive signals only.
    /// Order: HRR, α1, decoupling, EF, drift, TRIMP execution.
    func whatsWorkingPoints() -> [String] {
        let bundle = LanguageManager.appBundle
        let meta = report.session.workoutMetadata
        var out: [String] = []
        if let line = hrrWorkingPoint(meta: meta, bundle: bundle) { out.append(line) }
        if let line = alphaWorkingPoint(bundle: bundle) { out.append(line) }
        if let dec = meta?.decouplingPercent, dec < 5 {
            out.append(String(localized: "Pa:Hr decoupling at \(String(format: "%+.1f%%", locale: .current, dec)) — well coupled, fitness held the workload through the whole session.", bundle: bundle))
        }
        if let ef = meta?.efficiencyFactor, ef > 0 {
            // EF is sport-dependent; only flag when clearly strong
            if ef >= 1.8 {
                out.append(String(localized: "Efficiency factor \(String(format: "%.2f", locale: .current, ef)) — strong pace-per-beat output, aerobic economy in good shape.", bundle: bundle))
            }
        }
        if let peak = meta?.samples?.compactMap({ $0.heartRate }).max(),
           Double(peak) <= Double(report.userMaxHR) * 1.0 {
            // Stayed within configured HRmax — not a flag, just confirms anchors are sane
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

        if let dec = meta?.decouplingPercent, dec >= 5 {
            if dec >= 7 {
                out.append(String(localized: "Pa:Hr decoupling \(String(format: "%+.1f%%", locale: .current, dec)) is past the 7% threshold — meaningful cardiac drift. Most likely cause: dehydration, heat, or under-fueling for this duration.", bundle: bundle))
            } else {
                out.append(String(localized: "Pa:Hr decoupling \(String(format: "%+.1f%%", locale: .current, dec)) is borderline — fitness mostly held but the second half cost more cardiac output than the first. Worth checking hydration on similar efforts.", bundle: bundle))
            }
        }
        if let one = meta?.hrrSamples?.bestAtOneMinute, one.drop < 12, one.drop > 0 {
            out.append(String(localized: "HRR drop only \(one.drop) bpm — sub-threshold for normal vagal reactivation. If you see this across multiple sessions, look at sleep, hydration, or accumulated fatigue.", bundle: bundle))
        }
        if report.userMaxHR > 0,
           let peak = meta?.samples?.compactMap({ $0.heartRate }).max(),
           Double(peak) / Double(report.userMaxHR) > 1.02 {
            out.append(String(localized: "Peak HR \(peak) bpm exceeded your configured max (\(report.userMaxHR)) — consider updating HRmax in Settings; current TRIMP/hrTSS may be slightly under-counted.", bundle: bundle))
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
        if let dec = meta?.decouplingPercent, dec >= 5 {
            out.append(String(localized: "Decoupling was elevated — front-load fluids and carbs earlier in the next long effort. If heat was a factor, shift the start time earlier.", bundle: bundle))
        }
        if let one = meta?.hrrSamples?.bestAtOneMinute, one.drop < 12 {
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
