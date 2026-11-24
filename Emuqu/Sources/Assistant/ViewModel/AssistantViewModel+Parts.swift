import Foundation

// The view model's two subsystems: `AssistantTurnRouter` routes each turn
// to a provider and `AssistantToolRunner` runs the tool-use loop. Both are
// lightweight values built on each access around the view model, which keeps
// the conversation state.

extension AssistantViewModel {
    /// The routing subsystem: a lightweight value built on each access.
    var router: AssistantTurnRouter {
        AssistantTurnRouter(owner: self)
    }

    /// The index of a turn still in the live transcript, or `nil` once it
    /// has been dropped.
    func liveTurnIndex(for turnID: UUID) -> Int? { router.liveTurnIndex(for: turnID) }

    /// The tool-use subsystem: a lightweight value built on each access.
    var tools: AssistantToolRunner {
        AssistantToolRunner(owner: self)
    }
}
