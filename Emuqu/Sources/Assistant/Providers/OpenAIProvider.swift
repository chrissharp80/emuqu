import Foundation

/// Streams responses from OpenAI's Chat Completions API.
/// https://platform.openai.com/docs/api-reference/chat/create
final class OpenAIProvider: AIProvider {
    static let models: [ModelOption] = [
        ModelOption(
            providerID: .openai,
            apiID: "gpt-5.4-nano",
            displayName: "GPT-5.4 nano",
            blurb: "Fastest & cheapest",
            contextWindow: 128_000,
            inputPricePerMTok: 0.15,
            outputPricePerMTok: 0.60,
            isDefault: false
        ),
        ModelOption(
            providerID: .openai,
            apiID: "gpt-5.4-mini",
            displayName: "GPT-5.4 mini",
            blurb: "Balanced — recommended",
            contextWindow: 256_000,
            inputPricePerMTok: 0.40,
            outputPricePerMTok: 1.60,
            isDefault: true
        ),
        ModelOption(
            providerID: .openai,
            apiID: "gpt-5.4",
            displayName: "GPT-5.4",
            blurb: "Strongest reasoning",
            contextWindow: 256_000,
            inputPricePerMTok: 2.50,
            outputPricePerMTok: 10.0,
            isDefault: false
        )
        // GPT-5.4 Pro is not listed: OpenAI serves it on the Responses API
        // only, and this provider speaks Chat Completions. A saved Pro
        // selection falls back to the default model on launch.
    ]

    let id: ProviderID = .openai
    var availableModels: [ModelOption] {
        Self.models
    }

    var requiresKey: Bool {
        true
    }

    var isAvailable: Bool {
        AppDependencies.current.providers.apiKeyStore.hasKey(for: .openai)
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
            providerID: .openai,
            endpoint: OpenAICompatibleStreamer.Endpoint.openAI,
            messages: messages,
            model: model,
            contextRendered: contextRendered,
            systemPrompt: systemPrompt,
            tools: tools,
            toolRounds: toolRounds
        )
    }
}
