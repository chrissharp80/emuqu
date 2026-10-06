@testable import Emuqu
import XCTest

/// Holds the Help Center's English text to the app it describes.
///
/// Help is prose, so nothing else notices when a screen, a band or a model
/// list changes underneath it. These tests tie the claims that have drifted
/// before to the code they describe.
@MainActor
final class HelpContentAccuracyTests: XCTestCase {
    private var articles: [HelpArticle] {
        HelpContent.englishCategories(forAge: nil).flatMap(\.articles)
    }

    private func article(_ id: String) throws -> HelpArticle {
        try XCTUnwrap(articles.first { $0.id == id }, "no Help article \(id)")
    }

    private static func pairs(in article: HelpArticle) -> [(label: String, value: String)] {
        article.sections.flatMap { section -> [(label: String, value: String)] in
            if case let .keyValue(pairs) = section { return pairs }
            return []
        }
    }

    private static func strings(in section: ArticleSection) -> [String] {
        switch section {
        case let .text(t), let .heading(t), let .tip(t), let .warning(t), let .note(t): [t]
        case let .bullets(items), let .steps(items): items
        case let .keyValue(pairs): pairs.flatMap { [$0.label, $0.value] }
        case .divider: []
        }
    }

    private var everyEnglishString: [String] {
        articles.flatMap { [$0.title, $0.summary] + $0.sections.flatMap(Self.strings) }
    }

    /// The verdict bands as Help writes them ("90-100 · Excellent"), read off
    /// `ScoreVerdict` itself, highest first.
    private static var verdictBandLabels: [String] {
        var bands: [(low: Int, high: Int, word: String)] = []
        for score in 0 ... 100 {
            let word = ScoreVerdict(score: Double(score)).word
            if let last = bands.last, last.word == word {
                bands[bands.count - 1].high = score
            } else {
                bands.append((score, score, word))
            }
        }
        return bands.reversed().map { "\($0.low)-\($0.high) · \($0.word)" }
    }

    /// Every score-band table (the recovery score, the Dashboard ring and the
    /// Sleep screen, which shows the same verdict words) lists the bands the
    /// app actually uses.
    func testEveryScoreBandTableMatchesTheVerdictLadder() throws {
        for id in ["understanding-score", "dashboard-guide", "sleep-score"] {
            let bandLabels = Self.pairs(in: try article(id)).map(\.label).filter { $0.contains(" · ") }
            XCTAssertEqual(bandLabels, Self.verdictBandLabels, "\(id) lists different score bands from ScoreVerdict")
        }
    }

    /// The ChatGPT row names no model the provider doesn't offer.
    func testTheChatGPTRowMatchesTheProvidersModels() throws {
        let row = try XCTUnwrap(Self.pairs(in: try article("ai-providers")).first { $0.label == "ChatGPT" })
        let offersPro = OpenAIProvider.models.contains { $0.displayName.contains("Pro") }
        XCTAssertEqual(row.value.contains("Pro"), offersPro, "Help and OpenAIProvider.models disagree about a Pro model")
    }

    /// The privacy article names the reply filter and the report action, the
    /// two things App Review checks an app showing generated text for.
    func testThePrivacyArticleDescribesFilteringAndReporting() throws {
        let text = try article("ai-privacy").sections.flatMap(Self.strings).joined(separator: " ")
        XCTAssertTrue(text.contains("Report response"), "Help no longer names the Report response action")
        XCTAssertTrue(text.contains("removes sentences that make diagnostic claims"), "Help no longer describes the reply filter")
        XCTAssertFalse(text.contains("moderate the responses"), "Help claims replies are not moderated")
    }

    /// No TrainingPeaks trademarks, no competitor products and no promised
    /// features in Help.
    func testHelpNamesNoTrademarkedMetricsOrUnbuiltFeatures() throws {
        let banned = try NSRegularExpression(pattern: "\\b(hr)?TSS\\b|Training Stress|Garmin|iSmoothRun|FITIV|basis for future|coming soon")
        for string in everyEnglishString {
            let range = NSRange(string.startIndex..., in: string)
            XCTAssertNil(banned.firstMatch(in: string, range: range), "Help string uses a banned term: \(string.prefix(80))")
        }
    }

    /// A shipping app's Help reads as finished: no beta labels, no developer
    /// to-dos, no competitor comparisons and no "it used to" changelog voice.
    func testHelpCarriesNoBetaToDoOrChangelogWording() throws {
        let banned = try NSRegularExpression(
            pattern: "\\bMVP\\b|\\(Yet\\)|Will pin|calling out a bug|ChatGPT Advanced Voice|Gemini Live|Pi\\.ai|\\bused to fire\\b|no longer|\\bnow (works|work|kills)\\b|than before|future features"
        )
        for string in everyEnglishString {
            let range = NSRange(string.startIndex..., in: string)
            XCTAssertNil(banned.firstMatch(in: string, range: range), "Help string reads as unfinished: \(string.prefix(80))")
        }
    }

    /// The Dashboard article quotes the tier weights `ScoringWeights` uses.
    func testTheDashboardArticleQuotesTheScoringTierWeights() throws {
        let text = try article("dashboard-guide").sections.flatMap(Self.strings).joined(separator: " ")
        let tier2 = "\(Int((ScoringWeights.Tier2.hrvNormal * 100).rounded()))/\(Int((ScoringWeights.Tier2.sleepNormal * 100).rounded()))"
        let tier3 = [ScoringWeights.Tier3.hrv, ScoringWeights.Tier3.sleep, ScoringWeights.Tier3.vitals]
            .map { String(Int(($0 * 100).rounded())) }.joined(separator: "/")
        XCTAssertTrue(text.contains("HRV + Sleep at \(tier2)"), "Help quotes different HRV + Sleep weights")
        XCTAssertTrue(text.contains("HRV + Sleep + Vitals at \(tier3)"), "Help quotes different three-part weights")
    }

    /// The memory article states the cap `UserFactsStore` enforces
    /// (`UserFactsStoreTests` pins the enforcement itself).
    func testTheMemoryArticleStatesTheFactCap() throws {
        let text = try article("ai-memory").sections.flatMap(Self.strings).joined(separator: " ")
        XCTAssertTrue(text.contains("up to \(UserFactsStore.maxFacts) facts"), "Help states a different memory cap")
    }

    /// Voice ends from the ✕ in the voice bar; the mic sends or interrupts.
    /// Location answers exist only during a workout.
    func testTheVoiceAndLocationArticlesDescribeTheControlsAsBuilt() throws {
        let voice = try article("ai-voice-conversation").sections.flatMap(Self.strings).joined(separator: " ")
        XCTAssertTrue(voice.contains("tap ✕ in the voice bar to end"), "Help no longer says how to end voice")
        XCTAssertFalse(voice.contains("mic again to end"), "Help says the mic ends voice")
        let whereAmI = try article("ai-where-am-i").sections.flatMap(Self.strings).joined(separator: " ")
        XCTAssertTrue(whereAmI.contains("Outside a workout Flo doesn't share your location"), "Help implies location answers outside a workout")
    }

    /// More, Settings and Settings search all build `HelpCenterView()`; it
    /// has to be the page with the methodology card.
    func testEveryHelpEntryPointOpensThePageWithTheMethodologyCard() {
        XCTAssertTrue(type(of: HelpCenterView()) == HelpCenterV2View.self)
    }
}
