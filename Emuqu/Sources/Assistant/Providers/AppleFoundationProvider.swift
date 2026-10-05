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
    // we haven't exceeded `maxTurnsPerSession`, and the session's ledger
    // (`AppleContextCompactor.SessionLedger`) says the follow-up still fits
    // the 4K window beside everything the session already holds. A reused
    // session is sent the current time with the user's message (see
    // `prompt(from:isFresh:)`). Otherwise the cache starts a fresh session,
    // which is sent the compacted transcript. A failed send drops the session.
    #if canImport(FoundationModels)
        /// What a send asks of the session cache.
        @available(iOS 26, *)
        private struct SessionRequest {
            let instructions: String
            let tools: [any Tool]
            let toolCatalogHash: String
            /// Turns in the transcript a fresh session would be sent.
            let conversationLength: Int
            let previousReplyWasApple: Bool
            /// Estimated tokens of the instructions and tool descriptions.
            let prefixTokens: Int
            /// Estimated tokens of the prompt a reused session would be sent.
            let followUpPromptTokens: Int
            let perCallCap: Int
        }

        /// The session a send uses. `followUpToolBudget` is what tool calls
        /// and results may take on a reused session; nil on a fresh one,
        /// whose budget comes from the turn plan.
        @available(iOS 26, *)
        private struct SessionLease {
            let session: LanguageModelSession
            let isFresh: Bool
            let followUpToolBudget: Int?
        }

        @available(iOS 26, *)
        private actor SessionCache {
            static let maxTurnsPerSession = 20
            private static let volatileLinePrefixes = ["- now_iso:", "- local_date:"]

            private var session: LanguageModelSession?
            private var instructionsSignature: String = ""
            private var toolSignature: String = ""
            private var turnsSinceCreation: Int = 0
            private var ledger = AppleContextCompactor.SessionLedger(prefixTokens: 0)

            /// A session for the request. When the lease is fresh the caller
            /// must send the compacted transcript so the new session learns
            /// the prior turns. When it is reused, the caller sends ONLY the
            /// latest user message, the existing session already remembers
            /// everything, and tool results get `followUpToolBudget`.
            ///
            /// The tools flow through to `LanguageModelSession(tools:)` at
            /// construction time, and their hash is part of the signature, so
            /// a tool-list change starts a fresh session.
            ///
            /// `previousReplyWasApple` is false when the turn before the new
            /// question was answered by another provider (Auto routing): the
            /// cached session never saw that exchange.
            func lease(for request: SessionRequest) -> SessionLease {
                let budget = ledger.followUpToolBudget(
                    promptTokens: request.followUpPromptTokens, perCallCap: request.perCallCap
                )
                if let existing = session, let budget, canReuse(for: request) {
                    turnsSinceCreation += 1
                    return SessionLease(session: existing, isFresh: false, followUpToolBudget: budget)
                }
                if session != nil, budget == nil, canReuse(for: request) {
                    debugLog("[AppleFoundation] sessionCache: ~\(ledger.usedTokens) tokens held; starting a fresh session for the follow-up")
                }
                return SessionLease(session: adopt(request), isFresh: true, followUpToolBudget: nil)
            }

            /// Charges a finished turn to the ledger of the session that ran
            /// it, if that session is still the cached one.
            func record(
                _ used: LanguageModelSession, promptTokens: Int, toolTokens: Int, replyTokens: Int
            ) {
                guard used === session else { return }
                ledger.charge(promptTokens: promptTokens, toolTokens: toolTokens, replyTokens: replyTokens)
            }

            /// Whether everything but the window allows reusing the session.
            private func canReuse(for request: SessionRequest) -> Bool {
                Self.signature(of: request.instructions) == instructionsSignature
                    && request.toolCatalogHash == toolSignature
                    && turnsSinceCreation < Self.maxTurnsPerSession
                    && request.conversationLength > 1 // not the first message of a new thread
                    && request.previousReplyWasApple
            }

            /// Build a session and make it the cached one.
            ///
            /// Apple's `LanguageModelSession` accepts a variadic-collection
            /// `tools:` parameter at init time per WWDC25 session 248. An
            /// empty array is the toolless mode.
            private func adopt(_ request: SessionRequest) -> LanguageModelSession {
                let s = request.tools.isEmpty
                    ? LanguageModelSession(instructions: request.instructions)
                    : LanguageModelSession(tools: request.tools, instructions: request.instructions)
                session = s
                instructionsSignature = Self.signature(of: request.instructions)
                toolSignature = request.toolCatalogHash
                turnsSinceCreation = 1
                ledger = AppleContextCompactor.SessionLedger(prefixTokens: request.prefixTokens)
                return s
            }

            /// Drop the session entirely (after a failed send, whose
            /// transcript may be the reason it failed). The next
            /// `lease(for:)` call will create a fresh one.
            func invalidate() {
                session = nil
                instructionsSignature = ""
                turnsSinceCreation = 0
                ledger = AppleContextCompactor.SessionLedger(prefixTokens: 0)
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
        /// `translate`. Either drops the cached session.
        @available(iOS 26, *)
        private static func streamAndFinish(
            messages: [ChatTurn],
            systemPrompt: String,
            tools: [ToolSpec],
            continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
        ) async {
            do {
                try await runAttempts(
                    messages: messages,
                    systemPrompt: systemPrompt, tools: tools, continuation: continuation
                )
                continuation.finish()
            } catch is CancellationError {
                // The session may hold part of the cancelled reply, which its
                // ledger never saw.
                await sharedCache.invalidate()
                continuation.finish(throwing: AIProviderError.cancelled)
            } catch {
                await sharedCache.invalidate()
                continuation.finish(throwing: translate(error))
            }
        }
    #endif

    // MARK: - Private (iOS 26+)

    #if canImport(FoundationModels)
        /// Run the turn as `.full`; when that overflows Apple's window before
        /// any reply text reached the user, drop the session and run it once
        /// more as `.trimmed`. An overflow after text was shown is not retried:
        /// a second answer would be appended to the first.
        @available(iOS 26, *)
        private static func runAttempts(
            messages: [ChatTurn],
            systemPrompt: String,
            tools: [ToolSpec],
            continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
        ) async throws {
            var attempt = AppleContextCompactor.Attempt.full
            while let next = try await runAttempt(
                attempt, messages: messages, systemPrompt: systemPrompt, tools: tools, continuation: continuation
            ) {
                attempt = next
            }
        }

        /// One attempt. Returns the attempt to retry with after a context
        /// overflow, or nil when the turn finished.
        @available(iOS 26, *)
        private static func runAttempt(
            _ attempt: AppleContextCompactor.Attempt,
            messages: [ChatTurn],
            systemPrompt: String,
            tools: [ToolSpec],
            continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
        ) async throws -> AppleContextCompactor.Attempt? {
            do {
                let turnPlan = await makePlan(messages: messages, systemPrompt: systemPrompt, tools: tools, attempt: attempt)
                try await runStream(turnPlan, continuation: continuation)
                return nil
            } catch where isContextOverflow(error) {
                guard let next = attempt.afterOverflow else { throw error }
                debugLog("[AppleFoundation] context overflow on the \(attempt) attempt; retrying \(next) on a fresh session", level: .warning)
                await sharedCache.invalidate()
                return next
            }
        }

        /// Everything one attempt sends: the instructions, the tools that fit,
        /// the transcript, and what tool results may take.
        private struct TurnPlan {
            let instructions: String
            let tools: [ToolSpec]
            let transcript: [ChatTurn]
            let allowance: AppleContextCompactor.ToolOutputAllowance
            let toolTokens: Int
            /// Estimated tokens of the instructions and the tool descriptions.
            let prefixTokens: Int
            let allToolCount: Int
        }

        /// The instructions are Apple's own short prompt rebuilt from the
        /// composed one (`AssistantSystemPrompt.appleInstructions`): the shared
        /// prompt alone overflowed the 4K window. The composed prompt already
        /// carries the rendered data context under "# Current data", so
        /// `contextRendered` (the cloud live-state block, a subset of it) is
        /// not appended again.
        ///
        /// Verbatim compaction at 70% of Apple's 4K window. Without this,
        /// long voice sessions throw `.exceededContextWindowSize` on turn
        /// 12-15. CogCanvas (arxiv 2601.00821) reports verbatim deletion
        /// beats LLM-summary 19%→93% on fact-preservation in coaching dialog.
        /// The tool descriptions count against the same window: the tool set
        /// is cut to the attempt's `toolTokenBudget` and its size is added to
        /// the fixed prefix the compactor budgets around. Tool results get
        /// what is left after the reply's reserve (`toolOutputBudget`). These
        /// sizes hold for a fresh session; a reused one is sized from its
        /// ledger instead (`runStream`).
        @available(iOS 26, *)
        private static func makePlan(
            messages: [ChatTurn],
            systemPrompt: String,
            tools allTools: [ToolSpec],
            attempt: AppleContextCompactor.Attempt
        ) async -> TurnPlan {
            let composed = await MainActor.run { AssistantSystemPrompt.appleInstructions(fromComposed: systemPrompt) }
            let instructions = AppleContextCompactor.truncate(
                composed, toTokens: attempt.instructionTokenCap, note: AppleContextCompactor.instructionsCutNote
            )
            let (tools, toolTokens) = fittingTools(allTools, budget: attempt.toolTokenBudget)
            let fixedTokens = AppleContextCompactor.estimateTokens(instructions) + toolTokens
            let transcript = attempt.keepsHistory
                ? AppleContextCompactor.compactedPromptInput(messages: messages, systemPromptTokens: fixedTokens)
                : Array(messages.suffix(1))
            let budget = AppleContextCompactor.toolOutputBudget(
                fixedTokens: fixedTokens, transcriptTokens: AppleContextCompactor.transcriptTokens(transcript)
            )
            let allowance = AppleContextCompactor.ToolOutputAllowance(remaining: budget, perCallCap: attempt.toolOutputCap)
            return TurnPlan(
                instructions: instructions, tools: tools, transcript: transcript,
                allowance: allowance, toolTokens: toolTokens, prefixTokens: fixedTokens, allToolCount: allTools.count
            )
        }

        /// Leases a session, hands the tool-result allowance to the
        /// dispatcher, streams the reply, and charges the turn to the
        /// session's ledger. A fresh session gets the plan's transcript and
        /// allowance; a reused one gets the latest question and what its
        /// ledger has left.
        @available(iOS 26, *)
        private static func runStream(
            _ plan: TurnPlan,
            continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
        ) async throws {
            let followUp = prompt(from: plan.transcript, isFresh: false)
            let lease = await sharedCache.lease(for: request(for: plan, followUp: followUp))
            let promptText = lease.isFresh ? prompt(from: plan.transcript, isFresh: true) : followUp
            let allowance = lease.followUpToolBudget.map {
                AppleContextCompactor.ToolOutputAllowance(remaining: $0, perCallCap: plan.allowance.perCallCap)
            } ?? plan.allowance
            let dispatcher = await MainActor.run { AppDependencies.current.providers.appleToolDispatcher }
            await dispatcher.setToolOutputAllowance(allowance)
            debugLog("[AppleFoundation] session: \(plan.tools.count)/\(plan.allToolCount) tools ~\(plan.toolTokens) tokens, prefix ~\(plan.prefixTokens), tool results ≤\(allowance.remaining), isFresh=\(lease.isFresh)")
            let stream = lease.session.streamResponse(to: promptText, options: replyOptions)
            let reply = try await relay(stream, to: continuation)
            let toolTokens = await dispatcher.toolTokensSpent
            await sharedCache.record(
                lease.session, promptTokens: AppleContextCompactor.estimateTokens(promptText),
                toolTokens: toolTokens, replyTokens: AppleContextCompactor.estimateTokens(reply)
            )
            continuation.yield(.done)
        }

        /// What the plan asks of the session cache. `followUp` is the prompt
        /// a reused session would be sent.
        @available(iOS 26, *)
        private static func request(for plan: TurnPlan, followUp: String) -> SessionRequest {
            SessionRequest(
                instructions: plan.instructions, tools: appleTools(for: plan.tools),
                toolCatalogHash: hashToolCatalog(plan.tools), conversationLength: plan.transcript.count,
                previousReplyWasApple: plan.transcript.dropLast().last?.providerID == .apple,
                prefixTokens: plan.prefixTokens,
                followUpPromptTokens: AppleContextCompactor.estimateTokens(followUp),
                perCallCap: plan.allowance.perCallCap
            )
        }

        /// Caps the reply at the reserve the turn budget keeps for it, so a
        /// long answer cannot run past the window after it began streaming.
        @available(iOS 26, *)
        private static var replyOptions: GenerationOptions {
            GenerationOptions(maximumResponseTokens: AppleContextCompactor.responseReserve)
        }

        /// The highest-ranked tools that fit `budget`, and their estimated
        /// token cost. Tools arrive ranked by relevance; the lowest-ranked
        /// are dropped.
        @available(iOS 26, *)
        private static func fittingTools(_ tools: [ToolSpec], budget: Int) -> (tools: [ToolSpec], tokens: Int) {
            var kept: [ToolSpec] = []
            var used = 0
            for spec in tools {
                let cost = AppleToolCatalog.estimatedTokens(for: spec)
                if used + cost > budget { break }
                kept.append(spec)
                used += cost
            }
            return (kept, used)
        }

        /// True for Foundation Models' context-window overflow, the one
        /// failure a smaller second attempt can fix.
        @available(iOS 26, *)
        private static func isContextOverflow(_ error: Error) -> Bool {
            guard let generationError = error as? LanguageModelSession.GenerationError,
                  case .exceededContextWindowSize = generationError else { return false }
            return true
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
        ///
        /// Returns the whole reply. A failure after text was yielded comes out
        /// as `FailedAfterOutput`, so `runAttempts` does not retry it.
        @available(iOS 26, *)
        private static func relay(
            _ stream: some AsyncSequence<some Any, any Error>,
            to continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
        ) async throws -> String {
            var previous = ""
            do {
                for try await snapshot in stream {
                    try Task.checkCancellation()
                    previous = yieldDelta(Self.extractText(from: snapshot), after: previous, to: continuation)
                }
                return previous
            } catch {
                if previous.isEmpty || error is CancellationError { throw error }
                throw FailedAfterOutput(underlying: error)
            }
        }

        /// Yields what `text` adds to `previous` and returns `text`. A snapshot
        /// that doesn't extend the last one is yielded whole.
        private static func yieldDelta(
            _ text: String,
            after previous: String,
            to continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
        ) -> String {
            let delta = text.hasPrefix(previous) ? String(text.dropFirst(previous.count)) : text
            if !delta.isEmpty { continuation.yield(.textDelta(delta)) }
            return text
        }

        /// A stream failure after part of the reply reached the user.
        private struct FailedAfterOutput: Error {
            let underlying: Error
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
        /// `.guardrailViolation`, which is shown as it is and never sent on
        /// to another provider; anything else that isn't a `GenerationError`
        /// is logged and reported as a generic failure, which the chat may
        /// hand to another provider.
        @available(iOS 26, *)
        private static func translate(_ error: Error) -> Error {
            if let partial = error as? FailedAfterOutput { return translate(partial.underlying) }
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
