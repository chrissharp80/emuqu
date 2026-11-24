import Foundation

/// Streams responses from xAI's Grok API.
/// OpenAI-compatible endpoint at https://api.x.ai/v1/chat/completions.
///
/// Checked against docs.x.ai/developers/models and xAI's retirement
/// guide. `ProviderModelCatalogTests` pins this list. xAI redirects the
/// retired grok-4-1-fast models and grok-4-0709 to grok-4.3.
/// Each model runs at its default reasoning effort (grok-4.3 low,
/// grok-4.7 high). Prices are for prompts under 200k tokens.
final class GrokProvider: OpenAICompatibleProvider {
    static let models: [ModelOption] = [
        ModelOption(
            providerID: .grok,
            apiID: "grok-4.3",
            displayName: "Grok 4.3",
            blurb: "Balanced — recommended",
            contextWindow: 1_000_000,
            inputPricePerMTok: 1.25,
            outputPricePerMTok: 2.50,
            isDefault: true
        ),
        ModelOption(
            providerID: .grok,
            apiID: "grok-4.7",
            displayName: "Grok 4.7",
            blurb: "Top reasoning",
            contextWindow: 500_000,
            inputPricePerMTok: 2.00,
            outputPricePerMTok: 6.00,
            isDefault: false
        )
    ]

    let id: ProviderID = .grok
    let services: AIProviderServices

    init(services: AIProviderServices) {
        self.services = services
    }
    static let endpoint = OpenAICompatibleStreamer.Endpoint.grok

    /// Each model's default reasoning effort.
    static let reasoning: OpenAICompatibleStreamer.Reasoning = .modelDefault

    /// xAI's retired grok-4-1-fast models rejected requests with more than
    /// 200 tool schemas (HTTP 400 "Maximum tools limit reached"), and the
    /// current model pages state no limit. The compact tool catalog sent
    /// today is far below that, so this cap does not bind; it stays as a
    /// guard that keeps a future catalog under xAI's last known ceiling.
    /// If it ever binds, `AssistantViewModel.trimTools` keeps the first 110
    /// tools in `ToolRetriever`'s order and drops the rest.
    var maxToolSchemaCount: Int? { 110 }
}
