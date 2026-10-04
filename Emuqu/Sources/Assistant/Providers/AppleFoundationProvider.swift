import Foundation
#if canImport(FoundationModels)
    import FoundationModels
#endif

/// On-device Apple Intelligence (iOS 26+).
///
/// Free, private, runs locally on Apple-Intelligence-capable hardware.
/// Hard limits: ~4K token context window, content guardrails that may
/// refuse health-adjacent queries. Use `compactRender()` of `AssistantContext`
/// when calling this provider.
final class AppleFoundationProvider: AIProvider {
    // MARK: - Static catalog

    static let model = ModelOption(
        providerID: .apple,
        apiID: "apple.foundation.on-device",
        displayName: "Apple Intelligence",
        blurb: "On-device · free · private",
        contextWindow: 4096,
        inputPricePerMTok: nil,
        outputPricePerMTok: nil,
        isDefault: true
    )

    // MARK: - AIProvider conformance

    let id: ProviderID = .apple
    var availableModels: [ModelOption] {
        [Self.model]
    }

    var requiresKey: Bool {
        false
    }

    var isAvailable: Bool {
        // Wrapped in keyboard-perf signpost so the
        // trace shows whether `SystemLanguageModel.default.availability`
        // is being hit on hot render paths and how long it costs.
        // Cached inside ProviderRegistry, but other call sites bypass
        // the cache; this measures every actual call.
        AppDependencies.current.app.keyboardPerfSignpost.interval("AppleFoundationProvider.isAvailable") {
            #if canImport(FoundationModels)
                if #available(iOS 26, *) {
                    return SystemLanguageModel.default.availability == .available
                }
            #endif
            return false
        }
    }

    /// Best-effort warmup: build a throwaway session and call its
    /// `prewarm()` so the KV-cache and tokenizer are resident by the
    /// time the user sends their first question. Cuts the perceived
    /// "first answer" latency on Quick / Auto routing modes from ~1.5s
    /// to ~300ms on A17/M-series. Idempotent — safe to call multiple
    /// times. Never blocks the caller; runs detached.
    static func prewarm() {
        #if canImport(FoundationModels)
            if #available(iOS 26, *) {
                guard SystemLanguageModel.default.availability == .available else { return }
                Task.detached(priority: .utility) {
                    let session = LanguageModelSession(instructions: "")
                    session.prewarm()
                }
            }
        #endif
    }

    // Session cache. The on-device Apple Foundation Model
    // pays a non-trivial warmup cost when a fresh `LanguageModelSession`
    // is created (instructions get tokenised, KV cache primed). Building
    // a new session on every `send` was the dominant source of perceived
    // slowness for "ask the AI" → "answer arrives" latency, especially
    // for follow-up questions where the user expects snappy turn-taking.
    //
    // The cache reuses one session across multiple sends as long as the
    // `instructions` haven't materially changed (the per-minute clock lines
    // `now_iso` and `local_date` are stripped before the equality check),
    // the tool set is the same, the previous reply came from this provider,
    // and we haven't exceeded `maxTurnsPerSession`. A reused session is sent
    // the current time with the user's message (see `prompt(from:isFresh:)`). Past the rotation cap
    // we recycle the session to bound KV-cache drift and keep the on-device
    // context window healthy. A failed send drops the session.
    #if canImport(FoundationModels)
        @available(iOS 26, *)
        private actor SessionCache {
            static let maxTurnsPerSession = 20
            private static let volatileLinePrefixes = ["- now_iso:", "- local_date:"]

            private var session: LanguageModelSession?
            private var instructionsSignature: String = ""
            private var toolSignature: String = ""
            private var turnsSinceCreation: Int = 0

            /// Get a session for the given instructions and tools.
            /// Returns `(session, isFresh)`. When `isFresh` is true
            /// the caller must send the full conversation transcript
            /// so the new session learns the prior turns. When false,
            /// the caller should send ONLY the latest user message —
            /// the existing session already remembers everything.
            ///
            /// `tools`
            /// flows through to `LanguageModelSession(tools:)` at
            /// construction time. The session signature includes a
            /// hash of the tool set so a tool-list change invalidates
            /// the cache (per-turn retrieval picks tools by the question,
            /// so a different question often means a fresh session).
            ///
            /// `previousReplyWasApple` is false when the turn before the
            /// new question was answered by another provider (Auto
            /// routing): the cached session never saw that exchange, so
            /// sending it only the latest question would drop it.
            ///
            /// The reuse path does not force-unwrap `session`. The
            /// `needsFresh` branch implies session is non-nil by then (its
            /// very first condition is `session == nil`), but force-unwrap is
            /// a spec finding. It binds defensively; if somehow nil we
            /// create a fresh one so we never crash and the conversation
            /// continues.
            func session(
                instructions: String,
                tools: [any Tool],
                toolCatalogHash: String,
                conversationLength: Int,
                previousReplyWasApple: Bool
            ) -> (LanguageModelSession, isFresh: Bool) {
                let sig = Self.signature(of: instructions)
                let needsFresh = session == nil
                    || sig != instructionsSignature
                    || toolCatalogHash != toolSignature
                    || turnsSinceCreation >= Self.maxTurnsPerSession
                    || conversationLength <= 1 // user cleared / first message of a new thread
                    || !previousReplyWasApple
                if needsFresh {
                    return (adopt(instructions: instructions, tools: tools, hash: toolCatalogHash), true)
                }
                turnsSinceCreation += 1
                if let existing = session { return (existing, false) }
                debugLog("[AppleFoundation] sessionCache: recovered nil session after needsFresh=false (unexpected); created fresh", level: .warning)
                return (adopt(instructions: instructions, tools: tools, hash: toolCatalogHash), true)
            }

            /// Build a session and make it the cached one.
            ///
            /// Apple's `LanguageModelSession` accepts a variadic-collection
            /// `tools:` parameter at init time per WWDC25 session 248. An
            /// empty array is the toolless mode (existing behaviour).
            private func adopt(
                instructions: String,
                tools: [any Tool],
                hash: String
            ) -> LanguageModelSession {
                let s = tools.isEmpty
                    ? LanguageModelSession(instructions: instructions)
                    : LanguageModelSession(tools: tools, instructions: instructions)
                session = s
                instructionsSignature = Self.signature(of: instructions)
                toolSignature = hash
                turnsSinceCreation = 1
                return s
            }

            /// Drop the session entirely (after a failed send, whose
            /// transcript may be the reason it failed). The next
            /// `session(...)` call will create a fresh one.
            func invalidate() {
                session = nil
                instructionsSignature = ""
                turnsSinceCreation = 0
            }

            /// Hash a signature that ignores volatile lines. Two calls
            /// 30 seconds apart with the same underlying app data should
            /// produce the same signature so the session reuses.
            private static func signature(of instructions: String) -> String {
                instructions
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { line in
                        // Drop the system prompt's clock lines, which change
                        // every minute. Other content already changes only
                        // when real app state changes (live workout, new
                        // archive entry) which IS a legitimate reason to
                        // rotate the session.
                        !volatileLinePrefixes.contains { line.hasPrefix($0) }
                    }
                    .joined(separator: "\n")
            }
        }

        @available(iOS 26, *)
        private static let sharedCache = SessionCache()

        /// Tokens the tool set may take of Apple's 4K window. Tools arrive
        /// ranked by relevance; the lowest-ranked are dropped past this.
        private static let toolTokenBudget = 1024
    #endif

    func send(
        messages: [ChatTurn],
        model _: ModelOption,
        contextRendered _: String,
        systemPrompt: String,
        tools: [ToolSpec],
        toolRounds _: [[ToolExchange]]
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
                if #available(iOS 26, *) {
                    Self.startAppleStream(
                        messages: messages,
                        systemPrompt: systemPrompt, tools: tools, continuation: continuation
                    )
                    return
                }
            #endif
            continuation.finish(throwing: AIProviderError.unsupportedOS(required: "iOS 26 with Apple Intelligence"))
        }
    }

    #if canImport(FoundationModels)
        @available(iOS 26, *)
        private static func startAppleStream(
            messages: [ChatTurn],
            systemPrompt: String,
            tools: [ToolSpec],
            continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
        ) {
            let task = Task {
                await streamAndFinish(
                    messages: messages,
                    systemPrompt: systemPrompt, tools: tools, continuation: continuation
                )
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    #endif

    #if canImport(FoundationModels)
        /// Run the stream and close the continuation, mapping a cancellation
        /// to `.cancelled` and any Foundation Models failure through
        /// `translate`.
        @available(iOS 26, *)
        private static func streamAndFinish(
            messages: [ChatTurn],
            systemPrompt: String,
            tools: [ToolSpec],
            continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
        ) async {
            do {
                try await runStream(
                    messages: messages,
                    systemPrompt: systemPrompt, tools: tools, continuation: continuation
                )
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: AIProviderError.cancelled)
            } catch {
                await sharedCache.invalidate()
                continuation.finish(throwing: translate(error))
            }
        }
    #endif

    // MARK: - Private (iOS 26+)

    #if canImport(FoundationModels)
        /// The instructions are Apple's own short prompt rebuilt from the
        /// composed one (`AssistantSystemPrompt.appleInstructions`): the shared
        /// prompt alone overflowed the 4K window. The composed prompt already
        /// carries the rendered data context under "# Current data", so
        /// `contextRendered` (the cloud live-state block, a subset of it) is
        /// not appended again.
        ///
        /// Verbatim
        /// compaction at 70% of Apple's 4K window. Without this,
        /// long voice sessions throw `.exceededContextWindowSize`
        /// on turn 12-15. CogCanvas (arxiv 2601.00821) reports
        /// verbatim deletion beats LLM-summary 19%→93% on
        /// fact-preservation in coaching dialog. The tool descriptions
        /// count against the same window: the tool set is cut to
        /// `toolTokenBudget` and its size is added to the fixed prefix the
        /// compactor budgets around.
        ///
        /// `GenerationOptions()` is the default set.
        @available(iOS 26, *)
        private static func runStream(
            messages: [ChatTurn],
            systemPrompt: String,
            tools allTools: [ToolSpec],
            continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
        ) async throws {
            let instructions = await MainActor.run { AssistantSystemPrompt.appleInstructions(fromComposed: systemPrompt) }
            let (tools, toolTokens) = fittingTools(allTools)
            let compacted = AppleContextCompactor.compactedPromptInput(
                messages: messages,
                systemPromptTokens: AppleContextCompactor.estimateTokens(instructions) + toolTokens
            )
            let toolCatalogHash = Self.hashToolCatalog(tools)
            let (session, isFresh) = await sharedCache.session(
                instructions: instructions, tools: appleTools(for: tools),
                toolCatalogHash: toolCatalogHash, conversationLength: compacted.count,
                previousReplyWasApple: compacted.dropLast().last?.providerID == .apple
            )
            debugLog("[AppleFoundation] session: \(tools.count)/\(allTools.count) tools, ~\(toolTokens) tokens, isFresh=\(isFresh)")
            let stream = session.streamResponse(
                to: prompt(from: compacted, isFresh: isFresh), options: GenerationOptions()
            )
            try await relay(stream, to: continuation)
            continuation.yield(.done)
        }

        /// The highest-ranked tools that fit `toolTokenBudget`, and their
        /// estimated token cost.
        @available(iOS 26, *)
        private static func fittingTools(_ tools: [ToolSpec]) -> (tools: [ToolSpec], tokens: Int) {
            var kept: [ToolSpec] = []
            var used = 0
            for spec in tools {
                let cost = AppleToolCatalog.estimatedTokens(for: spec)
                if used + cost > toolTokenBudget { break }
                kept.append(spec)
                used += cost
            }
            return (kept, used)
        }

        /// Wire the
        /// tool catalog through to `LanguageModelSession(tools:)`.
        /// Each `ToolSpec` becomes an `AppleToolAdapter` whose
        /// handler delegates to `AppDependencies.current.providers.appleToolDispatcher`,
        /// which reads the active `FactResolverRegistry` set by
        /// `AssistantViewModel.dispatch()` immediately before
        /// this send. An empty array means toolless mode (existing
        /// behaviour preserved when no tools are passed).
        @available(iOS 26, *)
        private static func appleTools(for tools: [ToolSpec]) -> [any Tool] {
            tools.map { spec in
                AppleToolCatalog.wrap(spec) { argsJSON in
                    try await AppDependencies.current.providers.appleToolDispatcher.dispatch(name: spec.name, argumentsJSON: argsJSON)
                }
            }
        }

        /// On a session-cache hit we send only the latest user turn — the
        /// session already remembers everything before it. On a miss we send
        /// the full transcript so the freshly-created session gets primed.
        ///
        /// A reused session keeps the instructions it was created with, whose
        /// clock lines can be hours old (the cache signature ignores them), so
        /// the turn carries the current time.
        private static func prompt(from messages: [ChatTurn], isFresh: Bool, now: Date = Date()) -> String {
            guard !isFresh else { return buildPrompt(from: messages) }
            let latest = messages.reversed().first(where: { $0.role == .user })?.text ?? ""
            let clock = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withInternetDateTime])
            return "(Current time: \(clock))\n\(latest)"
        }

        /// Apple emits cumulative snapshots — each event carries the full
        /// response so far. Pull the `.content` text out (NOT
        /// `String(describing:)`, which would dump the whole struct debug
        /// description) and yield the suffix relative to what we've already
        /// shown. A snapshot that isn't a continuation of the previous one is
        /// a replacement (rare) and gets yielded whole.
        @available(iOS 26, *)
        private static func relay(
            _ stream: some AsyncSequence<some Any, any Error>,
            to continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
        ) async throws {
            var previous = ""
            for try await snapshot in stream {
                try Task.checkCancellation()
                let text = Self.extractText(from: snapshot)
                let delta = text.hasPrefix(previous) ? String(text.dropFirst(previous.count)) : text
                if !delta.isEmpty { continuation.yield(.textDelta(delta)) }
                previous = text
            }
        }

        /// Pulls the cumulative text out of a Foundation Models stream snapshot.
        /// Snapshot types vary across SDK revisions; reflect on `.content` so we
        /// don't have to bind to a specific concrete type.
        @available(iOS 26, *)
        private static func extractText(from snapshot: Any) -> String {
            let mirror = Mirror(reflecting: snapshot)
            if let content = mirror.children.first(where: { $0.label == "content" })?.value as? String {
                return content
            }
            // Some SDK builds expose a plain String snapshot; others a wrapper.
            if let str = snapshot as? String {
                return str
            }
            // Last resort — better to show *something* than nothing.
            return String(describing: snapshot)
        }

        private static func buildPrompt(from messages: [ChatTurn]) -> String {
            // Render the conversation history as a transcript. The model continues
            // from the trailing "Assistant:" position when it sees a final "User:" turn.
            var lines: [String] = []
            for turn in messages {
                switch turn.role {
                case .user: lines.append("User: \(turn.text)")
                case .assistant: lines.append("Assistant: \(turn.text)")
                }
            }
            // Trailing newline cues the model to write the next assistant turn.
            return lines.joined(separator: "\n\n") + "\n\nAssistant:"
        }

        /// Hash the tool catalog so the SessionCache invalidates
        /// when the tool list changes (rare — happens once per app
        /// launch when the FactResolverRegistry is rebuilt). Uses
        /// the same JSON-sort discipline as the other cache layers:
        /// `[.sortedKeys]` keeps the hash stable across runs.
        @available(iOS 26, *)
        private static func hashToolCatalog(_ tools: [ToolSpec]) -> String {
            guard !tools.isEmpty else { return "empty" }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = attempt("appleFoundation.toolSchema.encode", { try encoder.encode(tools.sorted { $0.name < $1.name }) }) else {
                return "unknown"
            }
            return FactResolverRegistry.sha256Hex(data)
        }

        /// Maps a Foundation Models failure to the shared error enum by
        /// its `GenerationError` case. A refusal or guardrail block becomes
        /// `.guardrailViolation`, which drives cloud escalation; anything
        /// else that isn't a `GenerationError` is logged and reported as a
        /// generic failure.
        @available(iOS 26, *)
        private static func translate(_ error: Error) -> Error {
            guard let generationError = error as? LanguageModelSession.GenerationError else {
                debugLog("[AppleFoundation] generation failed: \(error)", level: .warning)
                return couldNotAnswer
            }
            let bundle = LanguageManager.appBundle
            switch generationError {
            case .guardrailViolation, .refusal:
                return AIProviderError.guardrailViolation
            case .rateLimited, .concurrentRequests:
                return AIProviderError.rateLimited
            case .assetsUnavailable:
                return AIProviderError.modelUnavailable(String(localized: "Apple Intelligence isn't ready on this device yet. Try again later, or add another model in Settings → Flo.", bundle: bundle))
            case .unsupportedLanguageOrLocale:
                return AIProviderError.modelUnavailable(String(localized: "Apple Intelligence doesn't support this language yet. Add another model in Settings → Flo.", bundle: bundle))
            default:
                debugLog("[AppleFoundation] generation failed: \(generationError)", level: .warning)
                return couldNotAnswer
            }
        }

        /// The framework's own text reached the chat as "The operation
        /// couldn't be completed. (FoundationModels.LanguageModelSession.
        /// GenerationError error -1.)", so a generic failure gets this instead.
        private static var couldNotAnswer: AIProviderError {
            .unknown(String(localized: "Apple Intelligence couldn't answer that. Try again, or ask it another way.", bundle: LanguageManager.appBundle))
        }
    #endif
}
