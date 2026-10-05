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

    /// More, Settings and Settings search all build `HelpCenterView()`; it
    /// has to be the page with the methodology card.
    func testEveryHelpEntryPointOpensThePageWithTheMethodologyCard() {
        XCTAssertTrue(type(of: HelpCenterView()) == HelpCenterV2View.self)
    }
}
