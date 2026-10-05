import Foundation

/// Bridge between Apple's
/// `LanguageModelSession(tools:)` mechanism and our existing
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
/// the cloud providers' consent sheet discloses (Apple has none), so it is
/// refused here. Calls go through the existing CompactToolRouter, which
/// honors the same `MedicalQueryGuard` perimeter the rest of the app uses.
///
/// **Budget.** The same per-turn tool-call limit as the cloud tool loop
/// (`AssistantToolRunner.maxToolCallsPerTurn`), counted from each
/// `setRegistry` call, which starts a turn, and from each
/// `setToolOutputAllowance` call, which starts an attempt at it. Every result
/// also passes through the attempt's `ToolOutputAllowance`, which cuts it to
/// what Apple's 4K window has left: tool results arrive mid-generation, after
/// the transcript was sized, and uncapped ones overflowed the window. The calls
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
    /// What tool results may still take of Apple's window this attempt.
    private var outputAllowance = AppleContextCompactor.ToolOutputAllowance.unsized
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
    /// typed errors back to the model anyway.
    func dispatch(name: String, argumentsJSON: String) async throws -> String {
        guard let registry = currentRegistry else {
            return #"{"error":"tool dispatcher has no registry — call setRegistry before invoking the model","tool":"\#(name)"}"#
        }
        outputAllowance.charge(name + argumentsJSON)
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

    /// Counts the call, and returns why it may not run: a tool Apple's path
    /// does not offer, or a spent per-turn budget.
    private func refusal(for name: String) -> FactValue? {
        if Self.refusedTools.contains(name) {
            return .missing(reason: .invalidParameter, detail: "web search isn't available on the on-device model")
        }
        callsThisTurn += 1
        guard callsThisTurn > AssistantToolRunner.maxToolCallsPerTurn else { return nil }
        return .missing(reason: .rateLimited, detail: "tool budget exceeded for this turn — answer with what you have")
    }
}
