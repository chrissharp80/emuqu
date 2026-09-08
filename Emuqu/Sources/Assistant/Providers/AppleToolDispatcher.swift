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
/// **Privacy.** Stays on-device. The dispatcher only forwards calls
/// to the existing CompactToolRouter, which honors the same
/// `MedicalQueryGuard` perimeter the rest of the app uses.
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

    private init() {}

    /// Stash a registry for the upcoming Apple session. Called from
    /// `AssistantViewModel.dispatch()` immediately before
    /// `provider.send(...)` when the resolved provider is Apple.
    func setRegistry(_ registry: FactResolverRegistry?) {
        currentRegistry = registry
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
        let router = CompactToolRouter(registry: registry)
        let value = await router.resolveTool(name: name, argsJSON: argumentsJSON)
        // `FactValue.toToolResultJSON()` renders the same envelope
        // the cloud providers see when they get a tool result back
        // (`{"value": …, "missingReason": …}`), keeping wire-shape
        // parity between Apple and the cloud providers.
        return value.toToolResultJSON()
    }
}
