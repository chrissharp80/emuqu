import Foundation

// Routing lives in `AssistantTurnRouter` — ~750 lines off
// `AssistantViewModel`.

extension AssistantViewModel {
    /// The routing subsystem: a lightweight value built on each access.
    var router: AssistantTurnRouter {
        AssistantTurnRouter(owner: self)
    }

    func dispatch(regenerating replyID: UUID? = nil) { router.dispatch(regenerating: replyID) }
    func liveTurnIndex(for turnID: UUID) -> Int? { router.liveTurnIndex(for: turnID) }
    func recordCoachVoiceInterception(reason: String) { router.recordCoachVoiceInterception(reason: reason) }
    func snapshotUserFacts() async -> String { await router.snapshotUserFacts() }
}
