import Foundation

// Routing lives in `AssistantTurnRouter` — 750 lines off
// `AssistantViewModel`.

extension AssistantViewModel {
    /// The routing subsystem.
    var router: AssistantTurnRouter {
        AssistantTurnRouter(owner: self)
    }

    func resolveProviderForThisTurn() -> (provider: AIProvider, model: ModelOption, tier: SmartProviderRouter.Tier?) {
        router.resolveProviderForThisTurn()
    }

    func dispatch() { router.dispatch() }
    func liveTurnIndex(for turnID: UUID) -> Int? { router.liveTurnIndex(for: turnID) }
    func applyPostStreamEffects(turnID: UUID) { router.applyPostStreamEffects(turnID: turnID) }
    func recordCoachVoiceInterception(reason: String) { router.recordCoachVoiceInterception(reason: reason) }
    func snapshotUserFacts() async -> String { await router.snapshotUserFacts() }

    /// Pure predicates — no view-model state — so they forward to the type.
    static func providerSupportsTools(_ provider: AIProvider) -> Bool {
        AssistantTurnRouter.providerSupportsTools(provider)
    }

    static func messageRequiresTools(_ text: String) -> Bool {
        AssistantTurnRouter.messageRequiresTools(text)
    }
}
