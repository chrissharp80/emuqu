import Foundation

/// Streams responses from xAI's Grok API.
/// OpenAI-compatible endpoint at https://api.x.ai/v1/chat/completions.
///
/// Checked against docs.x.ai/developers/models and the May 15 retirement
/// guide. `ProviderModelCatalogTests` pins this list. xAI retired the
/// grok-4-1-fast models and grok-4-0709 and redirects them to grok-4.3.
/// Each model runs at its default reasoning effort (grok-4.3 low,
/// grok-4.7 high). Prices are for prompts under 200k tokens.
final class GrokProvider: AIProvider {
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
    var availableModels: [ModelOption] {
        Self.models
    }

    /// Each model's default reasoning effort.
    static let reasoning: OpenAICompatibleStreamer.Reasoning = .modelDefault

    var requiresKey: Bool {
        true
    }

    var isAvailable: Bool {
        AppDependencies.current.providers.apiKeyStore.hasKey(for: .grok)
    }

    /// xAI's retired grok-4-1-fast models rejected requests with more than
    /// 200 tool schemas (HTTP 400 "Maximum tools limit reached"), and the
    /// current model pages state no limit. The compact tool catalog sent
    /// today is far below that, so this cap does not bind; it stays as a
    /// guard that keeps a future catalog under xAI's last known ceiling.
    /// If it ever binds, `AssistantViewModel.trimTools` keeps the first 110
    /// tools in `ToolRetriever`'s order and drops the rest.
    var maxToolSchemaCount: Int? { 110 }

    func send(
        messages: [ChatTurn],
        model: ModelOption,
        contextRendered: String,
        systemPrompt: String,
        tools: [ToolSpec],
        toolRounds: [[ToolExchange]]
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        OpenAICompatibleStreamer.send(
            providerID: .grok,
            endpoint: OpenAICompatibleStreamer.Endpoint.grok,
            reasoning: Self.reasoning,
            messages: messages,
            model: model,
            contextRendered: contextRendered,
            systemPrompt: systemPrompt,
            tools: tools,
            toolRounds: toolRounds
        )
    }
}
