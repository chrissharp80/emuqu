import Foundation

/// Streams responses from DeepSeek's API.
/// OpenAI-compatible endpoint at https://api.deepseek.com/chat/completions.
///
/// `deepseek-chat` is the non-thinking V3.2 model, `deepseek-reasoner` is the
/// thinking variant. Same per-token price; different latency/output character.
final class DeepSeekProvider: AIProvider {
    static let models: [ModelOption] = [
        ModelOption(
            providerID: .deepseek,
            apiID: "deepseek-chat",
            displayName: "DeepSeek Chat (V3.2)",
            blurb: "Cheapest — recommended",
            contextWindow: 128_000,
            inputPricePerMTok: 0.28,
            outputPricePerMTok: 0.42,
            isDefault: true
        ),
        ModelOption(
            providerID: .deepseek,
            apiID: "deepseek-reasoner",
            displayName: "DeepSeek Reasoner (V3.2)",
            blurb: "Thinking mode for complex analysis",
            contextWindow: 128_000,
            inputPricePerMTok: 0.28,
            outputPricePerMTok: 0.42,
            isDefault: false
        )
    ]

    let id: ProviderID = .deepseek
    var availableModels: [ModelOption] {
        Self.models
    }

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
            endpoint: URL(string: "https://api.deepseek.com/chat/completions")!,
            messages: messages,
            model: model,
            contextRendered: contextRendered,
            systemPrompt: systemPrompt,
            tools: tools,
            toolRounds: toolRounds
        )
    }
}
