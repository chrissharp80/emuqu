import Foundation
import PDFKit
import UIKit

// MARK: - Comprehensive Deep-Dive Report Sections

// These sections transform the PDF from a highlights summary into the most
// comprehensive recovery document possible — every metric explained in full.

extension DeepDiveReportRenderer {
    /// One row of a deep-dive metric table: what it is, what it read, what it
    /// means, and how to read this particular value.
    ///
    /// The four metric sections would otherwise each inline 5-7 identical
    /// `drawMetricWithExplanation(...)` calls. Describing a row as data and
    /// drawing it in one place is what the spec means by "side effects isolated
    /// at boundaries; the core is pure logic": the rows are pure functions with
    /// no graphics context in sight, and the drawing is a single loop.
    struct DeepDiveMetric {
        let name: String
        let value: String
        let explanation: String
        /// Optional: some rows are self-explanatory and carry no reading.
        let interpretation: String?
    }

    // MARK: - Deep HRV Analysis

    /// The HRV deep-dive page.
    ///
    /// Five independent sections, each threading the same `y` cursor down the
    /// page, so they are five functions rather than one 300-line body.
    func drawDeepHRVAnalysis(
        result: HRVAnalysisResult,
        session: HRVSession,
        recentSessions: [HRVSession],
        pageNumber: inout Int,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        var y = drawDeepDiveSectionTitle(
            String(localized: "Heart Rate Variability — Complete Analysis", bundle: LanguageManager.appBundle),
            yPosition: yPosition,
            pageRect: pageRect
        )
        y = drawTimeDomainMetrics(result: result, session: session, pageNumber: &pageNumber, yPosition: y, in: context, pageRect: pageRect)
        y = drawFrequencyDomainMetrics(result: result, pageNumber: &pageNumber, yPosition: y, in: context, pageRect: pageRect)
        y = drawNonlinearMetrics(result: result, pageNumber: &pageNumber, yPosition: y, in: context, pageRect: pageRect)
        y = drawANSMetrics(result: result, pageNumber: &pageNumber, yPosition: y, in: context, pageRect: pageRect)
        return drawBaselineContext(
            result: result, recentSessions: recentSessions,
            pageNumber: &pageNumber, yPosition: y, in: context, pageRect: pageRect
        )
    }

    private func drawTimeDomainMetrics(
        result: HRVAnalysisResult,
        session: HRVSession,
        pageNumber: inout Int,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        let td = result.timeDomain
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let bundle = LanguageManager.appBundle
        var y = ensureSpace(needed: 80, y: yPosition, pageNumber: &pageNumber, context: context, pageRect: pageRect)
        y = drawSubsectionHeading(String(localized: "Time Domain Metrics", bundle: bundle), yPosition: y, pageRect: pageRect)
        for metric in timeDomainRows(td: td, session: session, bundle: bundle) {
            y = drawMetricWithExplanation(
                metric, y: y, contentWidth: contentWidth,
                pageNumber: &pageNumber, context: context, pageRect: pageRect
            )
        }
        return y
    }

    private func drawFrequencyDomainMetrics(
        result: HRVAnalysisResult,
        pageNumber: inout Int,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        guard let fd = result.frequencyDomain else { return yPosition }
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let bundle = LanguageManager.appBundle
        var y = ensureSpace(needed: 80, y: yPosition, pageNumber: &pageNumber, context: context, pageRect: pageRect)
        y = drawSubsectionHeading(String(localized: "Frequency Domain Metrics", bundle: bundle), yPosition: y, pageRect: pageRect)
        y = drawWrappedText(
            String(localized: "Frequency domain analysis decomposes your heart rhythm into spectral bands using Fourier transform. Each band reflects different physiological control mechanisms operating at different time scales.", bundle: bundle),
            style: .explanation, y: y, contentWidth: contentWidth, pageNumber: &pageNumber, context: context, pageRect: pageRect
        )
        for metric in frequencyDomainRows(fd: fd, bundle: bundle) {
            y = drawMetricWithExplanation(
                metric, y: y, contentWidth: contentWidth,
                pageNumber: &pageNumber, context: context, pageRect: pageRect
            )
        }
        return y
    }

    private func drawNonlinearMetrics(
        result: HRVAnalysisResult,
        pageNumber: inout Int,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        let nl = result.nonlinear
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let bundle = LanguageManager.appBundle
        var y = ensureSpace(needed: 80, y: yPosition, pageNumber: &pageNumber, context: context, pageRect: pageRect)
        y = drawSubsectionHeading(String(localized: "Nonlinear Dynamics", bundle: bundle), yPosition: y, pageRect: pageRect)
        y = drawWrappedText(
            String(localized: "Nonlinear analysis describes the complexity and fractal structure of heart-rate regulation — patterns that linear metrics (RMSSD, SDNN) cannot capture. These metrics describe how regular or complex last night's beat pattern was. They add context; they are not a verdict.", bundle: bundle),
            style: .explanation, y: y, contentWidth: contentWidth, pageNumber: &pageNumber, context: context, pageRect: pageRect
        )
        for metric in nonlinearRows(nl: nl, bundle: bundle) {
            y = drawMetricWithExplanation(
                metric, y: y, contentWidth: contentWidth,
                pageNumber: &pageNumber, context: context, pageRect: pageRect
            )
        }
        return y
    }

    private func nonlinearRows(nl: NonlinearMetrics, bundle: Bundle) -> [DeepDiveMetric] {
        [
            sd1Row(nl: nl, bundle: bundle),
            sd2Row(nl: nl, bundle: bundle),
            sd1Sd2RatioRow(nl: nl, bundle: bundle),
            dfaAlpha1Row(nl: nl, bundle: bundle),
            dfaAlpha2Row(nl: nl, bundle: bundle),
            sampleEntropyRow(nl: nl, bundle: bundle),
            approxEntropyRow(nl: nl, bundle: bundle)
        ].compactMap { $0 }
    }

    private func sampleEntropyRow(nl: NonlinearMetrics, bundle: Bundle) -> DeepDiveMetric? {
        guard let se = nl.sampleEntropy else { return nil }
        return DeepDiveMetric(
            name: String(localized: "Sample Entropy", bundle: bundle), value: String(format: "%.3f", locale: .current, se),
            explanation: String(localized: "Measures unpredictability/complexity of the RR series. Higher entropy = more complex, irregular patterns. Lower entropy = more regular, template-like patterns, which often follow heavy training load, stress or short sleep. Unlike approximate entropy, sample entropy avoids self-matching bias. Typical range during sleep: 0.8–2.0.", bundle: bundle),
            interpretation: banded(se, [
                (1.0, String(localized: "Higher complexity", bundle: bundle)),
                (0.5, String(localized: "Moderate complexity", bundle: bundle))
            ], else: String(localized: "Lower — more regular than usual; compare with your own trend", bundle: bundle))
        )
    }

    private func drawANSMetrics(
        result: HRVAnalysisResult,
        pageNumber: inout Int,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        guard let ans = result.ansMetrics else { return yPosition }
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let bundle = LanguageManager.appBundle
        var y = ensureSpace(needed: 80, y: yPosition, pageNumber: &pageNumber, context: context, pageRect: pageRect)
        y = drawSubsectionHeading(String(localized: "Autonomic Nervous System Indexes", bundle: bundle), yPosition: y, pageRect: pageRect)
        for metric in ansRows(ans: ans, bundle: bundle) {
            y = drawMetricWithExplanation(
                metric, y: y, contentWidth: contentWidth,
                pageNumber: &pageNumber, context: context, pageRect: pageRect
            )
        }
        return y
    }

    private func drawBaselineContext(
        result: HRVAnalysisResult,
        recentSessions: [HRVSession],
        pageNumber: inout Int,
        yPosition: CGFloat,
        in context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        // Overnight-only — a workout's crushed RMSSD in this list
        // would drag the "last-7" trend and misrepresent the baseline.
        let recent = recentSessions.filter { $0.sessionType == .overnight }.prefix(7).compactMap(\.rmssd)
        guard recent.count >= 3 else { return yPosition + 10 }
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let bundle = LanguageManager.appBundle
        var y = ensureSpace(needed: 60, y: yPosition, pageNumber: &pageNumber, context: context, pageRect: pageRect)
        y = drawSubsectionHeading(String(localized: "Last-7-Session Trend", bundle: bundle), yPosition: y, pageRect: pageRect)
        let text = lastSevenTrendText(rmssd: result.timeDomain.rmssd, recent: Array(recent), bundle: bundle)
        y = drawWrappedText(text, style: .body, y: y, contentWidth: contentWidth, pageNumber: &pageNumber, context: context, pageRect: pageRect)
        return y + 10
    }

    // MARK: - Drawing Helpers for Deep Dive

    /// Section title for deep-dive pages (larger than subsection headings)
    func drawDeepDiveSectionTitle(_ text: String, yPosition: CGFloat, pageRect: CGRect) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16, weight: .bold),
            .foregroundColor: config.primaryColor
        ]
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        text.draw(in: CGRect(x: config.margins.left, y: yPosition, width: contentWidth, height: 22), withAttributes: attributes)

        // Underline
        let lineY = yPosition + 24
        config.primaryColor.withAlphaComponent(0.3).setStroke()
        let path = UIBezierPath()
        path.move(to: CGPoint(x: config.margins.left, y: lineY))
        path.addLine(to: CGPoint(x: config.margins.left + contentWidth, y: lineY))
        path.lineWidth = 0.5
        path.stroke()

        return lineY + 8
    }

    /// Subsection heading (smaller)
    func drawSubsectionHeading(_ text: String, yPosition: CGFloat, pageRect _: CGRect) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor.darkGray
        ]
        text.draw(at: CGPoint(x: config.margins.left, y: yPosition), withAttributes: attributes)
        return yPosition + 16
    }

    /// Text style for drawWrappedText
    enum TextStyle {
        case explanation // Gray italic context
        case body // Normal dark text
    }

    /// Draw wrapped text that auto-paginates.
    func drawWrappedText(
        _ text: String,
        style: TextStyle,
        y: CGFloat,
        contentWidth: CGFloat,
        pageNumber: inout Int,
        context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: wrappedTextAttributes(for: style))
        let boundingRect = attributed.boundingRect(
            with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let textHeight = ceil(boundingRect.height) + 4
        let currentY = ensureSpace(needed: min(textHeight, 60), y: y, pageNumber: &pageNumber, context: context, pageRect: pageRect)
        attributed.draw(in: CGRect(x: config.margins.left, y: currentY, width: contentWidth, height: textHeight))
        return currentY + textHeight + 4
    }

    /// Draw a single metric with full explanation and optional interpretation.
    func drawMetricWithExplanation(
        _ metric: DeepDiveMetric,
        y: CGFloat,
        contentWidth: CGFloat,
        pageNumber: inout Int,
        context: UIGraphicsPDFRendererContext,
        pageRect: CGRect
    ) -> CGFloat {
        let explainHeight = metricExplanationHeight(metric.explanation, contentWidth: contentWidth)
        let totalHeight = 18 + ceil(explainHeight) + (metric.interpretation != nil ? 14 : 0) + 8
        var currentY = ensureSpace(needed: min(totalHeight, 80), y: y, pageNumber: &pageNumber, context: context, pageRect: pageRect)
        currentY = drawMetricNameAndValue(name: metric.name, value: metric.value, y: currentY)
        currentY = drawMetricExplanation(metric.explanation, y: currentY, contentWidth: contentWidth, height: explainHeight)
        if let interp = metric.interpretation {
            currentY = drawMetricInterpretation(interp, y: currentY)
        }
        return currentY + 4
    }

    private func drawMetricNameAndValue(name: String, value: String, y: CGFloat) -> CGFloat {
        let nameAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: UIColor.black
        ]
        let valueAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: config.primaryColor
        ]
        name.draw(at: CGPoint(x: config.margins.left + 4, y: y), withAttributes: nameAttr)
        let nameSize = name.size(withAttributes: nameAttr)
        value.draw(at: CGPoint(x: config.margins.left + nameSize.width + 12, y: y), withAttributes: valueAttr)
        return y + 15
    }

    private func drawMetricExplanation(_ explanation: String, y: CGFloat, contentWidth: CGFloat, height: CGFloat) -> CGFloat {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = 1.0
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8.5),
            .foregroundColor: UIColor.gray,
            .paragraphStyle: paragraphStyle
        ]
        NSAttributedString(string: explanation, attributes: attrs).draw(
            in: CGRect(x: config.margins.left + 4, y: y, width: contentWidth - 8, height: ceil(height) + 4)
        )
        return y + ceil(height) + 6
    }

    private func drawMetricInterpretation(_ interp: String, y: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8.5, weight: .medium),
            .foregroundColor: interpretationColour(interp)
        ]
        "→ \(interp)".draw(at: CGPoint(x: config.margins.left + 4, y: y), withAttributes: attrs)
        return y + 14
    }

    /// Green for a good reading, red for a poor one, orange for anything the
    /// keyword lists do not claim. Keyword matching, not semantics — an
    /// interpretation string that says neither is deliberately neutral.
    private func interpretationColour(_ interp: String) -> UIColor {
        let lower = interp.lowercased()
        if lower.contains("excellent") || lower.contains("strong") || lower.contains("healthy") || lower.contains("good") || lower.contains("optimal") || lower.contains("normal") {
            return config.secondaryColor
        }
        if lower.contains("low") || lower.contains("elevated") || lower.contains("reduced") || lower.contains("impair") || lower.contains("below") {
            return config.accentColor
        }
        return UIColor.systemOrange
    }

    // MARK: - Interpretation Helpers

    func interpretDeepSleep(deepPct: Double, deepMinutes: Int) -> String {
        let bundle = LanguageManager.appBundle
        if deepPct >= 20, deepMinutes >= 60 { return String(localized: "Excellent deep sleep — strong physical restoration", bundle: bundle) }
        if deepPct >= 15, deepMinutes >= 45 { return String(localized: "Good — meeting deep sleep needs", bundle: bundle) }
        if deepPct >= 10 { return String(localized: "Moderate — could benefit from more deep sleep (avoid alcohol, screen time before bed)", bundle: bundle) }
        return String(localized: "Low deep sleep — physical recovery may be compromised", bundle: bundle)
    }

    func interpretREMSleep(remPct: Double, remMinutes: Int) -> String {
        let bundle = LanguageManager.appBundle
        if remPct >= 22, remMinutes >= 90 { return String(localized: "Excellent REM — strong cognitive restoration", bundle: bundle) }
        if remPct >= 18, remMinutes >= 60 { return String(localized: "Good — meeting REM needs", bundle: bundle) }
        if remPct >= 12 { return String(localized: "Moderate — consider extending sleep duration to capture more REM cycles", bundle: bundle) }
        return String(localized: "Low REM — skill learning and emotional processing may be impaired", bundle: bundle)
    }

    func interpretCTL(_ ctl: Double) -> String {
        // Thresholds are scaled × 0.64 to match the Banister-TRIMP
        // scaling factor in HealthWorkoutSummary.calculateTrimp. The tier
        // labels refer to the same physiological fitness bands;
        // only the unit scale differs.
        let bundle = LanguageManager.appBundle
        if ctl > 64 { return String(localized: "Very high fitness — serious endurance athlete level", bundle: bundle) }
        if ctl > 45 { return String(localized: "High training load — consistently well-trained volume", bundle: bundle) }
        if ctl > 26 { return String(localized: "Moderate fitness — consistent training", bundle: bundle) }
        if ctl > 13 { return String(localized: "Building fitness — keep consistent", bundle: bundle) }
        return String(localized: "Low fitness base — building from scratch or extended break", bundle: bundle)
    }

    func interpretATL(_ atl: Double, ctl: Double) -> String {
        // Descriptive copy, not risk-prediction.
        let bundle = LanguageManager.appBundle
        if atl > ctl * 1.5 { return String(localized: "Fatigue far exceeds fitness — recent load is heavily outpacing your base", bundle: bundle) }
        if atl > ctl * 1.3 { return String(localized: "Fatigue elevated relative to fitness — recent load is above your usual range", bundle: bundle) }
        if atl > ctl { return String(localized: "Fatigue exceeds fitness — productive training zone if temporary", bundle: bundle) }
        return String(localized: "Fatigue below fitness — you're recovering or tapering", bundle: bundle)
    }

    func interpretTSB(_ tsb: Double) -> String {
        let bundle = LanguageManager.appBundle
        if tsb > 25 { return String(localized: "Very fresh — possible detraining if sustained; ideal for race day", bundle: bundle) }
        if tsb > 5 { return String(localized: "Fresh and ready — good performance window", bundle: bundle) }
        if tsb > -10 { return String(localized: "Near neutral — balanced training/recovery", bundle: bundle) }
        if tsb > -30 { return String(localized: "Fatigued — productive overload zone if planned", bundle: bundle) }
        return String(localized: "Deeply fatigued — significant high strain, rest recommended", bundle: bundle)
    }

    func interpretACWR(_ acr: Double) -> String {
        // Neutral observational copy, not risk-prediction language
        // (Advisory/Danger zone, "injury risk"). The ACR is shown for context on the Load
        // & Trajectory surface; the recovery score itself does not
        // use it. See ScoringWeights doc-comment for rationale
        // (Impellizzeri 2020/2021).
        let bundle = LanguageManager.appBundle
        if acr >= 0.8, acr <= 1.3 { return String(localized: "Within your usual training-load range", bundle: bundle) }
        if acr < 0.8 { return String(localized: "Recent load is below your usual range — taper, rest week, or natural variation", bundle: bundle) }
        if acr <= 1.5 { return String(localized: "Recent load is above your usual range — listen to your body", bundle: bundle) }
        return String(localized: "Sharp recent increase vs your usual load — consider easing back to absorb the work", bundle: bundle)
    }

    func interpretVO2Max(_ vo2: Double) -> String {
        let bundle = LanguageManager.appBundle
        if vo2 > 60 { return String(localized: "Elite — top-tier cardiovascular fitness", bundle: bundle) }
        if vo2 > 50 { return String(localized: "Excellent — well above average", bundle: bundle) }
        if vo2 > 40 { return String(localized: "Good — above average fitness", bundle: bundle) }
        if vo2 > 30 { return String(localized: "Fair — average range", bundle: bundle) }
        // #21 — frame VO₂max as aerobic CAPACITY vs CTL's training LOAD so the
        // two labels don't read as a flat contradiction on the same report.
        return String(localized: "Aerobic capacity has room to grow — your CTL reflects training load, VO₂max your aerobic ceiling", bundle: bundle)
    }

    func assessVitalsPattern(_ vitals: PDFReportGenerator.VitalsData) -> String {
        let bundle = LanguageManager.appBundle
        let concerns = vitalsConcerns(vitals, bundle: bundle)
        if concerns.count >= 2 {
            // Not "consistent with early illness, overtraining, or
            // significant physiological stress … monitoring for symptoms". That is
            // screening language in a document the user hands to someone else, and
            // it trips the copy perimeter on `overtrain(ing)`.
            //
            // Editing this English literal without re-translating silently
            // de-localises it: the key no longer matches any catalogue entry and
            // all 16 locales fall back to English.
            // `scripts/check_localization_resolution.sh` fails the build if a
            // literal drifts from its key.
            return String(localized: "Multiple vitals are above your usual range (\(concerns.joined(separator: ", "))). Vitals often move a day or two ahead of HRV, which is why they carry their own 15% weight in your composite score. A shift like this most often follows a hard session, a short night, heat, alcohol, or travel, and usually settles within a night or two.", bundle: bundle)
        }
        if concerns.count == 1 {
            return String(localized: "One vital is flagged (\(concerns[0])). Isolated elevation may be noise or a transient response, but if it persists for 2+ nights, it warrants attention. The recovery score applies a small penalty to reflect this uncertainty.", bundle: bundle)
        }
        return String(localized: "All vitals are within normal ranges. No recovery score penalties applied from vitals.", bundle: bundle)
    }

}

// MARK: - Banded interpretation
//
// The interpretation strings below were written as nested ternaries — three or
// four levels deep, each wrapping the next in parentheses, so the reader had to
// unwind them right-to-left to find which band a value lands in. `banded` states
// the bands in order, top to bottom, which is the order they are reasoned about.

private func banded(_ value: Double, _ cases: [(Double, String)], else fallback: String) -> String {
    for (threshold, text) in cases where value > threshold {
        return text
    }
    return fallback
}

private func bandedAscending(_ value: Double, _ cases: [(Double, String)], else fallback: String) -> String {
    for (threshold, text) in cases where value < threshold {
        return text
    }
    return fallback
}

// MARK: - File-scope helpers
//
// Kept out of the type. Each touches no instance state —
// including the computed properties — and
// calls nothing that stayed behind, so none was a method in anything but
// placement. `private` at file scope is fileprivate, so every call site in
// this file resolves exactly as before.
//
// This is what `check_aggregate_type_size.sh` measures: a type is the sum of
// its parts across every file, so code that does not need the type inflates
// that number without making the type do more.

private func timeDomainRows(td: TimeDomainMetrics, session: HRVSession, bundle: Bundle) -> [DeepDiveReportRenderer.DeepDiveMetric] {
    [
        rmssdRow(td: td, session: session, bundle: bundle),
        sdnnRow(td: td, session: session, bundle: bundle),
        meanRRRow(td: td, session: session, bundle: bundle),
        pnn50Row(td: td, session: session, bundle: bundle),
        sdsdRow(td: td, session: session, bundle: bundle),
        triangularIndexRow(td: td, session: session, bundle: bundle)
    ].compactMap { $0 }
}

private func rmssdRow(td: TimeDomainMetrics, session: HRVSession, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric {
    // #6 — a HealthKit summary import has no raw RR / no 5-min window.
    let hasRawRR = !(session.rrSeries?.points.isEmpty ?? true)
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: "RMSSD", value: String(format: "%.1f ms", locale: .current, td.rmssd),
        explanation: hasRawRR
            ? String(localized: "Root mean square of successive RR differences — the most widely used time-domain measure of beat-to-beat (vagal) variation. Read it against your own baseline rather than other people's. Your reading reflects the 5-minute analysis window selected for optimal data quality.", bundle: bundle)
            : String(localized: "Root mean square of successive RR differences — the most widely used time-domain measure of beat-to-beat (vagal) variation. Read it against your own baseline rather than other people's. This reading was imported as a summary value; the underlying beat-to-beat intervals aren't available for windowed re-analysis.", bundle: bundle),
        interpretation: interpretRMSSD(td.rmssd, session: session)
    )
}

private func sdnnRow(td: TimeDomainMetrics, session: HRVSession, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric {
    DeepDiveReportRenderer.DeepDiveMetric(
        name: "SDNN", value: String(format: "%.1f ms", locale: .current, td.sdnn),
        explanation: String(localized: "Standard deviation of all normal-to-normal intervals — total HRV power reflecting both sympathetic and parasympathetic contributions. In short recordings (<5 min), SDNN primarily reflects parasympathetic modulation. In 24-hour recordings, it also captures circadian and thermoregulatory rhythms.", bundle: bundle),
        interpretation: interpretSDNN(td.sdnn)
    )
}

private func meanRRRow(td: TimeDomainMetrics, session: HRVSession, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric {
    DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "Mean RR / Mean HR", bundle: bundle), value: String(format: "%.1f ms / %.0f bpm", locale: .current, td.meanRR, td.meanHR),
        explanation: String(localized: "Average interval between heartbeats and corresponding heart rate during the analysis window. Lower resting HR generally indicates better cardiovascular fitness and parasympathetic dominance, though individual baselines vary significantly.", bundle: bundle),
        interpretation: interpretMeanHR(td.meanHR)
    )
}

private func pnn50Row(td: TimeDomainMetrics, session: HRVSession, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric {
    DeepDiveReportRenderer.DeepDiveMetric(
        name: "pNN50", value: String(format: "%.1f%%", locale: .current, td.pnn50),
        explanation: String(localized: "Percentage of successive RR intervals differing by more than 50ms — a simple parasympathetic marker that correlates strongly with RMSSD. Values above 20% suggest strong vagal tone; below 5% suggest reduced beat-to-beat variability, often seen with heavy training load, poor sleep, or stress.", bundle: bundle),
        interpretation: interpretPNN50(td.pnn50)
    )
}

private func sdsdRow(td: TimeDomainMetrics, session: HRVSession, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric {
    DeepDiveReportRenderer.DeepDiveMetric(
        name: "SDSD", value: String(format: "%.1f ms", locale: .current, td.sdsd),
        explanation: String(localized: "Standard deviation of successive differences — mathematically related to RMSSD (SDSD² ≈ RMSSD²). Included for completeness. It captures beat-to-beat variability driven by vagal modulation of the sinoatrial node.", bundle: bundle),
        interpretation: nil
    )
}

private func triangularIndexRow(td: TimeDomainMetrics, session: HRVSession, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric? {
    guard let tri = td.triangularIndex else { return nil }
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "HRV Triangular Index", bundle: bundle), value: String(format: "%.1f", locale: .current, tri),
        explanation: String(localized: "Geometrical measure: total number of NN intervals divided by the height of the NN interval histogram. Less sensitive to ectopic beats than RMSSD/SDNN because it uses the distribution shape rather than individual intervals. Values above 20 are common in adults at rest.", bundle: bundle),
        interpretation: banded(tri, [
            (20, String(localized: "Above 20", bundle: bundle)),
            (10, String(localized: "Moderate — some variability present", bundle: bundle))
        ], else: String(localized: "Below 10 — lower than typical; compare with your own trend", bundle: bundle))
    )
}

private func frequencyDomainRows(fd: FrequencyDomainMetrics, bundle: Bundle) -> [DeepDiveReportRenderer.DeepDiveMetric] {
    [
        vlfRow(fd: fd, bundle: bundle),
        lfRow(fd: fd, bundle: bundle),
        hfRow(fd: fd, bundle: bundle),
        lfHfRatioRow(fd: fd, bundle: bundle),
        totalPowerRow(fd: fd, bundle: bundle),
        normalizedUnitsRow(fd: fd, bundle: bundle)
    ].compactMap { $0 }
}

private func vlfRow(fd: FrequencyDomainMetrics, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric? {
    guard let vlf = fd.vlf else { return nil }
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "VLF (Very Low Frequency)", bundle: bundle), value: String(format: "%.0f ms²", locale: .current, vlf),
        explanation: String(localized: "0.003–0.04 Hz band. Reflects thermoregulatory, hormonal, and renin-angiotensin system activity. In overnight recordings, it captures slow oscillations in autonomic outflow.", bundle: bundle),
        interpretation: banded(vlf, [
            (500, String(localized: "Above 500 ms²", bundle: bundle)),
            (100, String(localized: "Moderate VLF", bundle: bundle))
        ], else: String(localized: "Low VLF — read it against your own recent nights", bundle: bundle))
    )
}

private func lfRow(fd: FrequencyDomainMetrics, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric {
    DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "LF (Low Frequency)", bundle: bundle), value: String(format: "%.0f ms²", locale: .current, fd.lf),
        explanation: String(localized: "0.04–0.15 Hz band. Reflects a mix of sympathetic and parasympathetic activity, modulated by the baroreflex. Often misinterpreted as 'sympathetic only' — it actually requires intact vagal pathways. Low LF can indicate either relaxation OR sympathetic withdrawal.", bundle: bundle),
        interpretation: nil
    )
}

private func hfRow(fd: FrequencyDomainMetrics, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric {
    DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "HF (High Frequency)", bundle: bundle), value: String(format: "%.0f ms²", locale: .current, fd.hf),
        explanation: String(localized: "0.15–0.40 Hz band. Driven almost entirely by parasympathetic (vagal) activity at the respiratory frequency. This is the frequency-domain equivalent of RMSSD. Tracks respiratory sinus arrhythmia — the natural HR acceleration during inhalation and deceleration during exhalation.", bundle: bundle),
        interpretation: banded(fd.hf, [
            (300, String(localized: "Strong HF power — robust parasympathetic activity", bundle: bundle)),
            (100, String(localized: "Moderate parasympathetic activity", bundle: bundle))
        ], else: String(localized: "Low HF — reduced vagal modulation", bundle: bundle))
    )
}

private func lfHfRatioRow(fd: FrequencyDomainMetrics, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric? {
    guard let ratio = fd.lfHfRatio else { return nil }
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "LF/HF Ratio", bundle: bundle), value: String(format: "%.2f", locale: .current, ratio),
        explanation: String(localized: "Traditionally interpreted as 'sympathovagal balance' but this model is oversimplified (Billman 2013). During sleep, low ratios (<1.0) are expected as parasympathetic activity dominates. Very high ratios (>4.0) during rest may indicate sympathetic activation from stress, dehydration, or incomplete recovery. Best interpreted alongside absolute power values.", bundle: bundle),
        interpretation: bandedAscending(ratio, [
            (1.0, String(localized: "Parasympathetic-dominant — expected during quality sleep", bundle: bundle)),
            (2.5, String(localized: "Balanced — normal range", bundle: bundle))
        ], else: String(localized: "Sympathetic-leaning — may indicate stress or incomplete recovery", bundle: bundle))
    )
}

private func totalPowerRow(fd: FrequencyDomainMetrics, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric {
    DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "Total Power", bundle: bundle), value: String(format: "%.0f ms²", locale: .current, fd.totalPower),
        // #11 — VLF needs a 10+ min window; on shorter windows it's
        // gated out and Total = LF + HF. Don't claim VLF is included.
        explanation: fd.vlf != nil
            ? String(localized: "Sum of VLF + LF + HF. Represents overall autonomic modulation of heart rate. Higher total power generally indicates a more adaptable cardiovascular system. Declines with age and is reduced by chronic stress, heavy sustained training load, and illness.", bundle: bundle)
            : String(localized: "Sum of LF + HF. Represents overall autonomic modulation of heart rate. VLF requires a 10+ minute window to estimate reliably, so it is excluded from this shorter analysis. Higher total power generally indicates a more adaptable cardiovascular system.", bundle: bundle),
        interpretation: banded(fd.totalPower, [
            (2000, String(localized: "Strong total power — robust autonomic regulation", bundle: bundle)),
            (500, String(localized: "Moderate overall variability", bundle: bundle))
        ], else: String(localized: "Low total power — reduced autonomic modulation", bundle: bundle))
    )
}

private func normalizedUnitsRow(fd: FrequencyDomainMetrics, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric? {
    guard let lfNu = fd.lfNu, let hfNu = fd.hfNu else { return nil }
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "Normalized Units", bundle: bundle), value: String(format: "LF: %.1f%% / HF: %.1f%%", locale: .current, lfNu, hfNu),
        explanation: String(localized: "LF and HF expressed as percentages of LF+HF (excluding VLF). Normalized units remove the influence of total power, making it easier to compare autonomic balance across individuals and time points. During sleep, HF n.u. typically exceeds 50%.", bundle: bundle),
        interpretation: hfNu > 50 ? String(localized: "HF-dominant — parasympathetic tone strong during this recording", bundle: bundle) : String(localized: "LF-dominant — some sympathetic co-activation present", bundle: bundle)
    )
}

private func sd1Row(nl: NonlinearMetrics, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric {
    DeepDiveReportRenderer.DeepDiveMetric(
        name: "SD1 (Poincaré)", value: String(format: "%.1f ms", locale: .current, nl.sd1),
        explanation: String(localized: "Short-term beat-to-beat variability from the Poincaré plot. Mathematically equivalent to RMSSD/√2 — it's a geometric view of parasympathetic activity. The Poincaré plot graphs each RR interval against the previous one; SD1 is the width of the scatter perpendicular to the identity line.", bundle: bundle),
        interpretation: nil
    )
}

private func sd2Row(nl: NonlinearMetrics, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric {
    DeepDiveReportRenderer.DeepDiveMetric(
        name: "SD2 (Poincaré)", value: String(format: "%.1f ms", locale: .current, nl.sd2),
        explanation: String(localized: "Long-term variability along the identity line. Reflects both sympathetic and parasympathetic modulation, including baroreflex and breathing patterns. A larger SD2 relative to SD1 suggests strong slow oscillations (LF activity).", bundle: bundle),
        interpretation: nil
    )
}

private func sd1Sd2RatioRow(nl: NonlinearMetrics, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric {
    DeepDiveReportRenderer.DeepDiveMetric(
        name: "SD1/SD2 Ratio", value: String(format: "%.3f", locale: .current, nl.sd1Sd2Ratio),
        explanation: String(localized: "The balance between short-term and long-term variability. Higher ratios mean more beat-to-beat variation relative to slow trends. During sleep, ratios of 0.3–0.6 are typical.", bundle: bundle),
        interpretation: nl.sd1Sd2Ratio > 0.3 ? String(localized: "0.3 or higher", bundle: bundle) : String(localized: "Below 0.3 — lower than typical during sleep", bundle: bundle)
    )
}

private func dfaAlpha1Row(nl: NonlinearMetrics, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric? {
    guard let a1 = nl.dfaAlpha1 else { return nil }
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: "DFA α1 (Detrended Fluctuation Analysis)", value: String(format: "%.3f", locale: .current, a1),
        explanation: String(localized: "Fractal scaling exponent for short-term correlations (4–16 beats). Measures how predictable the beat-to-beat pattern is. Values near 0.75–1.0 are the app's reference range at rest; readings above or below it are described relative to that range, not as a recovery state. Lower values are common in deep sleep.", bundle: bundle),
        interpretation: interpretDFAAlpha1(a1)
    )
}

private func dfaAlpha2Row(nl: NonlinearMetrics, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric? {
    guard let a2 = nl.dfaAlpha2 else { return nil }
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: "DFA α2", value: String(format: "%.3f", locale: .current, a2),
        explanation: String(localized: "Long-term fractal scaling (16–64 beats). Captures slower regulatory patterns including thermoregulation and hormonal cycles. Less frequently used in recovery monitoring but provides context for overall autonomic complexity. Healthy range: 0.85–1.15.", bundle: bundle),
        interpretation: nil
    )
}

private func approxEntropyRow(nl: NonlinearMetrics, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric? {
    guard let ae = nl.approxEntropy else { return nil }
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "Approximate Entropy", bundle: bundle), value: String(format: "%.3f", locale: .current, ae),
        explanation: String(localized: "Older entropy measure (Pincus 1991) — quantifies regularity in the RR time series. Similar interpretation to sample entropy but with known biases toward lower values in short datasets. Included for comparison with older literature. Healthy values typically >0.8.", bundle: bundle),
        interpretation: nil
    )
}

private func ansRows(ans: ANSMetrics, bundle: Bundle) -> [DeepDiveReportRenderer.DeepDiveMetric] {
    [
        stressIndexRow(ans: ans, bundle: bundle),
        pnsIndexRow(ans: ans, bundle: bundle),
        snsIndexRow(ans: ans, bundle: bundle),
        readinessRow(ans: ans, bundle: bundle),
        respirationRateRow(ans: ans, bundle: bundle)
    ].compactMap { $0 }
}

private func stressIndexRow(ans: ANSMetrics, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric? {
    guard let si = ans.stressIndex else { return nil }
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "Stress Index (Baevsky)", bundle: bundle), value: String(format: "%.1f", locale: .current, si),
        explanation: String(localized: "Derived from the geometric properties of the RR interval histogram (Baevsky 1984). Reflects sympathetic activation and cardiovascular stress. Originally developed for space medicine. Values <100 suggest relaxation; 100–200 is normal daily range; >300 indicates significant sympathetic activation.", bundle: bundle),
        interpretation: bandedAscending(si, [
            (100, String(localized: "Low stress — parasympathetic-dominant state", bundle: bundle)),
            (200, String(localized: "Normal range", bundle: bundle)),
            (300, String(localized: "Elevated — sympathetic activation present", bundle: bundle))
        ], else: String(localized: "High stress index — significant sympathetic drive", bundle: bundle))
    )
}

private func pnsIndexRow(ans: ANSMetrics, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric? {
    guard let pns = ans.pnsIndex else { return nil }
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: "PNS Index", value: String(format: "%+.2f", locale: .current, pns),
        explanation: String(localized: "Parasympathetic Nervous System index (Kubios) — composite of Mean RR, RMSSD, and SD1 compared to age-matched population norms. Zero is the population average. Positive values indicate above-average parasympathetic activity; negative values indicate below-average. Values >+1.0 suggest excellent vagal tone.", bundle: bundle),
        interpretation: banded(pns, [
            (1.0, String(localized: "Excellent — well above average parasympathetic activity", bundle: bundle)),
            (0, String(localized: "Above average", bundle: bundle)),
            (-1.0, String(localized: "Below average — vagal tone could be stronger", bundle: bundle))
        ], else: String(localized: "Low — parasympathetic activity significantly reduced", bundle: bundle))
    )
}

private func snsIndexRow(ans: ANSMetrics, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric? {
    guard let sns = ans.snsIndex else { return nil }
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: "SNS Index", value: String(format: "%+.2f", locale: .current, sns),
        explanation: String(localized: "Sympathetic Nervous System index (Kubios) — composite of Mean HR, Stress Index, and SD2 compared to age norms. Zero is population average. During sleep, values should be negative (low sympathetic). Positive values during rest suggest incomplete sympathetic withdrawal — possibly from caffeine, alcohol, or training stress.", bundle: bundle),
        interpretation: bandedAscending(sns, [
            (-1.0, String(localized: "Very low sympathetic — deep recovery state", bundle: bundle)),
            (0, String(localized: "Low sympathetic — expected during rest", bundle: bundle)),
            (1.0, String(localized: "Moderately elevated — some sympathetic tone", bundle: bundle))
        ], else: String(localized: "Elevated — sympathetic activation present during rest", bundle: bundle))
    )
}

private func readinessRow(ans: ANSMetrics, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric? {
    guard let readiness = ans.readinessScore else { return nil }
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "HRV Readiness", bundle: bundle), value: String(format: "%.1f / 10", locale: .current, readiness),
        explanation: String(localized: "Composite readiness score derived from HRV metrics relative to your personal baseline. Accounts for RMSSD z-score, resting HR, DFA α1, and autonomic balance. Above 7.0 suggests you can train hard; 4.5–7.0 is moderate; below 4.5 suggests prioritizing recovery.", bundle: bundle),
        interpretation: readiness >= 7.0 ? String(
            localized: "High readiness — strong underlying capacity. This reads capacity, not today's recovery; check your Recovery score before going hard.",
            bundle: bundle
        ) : (readiness >= 4.5 ? String(localized: "Moderate readiness — listen to your body", bundle: bundle) : String(localized: "Low readiness — prioritize recovery today", bundle: bundle))
    )
}

private func respirationRateRow(ans: ANSMetrics, bundle: Bundle) -> DeepDiveReportRenderer.DeepDiveMetric? {
    guard let resp = ans.respirationRate else { return nil }
    return DeepDiveReportRenderer.DeepDiveMetric(
        name: String(localized: "HRV-Derived Respiration Rate", bundle: bundle), value: String(format: "%.1f breaths/min", locale: .current, resp),
        explanation: String(localized: "Respiration rate estimated from the HF peak frequency (respiratory sinus arrhythmia). During sleep, 12–16 breaths/min is typical. Rates below 10 during deep relaxation are normal. Elevated rates (>18) during rest are unusual and typically reflect arousal, illness, or physical exertion within the last few minutes — context-sensitive.", bundle: bundle),
        interpretation: bandedAscending(resp, [
            (16, String(localized: "Normal range for rest/sleep", bundle: bundle)),
            (20, String(localized: "Slightly elevated", bundle: bundle))
        ], else: String(localized: "Elevated — context-sensitive; check for arousal, recent activity, or illness", bundle: bundle))
    )
}

private func lastSevenTrendText(rmssd: Double, recent: [Double], bundle: Bundle) -> String {
    let avg = recent.reduce(0, +) / Double(recent.count)
    let diff = rmssd - avg
    let trendVerdict = diff > 5 ? String(localized: "This is a positive deviation — recovery is trending up.", bundle: bundle) :
        (
            diff < -5 ? String(localized: "This is a negative deviation — recovery may be under pressure.", bundle: bundle) :
                String(localized: "This is within your recent range.", bundle: bundle)
        )
    // #2 — labelled a SHORT-WINDOW trend, not "your average"/"baseline":
    // the recovery score's baseline is the 60-day geometric ln(RMSSD)
    // mean on the score page. This 7-session arithmetic mean must not
    // read as if it were the score baseline (it competed before).
    let trendText = String(
        localized: "Your RMSSD today (\(String(format: "%.1f", locale: .current, rmssd)) ms) is \(String(format: "%+.1f", locale: .current, diff)) ms relative to your last \(recent.count) sessions (\(String(format: "%.1f", locale: .current, avg)) ms). This short-window trend is separate from the 60-day baseline your recovery score uses. \(trendVerdict)",
        bundle: bundle
    )
    return trendText
}

private func wrappedTextAttributes(for style: DeepDiveReportRenderer.TextStyle) -> [NSAttributedString.Key: Any] {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineBreakMode = .byWordWrapping
    paragraphStyle.lineSpacing = 1.5
    switch style {
    case .explanation:
        return [.font: UIFont.systemFont(ofSize: 8.5), .foregroundColor: UIColor.gray, .paragraphStyle: paragraphStyle]
    case .body:
        return [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.darkGray, .paragraphStyle: paragraphStyle]
    }
}

/// Height the explanation will occupy once wrapped — needed before drawing
/// so the page-break decision can be made first.
private func metricExplanationHeight(_ explanation: String, contentWidth: CGFloat) -> CGFloat {
    NSAttributedString(string: explanation, attributes: [
        .font: UIFont.systemFont(ofSize: 8.5),
        .foregroundColor: UIColor.gray
    ]).boundingRect(
        with: CGSize(width: contentWidth - 20, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        context: nil
    ).height
}

private func interpretRMSSD(_ rmssd: Double, session _: HRVSession) -> String {
    let bundle = LanguageManager.appBundle
    if rmssd > 80 { return String(localized: "Above 80 ms", bundle: bundle) }
    if rmssd > 50 { return String(localized: "50–80 ms", bundle: bundle) }
    if rmssd > 30 { return String(localized: "30–50 ms", bundle: bundle) }
    if rmssd > 15 { return String(localized: "15–30 ms", bundle: bundle) }
    return String(localized: "Below 15 ms", bundle: bundle)
}

private func interpretSDNN(_ sdnn: Double) -> String {
    let bundle = LanguageManager.appBundle
    if sdnn > 100 { return String(localized: "Above 100 ms", bundle: bundle) }
    if sdnn > 60 { return String(localized: "60–100 ms", bundle: bundle) }
    if sdnn > 30 { return String(localized: "30–60 ms", bundle: bundle) }
    return String(localized: "Below 30 ms", bundle: bundle)
}

private func interpretMeanHR(_ hr: Double) -> String {
    let bundle = LanguageManager.appBundle
    if hr < 50 { return String(localized: "Below 50 bpm", bundle: bundle) }
    if hr < 60 { return String(localized: "50–60 bpm", bundle: bundle) }
    if hr < 70 { return String(localized: "60–70 bpm", bundle: bundle) }
    return String(localized: "Above 70 bpm during sleep — elevated relative to typical sleep values", bundle: bundle)
}

private func interpretPNN50(_ pnn50: Double) -> String {
    let bundle = LanguageManager.appBundle
    if pnn50 > 30 { return String(localized: "Above 30%", bundle: bundle) }
    if pnn50 > 15 { return String(localized: "15–30%", bundle: bundle) }
    if pnn50 > 5 { return String(localized: "5–15%", bundle: bundle) }
    return String(localized: "Below 5%", bundle: bundle)
}

private func interpretDFAAlpha1(_ a1: Double) -> String {
    let bundle = LanguageManager.appBundle
    if a1 < 0.65 { return String(localized: "Below 0.65 — below the reference range (common in deep sleep)", bundle: bundle) }
    if a1 < 0.85 { return String(localized: "0.65–0.85 — around the lower edge of the reference range", bundle: bundle) }
    if a1 < 1.05 { return String(localized: "0.85–1.05 — within the reference range", bundle: bundle) }
    if a1 < 1.2 { return String(localized: "1.05–1.2 — slightly above the reference range", bundle: bundle) }
    return String(localized: "Above 1.2 — above the reference range", bundle: bundle)
}

/// Which vitals sit outside their band, named the way the summary reads them.
private func vitalsConcerns(_ vitals: PDFReportGenerator.VitalsData, bundle: Bundle) -> [String] {
    var concerns: [String] = []
    // #5 — mirror the actual sub-scoring band (abs deviation), so a
    // cold-side temp (−0.9°C → Temp sub-score 50) or an off-band RR counts
    // as a concern. A one-sided `> 0.5` / `> baseline+2` only catches ELEVATED
    // deviations, so the summary falsely says "no penalties" while the vitals
    // sub-score is 64.
    if let rr = vitals.respiratoryRate, let baseline = vitals.respiratoryRateBaseline,
       abs(rr - baseline) > ScoringWeights.Vitals.respiratoryRateBandBreathsPerMin {
        concerns.append(String(localized: "respiratory rate outside your baseline band", bundle: bundle))
    }
    if let temp = vitals.wristTemperature,
       abs(temp) > ScoringWeights.Vitals.temperatureBandNormalCelsius {
        concerns.append(String(localized: "wrist temperature outside your normal band", bundle: bundle))
    }
    if let spo2 = vitals.oxygenSaturation, spo2 < 95 {
        concerns.append(String(localized: "low blood oxygen", bundle: bundle))
    }
    return concerns
}
