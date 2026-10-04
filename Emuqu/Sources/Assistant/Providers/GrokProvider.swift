import Foundation

/// Streams responses from xAI's Grok API.
/// OpenAI-compatible endpoint at https://api.x.ai/v1/chat/completions.
final class GrokProvider: AIProvider {
    static let models: [ModelOption] = [
        ModelOption(
            providerID: .grok,
            apiID: "grok-4-1-fast-non-reasoning",
            displayName: "Grok 4.1 Fast (instant)",
            blurb: "Cheapest, instant replies",
            contextWindow: 2_000_000,
            inputPricePerMTok: 0.20,
            outputPricePerMTok: 0.50,
            isDefault: false
        ),
        ModelOption(
            providerID: .grok,
            apiID: "grok-4-1-fast-reasoning",
            displayName: "Grok 4.1 Fast (reasoning)",
            blurb: "Cheap & fast with reasoning — recommended",
            contextWindow: 2_000_000,
            inputPricePerMTok: 0.20,
            outputPricePerMTok: 0.50,
            isDefault: true
        ),
        ModelOption(
            providerID: .grok,
            apiID: "grok-4",
            displayName: "Grok 4",
            blurb: "Top reasoning",
            contextWindow: 256_000,
            inputPricePerMTok: 3.00,
            outputPricePerMTok: 15.00,
            isDefault: false
        )
    ]

    let id: ProviderID = .grok
    var availableModels: [ModelOption] {
        Self.models
    }

    var requiresKey: Bool {
        true
    }

    var isAvailable: Bool {
        AppDependencies.current.providers.apiKeyStore.hasKey(for: .grok)
    }

    /// xAI's `grok-4-1-fast-*` endpoints reject requests with > 200 tool
    /// schemas (HTTP 400 "Maximum tools limit reached"). The compact tool
    /// catalog sent today is far below that, so this cap does not bind; it
    /// stays as a guard that keeps a future catalog under xAI's ceiling.
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
            messages: messages,
            model: model,
            contextRendered: contextRendered,
            systemPrompt: systemPrompt,
            tools: tools,
            toolRounds: toolRounds
        )
    }
}
