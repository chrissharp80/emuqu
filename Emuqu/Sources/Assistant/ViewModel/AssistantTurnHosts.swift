import Foundation

// The view model's two subsystems: `AssistantTurnRouter` routes each turn
// to a provider and `AssistantToolRunner` runs the tool-use loop. Both are
// lightweight values built on each access around the view model, which keeps
// the conversation state. Each holds the view model only as the protocol
// below that names what it reads and writes, so a part's reach is its
// protocol, not the whole view model.

/// The conversation a turn writes into: the turns, where they are saved, the
/// error banner and voice's speakable cursors. `StreamTextBuffer` and
/// `GrokQuirkPolicy` need only this.
@MainActor
protocol AssistantTranscript: AnyObject, Sendable {
    var turns: [ChatTurn] { get set }
    var store: ConversationStore { get }
    var errorMessage: String? { get set }
    var speakableTextCursor: [UUID: Int] { get set }
}

extension AssistantTranscript {
    /// The index of a turn still in the live transcript, or `nil` once it
    /// has been dropped (cleared conversation, regenerate, failure removal).
    /// Every stream write and read resolves the turn through this instead of
    /// trusting a positional index that may now point at a different turn.
    func liveTurnIndex(for turnID: UUID) -> Int? {
        turns.firstIndex(where: { $0.id == turnID })
    }

    /// Records that the reply in `turnID` is produced with context not every
    /// provider may see (`ChatTurn.sensitivity`), before any of it streams.
    /// The mark stays when a later provider writes the reply instead: the
    /// text that leaves the bubble can come back (a fallback that answers
    /// nothing restores it), and withholding a reply that did not need it
    /// costs context, never privacy.
    func mark(_ sensitivity: TurnSensitivity?, onTurn turnID: UUID) {
        guard let sensitivity, let index = liveTurnIndex(for: turnID) else { return }
        turns[index].sensitivity = sensitivity
        store.save(turns)
    }
}

/// What both parts read to run a turn: the services, the provider registry,
/// the context source, and the streaming state of the turn in flight.
@MainActor
protocol AssistantTurnStream: AssistantTranscript {
    var services: ChatServices { get }
    var registry: ProviderRegistry { get }
    var contextSource: AssistantContextSource { get }
    var isStreaming: Bool { get set }
    var streamTask: Task<Void, Never>? { get set }
    var streamGeneration: Int { get set }
    var streamingTurn: AssistantViewModel.StreamingTurn? { get set }
}

/// What `AssistantToolRunner` uses beyond `AssistantTurnStream`: the
/// pending action confirmations, the message queued behind the stream and
/// the send that drains it, and the router, whose system prompt a fallback
/// reuses.
@MainActor
protocol ToolRunnerHost: AssistantTurnStream {
    var actionConfirmations: AssistantActionConfirmations { get }
    var pendingSendOnFinish: (text: String, fromVoice: Bool)? { get set }
    var router: AssistantTurnRouter { get }
    @discardableResult
    func send(text: String, fromVoice: Bool) -> AssistantViewModel.SendOutcome
}

/// What `AssistantTurnRouter` uses beyond `AssistantTurnStream`: routing and
/// consent state, the input bar's returned draft, the remembered facts and
/// summary, the cached fact registry, and the tool runner it hands the
/// stream to.
@MainActor
protocol TurnRouterHost: AssistantTurnStream {
    var factsStore: UserFactsStore { get }
    var sessionState: RoutingSessionState { get }
    var composerState: ComposerState { get }
    var nextSendIsVoice: Bool { get set }
    var pendingConsentRequest: AssistantViewModel.PendingConsentRequest? { get set }
    var priorSummary: String? { get }
    var tools: AssistantToolRunner { get }
    func factRegistryAndTools() -> (FactResolverRegistry, [ToolSpec])
    func checkCatalogHashStability(newHash: String) async
    func unsummarizedTurns(in dropped: [ChatTurn]) -> [ChatTurn]
    func updateSummaryWith(droppedTurns: [ChatTurn], provider: AIProvider, model: ModelOption, contextRendered: String) async
    func runAutoFactExtraction(userText: String, assistantText: String) async
}

extension AssistantViewModel {
    /// The routing subsystem: a lightweight value built on each access.
    var router: AssistantTurnRouter {
        AssistantTurnRouter(owner: self)
    }

    /// The tool-use subsystem: a lightweight value built on each access.
    var tools: AssistantToolRunner {
        AssistantToolRunner(owner: self)
    }
}
