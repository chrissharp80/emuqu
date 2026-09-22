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
            String(localized: "Sleep architecture describes how your sleep is distributed across stages throughout the night. Healthy sleep follows a predictable pattern: deep sleep (slow-wave) is concentrated in the first half of the night for physical restoration, while REM sleep increases in the second half for cognitive processing and memory consolidation.", bundle: bundle),
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
        let deepFormatted = deep >= 60 ? "\(deep / 60)h \(deep % 60)m" : "\(deep)m"
        return DeepDiveMetric(
            name: String(localized: "Deep Sleep (N3/SWS)", bundle: bundle), value: "\(deepFormatted) (\(String(format: "%.0f%%", locale: .current, deepPct)))",
            explanation: String(localized: "Slow-wave sleep (Stage N3) — the most physically restorative stage. Growth hormone secretion peaks during deep sleep, driving muscle repair, immune function, and tissue regeneration. Adults typically need 60–120 minutes (15–25% of total sleep). Deep sleep is front-loaded — most occurs in the first 3 hours. Alcohol, aging, and heavy sustained training load reduce deep sleep percentage.", bundle: bundle),
            interpretation: interpretDeepSleep(deepPct: deepPct, deepMinutes: deep)
        )
    }

    private func remSleepRow(sleep: PDFReportGenerator.SleepData, bundle: Bundle) -> DeepDiveMetric? {
        guard let rem = sleep.remSleepMinutes else { return nil }
        let remPct = sleep.totalSleepMinutes > 0 ? Double(rem) / Double(sleep.totalSleepMinutes) * 100 : 0
        let remFormatted = rem >= 60 ? "\(rem / 60)h \(rem % 60)m" : "\(rem)m"
        return DeepDiveMetric(
            name: String(localized: "REM Sleep", bundle: bundle), value: "\(remFormatted) (\(String(format: "%.0f%%", locale: .current, remPct)))",
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
            String(localized: "Average deep sleep: \(String(format: "%.0f", locale: .current, avgDeep)) minutes per night.", bundle: bundle),
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
        var y = drawSubsectionHeading(String(localized: "Performance Management Chart (PMC)", bundle: bundle), yPosition: yPosition, pageRect: pageRect)
        y = drawWrappedText(
            String(localized: "The PMC tracks the relationship between fitness (chronic training load) and fatigue (acute training load). Your body adapts to consistent training stress (fitness rises) but needs recovery from recent efforts (fatigue). Form (TSB) = Fitness - Fatigue. It is bookkeeping on your training history, not a measurement of your physiology: a positive Form usually accompanies feeling fresh, rather than predicting how you will perform.", bundle: bundle),
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
            name: String(localized: "CTL (Chronic Training Load / Fitness)", bundle: bundle), value: String(format: "%.0f", locale: .current, training.ctl),
            explanation: String(localized: "42-day exponentially weighted moving average (EWMA) of daily training impulse (TRIMP). Represents your accumulated fitness — the training your body has adapted to. Higher CTL means higher work capacity. CTL rises slowly with consistent training and decays slowly during rest. A 1-point CTL increase requires approximately 1 TSS point above your daily average, sustained daily.", bundle: bundle),
            interpretation: interpretCTL(training.ctl)
        )
    }

    private func atlRow(training: TrainingContext, bundle: Bundle) -> DeepDiveMetric {
        DeepDiveMetric(
            name: String(localized: "ATL (Acute Training Load / Fatigue)", bundle: bundle), value: String(format: "%.0f", locale: .current, training.atl),
            explanation: String(localized: "7-day EWMA of daily TRIMP. Represents recent training fatigue — the stress your body hasn't yet adapted to. ATL responds quickly to training changes: it spikes after hard efforts and drops during rest days. When ATL significantly exceeds CTL, recent load is outpacing your fitness base — a descriptive signal that an easier session or recovery day is worth considering. Emuqu does not interpret this ratio as a clinical risk score.", bundle: bundle),
            interpretation: interpretATL(training.atl, ctl: training.ctl)
        )
    }

    private func tsbRow(training: TrainingContext, bundle: Bundle) -> DeepDiveMetric {
        DeepDiveMetric(
            name: String(localized: "TSB (Training Stress Balance / Form)", bundle: bundle), value: String(format: "%+.0f", locale: .current, training.tsb),
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
                    name: "ACWR", value: String(format: "%.2f", locale: .current, acr),
                    explanation: String(localized: "ATL divided by CTL — a ratio of recent load to your longer-term fitness base. Originally framed by Gabbett (2016) as having a 0.8–1.3 \"sweet spot,\" but Impellizzeri et al. (2020/2021) demonstrated that the chronic denominator carries little real signal — random numbers in the chronic position produce nearly identical odds ratios for injury. Emuqu shows ACWR for context on this Load & Trajectory page but does not use it in the Recovery Score and does not present it as an injury predictor. Treat it as one descriptive number among several: ratio above ~1.3 means recent load is above your usual range; above ~1.5 means a sharper increase that's worth easing back from to absorb properly. Context matters more than the number itself.", bundle: bundle),
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
                    name: String(localized: "Estimated VO₂max", bundle: bundle), value: String(format: "%.1f mL/kg/min", locale: .current, vo2),
                    explanation: String(localized: "Maximum oxygen consumption — the best single predictor of cardiovascular fitness and endurance performance. Higher values indicate greater aerobic capacity. Context: VO₂max declines ~1% per year after age 30 without training. Top endurance athletes exceed 70 mL/kg/min.", bundle: bundle),
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
            wristTemperatureRow(vitals: vitals, bundle: bundle),
            restingHeartRateRow(vitals: vitals, bundle: bundle)
        ].compactMap { $0 }
    }

    private func respiratoryRateRow(vitals: PDFReportGenerator.VitalsData, bundle: Bundle) -> DeepDiveMetric? {
        guard let rr = vitals.respiratoryRate else { return nil }
        return DeepDiveMetric(
            name: String(localized: "Respiratory Rate", bundle: bundle),
            value: String(format: "%.1f breaths/min", locale: .current, rr),
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
        if diff > 2 { return String(localized: "Elevated above baseline — recovery score penalized by −5 points", bundle: bundle) }
        if diff > 1 { return String(localized: "Slightly above baseline — within normal variation", bundle: bundle) }
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

private func sleepEfficiencyRow(sleep: PDFReportGenerator.SleepData, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric {
    let effPct = sleep.sleepEfficiency
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "Sleep Efficiency", bundle: bundle), value: String(format: "%.0f%%", locale: .current, effPct),
        explanation: String(localized: "Percentage of time in bed actually spent asleep. Efficiency above 85% is considered good; above 90% is excellent. Low efficiency (<80%) may indicate insomnia, sleep fragmentation, or spending too much time in bed awake. Clinical sleep medicine considers <85% a threshold for sleep maintenance issues.", bundle: bundle),
        interpretation: effPct >= 90 ? String(localized: "Excellent efficiency — sleep is well-consolidated", bundle: bundle) :
            (
                effPct >= 85 ? String(localized: "Good — within healthy range", bundle: bundle) :
                    (
                        effPct >= 80 ? String(localized: "Fair — some fragmentation present", bundle: bundle) :
                            String(localized: "Below 80% — significant sleep disruption", bundle: bundle)
                    )
            )
    )
}

private func timeInBedRow(sleep: PDFReportGenerator.SleepData, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric {
    let inBedFormatted: String = {
        let h = sleep.inBedMinutes / 60
        let m = sleep.inBedMinutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }()
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
    let awakeFormatted = sleep.awakeMinutes >= 60
        ? "\(sleep.awakeMinutes / 60)h \(sleep.awakeMinutes % 60)m"
        : "\(sleep.awakeMinutes)m"
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
    let lightFormatted = light >= 60 ? "\(light / 60)h \(light % 60)m" : "\(light)m"
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "Light Sleep (N1/N2)", bundle: bundle), value: "\(lightFormatted) (\(String(format: "%.0f%%", locale: .current, lightPct)))",
        explanation: String(localized: "Stages N1 (light drowsiness) and N2 (true light sleep with sleep spindles and K-complexes). N2 sleep spindles are essential for memory consolidation and motor learning. Light sleep typically comprises 50–60% of total sleep and serves as the transition between wake, deep, and REM stages. It's not 'wasted' sleep — sleep spindles in N2 actively process and consolidate information.", bundle: bundle),
        interpretation: nil
    )
}

private func sleepTrendSummary(_ trend: PDFReportGenerator.SleepTrendData, bundle: Bundle) -> String {
    let avgFormatted = String(format: "%.1f hours", locale: .current, Double(trend.averageSleepMinutes) / 60.0)
    let effFormatted = String(format: "%.0f%%", locale: .current, trend.averageEfficiency)
    var trendStr = String(localized: "Average: \(avgFormatted) at \(effFormatted) efficiency. ", bundle: bundle)
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
        name: String(localized: "Yesterday's TRIMP", bundle: bundle), value: String(format: "%.0f", locale: .current, training.yesterdayTrimp),
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
        explanation += String(localized: "Your baseline: \(String(format: "%.1f", locale: .current, baseline)) br/min. Current deviation: \(String(format: "%+.1f", locale: .current, diff)) br/min. ", bundle: bundle)
        explanation += String(localized: "An increase >2 breaths/min above your personal baseline is flagged as elevated. It most often follows hard exercise, alcohol, altitude or anxiety, and sometimes comes with the start of a respiratory illness; in prospective studies most such alerts were not confirmed infections (PPV roughly 4–10%).", bundle: bundle)
    } else {
        explanation += String(localized: "Overnight respiratory rate rises with respiratory infection and has been studied as an early signal, but in prospective use most alerts built on it are not confirmed infections (PPV roughly 4–10%). Read an elevation as a prompt to watch.", bundle: bundle)
    }
    return explanation
}

private func oxygenSaturationRow(vitals: PDFReportGenerator.VitalsData, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric? {
    guard let spo2 = vitals.oxygenSaturation else { return nil }
    var label = String(format: "%.0f%%", locale: .current, spo2)
    if let minSpo2 = vitals.oxygenSaturationMin {
        label += String(format: " (min: %.0f%%)", locale: .current, minSpo2)
    }
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "Blood Oxygen (SpO₂)", bundle: bundle), value: label,
        explanation: String(localized: "Peripheral oxygen saturation measured by Apple Watch pulse oximetry. Normal range: 95–100%. Values 93–95% may be normal at altitude. Sustained readings below 93% at sea level fall outside the typical range and are worth discussing with a clinician. During sleep, brief dips are common; sustained low readings are worth tracking and bringing up at your next medical appointment. When SpO₂ drops below 95%, the recovery score is penalized by −10 points.", bundle: bundle),
        interpretation: spo2 >= 96 ? String(localized: "Within typical range", bundle: bundle) :
            (
                spo2 >= 94 ? String(localized: "Slightly below typical — track trend", bundle: bundle) :
                    String(localized: "Below 94% — recovery score penalized (−10); worth raising with a clinician if persistent", bundle: bundle)
            )
    )
}

private func wristTemperatureRow(vitals: PDFReportGenerator.VitalsData, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric? {
    guard let temp = vitals.wristTemperature else { return nil }
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "Wrist Temperature Deviation", bundle: bundle), value: String(format: "%+.2f°C", locale: .current, temp),
        explanation: String(localized: "Deviation from your personal overnight wrist temperature baseline (Apple Watch Series 8+). Typical fluctuations are ±0.3°C. Increases >0.5°C are common after alcohol, a warm room or hard exercise, around ovulation (menstrual cycle), and sometimes with the start of an illness. Sustained increases >1.0°C are worth flagging, though illness is only one of several explanations. This is a deviation, not absolute temperature — it's calibrated to your personal norm, making it more sensitive than a thermometer reading. When deviation exceeds 0.5°C, the recovery score is penalized by −5 points. Above 1.0°C, the penalty increases to −10 points.", bundle: bundle),
        interpretation: abs(temp) <= 0.3 ? String(localized: "Within typical fluctuation range", bundle: bundle) :
            (
                temp > 1.0 ? String(localized: "Substantially elevated — recovery score penalized (−10); persistent increases worth checking", bundle: bundle) :
                    (
                        temp > 0.5 ? String(localized: "Elevated — recovery score penalized (−5); track trend", bundle: bundle) :
                            (
                                temp < -0.5 ? String(localized: "Below baseline — common with cold exposure or low metabolic rate", bundle: bundle) :
                                    String(localized: "Mildly elevated — track trend", bundle: bundle)
                            )
                    )
            )
    )
}

private func restingHeartRateRow(vitals: PDFReportGenerator.VitalsData, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric? {
    guard let rhr = vitals.restingHeartRate else { return nil }
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "Resting Heart Rate", bundle: bundle), value: String(format: "%.0f bpm", locale: .current, rhr),
        explanation: String(localized: "Lowest sustained heart rate during sleep from Apple Watch. A personal biomarker — absolute values vary widely (40–80 bpm is normal for adults). What matters is YOUR trend: an increase of >5 bpm from your baseline suggests accumulated fatigue, illness onset, dehydration, or stress. RHR typically decreases with improved cardiovascular fitness. In the recovery score, RHR is factored into the HRV Tier 1 calculation via HR adjustment, not as a separate vitals penalty.", bundle: bundle),
        interpretation: rhr < 50 ? String(localized: "Athletic range for adults — but recovery reads this vs. your OWN recent baseline, not the absolute value", bundle: bundle) :
            (
                rhr < 60 ? String(localized: "Athletic range for adults — recovery reads this vs. your recent baseline, not the absolute value", bundle: bundle) :
                    (
                        rhr < 70 ? String(localized: "Normal healthy range for adults — recovery reads this vs. your recent baseline", bundle: bundle) :
                            (
                                rhr < 80 ? String(localized: "Upper-normal for adults — check whether it's elevated vs. your recent baseline", bundle: bundle) :
                                    String(localized: "High for adults — and check whether it's elevated vs. your recent baseline", bundle: bundle)
                            )
                    )
            )
    )
}
