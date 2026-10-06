import Foundation

/// Streams responses from DeepSeek's API.
/// OpenAI-compatible endpoint at https://api.deepseek.com/chat/completions.
///
/// Checked against api-docs.deepseek.com (quick_start/pricing, updates,
/// guides/thinking_mode). `ProviderModelCatalogTests` pins this list.
///
/// DeepSeek retired `deepseek-chat` and `deepseek-reasoner` on 24 July 2026;
/// thinking is now a request field, on by default, rather than a model name.
/// Both models run with thinking off: a thinking turn that calls tools must
/// have its `reasoning_content` passed back in every later request, and
/// Flo's tool rounds carry only the calls and their results.
///
/// Prices are the peak-hour rates, so the figure never understates a bill;
/// off-peak rates are half.
final class DeepSeekProvider: AIProvider {
    static let models: [ModelOption] = [
        ModelOption(
            providerID: .deepseek,
            apiID: "deepseek-flash",
            displayName: "DeepSeek Flash",
            blurb: "Cheapest — recommended",
            contextWindow: 1_000_000,
            inputPricePerMTok: 0.30,
            outputPricePerMTok: 1.20,
            isDefault: true
        ),
        ModelOption(
            providerID: .deepseek,
            apiID: "deepseek-v4-pro",
            displayName: "DeepSeek V4 Pro",
            blurb: "Strongest reasoning",
            contextWindow: 1_000_000,
            inputPricePerMTok: 1.32,
            outputPricePerMTok: 3.96,
            isDefault: false
        )
    ]

    let id: ProviderID = .deepseek
    var availableModels: [ModelOption] {
        Self.models
    }

    /// Thinking off; see the type comment.
    static let reasoning: OpenAICompatibleStreamer.Reasoning = .thinkingDisabled

    var requiresKey: Bool {
        true
    }

    var isAvailable: Bool {
        AppDependencies.current.providers.apiKeyStore.hasKey(for: .deepseek)
    }

    func send(
        messages: [ChatTurn],
        model: ModelOption,
        contextRendered: String,
        systemPrompt: String,
        tools: [ToolSpec],
        toolRounds: [[ToolExchange]]
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        OpenAICompatibleStreamer.send(
            providerID: .deepseek,
            endpoint: OpenAICompatibleStreamer.Endpoint.deepSeek,
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
