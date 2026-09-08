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
    /// schemas (HTTP 400 "Maximum tools limit reached"). The hard ceiling
    /// was 190 for headroom; we now cap MUCH lower because the per-request
    /// input-token cost of 190 tool definitions (≈15k-20k tokens each
    /// send) was the dominant factor in the user's 10-15 s Grok response
    /// times — both in network transfer and in xAI's processing-time
    /// scaling. `trimTools` orders by namespace priority, so capping at
    /// 110 keeps the high-value tools (recovery / hrv / sleep / vitals /
    /// score / session / workout / training / location) and drops the
    /// long tail (low-frequency app-state / debug / capability lookups
    /// the model rarely calls). 110 also gives us ample headroom for
    /// future namespaces without hitting xAI's 200 ceiling.
    ///
    /// Trade-off: a question that needed one of the dropped
    /// tools will get a "tool not available" miss and fall back to a
    /// natural-language answer. Acceptable cost; the bulk of conversations
    /// don't touch the long tail. Other providers (Anthropic, OpenAI,
    /// Gemini, DeepSeek, Apple) keep the full catalog — only Grok's
    /// per-request token cost was disproportionate to its tier.
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
            endpoint: URL(string: "https://api.x.ai/v1/chat/completions")!,
            messages: messages,
            model: model,
            contextRendered: contextRendered,
            systemPrompt: systemPrompt,
            tools: tools,
            toolRounds: toolRounds
        )
    }
}
