import Foundation
import PDFKit
@preconcurrency import Translation
import UIKit

// MARK: - Drawing Helpers

extension PDFReportGenerator {
    // MARK: - Drawing Helpers

    func drawSectionHeading(_ text: String, yPosition: CGFloat, pageRect: CGRect) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: config.headingFont,
            .foregroundColor: config.primaryColor
        ]

        let rect = CGRect(x: config.margins.left, y: yPosition, width: pageRect.width - config.margins.left - config.margins.right, height: 18)
        text.draw(in: rect, withAttributes: attributes)

        return yPosition + 20
    }

    func drawCompactMetricsGrid(_ metrics: [(String, String)], yPosition: CGFloat, pageRect: CGRect) -> CGFloat {
        let contentWidth = pageRect.width - config.margins.left - config.margins.right
        let columns = 4
        let colWidth = contentWidth / CGFloat(columns)
        let rowHeight: CGFloat = 28
        var y = yPosition
        for (i, metric) in metrics.enumerated() {
            let col = i % columns
            let row = i / columns
            if col == 0, row > 0 { y += rowHeight }
            drawCompactMetricCell(metric, col: col, row: row, colWidth: colWidth,
                                  rowHeight: rowHeight, contentWidth: contentWidth, y: y)
        }
        let totalRows = (metrics.count + columns - 1) / columns
        return y + CGFloat(totalRows > 0 ? 1 : 0) * rowHeight
    }

    private func drawCompactMetricCell(
        _ metric: (String, String),
        col: Int,
        row: Int,
        colWidth: CGFloat,
        rowHeight: CGFloat,
        contentWidth: CGFloat,
        y: CGFloat
    ) {
        let nameAttr: [NSAttributedString.Key: Any] = [
            .font: config.captionFont,
            .foregroundColor: UIColor.gray
        ]
        let valueAttr: [NSAttributedString.Key: Any] = [
            .font: config.monoFont,
            .foregroundColor: UIColor.black
        ]
            let x = config.margins.left + CGFloat(col) * colWidth

            // Background for alternating rows
            if row % 2 == 0, col == 0 {
                let rowRect = CGRect(x: config.margins.left, y: y - 2, width: contentWidth, height: rowHeight)
                UIColor(white: 0.97, alpha: 1.0).setFill()
                UIBezierPath(rect: rowRect).fill()
            }

            metric.0.draw(at: CGPoint(x: x, y: y), withAttributes: nameAttr)
            metric.1.draw(at: CGPoint(x: x, y: y + 10), withAttributes: valueAttr)
    }
}

// MARK: - Report value formatting

/// What a report prints for a value it does not have. A dash reads the same
/// in every language.
let reportMissingValue = "—"

/// "7.2 br/min" in the app's language.
func reportBreathsPerMinute(_ rate: Double) -> String {
    String(format: String(localized: "%.1f br/min", bundle: LanguageManager.appBundle), locale: LanguageManager.appLocale, rate)
}

/// "1h 23m" or "45m" in the app's language, or the missing-value dash.
func reportHoursMinutes(_ minutes: Int?) -> String {
    guard let minutes else { return reportMissingValue }
    return LocalizedDuration.hoursMinutes(minutes: minutes)
}

// MARK: - Score text in the app's language

/// The score breakdown's message, factor details and penalty lines are
/// English the scorer assembles from numbers at runtime, so the string
/// catalogue has no entry for them. On screen `NarrativeTranslator` translates
/// them inside a SwiftUI translation session; a report is drawn outside any
/// view, so it translates them here first, on device, with the language models
/// already installed. When the app is in English, the system is older than
/// iOS 26, or the model is not installed, nothing is translated and the text
/// stays English, as before.
enum ReportNarrative {
    /// Every English string a breakdown prints that has no catalogue entry.
    static func strings(of breakdown: RecoveryScoreCalculator.ScoreBreakdown?) -> [String] {
        guard let breakdown else { return [] }
        return [breakdown.message] + breakdown.factors.map(\.detail) + breakdown.penalties
    }

    /// English → app-language translations of `strings`, or empty.
    static func translations(of strings: [String]) async -> [String: String] {
        let target = LanguageManager.appLocale.language
        let unique = Array(Set(strings.filter { !$0.isEmpty }))
        guard target.languageCode?.identifier != "en", !unique.isEmpty else { return [:] }
        guard #available(iOS 26.0, *) else { return [:] }
        let session = TranslationSession(installedSource: Locale.Language(identifier: "en"), target: target)
        let requests = unique.map { TranslationSession.Request(sourceText: $0, clientIdentifier: $0) }
        do {
            return byEnglish(try await session.translations(from: requests))
        } catch {
            debugLog("[ReportNarrative] on-device translation unavailable (\(error.localizedDescription)) — score text stays in English", level: .info)
            return [:]
        }
    }
}

extension ReportNarrative {
    /// Each request carried its English as the client identifier.
    @available(iOS 26.0, *)
    private static func byEnglish(_ responses: [TranslationSession.Response]) -> [String: String] {
        var out: [String: String] = [:]
        for response in responses {
            guard let english = response.clientIdentifier else { continue }
            out[english] = response.targetText
        }
        return out
    }
}

extension PDFReportGenerator {
    /// Translate the breakdown's score text before `generateReport`, so the
    /// recovery PDF reads in the app's language like the screen it came from.
    func prepareNarrative(for breakdown: RecoveryScoreCalculator.ScoreBreakdown?) async {
        narrative = await ReportNarrative.translations(of: ReportNarrative.strings(of: breakdown))
    }

    /// `english` in the app's language when a translation was prepared.
    func narrativeText(_ english: String) -> String {
        narrative[english] ?? english
    }
}
