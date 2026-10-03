import Foundation
import PDFKit
import UIKit

// MARK: - Sleep, Vitals, Overnight, Tags & Analysis Summary Sections

extension PDFReportGenerator {
    // MARK: - Sleep Analysis Section

    func drawSleepAnalysisSection(sleep: SleepData, yPosition: CGFloat, in _: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let y = drawSectionHeading(String(localized: "Sleep Analysis", bundle: LanguageManager.appBundle), yPosition: yPosition, pageRect: pageRect)

        let hasStages = sleep.deepSleepMinutes != nil || sleep.remSleepMinutes != nil
        let cardHeight: CGFloat = hasStages ? 100 : 56
        let cardRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: cardHeight)
        UIColor(white: 0.97, alpha: 1.0).setFill()
        UIBezierPath(roundedRect: cardRect, cornerRadius: 8).fill()

        let boxWidth = contentWidth / 4
        drawStatBoxRow(sleepSummaryBoxes(sleep), y: y + 8, boxWidth: boxWidth)
        if hasStages {
            drawStatBoxRow(sleepStageBoxes(sleep), y: y + 52, boxWidth: boxWidth)
        }
        return y + cardHeight + 10
    }

    /// Total, efficiency, awake and in-bed.
    private func sleepSummaryBoxes(_ sleep: SleepData) -> [(String, String, UIColor)] {
        // #10 — round (not printf-round vs the generator's floor) so page 1
        // and "What This Means" agree on efficiency.
        let efficiencyStr = "\(Int(sleep.sleepEfficiency.rounded()))%"
        let awakeStr = sleep.awakeMinutes > 0 ? reportHoursMinutes(sleep.awakeMinutes) : reportMissingValue
        let inBedStr = reportHoursMinutes(sleep.inBedMinutes)
        let row1: [(String, String, UIColor)] = [
            (String(localized: "Total Sleep", bundle: LanguageManager.appBundle), sleep.totalSleepFormatted, config.primaryColor),
            (String(localized: "Efficiency", bundle: LanguageManager.appBundle), efficiencyStr, sleep.sleepEfficiency >= 85 ? UIColor(red: 0.3, green: 0.6, blue: 0.4, alpha: 1) : UIColor(red: 0.8, green: 0.5, blue: 0.3, alpha: 1)),
            (String(localized: "Awake", bundle: LanguageManager.appBundle), awakeStr, UIColor.darkGray),
            (String(localized: "In Bed", bundle: LanguageManager.appBundle), inBedStr, UIColor.darkGray)
        ]
        return row1
    }

    /// One row of evenly-spaced compact stat boxes. Empty titles are spacers.
    private func drawStatBoxRow(_ items: [(String, String, UIColor)], y: CGFloat, boxWidth: CGFloat) {
        for (i, stat) in items.enumerated() where !stat.0.isEmpty {
            let boxX = config.margins.left + CGFloat(i) * boxWidth
            drawCompactStatBox(
                title: stat.0,
                value: stat.1,
                color: stat.2,
                rect: CGRect(x: boxX + 4, y: y, width: boxWidth - 8, height: 36)
            )
        }
    }

    // MARK: - Training Load Section

    func drawTrainingLoadSection(training: TrainingContext, yPosition: CGFloat, in _: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let y = drawSectionHeading(String(localized: "Training Load", bundle: LanguageManager.appBundle), yPosition: yPosition, pageRect: pageRect)

        let cardHeight: CGFloat = 56
        let cardRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: cardHeight)
        UIColor(white: 0.97, alpha: 1.0).setFill()
        UIBezierPath(roundedRect: cardRect, cornerRadius: 8).fill()

        drawStatBoxRow(trainingLoadBoxes(training), y: y + 8, boxWidth: contentWidth / 4)
        return y + cardHeight + 10
    }

    /// CTL / ATL / TSB / ACWR, with TSB coloured by Friel's productive range.
    private func trainingLoadBoxes(_ training: TrainingContext) -> [(String, String, UIColor)] {
        let tsbColor: UIColor = {
            if training.tsb > 10 { return UIColor(red: 0.3, green: 0.6, blue: 0.4, alpha: 1) }
            if training.tsb > -10 { return UIColor.darkGray }
            return UIColor(red: 0.8, green: 0.5, blue: 0.3, alpha: 1)
        }()

        let acwrStr: String = {
            guard let acr = training.acuteChronicRatio else { return reportMissingValue }
            return String(format: "%.2f", locale: .current, acr)
        }()

        let row: [(String, String, UIColor)] = [
            (String(localized: "Fitness (CTL)", bundle: LanguageManager.appBundle), String(format: "%.0f", locale: .current, training.ctl), config.primaryColor),
            (String(localized: "Fatigue (ATL)", bundle: LanguageManager.appBundle), String(format: "%.0f", locale: .current, training.atl), UIColor(red: 0.8, green: 0.5, blue: 0.3, alpha: 1)),
            (String(localized: "Form (TSB)", bundle: LanguageManager.appBundle), String(format: "%.0f", locale: .current, training.tsb), tsbColor),
            ("ACWR", acwrStr, UIColor.darkGray)
        ]
        return row
    }

    // MARK: - Recovery Vitals Section

    func drawVitalsSection(vitals: VitalsData, yPosition: CGFloat, in _: UIGraphicsPDFRendererContext, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let y = drawSectionHeading(String(localized: "Recovery Vitals", bundle: LanguageManager.appBundle), yPosition: yPosition, pageRect: pageRect)

        let items = vitalsBoxes(vitals)
        guard !items.isEmpty else { return y }

        let cardHeight: CGFloat = 56
        let cardRect = CGRect(x: config.margins.left, y: y, width: contentWidth, height: cardHeight)
        UIColor(white: 0.97, alpha: 1.0).setFill()
        UIBezierPath(roundedRect: cardRect, cornerRadius: 8).fill()

        drawStatBoxRow(items, y: y + 8, boxWidth: contentWidth / CGFloat(items.count))
        return y + cardHeight + 10
    }

    /// Only the vitals the night actually recorded.
    private func vitalsBoxes(_ vitals: VitalsData) -> [(String, String, UIColor)] {
        var items: [(String, String, UIColor)] = []
        if let box = respiratoryRateBox(vitals) { items.append(box) }
        if let box = oxygenSaturationBox(vitals) { items.append(box) }
        if let box = wristTemperatureBox(vitals) { items.append(box) }
        if let box = restingHeartRateBox(vitals) { items.append(box) }
        return items
    }

    /// A wrist-temperature DEVIATION in the user's unit: °F converts with
    /// ×9/5 and no +32 offset, because it is a difference, not a reading.
    func wristTemperatureDeviationLabel(_ celsiusDelta: Double, fractionDigits: Int) -> String {
        let fahrenheit = settingsProvider().temperatureUnit == .fahrenheit
        let value = fahrenheit ? celsiusDelta * 9 / 5 : celsiusDelta
        return String(format: "%+.\(fractionDigits)f\(fahrenheit ? "°F" : "°C")", locale: .current, value)
    }

    private func wristTemperatureBox(_ vitals: VitalsData) -> (String, String, UIColor)? {
        let title = String(localized: "Wrist Temp", bundle: LanguageManager.appBundle)
        if vitals.wristTemperatureLacksBaseline { return (title, "—", .darkGray) }
        guard let temp = vitals.wristTemperature else { return nil }
        // Honor the user's temperature unit (default is °F); a hardcoded
        // °C PDF disagrees with the in-app view.
        // Wrist temp is a DELTA from baseline, so convert with ×9/5 and
        // no +32 offset (matches SleepDetailV2View). The color threshold
        // stays on the raw °C delta — it's physiological, not display.
        let label = wristTemperatureDeviationLabel(temp, fractionDigits: 1)
        let color: UIColor = abs(temp) > 0.5 ? UIColor(red: 0.8, green: 0.5, blue: 0.3, alpha: 1) : .darkGray
        return (title, label, color)
    }

}

// MARK: - File-scope helpers
//
// Kept out of the type. Each touches no instance state —
// including the computed properties — and
// calls nothing inside the type, so none is a method in anything but
// placement. `private` at file scope is fileprivate, so every call site in
// this file resolves the same way.
//
// This is what `check_aggregate_type_size.sh` measures: a type is the sum of
// its parts across every file, so code that does not need the type inflates
// that number without making the type do more.

/// Deep / REM / Light, each with its share of the night.
private func sleepStageBoxes(_ sleep: PDFReportGenerator.SleepData) -> [(String, String, UIColor)] {
    let deepStr = sleep.deepSleepFormatted ?? reportMissingValue
    let remStr = reportHoursMinutes(sleep.remSleepMinutes)
    let deepPct = stageShare(sleep.deepSleepMinutes, of: sleep.totalSleepMinutes)
    let remPct = stageShare(sleep.remSleepMinutes, of: sleep.totalSleepMinutes)
    let coreStr = lightSleepFormatted(sleep)
    let row2: [(String, String, UIColor)] = [
        ("\(String(localized: "Deep", bundle: LanguageManager.appBundle))\(deepPct)", deepStr, UIColor(red: 0.3, green: 0.4, blue: 0.7, alpha: 1)),
        ("REM\(remPct)", remStr, UIColor(red: 0.5, green: 0.3, blue: 0.6, alpha: 1)),
        (String(localized: "Light", bundle: LanguageManager.appBundle), coreStr, UIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)),
        ("", "", .clear)
    ]
    return row2
}

/// " (27%)", or empty when the stage or the night is missing.
private func stageShare(_ stageMinutes: Int?, of totalMinutes: Int) -> String {
    guard let stageMinutes, totalMinutes > 0 else { return "" }
    return String(format: " (%.0f%%)", locale: .current, Double(stageMinutes) / Double(totalMinutes) * 100)
}

/// "Light" is core + unspecified.
///
/// `totalSleepMinutes` already EXCLUDES awake (see
/// SleepResolver: total = deep+core+rem+unspecified, inBed = total+awake).
/// Subtracting `awakeMinutes` here would double-exclude it AND drop the
/// `unspecified` bucket, so Deep+REM+Light would sum to ~90% of total (the
/// ~35 min unspecified vanishes). `total - deep - rem` matches the
/// on-screen SleepDetailV2View, so the three bars sum to 100%.
private func lightSleepFormatted(_ sleep: PDFReportGenerator.SleepData) -> String {
    guard sleep.totalSleepMinutes > 0 else { return reportMissingValue }
    let core = sleep.totalSleepMinutes - (sleep.deepSleepMinutes ?? 0) - (sleep.remSleepMinutes ?? 0)
    guard core > 0 else { return reportMissingValue }
    return reportHoursMinutes(core)
}

private func respiratoryRateBox(_ vitals: PDFReportGenerator.VitalsData) -> (String, String, UIColor)? {
    guard let rr = vitals.respiratoryRate else { return nil }
    var label = reportBreathsPerMinute(rr)
    if let baseline = vitals.respiratoryRateBaseline {
        let diff = rr - baseline
        if abs(diff) > 0.5 {
            label += String(format: " (%+.1f)", locale: .current, diff)
        }
    }
    let color: UIColor = {
        guard let baseline = vitals.respiratoryRateBaseline else { return .darkGray }
        return rr > baseline + 2 ? UIColor(red: 0.8, green: 0.5, blue: 0.3, alpha: 1) : .darkGray
    }()
    return (String(localized: "Resp. Rate", bundle: LanguageManager.appBundle), label, color)
}

private func oxygenSaturationBox(_ vitals: PDFReportGenerator.VitalsData) -> (String, String, UIColor)? {
    guard let spo2 = vitals.oxygenSaturation else { return nil }
    var label = String(format: "%.0f%%", locale: .current, spo2)
    if let spo2Min = vitals.oxygenSaturationMin {
        label += String(format: " (min %.0f%%)", locale: .current, spo2Min)
    }
    let color: UIColor = spo2 < 95 ? UIColor(red: 0.8, green: 0.3, blue: 0.3, alpha: 1) : .darkGray
    return (String(localized: "SpO2", bundle: LanguageManager.appBundle), label, color)
}

private func restingHeartRateBox(_ vitals: PDFReportGenerator.VitalsData) -> (String, String, UIColor)? {
    guard let rhr = vitals.restingHeartRate else { return nil }
    let label = String(format: "%.0f bpm", locale: .current, rhr)
    return (String(localized: "Resting HR", bundle: LanguageManager.appBundle), label, .darkGray)
}
