import Foundation

// The tool-use loop lives in `AssistantToolRunner` — 843 lines kept off
// `AssistantViewModel`, itself already spread across four files.
//
// These forwarders keep every existing call site working; the behaviour lives
// one reference away.

extension AssistantViewModel {
    /// The tool-use subsystem. Lazy — a launch that never opens the assistant
    /// never builds it.
    var tools: AssistantToolRunner {
        AssistantToolRunner(owner: self)
    }

    func runToolUseLoop(
        provider: AIProvider,
        model: ModelOption,
        outbound: [ChatTurn],
        systemPrompt: String,
        tools toolSpecs: [ToolSpec],
        factRegistry: FactResolverRegistry?,
        turnID: UUID
    ) async throws {
        try await tools.runToolUseLoop(
            provider: provider, model: model, outbound: outbound,
            systemPrompt: systemPrompt, tools: toolSpecs,
            factRegistry: factRegistry, turnID: turnID
        )
    }

    func handleStreamFailure(error: Error, turnID: UUID) async {
        await tools.handleStreamFailure(error: error, turnID: turnID)
    }

    func orderedFallbackProviders(after primary: AIProvider) -> [(AIProvider, ModelOption)] {
        tools.orderedFallbackProviders(after: primary)
    }

    func tryFallbacks(
        _ chain: [(AIProvider, ModelOption)],
        outbound: [ChatTurn],
        tools toolSpecs: [ToolSpec],
        factRegistry: FactResolverRegistry?,
        turnID: UUID,
        voiceMode: Bool
    ) async -> Bool {
        await tools.tryFallbacks(
            chain, outbound: outbound, tools: toolSpecs,
            factRegistry: factRegistry, turnID: turnID, voiceMode: voiceMode
        )
    }

    func escalateOnAppleRefusal(
        failedProvider: AIProvider,
        outbound: [ChatTurn],
        systemPrompt: String,
        tools toolSpecs: [ToolSpec],
        factRegistry: FactResolverRegistry?,
        turnID: UUID,
        voiceMode: Bool
    ) async -> AssistantToolRunner.EscalationOutcome {
        await tools.escalateOnAppleRefusal(
            failedProvider: failedProvider, outbound: outbound,
            systemPrompt: systemPrompt, tools: toolSpecs,
            factRegistry: factRegistry, turnID: turnID, voiceMode: voiceMode
        )
    }

    func finishStream(generation: Int) async {
        await tools.finishStream(generation: generation)
    }
}
