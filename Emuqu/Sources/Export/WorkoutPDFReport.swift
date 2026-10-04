import CoreGraphics
import CoreLocation
import Foundation
import MapKit
import PDFKit
import UIKit

// MARK: - Workout PDF Report
//
// Detailed, physician-readable workout analysis report. Generated
// from WorkoutMetadata + HRVSession + user anchors, rendered with
// CoreGraphics (no SwiftUI snapshotting — we draw direct into the PDF
// context so print resolution stays crisp).
//
// Pages (US Letter, portrait), in the order `generate` draws them:
//   1. EXECUTIVE SUMMARY — subject anchors (HRmax / HRrest / LTHR / sex),
//      physician-language clinical interpretation (2-3 paragraphs),
//      notable observations / flags, key-metrics grid with normative
//      context.
//   2. AUTONOMIC / HRV ANALYSIS — DFA α1 timeline with AT1/AT2 reference
//      lines, α1 statistics table (mean, SD, min, max, time-in-band),
//      α1-derived LT1 estimate, HRR analysis with clinical thresholds.
//   3. CARDIOPULMONARY RESPONSE — HR time-series with zone background
//      bands, zone distribution table with clinical relevance per zone,
//      Pa:Hr decoupling, efficiency factor, cardiac-drift readout.
//   4. EFFORT & TERRAIN — route map coloured by α1 band (only when the
//      session has a GPS track).
//   5. SPLITS & METRICS — splits table, HRR, zone distribution and
//      physiology lines; continues onto further pages for long sessions.
//   6. WHAT THIS MEANS — plain-English verdict, what's working, what to
//      watch, tomorrow.
//   7. METHODOLOGY APPENDIX — every formula used, inputs shown, primary
//      research citations (Banister 1991, Rogers & Gronwald 2021,
//      Friel, Manzi 2009).
//
// The report is designed so a sports cardiologist or a coach can skim
// page 1 for a clinical snapshot and drill into any subsystem without
// hunting — same progressive-disclosure pattern professional medical
// reports use.
//
// Why a separate generator (not PDFReportGenerator): that class is
// overnight-HRV-flavoured (Poincaré, PSD, tachogram, sleep stages) —
// extending it with workout-specific pages would bloat an already-large
// file. Keeping workout PDF cleanly separate makes both easier to reason
// about.
// Not @MainActor. All inputs are immutable (HRVSession is a Codable struct,
// CLLocation is an immutable class, Config is a struct). CoreGraphics /
// UIGraphicsPDFRenderer / MKMapSnapshotter are all safe off main.
// As @MainActor, `generate()` would pin the UI thread for the entire
// drawing pass (200-800 ms on a typical walk). The caller runs this from
// `Task.detached(priority: .userInitiated)` so the whole render happens
// on a utility queue and only the final "sheet presented" state-flip hops
// back to MainActor.
final class WorkoutPDFReport: Sendable {
    // MARK: - Configuration

    struct Config: Sendable {
        let pageSize: CGSize = CGSize(width: 612, height: 792) // US Letter
        let margin: CGFloat = 36
        let titleFont = UIFont.systemFont(ofSize: 24, weight: .bold)
        let heroFont = UIFont.systemFont(ofSize: 28, weight: .heavy)
        let sectionFont = UIFont.systemFont(ofSize: 14, weight: .semibold)
        let bodyFont = UIFont.systemFont(ofSize: 10, weight: .regular)
        let captionFont = UIFont.systemFont(ofSize: 8, weight: .regular)
        let monoFont = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let primary = UIColor(red: 0.79, green: 0.33, blue: 0.25, alpha: 1.0)   // terracotta
        let sage = UIColor(red: 0.40, green: 0.60, blue: 0.45, alpha: 1.0)
        let dustyRose = UIColor(red: 0.78, green: 0.53, blue: 0.56, alpha: 1.0)
        let textPrimary = UIColor(white: 0.10, alpha: 1.0)
        let textSecondary = UIColor(white: 0.35, alpha: 1.0)
        let textTertiary = UIColor(white: 0.55, alpha: 1.0)
        let divider = UIColor(white: 0.88, alpha: 1.0)
    }

    // MARK: - Inputs

    /// Everything that draws. Lazy — a report that is never rendered never
    /// builds it.
    var drawing: WorkoutPDFRenderer {
        WorkoutPDFRenderer(report: self)
    }

    let session: HRVSession
    let track: [CLLocation]
    let config: Config
    let userMaxHR: Int
    let userRestingHR: Int
    let userLTHR: Int
    let units: UnitsPreference

    init(
        session: HRVSession,
        track: [CLLocation],
        userMaxHR: Int,
        userRestingHR: Int,
        userLTHR: Int,
        units: UnitsPreference,
        config: Config = Config()
    ) {
        self.session = session
        self.track = track
        self.userMaxHR = userMaxHR
        self.userRestingHR = userRestingHR
        self.userLTHR = userLTHR
        self.units = units
        self.config = config
    }

    // MARK: - Entry point

    /// Render the report to a PDF file in the given URL. Async because the
    /// map snapshot requires an awaitable MKMapSnapshotter.start() bridge.
    func generate(to url: URL) async throws {
        let mapImage = await drawing.renderMapSnapshot()

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: config.pageSize))
        try renderer.writePDF(to: url) { ctx in
            drawExecutiveSummaryPage(ctx: ctx)
            drawing.physiology.drawAutonomicHRVPage(ctx: ctx)
            drawing.physiology.drawCardiopulmonaryPage(ctx: ctx)
            if let mapImage {
                drawing.physiology.drawEffortAndTerrainPage(ctx: ctx, mapImage: mapImage)
            }
            drawing.drawSplitsAndDerivedPage(ctx: ctx)
            // Plain-English bridge page. Mirrors the recovery PDF's "What
            // This Means" page: verdict callout, what's working, watch,
            // tomorrow. Sits before the methodology so a reader can stop
            // here and have actionable takeaways without parsing the
            // formula appendix.
            drawing.drawWhatThisMeansPage(ctx: ctx)
            drawing.physiology.drawMethodologyPage(ctx: ctx)
        }
    }

    // MARK: - Clinical interpretation generators

    /// Physician-language 2-3 paragraph clinical snapshot — the single
    /// highest-value readout on page 1. Written so a sports cardiologist
    /// can read it and immediately know whether the session was within
    /// expected parameters. NO invented numbers — every reference to a
    /// metric is sourced from the session's actual measured values.
    func clinicalInterpretation() -> String {
        let bundle = LanguageManager.appBundle
        let meta = session.workoutMetadata
        let sport = meta.map { Self.sportNoun($0.sport) } ?? String(localized: "session", bundle: bundle)
        let durationMin = Int((session.duration ?? 0) / 60)

        var paragraphs = [effortParagraph(sport: sport, durationMin: durationMin, bundle: bundle)]
        let auto = autonomicSentences(meta: meta, bundle: bundle)
        if !auto.isEmpty { paragraphs.append(auto.joined(separator: " ")) }
        let load = trainingLoadSentences(meta: meta, bundle: bundle)
        if !load.isEmpty { paragraphs.append(load.joined(separator: " ")) }
        return paragraphs.joined(separator: "\n\n")
    }

    /// The sport's name mid-sentence ("45-minute run"): lower-cased in the
    /// app's language, except German, which capitalises nouns.
    static func sportNoun(_ sport: Sport) -> String {
        let locale = LanguageManager.appLocale
        guard locale.language.languageCode != .german else { return sport.localizedName }
        return sport.localizedName.lowercased(with: locale)
    }

    /// How the session's time split across the two thresholds.
    private func effortParagraph(sport: String, durationMin: Int, bundle: Bundle) -> String {
        var effort = ""
        let stats = drawing.alpha1Stats()
        if stats.totalSec > 60 {
            let easyMin = stats.secondsBelowAT1 / 60
            let thrMin = stats.secondsBetween / 60
            let hardMin = stats.secondsAboveAT2 / 60
            if stats.secondsBetween == 0, stats.secondsAboveAT2 == 0 {
                effort = String(localized: "\(durationMin)-minute \(sport), entirely below aerobic threshold (α1 ≥ 0.75 throughout, \(easyMin) min). Consistent with Zone-2 aerobic-base work. No ventilatory-threshold crossings observed.", bundle: bundle)
            } else if stats.secondsBelowAT1 == 0, stats.secondsBetween == 0 {
                effort = String(localized: "\(durationMin)-minute \(sport) performed predominantly above anaerobic threshold (α1 < 0.50 for \(hardMin) min). High internal load. Short-duration, race-pace or interval-work profile.", bundle: bundle)
            } else if hardMin > 0 {
                effort = String(localized: "Mixed-intensity \(durationMin)-minute \(sport): \(easyMin) min easy (below LT1), \(thrMin) min threshold (LT1–LT2), \(hardMin) min above LT2. Characteristic of a structured tempo or interval session.", bundle: bundle)
            } else {
                effort = String(localized: "\(durationMin)-minute \(sport) with threshold exposure: \(easyMin) min below LT1, \(thrMin) min between LT1 and LT2. Steady-state aerobic–threshold transition.", bundle: bundle)
            }
        } else {
            effort = String(localized: "\(durationMin)-minute \(sport). Insufficient clean RR data to characterise autonomic response via DFA α1 (likely due to strap contact issues or Watch-only recording).", bundle: bundle)
        }
        return effort
    }

    /// Peak/mean HR, decoupling, efficiency and HRR — one sentence each,
    /// omitted entirely when the session did not measure them.
    private func autonomicSentences(meta: WorkoutMetadata?, bundle: Bundle) -> [String] {
        var auto = peakHRSentences(meta: meta, bundle: bundle)
        if let meanHR = session.meanHR {
            auto.append(String(localized: "Mean HR \(Int(meanHR)) bpm.", bundle: bundle))
        }
        if let decoupling = meta?.decouplingPercent {
            let desc = decoupling <= Self.decouplingDriftPercent ? String(localized: "within normal aerobic-stability limits", bundle: bundle) : String(localized: "suggesting cardiac drift or hydration/fuel demand in the second half", bundle: bundle)
            auto.append(String(localized: "Pa:Hr decoupling \(String(format: "%+.1f %%", locale: LanguageManager.appLocale, decoupling)) (\(desc)).", bundle: bundle))
        }
        if let ef = meta?.efficiencyFactor {
            auto.append(String(localized: "Efficiency factor \(WorkoutPDFRenderer.efficiencyFactorText(ef)) (speed in m/min ÷ mean HR).", bundle: bundle))
        }
        auto.append(contentsOf: hrrSentences(meta: meta, bundle: bundle))
        return auto
    }

    private func peakHRSentences(meta: WorkoutMetadata?, bundle: Bundle) -> [String] {
        var auto: [String] = []
        if let peak = meta?.samples?.compactMap({ $0.heartRate }).max() {
            if userMaxHR > 0 {
                // Guard userMaxHR > 0: Int(x / 0) is +inf → Int(inf) is a HARD
                // CRASH, not just a cosmetic "inf %".
                let pctMax = Int(Double(peak) / Double(userMaxHR) * 100)
                auto.append(String(localized: "Peak heart rate \(peak) bpm (≈ \(pctMax) % of configured HRmax \(userMaxHR)).", bundle: bundle))
            } else {
                auto.append(String(localized: "Peak heart rate \(peak) bpm.", bundle: bundle))
            }
        }
        return auto
    }

    private func trainingLoadSentences(meta: WorkoutMetadata?, bundle: Bundle) -> [String] {
        var load: [String] = []
        if let trimp = meta?.luciaTRIMP {
            load.append(String(localized: "Banister TRIMP \(Int(trimp)) (continuous HRR-based integration, k=\(banisterSexK()) per Banister 1991).", bundle: bundle))
        }
        if let tss = meta?.hrTSS {
            load.append(String(localized: "hrTSS \(Int(tss)) via HRSS formulation (session TRIMP ÷ 1-hour-at-LTHR TRIMP × 100).", bundle: bundle))
        }
        if let gain = meta?.elevationGainMeters {
            load.append(String(localized: "Elevation gain \(units.formatElevation(meters: gain)).", bundle: bundle))
        }
        return load
    }

    /// Friel's aerobic-decoupling line: above 5 % the second half drifted.
    /// The interpretation paragraph and the flag both read against it.
    static let decouplingDriftPercent = 5.0

    /// Bullet-point notable observations / flags — non-empty only when
    /// something warrants a doctor's / coach's attention. Empty for a
    /// textbook-normal session.
    func notableObservations() -> [String] {
        let bundle = LanguageManager.appBundle
        let meta = session.workoutMetadata
        var flags: [String] = []
        if let decoupling = meta?.decouplingPercent, decoupling > Self.decouplingDriftPercent {
            flags.append(String(localized: "Pa:Hr decoupling \(String(format: "%+.1f %%", locale: LanguageManager.appLocale, decoupling)) > 5 % benchmark — review for dehydration, heat stress, or insufficient base fitness for this duration.", bundle: bundle))
        }
        if let one = meta?.hrrSamples?.bestAtOneMinute, one.drop < 8 {
            flags.append(String(localized: "1-min HRR \(one.drop) bpm below the 8 bpm threshold. Persistent low HRR over multiple sessions may warrant review of recovery status or autonomic function.", bundle: bundle))
        }
        if userMaxHR > 0,
           let peak = meta?.samples?.compactMap({ $0.heartRate }).max(),
           Double(peak) / Double(userMaxHR) > 1.02 {
            flags.append(String(localized: "Peak HR \(peak) bpm exceeds configured HRmax (\(userMaxHR)). Consider updating HRmax in Settings — a tested max-HR field test or lab value increases TRIMP/hrTSS accuracy.", bundle: bundle))
        }
        flags.append(contentsOf: alphaObservations(meta: meta, bundle: bundle))
        return flags
    }

    func banisterSexK() -> String {
        // Without a sex field on the PDF inputs we can't show the exact
        // k used — the Banister formula picks 1.92 for male / 1.67 for
        // female. In practice the session was computed in
        // `WorkoutAnalyzer` using settings.biologicalSex; we state the
        // formula in the appendix.
        String(localized: "1.92 (male) / 1.67 (female)", bundle: LanguageManager.appBundle)
    }

    // MARK: - Page 1: Executive Summary

    func drawExecutiveSummaryPage(ctx: UIGraphicsPDFRendererContext) {
        ctx.beginPage()
        var y = config.margin + 6
        let contentW = config.pageSize.width - 2 * config.margin

        drawExecSummaryHeader(at: &y, contentW: contentW)
        // Hero verdict — the "above the fold" callout. Single sentence
        // verdict + colored badge so a glance tells the whole session
        // story before the reader hits the dense clinical paragraphs
        // below. Mirrors the recovery PDF's lead-with-the-verdict
        // pattern.
        drawing.drawHeroVerdict(at: &y, contentW: contentW)
        drawSubjectAnchors(at: &y, contentW: contentW)
        drawClinicalInterpretationBlock(at: &y, contentW: contentW)
        drawNotableObservationsBlock(at: &y, contentW: contentW)
        drawKeyMetricsGrid(at: &y, contentW: contentW)
        drawing.drawFooter()
    }

    /// Masthead, sport and date.
    private func drawExecSummaryHeader(at y: inout CGFloat, contentW: CGFloat) {
        // Clinical identity header
        drawing.drawText(String(localized: "EMUQU · WORKOUT ANALYSIS REPORT", bundle: LanguageManager.appBundle),
                 at: CGPoint(x: config.margin, y: y),
                 font: UIFont.systemFont(ofSize: 9, weight: .semibold),
                 color: config.textTertiary)
        y += 12
        drawing.drawDivider(at: y, width: contentW, strong: true)
        y += 14
        drawExecSummaryTitle(at: &y)
    }

    private func drawExecSummaryTitle(at y: inout CGFloat) {
        // Session title line — sport + date
        let sportLabel = session.sport?.localizedName ?? String(localized: "Workout", bundle: LanguageManager.appBundle)
        let df = DateFormatter()
        df.locale = LanguageManager.appLocale
        df.dateStyle = .long
        df.timeStyle = .short
        drawing.drawText(sportLabel.uppercased(with: LanguageManager.appLocale),
                 at: CGPoint(x: config.margin, y: y),
                 font: UIFont.systemFont(ofSize: 26, weight: .heavy),
                 color: config.textPrimary)
        y += 32
        drawing.drawText(df.string(from: session.startDate),
                 at: CGPoint(x: config.margin, y: y),
                 font: config.bodyFont,
                 color: config.textSecondary)
        y += 22
    }

    /// The reader's own configured HR anchors, so every percentage below is
    /// checkable against the numbers it was computed from.
    private func drawSubjectAnchors(at y: inout CGFloat, contentW: CGFloat) {
        // Two-column subject anchors block
        drawing.drawSectionHeading(String(localized: "SUBJECT ANCHORS", bundle: LanguageManager.appBundle), at: &y)
        let anchorRows: [(String, String)] = [
            (String(localized: "Max HR", bundle: LanguageManager.appBundle), String(localized: "\(userMaxHR) bpm", bundle: LanguageManager.appBundle)),
            (String(localized: "Resting HR", bundle: LanguageManager.appBundle), String(localized: "\(userRestingHR) bpm", bundle: LanguageManager.appBundle)),
            (String(localized: "Lactate-threshold HR", bundle: LanguageManager.appBundle), String(localized: "\(userLTHR) bpm", bundle: LanguageManager.appBundle)),
            (String(localized: "Units preference", bundle: LanguageManager.appBundle), units.resolved == .imperial ? String(localized: "imperial", bundle: LanguageManager.appBundle) : String(localized: "metric", bundle: LanguageManager.appBundle))
        ]
        drawing.drawTwoColumnRows(anchorRows, startY: &y, contentW: contentW)
        y += 6
    }

    private func drawClinicalInterpretationBlock(at y: inout CGFloat, contentW: CGFloat) {
        drawing.drawSectionHeading(String(localized: "INTERPRETATION", bundle: LanguageManager.appBundle), at: &y)
        y = drawing.drawWrappedText(
            clinicalInterpretation(),
            at: CGPoint(x: config.margin, y: y),
            width: contentW,
            font: UIFont.systemFont(ofSize: 11, weight: .regular),
            color: config.textPrimary,
            lineHeight: 15
        )
        y += 8
    }

    /// Omitted entirely for a textbook-normal session.
    private func drawNotableObservationsBlock(at y: inout CGFloat, contentW: CGFloat) {
        // Notable observations / flags — only shown if non-empty
        let flags = notableObservations()
        if !flags.isEmpty {
            drawing.drawSectionHeading(String(localized: "NOTABLE OBSERVATIONS", bundle: LanguageManager.appBundle), at: &y)
            for flag in flags {
                y = drawing.drawWrappedText(
                    "• \(flag)",
                    at: CGPoint(x: config.margin, y: y),
                    width: contentW,
                    font: config.bodyFont,
                    color: config.textPrimary,
                    lineHeight: 13
                )
                y += 2
            }
            y += 4
        }
    }

    private func drawKeyMetricsGrid(at y: inout CGFloat, contentW: CGFloat) {
        drawing.drawSectionHeading(String(localized: "KEY METRICS", bundle: LanguageManager.appBundle), at: &y)
        let heroItems = execSummaryMetrics()
        let columns = 3
        let rowH: CGFloat = 48
        for (i, item) in heroItems.enumerated() {
            drawKeyMetricCell(item, index: i, columns: columns, colW: contentW / CGFloat(columns), rowH: rowH, topY: y)
        }
        y += CGFloat((heroItems.count + columns - 1) / columns) * rowH + 12
    }

    private func drawKeyMetricCell(
        _ item: (String, String, String?),
        index i: Int,
        columns: Int,
        colW: CGFloat,
        rowH: CGFloat,
        topY y: CGFloat
    ) {
            let col = i % columns
            let row = i / columns
            let x = config.margin + CGFloat(col) * colW
            let rowY = y + CGFloat(row) * rowH
            drawing.drawText(item.0.uppercased(),
                     at: CGPoint(x: x, y: rowY),
                     font: UIFont.systemFont(ofSize: 8, weight: .semibold),
                     color: config.textTertiary)
            drawing.drawText(item.1,
                     at: CGPoint(x: x, y: rowY + 12),
                     font: UIFont.systemFont(ofSize: 16, weight: .semibold),
                     color: config.textPrimary)
            if let sub = item.2 {
                drawing.drawText(sub,
                         at: CGPoint(x: x, y: rowY + 32),
                         font: config.captionFont,
                         color: config.textTertiary)
            }
    }

    func execSummaryMetrics() -> [(String, String, String?)] {
        let bundle = LanguageManager.appBundle
        let meta = session.workoutMetadata
        return [
            (String(localized: "Distance", bundle: bundle), meta?.distanceMeters.map { units.formatDistance(meters: $0) } ?? "—", nil),
            (String(localized: "Duration", bundle: bundle), session.duration.map { drawing.formatDuration(Int($0)) } ?? "—", nil),
            (String(localized: "Avg Pace", bundle: bundle), drawing.avgPaceString(), nil),
            (String(localized: "Elev Gain", bundle: bundle), meta?.elevationGainMeters.map { units.formatElevation(meters: $0) } ?? "—", nil),
            (String(localized: "Avg HR", bundle: bundle), session.meanHR.map { String(localized: "\(Int($0)) bpm", bundle: bundle) } ?? "—", nil),
            (String(localized: "Peak HR", bundle: bundle), drawing.peakHRString(), nil),
            (String(localized: "Banister TRIMP", bundle: bundle), meta?.luciaTRIMP.map { String(format: "%.0f", locale: LanguageManager.appLocale, $0) } ?? "—", String(localized: "HRR-based", bundle: bundle)),
            ("hrTSS", meta?.hrTSS.map { String(format: "%.0f", locale: LanguageManager.appLocale, $0) } ?? "—", String(localized: "1hr@LTHR = 100", bundle: bundle)),
            (String(localized: "Calories", bundle: bundle), drawing.calorieString(), String(localized: "est · METs × kg × hr", bundle: bundle)),
            (String(localized: "DFA α1 avg", bundle: bundle), drawing.alphaAvgString(), String(localized: "LT1 proxy", bundle: bundle)),
            (String(localized: "1-min HRR", bundle: bundle), drawing.hrrDropString(minute: 1), String(localized: "vagal reactivation", bundle: bundle)),
            (String(localized: "Best Split", bundle: bundle), drawing.bestSplitString(), String(localized: "fastest effort", bundle: bundle))
        ]
    }
}

// MARK: - File-scope helpers
//
// Moved out of WorkoutPDFReport. Each names no member of the
// type and calls nothing that stayed behind, so none needed to be inside
// it. `private` at file scope is fileprivate, so every call site in this
// file resolves exactly as before.

/// The 1-minute drop, read against the trained-endurance benchmarks.
private func hrrSentences(meta: WorkoutMetadata?, bundle: Bundle) -> [String] {
    guard let one = meta?.hrrSamples?.bestAtOneMinute else { return [] }
    var auto: [String] = []
    let interp: String = one.drop > 18 ? String(localized: "exceeds the > 18 bpm benchmark cited for trained endurance athletes", bundle: bundle)
        : one.drop >= 12 ? String(localized: "at or above the 12 bpm convention from clinical exercise testing", bundle: bundle)
        : one.drop >= 8 ? String(localized: "below the 12 bpm convention", bundle: bundle)
        : String(localized: "well below the 12 bpm convention", bundle: bundle)
    auto.append(String(localized: "1-minute HRR drop \(one.drop) bpm — \(interp).", bundle: bundle))
    return auto
}

/// A mean α1 well above 1.0 usually means the RR stream was too noisy to
/// trust rather than an unusually parasympathetic session.
private func alphaObservations(meta: WorkoutMetadata?, bundle: Bundle) -> [String] {
    guard let samples = meta?.samples, !samples.isEmpty else { return [] }
    let alphaPoints = samples.compactMap(\.alpha1)
    guard !alphaPoints.isEmpty else { return [] }
    let mean = alphaPoints.reduce(0, +) / Double(alphaPoints.count)
    guard mean > 1.5 else { return [] }
    var flags: [String] = []
        flags.append(String(localized: "Mean α1 \(String(format: "%.2f", locale: LanguageManager.appLocale, mean)) unusually high for an exercise window. Possible ectopic-beat contamination despite filtering; consider re-checking strap contact for future sessions.", bundle: bundle))
    return flags
}
