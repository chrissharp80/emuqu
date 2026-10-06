@testable import Emuqu
import XCTest

/// Holds the Help Center's science articles to the scoring code they describe.
///
/// Each test pins a sentence that once disagreed with the code: the SpO₂ rule
/// (a 24-hour average, not "any reading"), the ACWR damper's real cap, the
/// short-night sleep cap, the sleep-stage targets, the Comeback weights and
/// the breathing-rate range. The first test keeps the illness lead-time claim
/// that App Store Guideline 1.4.1 rules out from coming back.
@MainActor
final class HelpScienceAccuracyTests: XCTestCase {
    private var articles: [HelpArticle] {
        HelpContent.englishCategories(forAge: nil).flatMap(\.articles)
    }

    private func article(_ id: String) throws -> HelpArticle {
        try XCTUnwrap(articles.first { $0.id == id }, "no Help article \(id)")
    }

    private static func strings(in section: ArticleSection) -> [String] {
        switch section {
        case let .text(t), let .heading(t), let .tip(t), let .warning(t), let .note(t): [t]
        case let .bullets(items), let .steps(items): items
        case let .keyValue(pairs): pairs.flatMap { [$0.label, $0.value] }
        case .divider: []
        }
    }

    private func text(of id: String) throws -> String {
        try article(id).sections.flatMap(Self.strings).joined(separator: " ")
    }

    private var everyEnglishString: [String] {
        articles.flatMap { [$0.title, $0.summary] + $0.sections.flatMap(Self.strings) }
    }

    private static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    /// No Help string says a pattern shows up before people feel or report
    /// being unwell. Mirrors the copy linter's widened lead-time rule.
    func testHelpStatesNoIllnessLeadTime() throws {
        let leadTime = try NSRegularExpression(
            pattern: "(?i)\\bbefore\\s+(?:(?:cold|flu)\\b|(?:you|people|they|users?|someone)\\s+(?:\\w+\\s+)?"
                + "(?:(?:feel|report|notice)\\w*\\s+(?:\\w+\\s+){0,2}(?:unwell|ill|sick|symptoms?|illness)|(?:get|fall|become)\\w*\\s+(?:sick|ill))\\b)"
        )
        for string in everyEnglishString {
            let range = NSRange(string.startIndex..., in: string)
            XCTAssertNil(leadTime.firstMatch(in: string, range: range), "Help states an illness lead time: \(string.prefix(100))")
        }
    }

    /// Every Help sentence that names the 95% SpO₂ penalty says it is the
    /// 24-hour average, which is what `fetchOxygenSaturation` returns.
    func testEverySpO2PenaltySentenceDescribesTheTwentyFourHourAverage() {
        let points = Int(RecoveryScoreConstants.Vitals.spo2Penalty)
        // The penalty itself is stated as "-10" or "10 points". A plain
        // substring also matches "90-100%" in the oximeter-accuracy note,
        // which states no rule, so the number must stand alone.
        let penalty = "(?<![\\d-])-?\(points)(?!\\d)(?: points|\\b)(?!%)"
        let penaltySentences = everyEnglishString.filter {
            $0.contains("below 95%") && $0.range(of: penalty, options: .regularExpression) != nil
        }
        XCTAssertFalse(penaltySentences.isEmpty)
        for sentence in penaltySentences {
            XCTAssertTrue(sentence.contains("24 hours"), "SpO₂ penalty copy doesn't say it uses the 24-hour average: \(sentence.prefix(100))")
            XCTAssertFalse(sentence.contains("any reading"), "SpO₂ penalty copy says any single reading counts: \(sentence.prefix(100))")
        }
    }

    /// The ACWR article quotes the damper's real numbers.
    func testTheACWRDamperCopyMatchesReadinessScoring() throws {
        let r = RecoveryScoreConstants.Readiness.self
        let copy = try text(of: "acwr-zones")
        XCTAssertTrue(copy.contains("capped at \(Self.percent(r.acwrPenaltyAutonomicRescueCap))"))
        XCTAssertTrue(copy.contains("\(Int(r.acwrRescueRecoveryThreshold)) or higher"))
        XCTAssertTrue(copy.contains("at most \(Self.percent(r.acwrOverreachingPenaltyCap))"))
        XCTAssertTrue(copy.contains("starts at \(Self.percent(r.acwrOverreachingPenaltyBase))"))
        XCTAssertFalse(copy.contains("near zero"))
    }

    /// The sleep-score article describes the short-night ceiling.
    func testTheSleepScoreArticleDescribesTheShortNightCap() throws {
        let w = SleepScienceAnalyzer.EnhancedScoreWeights.self
        let copy = try text(of: "sleep-score")
        XCTAssertTrue(copy.contains("Below \(Self.percent(w.durationDebtRatioThreshold)) of your sleep target"))
        XCTAssertTrue(copy.contains("no higher than \(Int(w.durationDebtCeilingAtThreshold))"))
        XCTAssertTrue(copy.contains("down to \(Int(w.durationDebtCeilingFloor))"))
    }

    /// Deep and REM targets are the sleep score's population targets, and
    /// the awakening count is not the unsourced "10-20 times".
    func testSleepStageTargetsMatchTheSleepScore() throws {
        let w = SleepScienceAnalyzer.EnhancedScoreWeights.self
        let copy = try text(of: "sleep-stages")
        XCTAssertTrue(copy.contains("about \(Int(w.populationDeepTargetPct))% of total sleep"))
        XCTAssertTrue(copy.contains("about \(Int(w.populationREMTargetPct))% of total sleep"))
        XCTAssertFalse(copy.contains("10-20 times"))
    }

    /// The Comeback article's weights are the Tier 3 Comeback weights, and it
    /// says they apply only when the score includes vitals.
    func testTheComebackArticleMatchesTheComebackWeights() throws {
        let copy = try text(of: "comeback-mode")
        let (hrv, sleep, vitals) = ScoreDetailBuilder.tier3Weights(comebackModeActive: true)
        XCTAssertTrue(copy.contains("HRV weight \(Self.percent(hrv))"))
        XCTAssertTrue(copy.contains("Sleep weight \(Self.percent(sleep))"))
        XCTAssertTrue(copy.contains("Vitals weight \(Self.percent(vitals))"))
        XCTAssertTrue(copy.contains("apply when your score includes vitals"))
        XCTAssertFalse(copy.contains("small indicator"))
    }

    /// The typical breathing range is the population band the vitals score
    /// falls back to.
    func testTheBreathingRateRangeMatchesThePopulationBand() throws {
        let v = ScoringWeights.Vitals.self
        let copy = try text(of: "vitals-overview")
        XCTAssertTrue(copy.contains("\(Int(v.respiratoryRatePopulationMinBPM))-\(Int(v.respiratoryRatePopulationMaxBPM))"))
    }

    /// Help reads as a 1.0: no architecture dates, removed features or
    /// "before this fix" history.
    func testScienceHelpCarriesNoVersionHistory() {
        let banned = ["May 2026", "Earlier versions", "before this fix", "v2 architecture", "Quality Score"]
        for string in everyEnglishString {
            for phrase in banned {
                XCTAssertFalse(string.contains(phrase), "Help string carries version history: \(string.prefix(100))")
            }
        }
    }

    /// The data-quality article names the rows the recording's Data Quality
    /// card shows (`RecordVerificationSection`).
    func testTheDataQualityRowsUseTheRecordScreensLabels() throws {
        let labels = try article("data-quality").sections.flatMap { section -> [String] in
            if case let .keyValue(pairs) = section { return pairs.map(\.label) }
            return []
        }
        XCTAssertEqual(labels, ["Artifact %", "Clean Beats", "Quality"])
    }
}
