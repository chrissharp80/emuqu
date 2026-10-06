@testable import Emuqu
import XCTest

/// Pins every cloud model ID the app ships to the set last checked against
/// the vendors' own documentation, so an ID changes only together with a
/// fresh check.
///
/// Verified on 5 October 2026 against:
/// - platform.claude.com/docs/en/about-claude/models/overview and /model-deprecations
/// - developers.openai.com/api/docs/models (gpt-6-luna, gpt-5.4-mini, gpt-5.4) and /deprecations
/// - ai.google.dev/gemini-api/docs/models, /pricing and /deprecations
/// - docs.x.ai/developers/models (grok-4.3, grok-4.7) and the May 15 retirement guide
/// - api-docs.deepseek.com/quick_start/pricing, /updates and /guides/thinking_mode
///
/// To change a list: re-check the vendor's model, pricing and deprecation
/// pages, update the provider's `models` table, Help's "ai-providers"
/// article and docs/USERS_MANUAL.md, then the expected list and date here.
@MainActor
final class ProviderModelCatalogTests: XCTestCase {
    /// IDs a vendor has retired, deprecated or never served under that name.
    /// Shipping one fails every request or bills a model the picker doesn't name.
    private static let retiredIDs: Set<String> = [
        "gemini-3-flash", "gemini-3.1-pro", "gemini-3.1-flash-lite",
        "deepseek-chat", "deepseek-reasoner",
        "grok-4-1-fast-non-reasoning", "grok-4-1-fast-reasoning", "grok-4",
        "gpt-5.4-nano"
    ]

    private static let cloudCatalogs: [(ProviderID, [ModelOption])] = [
        (.anthropic, AnthropicProvider.models),
        (.openai, OpenAIProvider.models),
        (.gemini, GeminiProvider.models),
        (.grok, GrokProvider.models),
        (.deepseek, DeepSeekProvider.models)
    ]

    private static var allModels: [ModelOption] {
        cloudCatalogs.flatMap { $0.1 }
    }

    func testAnthropicShipsTheVerifiedIDs() {
        XCTAssertEqual(
            AnthropicProvider.models.map(\.apiID),
            ["claude-haiku-4-5-20251001", "claude-sonnet-4-6", "claude-opus-4-7"]
        )
    }

    func testOpenAIShipsTheVerifiedIDs() {
        XCTAssertEqual(OpenAIProvider.models.map(\.apiID), ["gpt-6-luna", "gpt-5.4-mini", "gpt-5.4"])
    }

    func testGeminiShipsTheVerifiedIDs() {
        XCTAssertEqual(
            GeminiProvider.models.map(\.apiID),
            ["gemini-3.5-flash-lite", "gemini-3.8-flash", "gemini-3.1-pro-preview"]
        )
    }

    func testGrokShipsTheVerifiedIDs() {
        XCTAssertEqual(GrokProvider.models.map(\.apiID), ["grok-4.3", "grok-4.7"])
    }

    func testDeepSeekShipsTheVerifiedIDs() {
        XCTAssertEqual(DeepSeekProvider.models.map(\.apiID), ["deepseek-flash", "deepseek-v4-pro"])
    }

    /// The prices the vendors list per million tokens (input, output). The
    /// cheapest-cloud routing compares these.
    func testPricesMatchTheVendorsLists() {
        let expected: [String: (Decimal, Decimal)] = [
            "claude-haiku-4-5-20251001": (1, 5), "claude-sonnet-4-6": (3, 15), "claude-opus-4-7": (5, 25),
            "gpt-6-luna": (0.10, 0.50), "gpt-5.4-mini": (0.75, 4.50), "gpt-5.4": (2.50, 15),
            "gemini-3.5-flash-lite": (0.30, 2.50), "gemini-3.8-flash": (1.50, 7.50), "gemini-3.1-pro-preview": (2, 12),
            "grok-4.3": (1.25, 2.50), "grok-4.7": (2, 6),
            "deepseek-flash": (0.30, 1.20), "deepseek-v4-pro": (1.32, 3.96)
        ]
        for model in Self.allModels {
            let price = expected[model.apiID]
            XCTAssertEqual(model.inputPricePerMTok, price?.0, "\(model.apiID) input price")
            XCTAssertEqual(model.outputPricePerMTok, price?.1, "\(model.apiID) output price")
        }
    }

    func testNoRetiredIDShips() {
        let shipped = Set(Self.allModels.map(\.apiID))
        XCTAssertTrue(shipped.isDisjoint(with: Self.retiredIDs), "retired IDs shipped: \(shipped.intersection(Self.retiredIDs))")
    }

    func testEachProviderHasOneDefaultAndOnlyItsOwnModels() {
        for (providerID, models) in Self.cloudCatalogs {
            XCTAssertEqual(models.filter(\.isDefault).count, 1, "\(providerID) defaults")
            XCTAssertTrue(models.allSatisfy { $0.providerID == providerID }, "\(providerID) lists another provider's model")
        }
    }

    /// A chat saved while a retired model was selectable keeps that model's
    /// name instead of showing the raw API ID.
    func testRetiredModelsKeepTheirNamesInSavedChats() {
        XCTAssertEqual(Set(ProviderRegistry.retiredDisplayNames.keys), Self.retiredIDs)
        XCTAssertEqual(ProviderRegistry.retiredDisplayNames["deepseek-chat"], "DeepSeek Chat (V3.2)")
    }

    /// Help's provider table names every shipped model, and marks the
    /// default as the recommended one.
    func testHelpListsEveryShippedModel() throws {
        let labels: [ProviderID: String] = [
            .anthropic: "Claude", .openai: "ChatGPT", .gemini: "Gemini", .grok: "Grok", .deepseek: "DeepSeek"
        ]
        let article = try XCTUnwrap(
            HelpContent.englishCategories(forAge: nil).flatMap(\.articles).first { $0.id == "ai-providers" }
        )
        let rows = article.sections.flatMap { section -> [(label: String, value: String)] in
            if case let .keyValue(pairs) = section { return pairs }
            return []
        }
        for (providerID, models) in Self.cloudCatalogs {
            let row = try XCTUnwrap(rows.first { $0.label == labels[providerID] }, "no Help row for \(providerID)")
            for model in models {
                XCTAssertTrue(row.value.contains(model.displayName), "Help's \(row.label) row omits \(model.displayName)")
            }
            let recommended = try XCTUnwrap(models.first(where: \.isDefault)).displayName + " (recommended)"
            XCTAssertTrue(row.value.contains(recommended), "Help's \(row.label) row doesn't recommend the default")
        }
    }
}
