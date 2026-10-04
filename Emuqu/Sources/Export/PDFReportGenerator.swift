import Foundation
import PDFKit
import UIKit

/// Generates professional PDF reports for HRV analysis results
/// Includes Poincaré plot, PSD graph, and tachogram visualizations
final class PDFReportGenerator {
    // MARK: - Report Style

    /// Controls the depth of the generated PDF report.
    enum ReportStyle {
        /// Consumer-friendly summary: score, key metrics, charts (~3 pages)
        case summary
        /// Full clinical report with deep-dive analysis of every metric
        case comprehensive
    }

    // MARK: - Report Sections

    /// Controls which content sections are included in the report.
    /// Used with the section picker to let users build custom reports.
    struct ReportSections: OptionSet, Sendable {
        let rawValue: Int

        /// Core HRV summary card. Every report draws it; presets keep the bit
        /// so a preset still matches the picker's selection.
        static let hrvSummary = ReportSections(rawValue: 1 << 0)
        /// Overnight stats (sleep/wake times, nadir HR, peak HRV from raw data)
        static let overnightStats = ReportSections(rawValue: 1 << 1)
        /// Sleep analysis (stages, duration, efficiency)
        static let sleep = ReportSections(rawValue: 1 << 2)
        /// Training load (CTL, ATL, TSB, ACWR)
        static let trainingLoad = ReportSections(rawValue: 1 << 3)
        /// Recovery vitals (respiratory rate, SpO2, temperature, RHR)
        static let vitals = ReportSections(rawValue: 1 << 4)
        /// Score breakdown (composite score components)
        static let scoreBreakdown = ReportSections(rawValue: 1 << 5)
        /// Visualizations (overnight HR chart, Poincaré, PSD, tachogram)
        static let charts = ReportSections(rawValue: 1 << 6)
        /// Deep-dive analysis pages (comprehensive metrics, clinical detail)
        static let deepDive = ReportSections(rawValue: 1 << 7)

        /// All sections enabled
        static let all: ReportSections = [.hrvSummary, .overnightStats, .sleep, .trainingLoad, .vitals, .scoreBreakdown, .charts, .deepDive]

        // MARK: Presets

        /// Summary preset: everything except deep-dive
        static let summaryPreset: ReportSections = [.hrvSummary, .overnightStats, .sleep, .trainingLoad, .vitals, .scoreBreakdown, .charts]
        /// Sleep-focused preset
        static let sleepPreset: ReportSections = [.hrvSummary, .overnightStats, .sleep]

        /// Human-readable label for each section (used in picker UI). The HRV
        /// summary card is on every report, so it has no switch. Computed, so
        /// a live language switch relabels the picker.
        static var sectionLabels: [(section: ReportSections, label: String, icon: String)] {
            [
                (.overnightStats, String(localized: "Overnight Stats", bundle: LanguageManager.appBundle), "moon.stars"),
                (.sleep, String(localized: "Sleep Analysis", bundle: LanguageManager.appBundle), "bed.double.fill"),
                (.trainingLoad, String(localized: "Training Load", bundle: LanguageManager.appBundle), "figure.run"),
                (.vitals, String(localized: "Recovery Vitals", bundle: LanguageManager.appBundle), "heart.text.clipboard"),
                (.scoreBreakdown, String(localized: "Score Breakdown", bundle: LanguageManager.appBundle), "chart.pie"),
                (.charts, String(localized: "Charts & Plots", bundle: LanguageManager.appBundle), "chart.xyaxis.line"),
                (.deepDive, String(localized: "Deep-Dive Analysis", bundle: LanguageManager.appBundle), "magnifyingglass")
            ]
        }
    }

    // MARK: - Configuration

    /// Sleep data from HealthKit (passed in for accurate reporting)
    struct SleepData {
        let sleepStart: Date?
        let sleepEnd: Date?
        let totalSleepMinutes: Int
        let inBedMinutes: Int
        let deepSleepMinutes: Int?
        let remSleepMinutes: Int?
        let awakeMinutes: Int
        /// Percent; nil when the night's wake was not measured.
        let sleepEfficiency: Double?

        var totalSleepFormatted: String {
            LocalizedDuration.hoursMinutes(minutes: totalSleepMinutes)
        }

        var deepSleepFormatted: String? {
            deepSleepMinutes.map { LocalizedDuration.hoursMinutes(minutes: $0) }
        }

        static let empty = SleepData(
            sleepStart: nil, sleepEnd: nil,
            totalSleepMinutes: 0, inBedMinutes: 0,
            deepSleepMinutes: nil, remSleepMinutes: nil,
            awakeMinutes: 0, sleepEfficiency: nil
        )

        init(sleepStart: Date? = nil, sleepEnd: Date? = nil, totalSleepMinutes: Int, inBedMinutes: Int, deepSleepMinutes: Int?, remSleepMinutes: Int?, awakeMinutes: Int, sleepEfficiency: Double?) {
            self.sleepStart = sleepStart
            self.sleepEnd = sleepEnd
            self.totalSleepMinutes = totalSleepMinutes
            self.inBedMinutes = inBedMinutes
            self.deepSleepMinutes = deepSleepMinutes
            self.remSleepMinutes = remSleepMinutes
            self.awakeMinutes = awakeMinutes
            self.sleepEfficiency = sleepEfficiency
        }

        init(from healthKit: Emuqu.SleepData?) {
            guard let hk = healthKit else {
                self = .empty
                return
            }
            sleepStart = hk.sleepStart
            sleepEnd = hk.sleepEnd
            totalSleepMinutes = hk.nightSleepMinutes
            inBedMinutes = hk.inBedMinutes
            deepSleepMinutes = hk.deepSleepMinutes
            remSleepMinutes = hk.remSleepMinutes
            awakeMinutes = hk.awakeMinutes
            sleepEfficiency = hk.measuredSleepEfficiency
        }
    }

    struct SleepTrendData {
        let averageSleepMinutes: Double
        let averageDeepSleepMinutes: Double?
        /// Percent over the nights whose wake was measured; nil when none was.
        let averageEfficiency: Double?
        let trend: AnalysisSleepTrendInput.SleepTrend
        let nightsAnalyzed: Int

        static let empty = SleepTrendData(
            averageSleepMinutes: 0, averageDeepSleepMinutes: nil,
            averageEfficiency: nil, trend: .insufficient, nightsAnalyzed: 0
        )

        init(averageSleepMinutes: Double, averageDeepSleepMinutes: Double?, averageEfficiency: Double?, trend: AnalysisSleepTrendInput.SleepTrend, nightsAnalyzed: Int) {
            self.averageSleepMinutes = averageSleepMinutes
            self.averageDeepSleepMinutes = averageDeepSleepMinutes
            self.averageEfficiency = averageEfficiency
            self.trend = trend
            self.nightsAnalyzed = nightsAnalyzed
        }

        init(from healthKit: HealthKitManager.SleepTrendStats?) {
            guard let hk = healthKit else {
                self = .empty
                return
            }
            averageSleepMinutes = hk.averageSleepMinutes
            averageDeepSleepMinutes = hk.averageDeepSleepMinutes
            // `SleepTrendStats` reports 0 when no night's wake was measured.
            averageEfficiency = hk.averageEfficiency
            nightsAnalyzed = hk.nightsAnalyzed
            switch hk.trend {
            case .improving: trend = .improving
            case .declining: trend = .declining
            case .stable: trend = .stable
            case .insufficient: trend = .insufficient
            }
        }
    }

    struct Config {
        var pageSize: CGSize = .init(width: 612, height: 792) // Letter size
        var margins: UIEdgeInsets = .init(top: 40, left: 40, bottom: 40, right: 40)
        var titleFont: UIFont = .systemFont(ofSize: 22, weight: .bold)
        var headingFont: UIFont = .systemFont(ofSize: 14, weight: .semibold)
        var subheadingFont: UIFont = .systemFont(ofSize: 11, weight: .medium)
        var bodyFont: UIFont = .systemFont(ofSize: 10)
        var captionFont: UIFont = .systemFont(ofSize: 8)
        var monoFont: UIFont = .monospacedSystemFont(ofSize: 9, weight: .regular)

        // Colors
        var primaryColor: UIColor = .init(red: 0.2, green: 0.4, blue: 0.8, alpha: 1.0)
        var secondaryColor: UIColor = .init(red: 0.3, green: 0.7, blue: 0.4, alpha: 1.0)
        var accentColor: UIColor = .init(red: 0.9, green: 0.3, blue: 0.3, alpha: 1.0)
    }

    let config: Config
    let settingsProvider: () -> UserSettings
    /// The scorer's English score text translated into the app's language
    /// (`ReportNarrative`), keyed by the English. Filled by
    /// `prepareNarrative(for:)` before rendering; empty leaves it in English.
    var narrative: [String: String] = [:]

    init(
        config: Config = Config(),
        settingsProvider: @escaping () -> UserSettings = { AppDependencies.current.app.settingsManager.settingsSnapshot }
    ) {
        self.config = config
        self.settingsProvider = settingsProvider
    }

    // MARK: - Public API

    /// Vitals data for the PDF report (mirrors RecoveryVitals)
    struct VitalsData {
        let respiratoryRate: Double?
        let respiratoryRateBaseline: Double?
        let oxygenSaturation: Double?
        let oxygenSaturationMin: Double?
        /// Tonight's wrist temperature against the user's own baseline (°C).
        let wristTemperature: Double?
        /// A reading exists but no baseline to set it against, so no
        /// deviation can be shown.
        var wristTemperatureLacksBaseline = false
        let restingHeartRate: Double?

        var hasAnyData: Bool {
            respiratoryRate != nil || oxygenSaturation != nil || wristTemperature != nil
                || wristTemperatureLacksBaseline || restingHeartRate != nil
        }

        static let empty = VitalsData(
            respiratoryRate: nil, respiratoryRateBaseline: nil,
            oxygenSaturation: nil, oxygenSaturationMin: nil,
            wristTemperature: nil, restingHeartRate: nil
        )

        init(respiratoryRate: Double?, respiratoryRateBaseline: Double?, oxygenSaturation: Double?, oxygenSaturationMin: Double?, wristTemperature: Double?, restingHeartRate: Double?) {
            self.respiratoryRate = respiratoryRate
            self.respiratoryRateBaseline = respiratoryRateBaseline
            self.oxygenSaturation = oxygenSaturation
            self.oxygenSaturationMin = oxygenSaturationMin
            self.wristTemperature = wristTemperature
            self.restingHeartRate = restingHeartRate
        }

        init(from healthKit: RecoveryVitals?) {
            guard let hk = healthKit else {
                self = .empty
                return
            }
            respiratoryRate = hk.respiratoryRate
            respiratoryRateBaseline = hk.respiratoryRateBaseline
            oxygenSaturation = hk.oxygenSaturation
            oxygenSaturationMin = hk.oxygenSaturationMin
            wristTemperature = hk.wristTemperatureDeviation
            wristTemperatureLacksBaseline = hk.wristTemperature != nil && hk.wristTemperatureDeviation == nil
            restingHeartRate = hk.restingHeartRate
        }
    }

    /// Everything one report render reads.
    ///
    /// The page drawers take this one value rather than fourteen parameters
    /// threaded identically through every level. Naming
    /// the set means a new input is added in one place, and no call site can
    /// transpose two same-typed arguments.
    struct ReportInputs {
        let session: HRVSession
        let result: HRVAnalysisResult
        let series: RRSeries?
        let artifactFlags: [ArtifactFlags]
        let hasRawData: Bool
        let sleepData: SleepData?
        let sleepTrend: SleepTrendData?
        let recentSessions: [HRVSession]
        let healthKitHR: HeartRateStats?
        let vitals: VitalsData?
        let compositeRecoveryScore: Double?
        let scoreBreakdown: RecoveryScoreCalculator.ScoreBreakdown?
        let baselineStats: BaselineTracker.RecoveryBaselineStats?
        let trainingContext: TrainingContext?
        let style: ReportStyle
        let sections: ReportSections
    }

    /// Generate PDF report for an HRV session
    /// Supports both full sessions (with RR series) and summary-only sessions (imported data)
    /// - Parameters:
    ///   - session: The HRV session to generate a report for
    ///   - flags: Optional artifact flags
    ///   - sleepData: HealthKit sleep data for accurate sleep reporting
    ///   - sleepTrend: Sleep trend data for context
    ///   - recentSessions: Recent sessions for trend comparison
    ///   - healthKitHR: HealthKit heart rate statistics (mean, min, max, nadir time) for accurate HR reporting
    ///   - vitals: Recovery vitals (respiratory rate, SpO2, temperature, RHR)
    ///   - compositeRecoveryScore: Composite recovery score (0-100) combining HRV (60%), sleep (25%), and vitals (15%) under the v3.oct2026 architecture
    func generateReport(
        for session: HRVSession,
        flags: [ArtifactFlags]? = nil,
        sleepData: SleepData? = nil,
        sleepTrend: SleepTrendData? = nil,
        recentSessions: [HRVSession] = [],
        healthKitHR: HeartRateStats? = nil,
        vitals: VitalsData? = nil,
        compositeRecoveryScore: Double? = nil,
        scoreBreakdown: RecoveryScoreCalculator.ScoreBreakdown? = nil,
        baselineStats: BaselineTracker.RecoveryBaselineStats? = nil,
        // Pre-resolved live training-load snapshot from the
        // caller (must be captured on MainActor via
        // `TrainingLoadRegistry.live()`). When non-nil, the report
        // overrides the frozen `result.trainingContext` ATL/CTL/TSB
        // with these live values so the report shows the same numbers
        // as the Load & Trajectory dashboard. User complaint:
        // "the report showed a totally different TSB than
        // the loading page." Root cause: `result.trainingContext`
        // is frozen at session-acceptance time, pre-walk, while
        // Dashboard subscribes to the live cache. Other frozen fields
        // (yesterdayTrimp, vo2Max, daysSinceHardWorkout,
        // recentWorkouts) are preserved from the session snapshot.
        liveLoadSnapshot: TrainingLoadRegistry.TrainingLoad? = nil,
        style: ReportStyle = .comprehensive,
        sections: ReportSections = .all
    ) -> Data? {
        guard let result = session.analysisResult else { return nil }
        let health = ReportHealthContext(
            sleepData: sleepData, sleepTrend: sleepTrend, recentSessions: recentSessions,
            healthKitHR: healthKitHR, vitals: vitals,
            compositeRecoveryScore: compositeRecoveryScore, scoreBreakdown: scoreBreakdown,
            baselineStats: baselineStats
        )
        let inputs = reportInputs(
            session: session, result: result, flags: flags, health: health,
            liveLoadSnapshot: liveLoadSnapshot, style: style, sections: sections
        )
        let pageRect = CGRect(origin: .zero, size: config.pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: reportRendererFormat())
        return renderer.pdfData { context in
            drawReportPages(inputs, in: context, pageRect: pageRect)
        }
    }

    /// Everything the report knows about the night beyond the session itself.
    ///
    /// These eight are one thing: the health
    /// context a report is rendered against, so they travel together rather
    /// than as loose arguments. `generateReport` still names them
    /// individually because they are its defaulted public surface.
    struct ReportHealthContext {
        let sleepData: SleepData?
        let sleepTrend: SleepTrendData?
        let recentSessions: [HRVSession]
        let healthKitHR: HeartRateStats?
        let vitals: VitalsData?
        let compositeRecoveryScore: Double?
        let scoreBreakdown: RecoveryScoreCalculator.ScoreBreakdown?
        /// The baseline the score was computed against, so "What This Means"
        /// rates HRV the way Today does.
        let baselineStats: BaselineTracker.RecoveryBaselineStats?
    }

    private func drawReportPages(_ inputs: ReportInputs, in context: UIGraphicsPDFRendererContext, pageRect: CGRect) {
        var pageNumber = 1
        _ = drawPage1_SummaryAndMetrics(inputs, pageNumber: &pageNumber, in: context, pageRect: pageRect)
        // Page 2 needs raw RR data to have anything to plot.
        if inputs.sections.contains(.charts), inputs.hasRawData, inputs.series != nil {
            _ = drawPage2_Visualizations(inputs, pageNumber: &pageNumber, in: context, pageRect: pageRect)
        }
        if inputs.style == .comprehensive, inputs.sections.contains(.deepDive) {
            drawDeepDivePages(inputs, pageNumber: &pageNumber, in: context, pageRect: pageRect)
        }
    }

    /// Draw a note indicating this is imported data
    func drawImportedDataNote(yPosition: CGFloat, session: HRVSession, in _: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let y = yPosition + 10
        let note = importedDataNote(session: session)
        let noteHeight = ceil(note.boundingRect(
            with: CGSize(width: contentWidth - 50, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
        ).height)
        // The box grows with the note, so a long or translated one is not clipped.
        let boxHeight = max(50, noteHeight + 20)
        let boxRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: boxHeight)
        UIColor(red: 0.95, green: 0.95, blue: 0.98, alpha: 1.0).setFill()
        UIBezierPath(roundedRect: boxRect, cornerRadius: 6).fill()
        "ℹ️".draw(at: CGPoint(x: config.margins.left + 10, y: y + 15), withAttributes: [
            .font: UIFont.systemFont(ofSize: 16),
            .foregroundColor: UIColor.systemBlue
        ])
        note.draw(in: CGRect(x: config.margins.left + 35, y: y + 10, width: contentWidth - 50, height: noteHeight))
        return y + boxHeight + 15
    }

    private func importedDataNote(session: HRVSession) -> NSAttributedString {
        let noteText = if let source = session.importedMetrics?.source {
            String(localized: "Imported from \(source). Raw RR data not available - visualizations omitted.", bundle: LanguageManager.appBundle)
        } else {
            String(localized: "Summary data only. Raw RR intervals not available for visualization.", bundle: LanguageManager.appBundle)
        }
        return NSAttributedString(string: noteText, attributes: [.font: config.bodyFont, .foregroundColor: UIColor.darkGray])
    }
}

// MARK: - File-scope helpers
//
// Kept outside the type. Each touches no instance state —
// including the computed properties — and
// calls nothing inside the type, so none is a method in anything but
// placement. `private` at file scope is fileprivate, so every call site in
// this file resolves the same way.
//
// This is what `check_aggregate_type_size.sh` measures: a type is the sum of
// its parts across every file, so code that does not need the type inflates
// that number without making the type do more.

private func reportInputs(
    session: HRVSession, result: HRVAnalysisResult, flags: [ArtifactFlags]?,
    health: PDFReportGenerator.ReportHealthContext,
    liveLoadSnapshot: TrainingLoadRegistry.TrainingLoad?,
    style: PDFReportGenerator.ReportStyle, sections: PDFReportGenerator.ReportSections
) -> PDFReportGenerator.ReportInputs {
    let series = session.rrSeries // Optional - may be nil for imported data
    return PDFReportGenerator.ReportInputs(
        session: session,
        result: result,
        series: series,
        artifactFlags: flags ?? session.artifactFlags ?? [],
        hasRawData: series.map { !$0.points.isEmpty } ?? false,
        sleepData: health.sleepData,
        sleepTrend: health.sleepTrend,
        recentSessions: health.recentSessions,
        healthKitHR: health.healthKitHR,
        vitals: health.vitals,
        compositeRecoveryScore: health.compositeRecoveryScore,
        scoreBreakdown: health.scoreBreakdown,
        baselineStats: health.baselineStats,
        trainingContext: mergedTrainingContext(frozen: result.trainingContext, live: liveLoadSnapshot, session: session),
        style: style,
        sections: sections
    )
}

/// The training context the report renders against: the live snapshot's
/// ATL/CTL/TSB when the caller captured one for today's session, otherwise
/// the frozen session values (a past day's report shows that day's load). Non-load fields (yesterdayTrimp, vo2Max, ...) have no live
/// equivalent and stay session-context either way.
///
/// User complaint: "the report showed a totally different TSB
/// than the loading page." `result.trainingContext` is frozen at
/// session-acceptance time, pre-walk, while the Dashboard subscribes to the
/// live cache.
private func mergedTrainingContext(
    frozen: TrainingContext?,
    live: TrainingLoadRegistry.TrainingLoad?,
    session: HRVSession
) -> TrainingContext? {
    guard let live, Calendar.current.isDateInToday(session.endDate ?? session.startDate) else { return frozen }
    return TrainingContext(
        atl: live.atl,
        ctl: live.ctl,
        tsb: live.tsb,
        yesterdayTrimp: frozen?.yesterdayTrimp ?? 0,
        vo2Max: frozen?.vo2Max,
        daysSinceHardWorkout: frozen?.daysSinceHardWorkout,
        recentWorkouts: frozen?.recentWorkouts
    )
}

private func reportRendererFormat() -> UIGraphicsPDFRendererFormat {
    let format = UIGraphicsPDFRendererFormat()
    format.documentInfo = [
        kCGPDFContextCreator: "Emuqu",
        kCGPDFContextTitle: String(localized: "Recovery Report", bundle: LanguageManager.appBundle),
        kCGPDFContextAuthor: "Emuqu"
    ] as [String: Any]
    return format
}
