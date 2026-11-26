import Foundation
import os

/// Bridge between Apple's
/// `LanguageModelSession(tools:)` mechanism and our
/// `CompactToolRouter`-driven tool dispatch.
///
/// Apple's `Tool` protocol invokes the handler synchronously inside
/// the session — there's no streaming `toolUse` event to dispatch
/// from the AssistantViewModel layer the way Anthropic / OpenAI /
/// Gemini do. To make our 30-tool catalog reachable from inside an
/// Apple `Tool`, the adapter needs a way to look up "given this tool
/// name and these JSON args, what's the result string?" without
/// owning the registry itself.
///
/// This singleton is the answer. AssistantViewModel sets the active
/// `FactResolverRegistry` before each send when Apple is the resolved
/// provider; the `AppleToolAdapter`'s handler closure reads from
/// here. Lifecycle is bounded — set on dispatch, never persisted.
///
/// **Privacy.** The model runs on-device, but some tools reach the network:
/// location names and directions come from Apple's geocoder and MapKit, as
/// on every provider. Web search would send the query to Tavily, which only
/// the cloud providers' consent sheet discloses (Apple has none), so Apple
/// never runs it. When the turn may move to a consented cloud model that can
/// search (`armWebSearchEscalation`), the call ends the Apple attempt with
/// `AppleWebSearchEscalation` and the chat runs the turn on that model;
/// otherwise the model gets a refusal note and answers without it. Calls go
/// through CompactToolRouter, which honors the same `MedicalQueryGuard`
/// perimeter the rest of the app uses.
///
/// **Escalation.** It happens only before any of the reply reached the user
/// and before a tool that changes the user's data ran this turn: the cloud
/// model starts the turn over, and would repeat both. `AppleReplyGate`
/// decides which of the two comes first, the reply's first shown text or the
/// escalation, and once the turn has escalated no further tool call runs.
///
/// **Budget.** The same per-turn tool-call limit as the cloud tool loop
/// (`AssistantToolRunner.maxToolCallsPerTurn`), counted from each
/// `setRegistry` call, which starts a turn, and from each
/// `setToolOutputAllowance` call, which starts an attempt at it. Every result
/// also passes through the attempt's `ToolOutputAllowance`, which cuts it to
/// what Apple's 4K window has left: tool results arrive mid-generation, after
/// the transcript was sized, and uncapped ones would overflow it. The calls
/// themselves are charged to the same allowance, and what the attempt spent is
/// read back (`toolTokensSpent`) so a reused session's ledger counts it.
///
/// **Concurrency.** `@MainActor` — every call comes from the
/// `LanguageModelSession`'s tool-call path which Apple invokes on
/// the main thread. The router itself is `@MainActor` so this is
/// the natural isolation domain.
@MainActor
final class AppleToolDispatcher {
    static let shared = AppleToolDispatcher()

    /// The active fact-resolver registry. Set by AssistantViewModel
    /// before each Apple-routed send; nil during cloud-routed sends.
    /// When nil, `dispatch` returns a documented error string so the
    /// model sees an explicit "no registry" rather than crashing.
    private var currentRegistry: FactResolverRegistry?
    /// Tool calls since the last `setRegistry` or `setToolOutputAllowance`.
    private var callsThisTurn = 0
    /// Whether this turn has called a tool that changes the user's data or the
    /// app's state (`AssistantToolRunner.mutatingToolNames`). Counted when the
    /// call is made, as the cloud loop counts its rounds, and kept across
    /// attempts: only a new turn (`setRegistry`) clears it.
    private(set) var ranMutatingTool = false
    /// What tool results may still take of Apple's window this attempt.
    private var outputAllowance = AppleContextCompactor.ToolOutputAllowance.unsized
    /// Whether a `web_search` call may end the Apple attempt so the turn runs
    /// on a cloud model that can search. Set per turn by the chat
    /// (`AssistantTurnRouter.publishAppleDispatcher`); `setRegistry` clears it.
    private var escalatesWebSearch = false
    /// Orders the reply's first shown text against an escalation, for the
    /// turn `setRegistry` started. `AppleFoundationProvider` passes every
    /// reply delta through it.
    private(set) var replyGate = AppleReplyGate()
    /// Tools that would send the user's words to a third party Apple's path
    /// has not disclosed.
    private static let refusedTools: Set<String> = ["web_search"]

    private init() {}

    /// Stash a registry for the upcoming Apple session. Called from
    /// `AssistantViewModel.dispatch()` immediately before
    /// `provider.send(...)` when the resolved provider is Apple.
    func setRegistry(_ registry: FactResolverRegistry?) {
        currentRegistry = registry
        callsThisTurn = 0
        ranMutatingTool = false
        escalatesWebSearch = false
        replyGate = AppleReplyGate()
    }

    /// Allow or forbid this turn's `web_search` call to move the turn to a
    /// cloud model. Called after `setRegistry`, which forbids it.
    func armWebSearchEscalation(_ armed: Bool) {
        escalatesWebSearch = armed
    }

    /// Whether a `web_search` call escalates: the turn may move to a model
    /// that can search, and no tool that changes the user's data ran this
    /// turn. Whether reply text was shown first is `AppleReplyGate`'s part.
    static func escalatesWebSearch(armed: Bool, ranMutatingTool: Bool) -> Bool {
        armed && !ranMutatingTool
    }

    /// Start one attempt at the turn: `AppleFoundationProvider` sizes what
    /// tool results may take before each attempt, including the trimmed retry
    /// after a context overflow, which also gets a fresh call count.
    func setToolOutputAllowance(_ allowance: AppleContextCompactor.ToolOutputAllowance) {
        outputAllowance = allowance
        callsThisTurn = 0
    }

    /// Tokens the tool calls and results of the current attempt took, which
    /// stay in the Apple session's transcript after the turn.
    var toolTokensSpent: Int {
        outputAllowance.spent
    }

    /// Resolve a tool call by name + JSON args. Returns the tool's
    /// rendered result as a string the model can read back. Errors
    /// from the underlying router are stringified — callers (Apple
    /// `Tool.call`) expect a string response and can't surface
    /// typed errors back to the model anyway. The one error thrown is
    /// `AppleWebSearchEscalation`, which ends the Apple attempt
    /// (`escalateIfAllowed`).
    func dispatch(name: String, argumentsJSON: String) async throws -> String {
        guard let registry = currentRegistry else {
            return #"{"error":"tool dispatcher has no registry — call setRegistry before invoking the model","tool":"\#(name)"}"#
        }
        outputAllowance.charge(name + argumentsJSON)
        if Self.refusedTools.contains(name) { try escalateIfAllowed() }
        if replyGate.hasEscalated { return Self.afterEscalationNote }
        if let refusal = refusal(for: name) {
            let note = refusal.toToolResultJSON()
            outputAllowance.charge(note)
            return note
        }
        let router = CompactToolRouter(registry: registry)
        let value = await router.resolveTool(name: name, argsJSON: argumentsJSON)
        // `FactValue.toToolResultJSON()` renders the same envelope
        // the cloud providers see when they get a tool result back
        // (`{"value": …, "missingReason": …}`), keeping wire-shape
        // parity between Apple and the cloud providers, then cut to the
        // attempt's allowance.
        return outputAllowance.admit(value.toToolResultJSON())
    }

    /// Ends the Apple attempt with `AppleWebSearchEscalation` when the turn may
    /// move to a model that can search and no reply text has been shown;
    /// returns, so the call gets the refusal note, otherwise.
    private func escalateIfAllowed() throws {
        guard Self.escalatesWebSearch(armed: escalatesWebSearch, ranMutatingTool: ranMutatingTool),
              replyGate.claimEscalation() else { return }
        debugLog("[AppleTools] web_search requested; ending the Apple attempt so a model that can search answers")
        throw AppleWebSearchEscalation()
    }

    /// The result of a call made after the turn escalated, which does not run:
    /// the turn starts over on another model.
    private static let afterEscalationNote = FactValue.missing(
        reason: .invalidParameter, detail: "this turn is moving to another model"
    ).toToolResultJSON()

    /// Counts the call, and returns why it may not run: a tool Apple's path
    /// does not offer, or a spent per-turn budget.
    private func refusal(for name: String) -> FactValue? {
        if Self.refusedTools.contains(name) {
            return .missing(reason: .invalidParameter, detail: "web search isn't available on the on-device model")
        }
        callsThisTurn += 1
        guard callsThisTurn > AssistantToolRunner.maxToolCallsPerTurn else {
            if AssistantToolRunner.mutatingToolNames.contains(name) { ranMutatingTool = true }
            return nil
        }
        return .missing(reason: .rateLimited, detail: "tool budget exceeded for this turn — answer with what you have")
    }
}

/// Thrown from Apple's `web_search` tool call when the turn moves to a cloud
/// model that can search (`AppleToolDispatcher.escalateIfAllowed`).
/// Foundation Models ends the generation with a
/// `LanguageModelSession.ToolCallError` carrying it, which
/// `AppleFoundationProvider` reports as `AIProviderError.needsWebSearch`.
struct AppleWebSearchEscalation: Error {}

/// Decides, for one Apple turn, whether reply text reaches the user or the
/// turn escalates to another model: whichever claims the gate first. Once
/// text was shown the turn cannot escalate (the other model's answer would
/// follow Apple's), and once it escalated no more Apple text is shown, so the
/// user sees only the answer of the model that took the turn. Shared between
/// the dispatcher on the main actor and the provider's stream.
final class AppleReplyGate: Sendable {
    private enum Phase {
        case open, shown, escalated
    }

    private let phase = OSAllocatedUnfairLock(initialState: Phase.open)

    /// True when reply text may be shown; the first true closes the gate to
    /// an escalation.
    func admitText() -> Bool {
        phase.withLock { phase in
            if phase == .open { phase = .shown }
            return phase == .shown
        }
    }

    /// True when the turn may escalate; the first true stops any further
    /// reply text.
    func claimEscalation() -> Bool {
        phase.withLock { phase in
            if phase == .open { phase = .escalated }
            return phase == .escalated
        }
    }

    /// Whether the turn has escalated.
    var hasEscalated: Bool {
        phase.withLock { $0 == .escalated }
    }
}
