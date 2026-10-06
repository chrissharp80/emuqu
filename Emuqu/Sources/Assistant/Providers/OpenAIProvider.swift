import Foundation

/// Streams responses from OpenAI's Chat Completions API.
/// https://platform.openai.com/docs/api-reference/chat/create
final class OpenAIProvider: AIProvider {
    /// Checked against developers.openai.com/api/docs/models and
    /// /deprecations. `ProviderModelCatalogTests` pins this list.
    ///
    /// gpt-6-luna replaces gpt-5.4-nano, which OpenAI has deprecated. Chat
    /// Completions accepts function calling on gpt-6-luna only with
    /// `reasoning_effort` "none", so every model here is sent "none" (the
    /// default for gpt-5.4 and gpt-5.4-mini). gpt-6.1-sol is not listed: Chat
    /// Completions serves it without tool calling. gpt-6-astra is not listed:
    /// at $10 / $50 it costs four times gpt-5.4 for a chat assistant.
    /// A saved selection that is no longer listed takes the default model.
    static let models: [ModelOption] = [
        ModelOption(
            providerID: .openai,
            apiID: "gpt-6-luna",
            displayName: "GPT-6 Luna",
            blurb: "Fastest & cheapest",
            contextWindow: 1_050_000,
            inputPricePerMTok: 0.10,
            outputPricePerMTok: 0.50,
            isDefault: false
        ),
        ModelOption(
            providerID: .openai,
            apiID: "gpt-5.4-mini",
            displayName: "GPT-5.4 mini",
            blurb: "Balanced — recommended",
            contextWindow: 400_000,
            inputPricePerMTok: 0.75,
            outputPricePerMTok: 4.50,
            isDefault: true
        ),
        ModelOption(
            providerID: .openai,
            apiID: "gpt-5.4",
            displayName: "GPT-5.4",
            blurb: "Strongest reasoning",
            contextWindow: 1_050_000,
            inputPricePerMTok: 2.50,
            outputPricePerMTok: 15.0,
            isDefault: false
        )
    ]

    let id: ProviderID = .openai
    var availableModels: [ModelOption] {
        Self.models
    }

    /// Reasoning off: gpt-6-luna takes tools on Chat Completions only at
    /// `reasoning_effort` "none", and it is the default for the other two.
    static let reasoning: OpenAICompatibleStreamer.Reasoning = .effortNone

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
