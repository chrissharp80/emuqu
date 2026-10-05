import CoreGraphics
import CoreLocation
import Foundation
import MapKit
import PDFKit
import UIKit

// The autonomic, cardiopulmonary, terrain and methodology pages plus the
// layout primitives. Members are internal rather than `private` because
// Swift's `private` does not reach across files.

extension WorkoutPDFPhysiologyPages {
    // MARK: - Page: Autonomic / HRV analysis

    func drawAutonomicHRVPage(ctx: UIGraphicsPDFRendererContext) {
        PDFReadingDirection.beginPage(ctx)
        var y = report.config.margin
        let contentW = report.config.pageSize.width - 2 * report.config.margin
        drawPageTitle(String(localized: "AUTONOMIC / HRV ANALYSIS", bundle: LanguageManager.appBundle), at: &y)
        drawAlpha1Explainer(at: &y, contentW: contentW)
        drawAlpha1StatsTable(at: &y, contentW: contentW)
        drawAlpha1LT1Estimate(at: &y, contentW: contentW)
        drawHRRBlock(at: &y, contentW: contentW)
        renderer.drawFooter()
    }

    /// What DFA α1 is, plus the chart itself.
    func drawAlpha1Explainer(at y: inout CGFloat, contentW: CGFloat) {
        // Explainer
        let explainer = String(localized: "Non-linear heart-rate variability analysis via Detrended Fluctuation Analysis (DFA α1). In incremental lab tests α1 crosses ≈ 0.75 near the first ventilatory threshold (LT1/VT1), with individual error of roughly ±10 bpm, so the threshold here is an estimate. The link between ≈ 0.50 and the second threshold is weaker. Reference: Rogers B., Berk S., Gronwald T., Sports 2022 (PMC8875480); Gronwald T. & Rogers B., Sports 2021 (PMC7845545).", bundle: LanguageManager.appBundle)
        y = renderer.drawWrappedText(
            explainer,
            at: CGPoint(x: report.config.margin, y: y),
            width: contentW,
            font: UIFont.systemFont(ofSize: 9, weight: .regular),
            color: report.config.textSecondary,
            lineHeight: 12
        )
        y += 6

        // α1 chart
        let chartRect = CGRect(x: report.config.margin, y: y, width: contentW, height: 220)
        renderer.drawAlpha1Chart(in: chartRect)
        y += 220 + 10
    }

    func drawAlpha1StatsTable(at y: inout CGFloat, contentW: CGFloat) {
        let bundle = LanguageManager.appBundle
        renderer.drawSectionHeading(String(localized: "α1 STATISTICS", bundle: bundle), at: &y)
        let stats = renderer.alpha1Stats()
        renderer.drawTwoColumnRows(alpha1StatRows(stats, bundle: bundle), startY: &y, contentW: contentW)
        y += 4
        drawAlpha1PlainEnglishStatus(stats, at: &y)
        y += 6
    }

    func alpha1StatRows(_ stats: WorkoutPDFRenderer.Alpha1Stats, bundle: Bundle) -> [(String, String)] {
        let rows: [(String, String)] = [
            (String(localized: "Mean α1", bundle: bundle), stats.avgAlpha1.map { String(format: "%.2f", locale: LanguageManager.appLocale, $0) } ?? "—"),
            (String(localized: "Max α1", bundle: bundle), stats.maxAlpha1.map { String(format: "%.2f", locale: LanguageManager.appLocale, $0) } ?? "—"),
            (String(localized: "Min α1", bundle: bundle), stats.minAlpha1.map { String(format: "%.2f", locale: LanguageManager.appLocale, $0) } ?? "—"),
            (String(localized: "Time below AT1 (α1 ≥ 0.75)", bundle: bundle), String(localized: "\(stats.secondsBelowAT1 / 60) min", bundle: bundle)),
            (String(localized: "Time AT1–AT2 (0.50 ≤ α1 < 0.75)", bundle: bundle), String(localized: "\(stats.secondsBetween / 60) min", bundle: bundle)),
            (String(localized: "Time above AT2 (α1 < 0.50)", bundle: bundle), String(localized: "\(stats.secondsAboveAT2 / 60) min", bundle: bundle))
        ]
        return rows
    }

    func drawAlpha1PlainEnglishStatus(_ stats: WorkoutPDFRenderer.Alpha1Stats, at y: inout CGFloat) {
        let bundle = LanguageManager.appBundle
        // Plain-English α1 status — adds the lay-friendly bridge so the
        // reader doesn't need to know what "below AT1" means in clinical
        // terms.
        if let avg = stats.avgAlpha1 {
            if avg >= 0.75 {
                renderer.drawStatusArrow(String(localized: "Predominantly aerobic — pure base-building work", bundle: bundle), kind: .good, at: &y)
            } else if avg >= 0.50 {
                renderer.drawStatusArrow(String(localized: "Threshold band — productive lactate-clearance stimulus", bundle: bundle), kind: .good, at: &y)
            } else {
                renderer.drawStatusArrow(String(localized: "Above anaerobic threshold — high-cost session, needs full recovery", bundle: bundle), kind: .caution, at: &y)
            }
        }
    }

    /// The HR at the first downward α1 = 0.75 crossing — an aerobic-threshold
    /// estimate the report.session measured rather than one the user configured.
    func drawAlpha1LT1Estimate(at y: inout CGFloat, contentW: CGFloat) {
        let bundle = LanguageManager.appBundle
        guard let crossing = renderer.firstDownwardAT1Crossing(), let hr = crossing.hr else { return }
        renderer.drawSectionHeading(String(localized: "α1-ESTIMATED LT1 (AEROBIC THRESHOLD)", bundle: bundle), at: &y)
        renderer.drawText("\(hr) bpm",
                 at: CGPoint(x: report.config.margin, y: y),
                 font: UIFont.systemFont(ofSize: 26, weight: .heavy),
                 color: report.config.sage)
        y += 32
        drawAlpha1LT1Detail(crossing: crossing, at: &y, contentW: contentW)
        y += 10
    }

    func drawAlpha1LT1Detail(crossing: (offsetSec: Int, hr: Int?), at y: inout CGFloat, contentW: CGFloat) {
        let bundle = LanguageManager.appBundle
        let mm = crossing.offsetSec / 60, ss = crossing.offsetSec % 60
        // LT1 sits below the lactate threshold that LTHR describes, so the two
        // are reported side by side and never compared as if one should
        // replace the other.
        y = renderer.drawWrappedText(
            String(localized: "HR at first downward α1 = 0.75 crossing, observed at \(mm):\(String(format: "%02d", ss)). This estimates the aerobic threshold (LT1), which sits below lactate threshold, so it is not a substitute for the configured LTHR (\(report.userLTHR) bpm).", bundle: bundle),
            at: CGPoint(x: report.config.margin, y: y),
            width: contentW,
            font: report.config.bodyFont,
            color: report.config.textSecondary,
            lineHeight: 13
        )
    }

    func drawHRRBlock(at y: inout CGFloat, contentW: CGFloat) {
        let bundle = LanguageManager.appBundle
        renderer.drawSectionHeading(String(localized: "HEART-RATE RECOVERY (HRR)", bundle: bundle), at: &y)
        guard let hrr = report.session.workoutMetadata?.hrrSamples else { return }
        guard !hrr.isEmpty else { return drawHRRUnavailable(at: &y, contentW: contentW) }
        renderer.drawTwoColumnRows(hrrRows(hrr, bundle: bundle), startY: &y, contentW: contentW)
        y += 4
        drawHRRClassification(hrr, at: &y, contentW: contentW)
    }

    /// The strap stopped before the recovery window closed.
    func drawHRRUnavailable(at y: inout CGFloat, contentW: CGFloat) {
        let bundle = LanguageManager.appBundle
        y = renderer.drawWrappedText(
            String(localized: "No HR signal captured during the 60–120 s post-stop window. Tier-1 (strap) and Tier-2 (Watch HR) both failed; no clinical value available for this session.", bundle: bundle),
            at: CGPoint(x: report.config.margin, y: y),
            width: contentW,
            font: report.config.bodyFont,
            color: report.config.textSecondary,
            lineHeight: 13
        )
    }

    func hrrRows(_ hrr: [HRRSample], bundle: Bundle) -> [(String, String)] {
        var hrrRows: [(String, String)] = []
        if let one = hrr.bestAtOneMinute {
            hrrRows.append((String(localized: "1-min HR drop", bundle: bundle), String(localized: "\(one.drop) bpm (from peak \(one.peakHR) bpm)", bundle: bundle)))
            hrrRows.append((String(localized: "1-min absolute HR", bundle: bundle), String(localized: "\(one.hr) bpm, source: \(renderer.provenanceLabel(one.provenance))", bundle: bundle)))
        }
        if let two = hrr.bestAtTwoMinutes {
            hrrRows.append((String(localized: "2-min HR drop", bundle: bundle), "\(two.drop) bpm"))
            hrrRows.append((String(localized: "2-min absolute HR", bundle: bundle), String(localized: "\(two.hr) bpm, source: \(renderer.provenanceLabel(two.provenance))", bundle: bundle)))
        }
        return hrrRows
    }

    /// The 1-minute drop read against the conventional benchmarks.
    func drawHRRClassification(_ hrr: [HRRSample], at y: inout CGFloat, contentW: CGFloat) {
        let bundle = LanguageManager.appBundle
        guard let one = hrr.bestAtOneMinute else { return }
        let clinical = one.drop >= 18 ? String(localized: "18 bpm or more: above the figure often quoted for trained endurance athletes.", bundle: bundle)
            : one.drop >= 12 ? String(localized: "12–17 bpm: at or above the 12 bpm convention from clinical exercise testing (Cole 1999).", bundle: bundle)
            : one.drop >= 8 ? String(localized: "8–11 bpm: below the 12 bpm convention. One session says little; compare across sessions.", bundle: bundle)
            : String(localized: "Under 8 bpm: well below the 12 bpm convention. One session says little; if it stays this low across sessions, mention it to your doctor.", bundle: bundle)
        y = renderer.drawWrappedText(
            clinical,
            at: CGPoint(x: report.config.margin, y: y),
            width: contentW,
            font: report.config.bodyFont,
            color: report.config.textSecondary,
            lineHeight: 13
        )
        y += 4
        drawHRRProvenance(at: &y, contentW: contentW)
        drawHRRVerdictArrow(one, at: &y)
    }

    /// Where the 12 bpm line comes from — and what it was measured for.
    ///
    /// Of every threshold in this app, HRR is the one with the strongest
    /// evidence behind it: Cole et al. (NEJM 1999, n=2428). The report names
    /// the source and its context, and leaves out the study's mortality
    /// figure, which describes a clinical population and would read as a
    /// verdict on the user. Cole measured recovery after symptom-limited
    /// maximal testing; this report applies the same cut-off to a self-paced
    /// training session. The threshold transfers by convention, not by
    /// evidence, and the text says so.
    func drawHRRProvenance(at y: inout CGFloat, contentW: CGFloat) {
        let bundle = LanguageManager.appBundle
        y = renderer.drawWrappedText(
            String(localized: "The 12 bpm cut-off comes from Cole et al. (NEJM 1999), a study of 2,428 adults after maximal clinical exercise testing, not self-paced training. It is applied here by convention.", bundle: bundle),
            at: CGPoint(x: report.config.margin, y: y),
            width: contentW,
            font: report.config.captionFont,
            color: report.config.textTertiary,
            lineHeight: 11
        )
        y += 4
    }

    /// The one-line plain-English reading underneath the classification.
    func drawHRRVerdictArrow(_ one: HRRSample, at y: inout CGFloat) {
        let bundle = LanguageManager.appBundle
        let kind: WorkoutPDFRenderer.Verdict = one.drop >= 18 ? .good : one.drop >= 12 ? .good : one.drop >= 8 ? .neutral : .caution
        let line = one.drop >= 18 ? String(localized: "Fast heart-rate recovery for this session", bundle: bundle)
            : one.drop >= 12 ? String(localized: "At or above the 12 bpm convention", bundle: bundle)
            : one.drop >= 8 ? String(localized: "Below the 12 bpm convention — sleep, hydration and fatigue can all slow it", bundle: bundle)
            : String(localized: "Well below the convention — compare across sessions", bundle: bundle)
        renderer.drawStatusArrow(line, kind: kind, at: &y)
    }

    // MARK: - Page 3: Cardiopulmonary

    func drawCardiopulmonaryPage(ctx: UIGraphicsPDFRendererContext) {
        PDFReadingDirection.beginPage(ctx)
        var y = report.config.margin
        let contentW = report.config.pageSize.width - 2 * report.config.margin
        drawPageTitle(String(localized: "CARDIOPULMONARY RESPONSE", bundle: LanguageManager.appBundle), at: &y)
        drawHRTimeSeriesBlock(at: &y, contentW: contentW)
        drawZoneDistributionBlock(at: &y, contentW: contentW)
        drawPhysiologyBlock(at: &y, contentW: contentW)
        renderer.drawFooter()
    }

    func drawHRTimeSeriesBlock(at y: inout CGFloat, contentW: CGFloat) {
        let bundle = LanguageManager.appBundle
        // HR time-series with zone bands
        let samples = report.session.workoutMetadata?.samples ?? []
        if samples.contains(where: { $0.heartRate != nil }) {
            renderer.drawSectionHeading(String(localized: "HEART RATE VS TIME (WITH ZONE BANDS)", bundle: bundle), at: &y)
            let r = CGRect(x: report.config.margin, y: y, width: contentW, height: 170)
            renderer.drawHRChart(in: r, samples: samples)
            y += 170 + 10
        }
    }

    func drawZoneDistributionBlock(at y: inout CGFloat, contentW: CGFloat) {
        let bundle = LanguageManager.appBundle
        renderer.drawSectionHeading(String(localized: "ZONE DISTRIBUTION (% HRMAX)", bundle: bundle), at: &y)
        let zs = renderer.hrZoneSeconds()
        let total = zs.reduce(0, +)
        if total > 0 {
            let meanings = zoneMeanings(bundle: bundle)
            let ranges = zoneRanges()
            for (idx, secs) in zs.enumerated() where secs > 0 {
                drawZoneRow(index: idx, seconds: secs, total: total,
                            range: ranges[idx], meaning: meanings[idx],
                            at: &y, contentW: contentW)
            }
        }
        y += 6
    }

    /// What each zone is actually training — the clinical relevance line.
    func zoneMeanings(bundle: Bundle) -> [String] {
        let zoneMeaning: [String] = [
            String(localized: "Recovery / active rest", bundle: bundle),
            String(localized: "Aerobic base · fat oxidation · mitochondrial adaptation", bundle: bundle),
            String(localized: "Tempo · between aerobic and anaerobic thresholds", bundle: bundle),
            String(localized: "Threshold · lactate clearance adaptation", bundle: bundle),
            String(localized: "VO₂max · max aerobic power, short-duration tolerance", bundle: bundle)
        ]
        return zoneMeaning
    }

    /// Zone edges in bpm, derived from the reader's own configured HRmax.
    func zoneRanges() -> [String] {
        let zoneRanges: [String] = (0 ..< 5).map { idx in
            let lows = [0.50, 0.60, 0.70, 0.80, 0.90]
            let highs = [0.60, 0.70, 0.80, 0.90, 1.05]
            let lo = Int((lows[idx] * Double(report.userMaxHR)).rounded())
            let hi = Int((highs[idx] * Double(report.userMaxHR)).rounded())
            return "\(lo)–\(hi) bpm"
        }
        return zoneRanges
    }

    func drawZoneRow(
        index idx: Int,
        seconds secs: Int,
        total: Int,
        range: String,
        meaning: String,
        at y: inout CGFloat,
        contentW: CGFloat
    ) {
        let pct = Int((Double(secs) / Double(total)) * 100)
        let row = "Z\(idx + 1) (\(range))"
        let val = "\(PDFDurationText.minutesSeconds(secs)) · \(pct) % · \(meaning)"
        renderer.drawText(row,
                 at: CGPoint(x: report.config.margin, y: y),
                 font: UIFont.systemFont(ofSize: 10, weight: .semibold),
                 color: report.config.textPrimary)
        y = renderer.drawWrappedText(
            val,
            at: CGPoint(x: report.config.margin + 14, y: y + 12),
            width: contentW - 14,
            font: report.config.captionFont,
            color: report.config.textSecondary,
            lineHeight: 11
        )
        y += 6
    }

    func drawPhysiologyBlock(at y: inout CGFloat, contentW: CGFloat) {
        let bundle = LanguageManager.appBundle
        renderer.drawSectionHeading(String(localized: "PHYSIOLOGY", bundle: bundle), at: &y)
        renderer.drawTwoColumnRows(physiologyRows(bundle: bundle), startY: &y, contentW: contentW)
        y += 4
        drawDriftTakeaway(at: &y)
    }

    func physiologyRows(bundle: Bundle) -> [(String, String)] {
        var physioRows: [(String, String)] = []
        if let d = report.session.workoutMetadata?.decouplingPercent {
            let desc = d < 5 ? String(localized: "strong aerobic efficiency", bundle: bundle) : d < 7 ? String(localized: "mild drift", bundle: bundle) : String(localized: "significant drift — hydration / fuel / heat review", bundle: bundle)
            physioRows.append((String(localized: "Pa:Hr decoupling", bundle: bundle), String(localized: "\(String(format: "%+.1f", locale: LanguageManager.appLocale, d)) % (\(desc))", bundle: bundle)))
        }
        if let ef = report.session.workoutMetadata?.efficiencyFactor {
            physioRows.append((String(localized: "Efficiency factor", bundle: bundle), String(localized: "\(WorkoutPDFRenderer.efficiencyFactorText(ef)) (speed in m/min ÷ mean HR)", bundle: bundle)))
        }
        if let rmssd = report.session.rmssd {
            physioRows.append((String(localized: "Session RMSSD", bundle: bundle), String(format: "%.0f ms", locale: LanguageManager.appLocale, rmssd)))
        }
        return physioRows
    }

    /// Connects the decoupling number to what it means for training right now.
    func drawDriftTakeaway(at y: inout CGFloat) {
        let bundle = LanguageManager.appBundle
        if let d = report.session.workoutMetadata?.decouplingPercent {
            if d < 5 {
                renderer.drawStatusArrow(String(localized: "Cardiac drift well-controlled — aerobic system handled the workload cleanly", bundle: bundle), kind: .good, at: &y)
            } else if d < 7 {
                renderer.drawStatusArrow(String(localized: "Mild cardiac drift — body worked harder in the second half; hydration / fuel worth a look on similar efforts", bundle: bundle), kind: .neutral, at: &y)
            } else {
                renderer.drawStatusArrow(String(localized: "Significant drift — meaningful cost in the second half from heat, dehydration, or fueling shortfall", bundle: bundle), kind: .caution, at: &y)
            }
        }
    }

    // MARK: - Page 4: Effort & terrain

    func drawEffortAndTerrainPage(ctx: UIGraphicsPDFRendererContext, mapImage: WorkoutPDFRenderer.RouteMapImage) {
        PDFReadingDirection.beginPage(ctx)
        var y = report.config.margin
        let contentW = report.config.pageSize.width - 2 * report.config.margin
        drawPageTitle(String(localized: "EFFORT & TERRAIN", bundle: LanguageManager.appBundle), at: &y)
        drawRouteMap(mapImage, at: &y, contentW: contentW)
        drawRouteLegend(at: &y)
        renderer.drawFooter()
    }

    /// The map is drawn at the snapshot's own aspect ratio, so the polyline
    /// projected by the snapshot stays on its roads. Map and route keep
    /// their geography on a mirrored page.
    func drawRouteMap(_ map: WorkoutPDFRenderer.RouteMapImage, at y: inout CGFloat, contentW: CGFloat) {
        let bundle = LanguageManager.appBundle
        renderer.drawSectionHeading(String(localized: "ROUTE (coloured by α1 band)", bundle: bundle), at: &y)
        let size = map.image.size
        let height = size.width > 0 ? contentW * size.height / size.width : 320
        let mapRect = CGRect(x: report.config.margin, y: y, width: contentW, height: height)
        PDFReadingDirection.drawingLeftToRight(minX: mapRect.minX, width: mapRect.width) {
            map.image.draw(in: mapRect)
            report.config.divider.setStroke()
            UIBezierPath(rect: mapRect).stroke()
            renderer.drawColouredPolyline(map, in: mapRect)
        }
        y += height + 10
    }

    /// What the three polyline colours mean.
    func drawRouteLegend(at y: inout CGFloat) {
        let bundle = LanguageManager.appBundle
        let legendItems: [(UIColor, String)] = [
            (report.config.sage, String(localized: "Easy · below aerobic threshold (α1 ≥ 0.75)", bundle: bundle)),
            (.systemYellow, String(localized: "Threshold · between LT1 and LT2 (0.50–0.75)", bundle: bundle)),
            (.orange, String(localized: "Hard · above anaerobic threshold (< 0.50)", bundle: bundle))
        ]
        for item in legendItems {
            let box = CGRect(x: report.config.margin, y: y + 4, width: 14, height: 4)
            item.0.setFill()
            UIBezierPath(rect: box).fill()
            renderer.drawText(item.1,
                     at: CGPoint(x: report.config.margin + 20, y: y),
                     font: report.config.captionFont,
                     color: report.config.textSecondary)
            y += 14
        }
    }

    // MARK: - Page 6: Methodology appendix

    func drawMethodologyPage(ctx: UIGraphicsPDFRendererContext) {
        PDFReadingDirection.beginPage(ctx)
        var y = report.config.margin
        let contentW = report.config.pageSize.width - 2 * report.config.margin
        drawPageTitle(String(localized: "METHODOLOGY", bundle: LanguageManager.appBundle), at: &y)
        for (title, body) in methodologySections(bundle: LanguageManager.appBundle) {
            renderer.drawSectionHeading(title.uppercased(), at: &y)
            y = renderer.drawWrappedText(
                body,
                at: CGPoint(x: report.config.margin, y: y),
                width: contentW,
                font: UIFont.systemFont(ofSize: 9, weight: .regular),
                color: report.config.textPrimary,
                lineHeight: 12
            )
            y += 8
        }
        renderer.drawFooter()
    }

    /// Every formula the report uses, cited — and the ones it deliberately
    /// does not, with the reason.
    func methodologySections(bundle: Bundle) -> [(String, String)] {
        methodologyLoadSections(bundle: bundle) + methodologyAnchorSections(bundle: bundle)
    }

    /// Training load, threshold proxy and drift.
    private func methodologyLoadSections(bundle: Bundle) -> [(String, String)] {
        [
            (String(localized: "TRIMP — Banister (1991)", bundle: bundle),
             String(localized: "Continuous training-impulse integration on heart-rate reserve.\nTRIMP = Σ (duration_min × HRR × A·e^(b·HRR))\nwhere HRR = (HR − HR_rest) / (HR_max − HR_rest); A = 0.64, b = 1.92 (male) or A = 0.86, b = 1.67 (female) from Banister's sex-split lactate–HR regressions. Range 0–4.37 TRIMP/min (male), 0–4.57 (female).", bundle: bundle)),
            (String(localized: "HRSS — heart-rate stress score", bundle: bundle),
             String(localized: """
                 HRSS = session_TRIMP / TRIMP_1hr_at_LTHR × 100.
                 One hour at lactate-threshold heart rate scores 100, the same scale as the power- and MET-based \
                 loads, so they share one training-load series. Reference implementation in fellrnr.com and intervals.icu.
                 """, bundle: bundle)),
            (String(localized: "DFA α1 — Rogers & Gronwald", bundle: bundle),
             String(localized: "Detrended Fluctuation Analysis short-term scaling exponent (Peng 1995) computed on a rolling 2-minute RR window, recomputed every 20 s with Kubios-style ectopic-beat filtering + linear interpolation before DFA. α1 ≈ 0.75 is a proxy for the first ventilatory threshold (LT1/VT1), with individual error of roughly ±10 bpm; the ≈ 0.50 link to the second threshold is weaker. Evidence: Rogers 2021 (PMC7845545); later cohorts agree less closely.", bundle: bundle)),
            (String(localized: "Pa:Hr decoupling", bundle: bundle),
             String(localized: "First-half vs second-half ratio of (pace ÷ HR). Values < 5 % indicate aerobic stability; > 7 % suggests cardiac drift from hydration / fuel / heat demand.", bundle: bundle))
        ]
    }

    /// Elevation, anchors, filters, and what is deliberately left out.
    private func methodologyAnchorSections(bundle: Bundle) -> [(String, String)] {
        [
            (String(localized: "Elevation", bundle: bundle),
             String(localized: """
                 Primary source: CMAltimeter barometric altitude (±0.5 m). Fallback for retroactive \
                 computation on GPS-only sessions: OpenTopoData terrain models (USGS NED 10 m in the US, \
                 SRTM 30 m elsewhere) with a 15 m sustained-climb threshold.
                 """, bundle: bundle)),
            (String(localized: "LTHR estimation", bundle: bundle),
             String(localized: """
                 User-override preferred (Friel 30-min time-trial protocol). Default fallback 0.88 × HRmax — \
                 midpoint of Friel's 85–90 % band for fit endurance athletes. α1-derived LT1 estimate \
                 (Rogers 2021) is shown each session as a separate aerobic-threshold marker; it does not set LTHR.
                 """, bundle: bundle))
        ] + methodologyFilterSections(bundle: bundle)
    }

    /// The cadence filter, and the methods deliberately not used.
    private func methodologyFilterSections(bundle: Bundle) -> [(String, String)] {
        [
            (String(localized: "Cadence filter", bundle: bundle),
             String(localized: "Sport-aware physiological cap: walks / hikes 125 spm, runs 220, bikes 140 RPM. Below cap, trailing-15-sample check against preceding 30-sample median with 1.5× threshold drops foot-pod artefacts.", bundle: bundle)),
            (String(localized: "Methods not used, and why", bundle: bundle),
             String(localized: """
                 Lucia TRIMP (2003) — published but no dose-response validation. Stagno modified TRIMP — validated for team sports only. \
                 Individualized TRIMP (Manzi 2009) — requires incremental blood-lactate testing; out of reach without lab access.
                 """, bundle: bundle))
        ]
    }

    // MARK: - Layout primitives

    func drawPageTitle(_ text: String, at y: inout CGFloat) {
        renderer.drawText(text,
                 at: CGPoint(x: report.config.margin, y: y),
                 font: UIFont.systemFont(ofSize: 16, weight: .heavy),
                 color: report.config.textPrimary)
        y += 22
        let contentW = report.config.pageSize.width - 2 * report.config.margin
        renderer.drawDivider(at: y, width: contentW, strong: true)
        y += 10
    }

}
