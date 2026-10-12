import Foundation
import PDFKit
import UIKit

// MARK: - Deep-Dive: Sleep, Training, Vitals
//
// Split out of `PDFReportGenerator+DeepDive.swift` to keep that file under
// the 1000-line file limit. The HRV deep dive, the shared drawing helpers
// and the interpretation bands stay behind; the three body-system sections live
// here. The helpers those sections call are internal rather than `private`
// because Swift's `private` does not reach across files.

extension DeepDiveReportRenderer {
    // MARK: - Deep Sleep Analysis

    func drawDeepSleepAnalysis(
        sleep: PDFReportGenerator.SleepData,
        sleepTrend: PDFReportGenerator.SleepTrendData?,
        pageNumber: inout Int,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        let bundle = LanguageManager.appBundle
        var y = yPosition
        y = drawDeepDiveSectionTitle(String(localized: "Sleep — Complete Analysis", bundle: bundle), yPosition: y, pageRect: pageRect)

        y = drawSleepDurationSection(sleep: sleep, sleepTrend: sleepTrend, pageNumber: &pageNumber, yPosition: y, in: context, pageRect: pageRect)
        y = drawSleepArchitectureSection(sleep: sleep, sleepTrend: sleepTrend, pageNumber: &pageNumber, yPosition: y, in: context, pageRect: pageRect)
        y = drawSleepTrendsSection(sleep: sleep, sleepTrend: sleepTrend, pageNumber: &pageNumber, yPosition: y, in: context, pageRect: pageRect)
        return y
    }

    private func drawSleepDurationSection(
        sleep: PDFReportGenerator.SleepData,
        sleepTrend _: PDFReportGenerator.SleepTrendData?,
        pageNumber: inout Int,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let bundle = LanguageManager.appBundle
        var y = drawSubsectionHeading(String(localized: "Duration & Efficiency", bundle: bundle), yPosition: yPosition, pageRect: pageRect)
        for metric in sleepDurationRows(sleep: sleep, bundle: bundle) {
            y = drawMetricWithExplanation(
                metric, y: y, contentWidth: contentWidth,
                pageNumber: &pageNumber, context: context, pageRect: pageRect
            )
        }
        return y
    }

    private func drawSleepArchitectureSection(
        sleep: PDFReportGenerator.SleepData,
        sleepTrend _: PDFReportGenerator.SleepTrendData?,
        pageNumber: inout Int,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        guard sleep.deepSleepMinutes != nil || sleep.remSleepMinutes != nil else { return yPosition }
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let bundle = LanguageManager.appBundle
        var y = ensureSpace(needed: 80, y: yPosition, pageNumber: &pageNumber, context: context, pageRect: pageRect)
        y = drawSubsectionHeading(String(localized: "Sleep Architecture", bundle: bundle), yPosition: y, pageRect: pageRect)
        y = drawWrappedText(
            String(localized: "Sleep architecture describes how your sleep is distributed across stages throughout the night. A typical night follows a predictable pattern: deep sleep (slow-wave) is concentrated in the first half of the night, while REM sleep increases in the second half.", bundle: bundle),
            style: .explanation, y: y, contentWidth: contentWidth, pageNumber: &pageNumber, context: context, pageRect: pageRect
        )
        for metric in sleepArchitectureRows(sleep: sleep, bundle: bundle) {
            y = drawMetricWithExplanation(
                metric, y: y, contentWidth: contentWidth,
                pageNumber: &pageNumber, context: context, pageRect: pageRect
            )
        }
        return y
    }

    private func sleepArchitectureRows(sleep: PDFReportGenerator.SleepData, bundle: Bundle) -> [DeepDiveMetric] {
        [
            deepSleepRow(sleep: sleep, bundle: bundle),
            remSleepRow(sleep: sleep, bundle: bundle),
            lightSleepRow(sleep: sleep, bundle: bundle)
        ].compactMap { $0 }
    }

    private func deepSleepRow(sleep: PDFReportGenerator.SleepData, bundle: Bundle) -> DeepDiveMetric? {
        guard let deep = sleep.deepSleepMinutes else { return nil }
        let deepPct = sleep.totalSleepMinutes > 0 ? Double(deep) / Double(sleep.totalSleepMinutes) * 100 : 0
        let deepFormatted = reportHoursMinutes(deep)
        return DeepDiveMetric(
            name: String(localized: "Deep Sleep (N3/SWS)", bundle: bundle), value: "\(deepFormatted) (\(String(format: "%.0f%%", locale: LanguageManager.appLocale, deepPct)))",
            explanation: String(localized: "Slow-wave sleep (Stage N3) — the most physically restorative stage. Growth hormone secretion peaks during deep sleep, driving muscle repair, immune function, and tissue regeneration. Adults typically need 60–120 minutes (15–25% of total sleep). Deep sleep is front-loaded — most occurs in the first 3 hours. Alcohol, aging, and heavy sustained training load reduce deep sleep percentage.", bundle: bundle),
            interpretation: interpretDeepSleep(deepPct: deepPct, deepMinutes: deep)
        )
    }

    private func remSleepRow(sleep: PDFReportGenerator.SleepData, bundle: Bundle) -> DeepDiveMetric? {
        guard let rem = sleep.remSleepMinutes else { return nil }
        let remPct = sleep.totalSleepMinutes > 0 ? Double(rem) / Double(sleep.totalSleepMinutes) * 100 : 0
        let remFormatted = reportHoursMinutes(rem)
        return DeepDiveMetric(
            name: String(localized: "REM Sleep", bundle: bundle), value: "\(remFormatted) (\(String(format: "%.0f%%", locale: LanguageManager.appLocale, remPct)))",
            explanation: String(localized: "Rapid Eye Movement sleep — critical for memory consolidation, emotional regulation, and motor learning. REM increases across the night, with the longest REM periods in the final 2 hours. Adults need 90–120 minutes (20–25% of total sleep). REM deprivation impairs skill acquisition and emotional resilience. Early wake times disproportionately cut REM.", bundle: bundle),
            interpretation: interpretREMSleep(remPct: remPct, remMinutes: rem)
        )
    }

    private func drawSleepTrendsSection(
        sleep _: PDFReportGenerator.SleepData,
        sleepTrend: PDFReportGenerator.SleepTrendData?,
        pageNumber: inout Int,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        guard let trend = sleepTrend, trend.nightsAnalyzed > 2 else { return yPosition }
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let bundle = LanguageManager.appBundle
        var y = ensureSpace(needed: 60, y: yPosition, pageNumber: &pageNumber, context: context, pageRect: pageRect)
        y = drawSubsectionHeading(String(localized: "Sleep Trends (\(trend.nightsAnalyzed) nights)", bundle: bundle), yPosition: y, pageRect: pageRect)
        y = drawWrappedText(sleepTrendSummary(trend, bundle: bundle), style: .body, y: y, contentWidth: contentWidth, pageNumber: &pageNumber, context: context, pageRect: pageRect)
        guard let avgDeep = trend.averageDeepSleepMinutes, avgDeep > 0 else { return y }
        return drawWrappedText(
            String(localized: "Average deep sleep: \(String(format: "%.0f", locale: LanguageManager.appLocale, avgDeep)) minutes per night.", bundle: bundle),
            style: .body, y: y, contentWidth: contentWidth, pageNumber: &pageNumber, context: context, pageRect: pageRect
        )
    }

    // MARK: - Deep Training Analysis

    func drawDeepTrainingAnalysis(
        training: TrainingContext,
        pageNumber: inout Int,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        let bundle = LanguageManager.appBundle
        var y = yPosition
        y = drawDeepDiveSectionTitle(String(localized: "Training Load — Complete Analysis", bundle: bundle), yPosition: y, pageRect: pageRect)

        y = drawPMCMetricsSection(training: training, pageNumber: &pageNumber, yPosition: y, in: context, pageRect: pageRect)
        y = drawACWRSection(training: training, pageNumber: &pageNumber, yPosition: y, in: context, pageRect: pageRect)
        y = drawYesterdayTrainingSection(training: training, pageNumber: &pageNumber, yPosition: y, in: context, pageRect: pageRect)
        y = drawVO2MaxSection(training: training, pageNumber: &pageNumber, yPosition: y, in: context, pageRect: pageRect)
        return y
    }

    private func drawPMCMetricsSection(
        training: TrainingContext,
        pageNumber: inout Int,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let bundle = LanguageManager.appBundle
        var y = drawSubsectionHeading(String(localized: "Fitness, fatigue, form", bundle: bundle), yPosition: yPosition, pageRect: pageRect)
        y = drawWrappedText(
            String(localized: "This model tracks the relationship between fitness (chronic training load) and fatigue (acute training load). Your body adapts to consistent training stress (fitness rises) but needs recovery from recent efforts (fatigue). Form (TSB) = Fitness - Fatigue. It is bookkeeping on your training history, not a measurement of your physiology: a positive Form usually accompanies feeling fresh, rather than predicting how you will perform.", bundle: bundle),
            style: .explanation, y: y, contentWidth: contentWidth, pageNumber: &pageNumber, context: context, pageRect: pageRect

        )
        for metric in pmcRows(training: training, bundle: bundle) {
            y = drawMetricWithExplanation(
                metric, y: y, contentWidth: contentWidth,
                pageNumber: &pageNumber, context: context, pageRect: pageRect
            )
        }
        return y
    }

    private func pmcRows(training: TrainingContext, bundle: Bundle) -> [DeepDiveMetric] {
        [ctlRow(training: training, bundle: bundle),
         atlRow(training: training, bundle: bundle),
         tsbRow(training: training, bundle: bundle)]
    }

    private func ctlRow(training: TrainingContext, bundle: Bundle) -> DeepDiveMetric {
        DeepDiveMetric(
            name: String(localized: "CTL (Chronic Training Load / Fitness)", bundle: bundle), value: String(format: "%.0f", locale: LanguageManager.appLocale, training.ctl),
            explanation: String(localized: "42-day exponentially weighted moving average (EWMA) of daily training load. Represents your accumulated fitness — the training your body has adapted to. Higher CTL means higher work capacity. CTL rises slowly with consistent training and decays slowly during rest. A 1-point CTL increase requires approximately 1 load point above your daily average, sustained daily.", bundle: bundle),
            interpretation: interpretCTL(training.ctl)
        )
    }

    private func atlRow(training: TrainingContext, bundle: Bundle) -> DeepDiveMetric {
        DeepDiveMetric(
            name: String(localized: "ATL (Acute Training Load / Fatigue)", bundle: bundle), value: String(format: "%.0f", locale: LanguageManager.appLocale, training.atl),
            explanation: String(localized: "7-day EWMA of daily training load. Represents recent training fatigue — the stress your body hasn't yet adapted to. ATL responds quickly to training changes: it spikes after hard efforts and drops during rest days. When ATL significantly exceeds CTL, recent load is outpacing your fitness base — a descriptive signal that an easier session or recovery day is worth considering. Emuqu does not interpret this ratio as a clinical risk score.", bundle: bundle),
            interpretation: interpretATL(training.atl, ctl: training.ctl)
        )
    }

    private func tsbRow(training: TrainingContext, bundle: Bundle) -> DeepDiveMetric {
        DeepDiveMetric(
            name: String(localized: "TSB (Training-Load Balance / Form)", bundle: bundle), value: String(format: "%+.0f", locale: LanguageManager.appLocale, training.tsb),
            explanation: String(localized: "CTL minus ATL. Positive TSB means fitness exceeds fatigue — you're relatively fresh and ready to perform. Negative TSB means recent training is creating more fatigue than your base can easily absorb. For peak performance, aim for TSB between +5 and +25. For productive training, TSB between -10 and -30 is the adaptive zone. Below -30, you're carrying significant accumulated fatigue — recovery sessions become more important.", bundle: bundle),
            interpretation: interpretTSB(training.tsb)
        )
    }

    private func drawACWRSection(
        training: TrainingContext,
        pageNumber: inout Int,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let bundle = LanguageManager.appBundle
        var y = yPosition
        // ── ACWR ──
        if let acr = training.acuteChronicRatio {
            y = ensureSpace(needed: 60, y: y, pageNumber: &pageNumber, context: context, pageRect: pageRect)
            y = drawSubsectionHeading(String(localized: "Acute:Chronic Workload Ratio (ACWR)", bundle: bundle), yPosition: y, pageRect: pageRect)

            y = drawMetricWithExplanation(
                DeepDiveMetric(
                    name: "ACWR", value: String(format: "%.2f", locale: LanguageManager.appLocale, acr),
                    explanation: String(localized: "ATL divided by CTL — a ratio of recent load to your longer-term fitness base. Originally framed by Gabbett (2016) as having a 0.8–1.3 \"sweet spot,\" but Impellizzeri et al. (2020/2021) demonstrated that the chronic denominator carries little real signal — random numbers in the chronic position produce nearly identical odds ratios for injury. Emuqu shows ACWR for context but does not use it in the Recovery Score and does not present it as an injury predictor. Treat it as one descriptive number among several: ratio above ~1.3 means recent load is above your usual range; above ~1.5 means a sharper increase that's worth easing back from to absorb properly. Context matters more than the number itself.", bundle: bundle),
                    interpretation: interpretACWR(acr)
                ),
                y: y, contentWidth: contentWidth, pageNumber: &pageNumber, context: context, pageRect: pageRect
            )
        }

        return y
    }

    private func drawYesterdayTrainingSection(
        training: TrainingContext,
        pageNumber: inout Int,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        guard training.yesterdayTrimp > 0 else { return yPosition }
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let bundle = LanguageManager.appBundle
        var y = ensureSpace(needed: 40, y: yPosition, pageNumber: &pageNumber, context: context, pageRect: pageRect)
        y = drawSubsectionHeading(String(localized: "Recent Training Context", bundle: bundle), yPosition: y, pageRect: pageRect)
        let metric = yesterdayTrimpRow(training: training, bundle: bundle)
        return drawMetricWithExplanation(
            metric, y: y, contentWidth: contentWidth,
            pageNumber: &pageNumber, context: context, pageRect: pageRect
        )
    }

    private func drawVO2MaxSection(
        training: TrainingContext,
        pageNumber: inout Int,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let bundle = LanguageManager.appBundle
        var y = yPosition
        // ── VO2max ──
        if let vo2 = training.vo2Max {
            y = drawMetricWithExplanation(
                DeepDiveMetric(
                    name: String(localized: "Estimated VO₂max", bundle: bundle), value: String(format: "%.1f mL/kg/min", locale: LanguageManager.appLocale, vo2),
                    explanation: String(localized: "Maximum oxygen consumption — a standard measure of aerobic capacity. Higher values indicate greater aerobic capacity. Context: VO₂max declines ~1% per year after age 30 without training. Top endurance athletes exceed 70 mL/kg/min.", bundle: bundle),
                    interpretation: interpretVO2Max(vo2)
                ),
                y: y, contentWidth: contentWidth, pageNumber: &pageNumber, context: context, pageRect: pageRect
            )
        }

        return y
    }

    // MARK: - Deep Vitals Analysis

    func drawDeepVitalsAnalysis(
        vitals: PDFReportGenerator.VitalsData,
        pageNumber: inout Int,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let bundle = LanguageManager.appBundle
        var y = drawDeepDiveSectionTitle(String(localized: "Recovery Vitals — Complete Analysis", bundle: bundle), yPosition: yPosition, pageRect: pageRect)
        y = drawWrappedText(
            String(localized: "Recovery vitals are physiological signals collected by Apple Watch during sleep. Unlike HRV (which reflects autonomic tone), vitals shift with broader physiological load — hard training, alcohol, heat, altitude, and sometimes the start of an illness. Elevated vitals lower the score even when HRV looks good, because they can move when HRV has not.", bundle: bundle),
            style: .explanation, y: y, contentWidth: contentWidth, pageNumber: &pageNumber, context: context, pageRect: pageRect

        )
        for metric in vitalsRows(vitals: vitals, bundle: bundle) {
            y = drawMetricWithExplanation(
                metric, y: y, contentWidth: contentWidth,
                pageNumber: &pageNumber, context: context, pageRect: pageRect
            )
        }
        y = drawCombinedVitalsPattern(vitals: vitals, pageNumber: &pageNumber, yPosition: y, in: context, pageRect: pageRect)
        return y + 10
    }

    private func drawCombinedVitalsPattern(
        vitals: PDFReportGenerator.VitalsData,
        pageNumber: inout Int,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let bundle = LanguageManager.appBundle
        var y = ensureSpace(needed: 40, y: yPosition, pageNumber: &pageNumber, context: context, pageRect: pageRect)
        let pattern = assessVitalsPattern(vitals)
        guard !pattern.isEmpty else { return y }
        y = drawSubsectionHeading(String(localized: "Combined Vitals Pattern", bundle: bundle), yPosition: y, pageRect: pageRect)
        return drawWrappedText(pattern, style: .body, y: y, contentWidth: contentWidth, pageNumber: &pageNumber, context: context, pageRect: pageRect)
    }

    private func vitalsRows(vitals: PDFReportGenerator.VitalsData, bundle: Bundle) -> [DeepDiveMetric] {
        [
            respiratoryRateRow(vitals: vitals, bundle: bundle),
            oxygenSaturationRow(vitals: vitals, bundle: bundle),
            wristTemperatureRow(vitals: vitals, valueLabel: generator.wristTemperatureDeviationLabel, bundle: bundle),
            restingHeartRateRow(vitals: vitals, bundle: bundle)
        ].compactMap { $0 }
    }

    private func respiratoryRateRow(vitals: PDFReportGenerator.VitalsData, bundle: Bundle) -> DeepDiveMetric? {
        guard let rr = vitals.respiratoryRate else { return nil }
        return DeepDiveMetric(
            name: String(localized: "Respiratory Rate", bundle: bundle),
            value: reportBreathsPerMinute(rr),
            explanation: respiratoryRateExplanation(rr: rr, vitals: vitals, bundle: bundle),
            interpretation: Self.respiratoryRateInterpretation(rr: rr, vitals: vitals, bundle: bundle)
        )
    }

    /// Against a known baseline the deviation is what matters (and what the
    /// score penalises); without one, absolute breaths/min is the only read.
    private static func respiratoryRateInterpretation(rr: Double, vitals: PDFReportGenerator.VitalsData, bundle: Bundle) -> String {
        guard let baseline = vitals.respiratoryRateBaseline else {
            if rr <= 16 { return String(localized: "Normal range", bundle: bundle) }
            return rr <= 20
                ? String(localized: "Upper normal", bundle: bundle)
                : String(localized: "Elevated", bundle: bundle)
        }
        let diff = rr - baseline
        if diff > 2 { return String(localized: "Elevated above baseline — lowers the Vitals part of your recovery score", bundle: bundle) }
        if diff > 1 { return String(localized: "Slightly above baseline — lowers the Vitals part a little", bundle: bundle) }
        return String(localized: "At or below baseline — no concerns", bundle: bundle)
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

private func sleepDurationRows(sleep: PDFReportGenerator.SleepData, bundle: Bundle) -> [DeepDiveReportRenderer.DeepDiveMetric] {
    [
        totalSleepTimeRow(sleep: sleep, bundle: bundle),
        sleepEfficiencyRow(sleep: sleep, bundle: bundle),
        timeInBedRow(sleep: sleep, bundle: bundle),
        timeAwakeRow(sleep: sleep, bundle: bundle)
    ].compactMap { $0 }
}

private func totalSleepTimeRow(sleep: PDFReportGenerator.SleepData, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric {
    let totalHours = Double(sleep.totalSleepMinutes) / 60.0
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "Total Sleep Time", bundle: bundle), value: sleep.totalSleepFormatted,
        explanation: String(localized: "Time actually spent asleep (excludes awake periods during the night). The National Sleep Foundation recommends 7–9 hours for adults 18–64, and 7–8 hours for adults 65+. Below 6 hours consistently is associated with impaired cognitive function, weakened immune response, and reduced training adaptation in athletes (Watson et al. 2015).", bundle: bundle),
        interpretation: totalHours >= 7.0 ? String(localized: "Within recommended range — supports optimal recovery", bundle: bundle) :
            (
                totalHours >= 6.0 ? String(localized: "Slightly below recommended — aim for 7+ hours", bundle: bundle) :
                    String(localized: "Below 6 hours — sleep debt is accumulating, recovery will be impaired", bundle: bundle)
            )
    )
}

/// Shows "Not measured" with no interpretation when the night's wake was not measured.
private func sleepEfficiencyRow(sleep: PDFReportGenerator.SleepData, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric {
    let explanation = String(localized: "Percentage of time in bed actually spent asleep. Efficiency above 85% is considered good; above 90% is excellent. Low efficiency (<80%) usually means broken sleep or time in bed awake.", bundle: bundle)
    guard let effPct = sleep.sleepEfficiency else {
        return DeepDiveReportRenderer.DeepDiveMetric(
            name: String(localized: "Sleep Efficiency", bundle: bundle), value: String(localized: "Not measured", bundle: bundle),
            explanation: explanation, interpretation: nil
        )
    }
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "Sleep Efficiency", bundle: bundle), value: String(format: "%.0f%%", locale: LanguageManager.appLocale, effPct),
        explanation: explanation,
        interpretation: effPct >= 90 ? String(localized: "Excellent efficiency — sleep is well-consolidated", bundle: bundle) :
            (
                effPct >= 85 ? String(localized: "Good — sleep is mostly consolidated", bundle: bundle) :
                    (
                        effPct >= 80 ? String(localized: "Fair — some fragmentation present", bundle: bundle) :
                            String(localized: "Below 80% — significant sleep disruption", bundle: bundle)
                    )
            )
    )
}

private func timeInBedRow(sleep: PDFReportGenerator.SleepData, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric {
    let inBedFormatted = reportHoursMinutes(sleep.inBedMinutes)
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "Time In Bed", bundle: bundle), value: inBedFormatted,
        explanation: String(localized: "Total time from lights-out to final wake. The difference between in-bed time and sleep time is your wake-after-sleep-onset (WASO) plus sleep onset latency. Spending >30 minutes awake in bed may reinforce insomnia patterns — cognitive behavioral therapy for insomnia (CBT-I) uses stimulus control to address this.", bundle: bundle),
        interpretation: nil
    )
}

/// Nil when the night had no recorded wake time — the row is omitted rather
/// than printed as "0m", which reads like a measurement instead of an absence.
private func timeAwakeRow(sleep: PDFReportGenerator.SleepData, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric? {
    guard sleep.awakeMinutes > 0 else { return nil }
    let awakeFormatted = reportHoursMinutes(sleep.awakeMinutes)
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "Time Awake", bundle: bundle), value: awakeFormatted,
        explanation: String(localized: "Total wake time during the sleep period. Brief awakenings (<5 minutes each, totaling <30 minutes) are normal and often not remembered. Excessive wake time fragments sleep architecture and reduces the restorative benefits of deep sleep and REM cycles.", bundle: bundle),
        interpretation: sleep.awakeMinutes < 30 ? String(localized: "Minimal wake time — sleep well-consolidated", bundle: bundle) :
            (
                sleep.awakeMinutes < 60 ? String(localized: "Some disruption — still within acceptable range", bundle: bundle) :
                    String(localized: "Significant wake time — may impair recovery quality", bundle: bundle)
            )
    )
}

/// Light sleep (core). `totalSleepMinutes` already EXCLUDES awake time
/// (it is deep+rem+core), so subtracting awake again would double-count it and
/// make deep/rem/light sum to less than 100 (matches +Sections.swift).
private func lightSleepRow(sleep: PDFReportGenerator.SleepData, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric? {
    let deep = sleep.deepSleepMinutes ?? 0
    let rem = sleep.remSleepMinutes ?? 0
    let light = sleep.totalSleepMinutes - deep - rem
    guard light > 0 else { return nil }
    let lightPct = sleep.totalSleepMinutes > 0 ? Double(light) / Double(sleep.totalSleepMinutes) * 100 : 0
    let lightFormatted = reportHoursMinutes(light)
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "Light Sleep (N1/N2)", bundle: bundle), value: "\(lightFormatted) (\(String(format: "%.0f%%", locale: LanguageManager.appLocale, lightPct)))",
        explanation: String(localized: "Stages N1 (light drowsiness) and N2 (true light sleep with sleep spindles and K-complexes). N2 sleep spindles are essential for memory consolidation and motor learning. Light sleep typically comprises 50–60% of total sleep and serves as the transition between wake, deep, and REM stages. It's not 'wasted' sleep — sleep spindles in N2 actively process and consolidate information.", bundle: bundle),
        interpretation: nil
    )
}

private func sleepTrendSummary(_ trend: PDFReportGenerator.SleepTrendData, bundle: Bundle) -> String {
    let averageMinutes = trend.averageSleepMinutes.isFinite ? Int(trend.averageSleepMinutes.rounded()) : 0
    let avgFormatted = LocalizedDuration.hoursMinutes(minutes: averageMinutes)
    let effFormatted = trend.averageEfficiency.map { String(format: "%.0f%%", locale: LanguageManager.appLocale, $0) }
    var trendStr = if let effFormatted {
        String(localized: "Average: \(avgFormatted) at \(effFormatted) efficiency. ", bundle: bundle)
    } else {
        String(localized: "Average: \(avgFormatted).", bundle: bundle) + " "
    }
    switch trend.trend {
    case .improving: trendStr += String(localized: "Trend: Improving — sleep quality is getting better.", bundle: bundle)
    case .declining: trendStr += String(localized: "Trend: Declining — sleep quality has dropped recently.", bundle: bundle)
    case .stable: trendStr += String(localized: "Trend: Stable — consistent sleep patterns.", bundle: bundle)
    case .insufficient: trendStr += String(localized: "Insufficient data for reliable trend detection.", bundle: bundle)
    }
    return trendStr
}

private func yesterdayTrimpRow(training: TrainingContext, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric {
    DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "Yesterday's TRIMP", bundle: bundle), value: String(format: "%.0f", locale: LanguageManager.appLocale, training.yesterdayTrimp),
        explanation: String(localized: "Training impulse from your most recent day of training. TRIMP combines duration and intensity (heart rate zones) into a single load metric. Values <50 are light; 50–150 moderate; 150–300 hard; >300 very hard. Recovery from yesterday's session directly influences today's HRV and readiness.", bundle: bundle),
        interpretation: training.yesterdayTrimp < 50 ? String(localized: "Light day — minimal recovery demand", bundle: bundle) :
            (
                training.yesterdayTrimp < 150 ? String(localized: "Moderate load — normal recovery expected within 24h", bundle: bundle) :
                    (
                        training.yesterdayTrimp < 300 ? String(localized: "Hard session — may take 24–48h for full HRV recovery", bundle: bundle) :
                            String(localized: "Very hard — expect 36–72h for complete parasympathetic rebound", bundle: bundle)
                    )
            )
    )
}

/// The explanation reads differently once a personal baseline exists — with
/// one it can talk about deviation, without one only about population range.
private func respiratoryRateExplanation(rr: Double, vitals: PDFReportGenerator.VitalsData, bundle: Bundle) -> String {
    var explanation = String(localized: "Overnight breathing rate from Apple Watch accelerometer. Normal adult range during sleep: 12–20 breaths/min. ", bundle: bundle)
    if let baseline = vitals.respiratoryRateBaseline {
        let diff = rr - baseline
        explanation += String(localized: "Your baseline: \(String(format: "%.1f", locale: LanguageManager.appLocale, baseline)) br/min. Current deviation: \(String(format: "%+.1f", locale: LanguageManager.appLocale, diff)) br/min. ", bundle: bundle)
        explanation += String(localized: "An increase >2 breaths/min above your personal baseline is flagged as elevated. It most often follows hard exercise, alcohol, altitude or anxiety, and sometimes comes with the start of a respiratory illness; in prospective studies most such alerts were not confirmed infections (PPV roughly 4–10%).", bundle: bundle)
    } else {
        explanation += String(localized: "Overnight respiratory rate rises with respiratory infection and has been studied as an early signal, but in prospective use most alerts built on it are not confirmed infections (PPV roughly 4–10%). Read an elevation as a prompt to watch.", bundle: bundle)
    }
    return explanation
}

private func oxygenSaturationRow(vitals: PDFReportGenerator.VitalsData, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric? {
    guard let spo2 = vitals.oxygenSaturation else { return nil }
    let average = String(format: "%.0f%%", locale: LanguageManager.appLocale, spo2)
    let label = vitals.oxygenSaturationMin.map {
        String(localized: "\(average) (min: \(String(format: "%.0f%%", locale: LanguageManager.appLocale, $0)))", bundle: bundle)
    } ?? average
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "Blood Oxygen (SpO₂)", bundle: bundle), value: label,
        explanation: String(localized: "Peripheral oxygen saturation measured by Apple Watch pulse oximetry. Normal range: 95–100%. Values 93–95% may be normal at altitude. Sustained readings below 93% at sea level fall outside the typical range and are worth discussing with a clinician. During sleep, brief dips are common; sustained low readings are worth tracking and bringing up at your next medical appointment. When SpO₂ drops below 95%, the recovery score is penalized by −10 points.", bundle: bundle),
        interpretation: spo2 < RecoveryVitals.concerningSpO2Below
            ? String(localized: "Below 95% — flat -10 score penalty applied", bundle: bundle)
            : String(localized: "Within typical range", bundle: bundle)
    )
}

/// `valueLabel` formats the deviation in the user's temperature unit, the
/// same way page 1 does. A reading with no baseline to set it against shows
/// no number: the raw value is offset from 36.5 °C, not from the user.
private func wristTemperatureRow(
    vitals: PDFReportGenerator.VitalsData, valueLabel: (Double, Int) -> String, bundle: Bundle
) -> DeepDiveReportRenderer.DeepDiveMetric? {
    let temp = vitals.wristTemperature
    guard temp != nil || vitals.wristTemperatureLacksBaseline else { return nil }
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "Wrist Temperature Deviation", bundle: bundle), value: temp.map { valueLabel($0, 2) } ?? "—",
        explanation: String(localized: "Deviation from your personal overnight wrist temperature baseline (Apple Watch Series 8+). Typical fluctuations are ±0.3°C. Increases >0.5°C are common after alcohol, a warm room or hard exercise, around ovulation (menstrual cycle), and sometimes with the start of an illness. Sustained increases >1.0°C are worth flagging, though illness is only one of several explanations. This is a deviation, not absolute temperature — it's calibrated to your personal norm, making it more sensitive than a thermometer reading. In the recovery score it is one of the inputs to the Vitals part (15%): the further it runs more than 0.3°C above your baseline, the lower that part. A cooler reading costs nothing.", bundle: bundle),
        interpretation: temp.map { wristTemperatureInterpretation($0, bundle: bundle) }
            ?? String(localized: "No baseline yet", bundle: bundle)
    )
}

/// Bands match the score: only warmth above baseline counts against it.
private func wristTemperatureInterpretation(_ temp: Double, bundle: Bundle) -> String {
    if temp > 1.0 { return String(localized: "Substantially elevated — lowers the Vitals part of your recovery score; persistent increases worth checking", bundle: bundle) }
    if temp > 0.5 { return String(localized: "Elevated — lowers the Vitals part of your recovery score; track trend", bundle: bundle) }
    if temp > 0.3 { return String(localized: "Mildly elevated — slightly lowers the Vitals part of your recovery score; track trend", bundle: bundle) }
    if temp < -0.3 { return String(localized: "Below baseline — common with cold exposure or low metabolic rate", bundle: bundle) }
    return String(localized: "Within typical fluctuation range", bundle: bundle)
}

private func restingHeartRateRow(vitals: PDFReportGenerator.VitalsData, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric? {
    guard let rhr = vitals.restingHeartRate else { return nil }
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "Resting Heart Rate", bundle: bundle), value: String(format: "%.0f bpm", locale: LanguageManager.appLocale, rhr),
        explanation: String(localized: "Lowest sustained heart rate during sleep from Apple Watch. A personal biomarker — absolute values vary widely (40–80 bpm is normal for adults). What matters is YOUR trend: an increase of >5 bpm from your baseline is common with accumulated fatigue, dehydration, stress or alcohol, and sometimes with an oncoming illness. RHR typically decreases with improved cardiovascular fitness. In the recovery score, a resting HR above your own baseline lowers the Vitals part (15%).", bundle: bundle),
        interpretation: rhr < 50 ? String(localized: "Athletic range for adults — but recovery reads this vs. your OWN recent baseline, not the absolute value", bundle: bundle) :
            (
                rhr < 60 ? String(localized: "Athletic range for adults — recovery reads this vs. your recent baseline, not the absolute value", bundle: bundle) :
                    (
                        rhr < 70 ? String(localized: "Within the 60–70 bpm range common in adults — recovery reads this vs. your recent baseline", bundle: bundle) :
                            (
                                rhr < 80 ? String(localized: "Upper-normal for adults — check whether it's elevated vs. your recent baseline", bundle: bundle) :
                                    String(localized: "High for adults — and check whether it's elevated vs. your recent baseline", bundle: bundle)
                            )
                    )
            )
    )
}
