import Combine
import Foundation
import os.log
import SwiftUI

// Split out of AssistantViewModel.swift to keep the primary FILE under the
// 1500-line budget, and off the TYPE (which is what the aggregate type-size
// gate measures) for the same reason as the RRCollector and WorkoutRecorder
// coordinator splits: ~800 lines reading 26 view-model members. The reads are
// `owner.` and countable instead of looking like this type's own state.

extension AssistantToolRunner {
    // MARK: - Tool-use dispatch loop

    /// Hard cap on tool calls per user turn. Stops runaway loops (a
    /// misbehaving model that keeps retrying a failing resolver) and keeps
    /// worst-case round-trip latency bounded.
    ///
    /// Coaching-context queries commonly need: workout.live.snapshot +
    /// historical_baseline + today_readiness + race_predictions + per-route
    /// history + recent splits + sport baseline + a comparison call. A cap of
    /// four forces the model to either bundle weakly via composites or skip
    /// data it should have fetched.
    ///
    /// Each round = one full HTTP round trip to the provider (~800–2000 ms).
    /// Real coaching turns rarely use more than 4–6 tools (the longest in the
    /// wild was 6); a higher ceiling just gives misbehaving models room to
    /// wander. Eight covers every real coaching path from the list above and
    /// keeps pathological turns bounded at 8 × ~1 s.
    static let maxToolCallsPerTurn = 8

    /// Accumulator for a single tool_use seen during one streaming round.
    struct PendingToolCall {
        let id: String
        let name: String
        let inputJSON: String
    }

    /// Run the provider.send / resolve-tools / provider.send … loop until
    /// the model stops asking for tools or we hit the budget. Text deltas
    /// from every round accumulate into the same assistant turn so the user
    /// sees one continuous answer regardless of how many internal tool hops
    /// happened.
    ///
    /// Grok-only quirk handling (the announce-but-don't-call retry counter and
    /// the end-of-turn fallback substitution) lives in `GrokQuirkPolicy`
    /// (`GrokQuirkPolicy.swift`). The substitution runs only on a normal
    /// finish: a thrown failure leaves the turn to the fallback chain or the
    /// error banner.
    ///
    /// The policy receives the stable turn id (not a positional index) so it
    /// resolves the live turn at flush time.
    func runToolUseLoop(
        provider: AIProvider,
        model: ModelOption,
        outbound: [ChatTurn],
        systemPrompt: String,
        tools: [ToolSpec],
        factRegistry: FactResolverRegistry?,
        turnID: UUID
    ) async throws {
        var state = ToolLoopState(outbound: outbound)
        var grokQuirks = GrokQuirkPolicy(owner: owner, provider: provider, turnID: turnID)
        while true {
            // Honor Stop between rounds — without this, hitting Stop between
            // a tool_result and the next send() still proceeds to the next
            // round because async for-in loops don't auto-throw on cancel.
            try Task.checkCancellation()
            let done = try await runOneRound(
                RoundContext(
                    provider: provider, model: model, systemPrompt: systemPrompt,
                    tools: tools, factRegistry: factRegistry, turnID: turnID
                ),
                state: &state, grokQuirks: &grokQuirks
            )
            if done {
                grokQuirks.substituteFallbackIfTurnEndedBlankOrAnnounced()
                return
            }
        }
    }

    /// Everything the tool loop carries between rounds.
    ///
    /// `budgetExhausted`: after we feed back a budget-exceeded result, the
    /// next `send()` is ALLOWED one more pass for the model to compose a final
    /// text answer — but we drop any further tool_use blocks on the floor and
    /// force-exit so a misbehaving model can't loop us to death.
    private struct ToolLoopState {
        var outbound: [ChatTurn]
        var toolRounds: [[ToolExchange]] = []
        var totalToolCalls = 0
        var budgetExhausted = false
    }

    /// The parts of a tool-loop round that don't change between rounds.
    private struct RoundContext {
        let provider: AIProvider
        let model: ModelOption
        let systemPrompt: String
        let tools: [ToolSpec]
        let factRegistry: FactResolverRegistry?
        let turnID: UUID
    }

    /// One round of the loop. Returns true when the loop should stop.
    ///
    /// The round-local text buffer snapshots the round-start text length (for
    /// the pre-tool-use rewind) and owns the 33 ms publish throttle and the
    /// speakable-cursor advance. See `StreamTextBuffer` (`AssistantViewModel+Context.swift`).
    /// The buffer resolves the live turn by id, not by position.
    ///
    /// The post-budget pass is a one-shot: the model spoke its closing text,
    /// so we exit regardless of whether it tried more tools.
    ///
    /// An empty round normally means the model is done — but we guard against
    /// the announce-but-don't-do pattern before exiting, see `GrokQuirkPolicy`
    /// (`GrokQuirkPolicy.swift`).
    private func runOneRound(
        _ round: RoundContext,
        state: inout ToolLoopState,
        grokQuirks: inout GrokQuirkPolicy
    ) async throws -> Bool {
        let buffer = StreamTextBuffer(owner: owner, turnID: round.turnID)
        let thisRound = try await consumeStreamRound(round, state: state, buffer: buffer)
        applyRoundEndTextPolicy(
            thisRound: thisRound, budgetExhausted: state.budgetExhausted,
            buffer: buffer, turnID: round.turnID
        )
        if state.budgetExhausted { return true }
        if thisRound.isEmpty {
            guard let nudge = grokQuirks.announceWithoutCallNudge(outbound: state.outbound, buffer: buffer)
            else { return true }
            state.outbound.append(nudge)
            return false
        }
        return try await recordResolutions(thisRound, factRegistry: round.factRegistry, state: &state)
    }

    /// Resolve this round's tool calls into `state` and report whether the
    /// loop should stop (it never should here — resolution always feeds
    /// another round).
    private func recordResolutions(
        _ thisRound: [PendingToolCall],
        factRegistry: FactResolverRegistry?,
        state: inout ToolLoopState
    ) async throws -> Bool {
        let resolution = try await resolveToolCalls(
            thisRound: thisRound, totalToolCalls: state.totalToolCalls, factRegistry: factRegistry
        )
        state.toolRounds.append(resolution.exchanges)
        state.totalToolCalls += thisRound.count
        if resolution.overBudget { state.budgetExhausted = true }
        return false
    }

    // MARK: - Tool-loop stages

    /// Stream-consumption stage of
    /// `runToolUseLoop`. One provider round-trip: audit-record the
    /// request, open the stream, and consume events until it ends.
    /// Text deltas flow through `buffer`; returns the tool calls the
    /// model requested this round.
    ///
    /// The per-event cancel check is explicit: `for try await` alone does NOT
    /// throw CancellationError on `Task.cancel()` — Apple's AsyncSequence docs
    /// say to iterate manually (or check in the body) if you need early exit.
    /// Without it, the Stop button would wait for the provider's stream to
    /// drain naturally before firing, which can be seconds.
    ///
    /// The closing flush is forced so tail chunks that arrived within the
    /// last 33 ms before the stream completed still land. Without it the user
    /// can lose the final word or two of the response while the throttle
    /// window is still pending.
    ///
    /// That flush is a `defer`, not a trailing statement.
    /// The buffer deliberately withholds an incomplete sentence so the FDA
    /// output perimeter can judge it (see `StreamTextBuffer.takePublishableText`),
    /// which means that on a mid-stream throw — provider error, or the user
    /// pressing Stop — a straight-line flush is never reached and the held
    /// tail is discarded. The user sees a reply that stops one sentence
    /// earlier than the one they were actually sent. `defer` flushes on every
    /// exit path and exactly once; it also covers the cancellation check, which
    /// can throw past a trailing flush.
    ///
    /// A round that produced no text still publishes nothing — `flush` returns
    /// early on an empty buffer — so `handleStreamFailure` still sees an empty
    /// turn to remove when the stream failed before the first delta.
    private func consumeStreamRound(
        _ round: RoundContext,
        state: ToolLoopState,
        buffer: StreamTextBuffer
    ) async throws -> [PendingToolCall] {
        let auditID = recordPromptAudit(
            provider: round.provider, model: round.model, outbound: state.outbound,
            systemPrompt: round.systemPrompt, tools: round.tools, toolRounds: state.toolRounds
        )
        let stream = round.provider.send(
            messages: state.outbound, model: round.model,
            contextRendered: await owner.contextSource.currentContext().renderLiveStateForCloud(),
            systemPrompt: round.systemPrompt, tools: round.tools, toolRounds: state.toolRounds
        )
        var thisRound: [PendingToolCall] = []
        defer { buffer.flush(force: true, thisRoundIsEmpty: thisRound.isEmpty) }
        for try await event in stream {
            try Task.checkCancellation()
            handle(
                event, provider: round.provider, auditID: auditID,
                budgetExhausted: state.budgetExhausted, buffer: buffer, thisRound: &thisRound
            )
        }
        try Task.checkCancellation()
        return thisRound
    }

    /// Prompt audit. Capture the inputs we're
    /// about to hand the provider BEFORE the per-provider
    /// transforms (cache marker stripping, `<live_state>`
    /// splice, Anthropic block-form encoding). That gives us a
    /// provider-agnostic record of "what did we ask?" which is
    /// the question users actually have when an answer looks
    /// off ("did the AI even know I just walked 2 miles?").
    /// In-memory FIFO of 10; surfaced in Settings →
    /// Troubleshooting → AI prompt audit.
    ///
    /// The caller passes the live-state location block to cloud providers;
    /// an empty `contextRendered` would mean the model never sees the
    /// "📍 LOCATION:" line that the system prompt instructs it to read ("AI
    /// has no awareness of my location"). `renderLiveStateForCloud()` emits
    /// ONLY the location (not the heavy session dump), keeping the Anthropic /
    /// Gemini prompt-prefix cache hot while giving the model the volatile data
    /// it's told to use.
    ///
    /// Privacy: that location line is emitted only
    /// while a workout is actively recording (LiveWorkoutBroker snapshot
    /// non-nil) — matching the ProviderConsentSheet disclosure. Outside a
    /// workout the render returns "" and no `<live_state>` block is spliced.
    private func recordPromptAudit(
        provider: AIProvider,
        model: ModelOption,
        outbound: [ChatTurn],
        systemPrompt: String,
        tools: [ToolSpec],
        toolRounds: [[ToolExchange]]
    ) -> UUID {
        AppDependencies.current.providers.llmRequestAudit.record(
            provider: provider.id.rawValue,
            model: model.apiID,
            systemPrompt: systemPrompt,
            messagesJSON: AssistantViewModel.auditEncodeMessages(outbound, toolRounds: toolRounds),
            toolsJSON: AssistantViewModel.auditEncodeTools(tools)
        )
    }

    /// One stream event: text into the buffer, tool calls into `thisRound`,
    /// usage into telemetry.
    ///
    /// after cancellation, late tool_use chunks must be dropped
    /// before they reach the resolver. Response discard is a filter, not a
    /// guarantee the bytes stop arriving — chunks can trickle in after
    /// `cancel()` returns, so we drop them here.
    private func handle(
        _ event: AIStreamEvent,
        provider: AIProvider,
        auditID: UUID,
        budgetExhausted: Bool,
        buffer: StreamTextBuffer,
        thisRound: inout [PendingToolCall]
    ) {
        switch event {
        case let .textDelta(chunk):
            buffer.append(chunk: chunk, thisRoundIsEmpty: thisRound.isEmpty)
            AppDependencies.current.providers.llmRequestAudit.append(textDelta: chunk, to: auditID)
        case let .toolUse(id, name, inputJSON):
            guard !budgetExhausted, !Task.isCancelled else { return }
            thisRound.append(PendingToolCall(id: id, name: name, inputJSON: inputJSON))
        case let .usage(input, output, cached, cacheCreate):
            recordUsage(
                provider: provider, auditID: auditID,
                input: input, output: output, cached: cached, cacheCreate: cacheCreate
            )
        case .done:
            break
        }
    }

    /// Cache-hit telemetry: log the
    /// ratio so cache regressions are visible. >0.8 is the
    /// healthy turn-2+ target; lower means the prefix
    /// changed and every turn is paying full inference cost.
    /// Catalog-version bumps, session start, and provider-
    /// side TTL expiry are legit reasons to miss — they
    /// show as low cacheRead + high cacheCreate on
    /// Anthropic; the initial warm-up. Subsequent owner.turns
    /// should hit.
    ///
    /// Also feed `AppDependencies.current.providers.llmCacheTelemetry` so the
    /// Settings → Troubleshooting → AI cache health
    /// card has rolling counters (not just a debug
    /// log line that scrolls past).
    ///
    /// The denominator is total prompt size, not `input` alone. Provider APIs
    /// report `input_tokens` as ONLY the uncached billed portion; total
    /// processed = input + cache_read + cache_create. Dividing by `input`
    /// alone produces >100% values.
    private func recordUsage(
        provider: AIProvider,
        auditID: UUID,
        input: Int,
        output: Int,
        cached: Int,
        cacheCreate: Int
    ) {
        let totalProcessed = input + cached + cacheCreate
        let hitRatio = totalProcessed > 0 ? Double(cached) / Double(totalProcessed) : 0
        debugLog("[Assistant] usage \(provider.id.rawValue): input=\(input) output=\(output) cached=\(cached) cacheCreate=\(cacheCreate) hit_ratio=\(String(format: "%.2f", hitRatio))")
        AppDependencies.current.providers.llmCacheTelemetry.record(
            provider: provider.id.rawValue, input: input, output: output,
            cachedRead: cached, cacheCreate: cacheCreate
        )
        AppDependencies.current.providers.llmRequestAudit.setUsage(
            .init(
                inputTokens: input, outputTokens: output,
                cachedReadTokens: cached, cacheCreateTokens: cacheCreate
            ),
            for: auditID
        )
    }

    /// Round-end text-policy stage of
    /// `runToolUseLoop`: speakable-cursor advance (text-only rounds),
    /// pre-tool-use rewind (tool rounds), then the MetricsVerifier
    /// hallucination guard.
    ///
    /// A round that ended text-only (no tool_use) advances the voice
    /// speakable cursor to the full current text length; voice TTS then
    /// flushes any buffered text up through there. Post-budget final text
    /// counts as text-only for cursor purposes: the model spoke its closing
    /// line, so it's safe to read.
    ///
    /// A round that had tool_use rewinds any pre-tool-use text the model
    /// emitted ("Based on your data…" before actually resolving the data).
    /// Voice hasn't spoken it yet (the cursor wasn't advanced); chat did
    /// render it, but replacing is correct — the model itself threw it away by
    /// deciding to call a tool.
    private func applyRoundEndTextPolicy(
        thisRound: [PendingToolCall],
        budgetExhausted: Bool,
        buffer: StreamTextBuffer,
        turnID: UUID
    ) {
        if thisRound.isEmpty || budgetExhausted {
            buffer.advanceSpeakableCursorToCurrentEnd()
        } else {
            buffer.rewindToRoundStart()
        }
        verifyAppStateNumbers(turnID: turnID)
    }

    /// Hallucination guard for app-state numbers (TSB / ATL /
    /// CTL / RMSSD / recovery score). The voice path runs the
    /// existing live-workout-metrics guard separately;
    /// text-mode (chat) needs its own guard, otherwise fabricated
    /// TSB-swing claims reach the chat surface unchallenged.
    /// Runs on EVERY round-end —
    /// even mid-tool-loop, so a fabricated number in the
    /// pre-tool-use "based on your data…" lead-in gets caught
    /// before the tool result lands. The caller's rewind for tool-use rounds
    /// runs AFTER this so corrected text doesn't get clobbered.
    ///
    /// Use the verifier's pre-built corrected text instead of
    /// splicing ranges here. The verifier matches against its own
    /// normalized text (spelled-out → digits), so splicing those ranges
    /// into the original produced mid-word corruption. Its
    /// `correctedText` is the original text with only the claimed spans
    /// replaced, so we just swap the whole string.
    ///
    /// Resolve the live turn position by id so
    /// a shifted array (clear / regenerate / removal) can't make this
    /// verify-and-rewrite land on the wrong turn.
    private func verifyAppStateNumbers(turnID: UUID) {
        guard let assistantIndex = owner.liveTurnIndex(for: turnID) else { return }
        let result = MetricsVerifier.verifyAppStateClaims(owner.turns[assistantIndex].text)
        guard !result.discrepancies.isEmpty else { return }
        debugLog(MetricsVerifier.formatForLog(result.discrepancies), level: .warning)
        MetricsVerifier.recordCorrections(result.discrepancies)
        guard let corrected = result.correctedText else { return }
        owner.turns[assistantIndex].text = corrected
        owner.store.save(owner.turns)
    }

    /// Tool-resolution + budget stage of
    /// `runToolUseLoop`. Resolves each pending call through
    /// `CompactToolRouter` (or emits the budget / no-owner.registry missing
    /// envelope) and reports whether this round crossed the per-turn
    /// budget.
    ///
    /// Resolver cancellation rule: check `Task.isCancelled`
    /// before dispatching resolver work and between each resolve so a
    /// batch of parallel tool calls doesn't keep running after the
    /// user has moved on. Resolvers are cheap closures (microseconds)
    /// but the check keeps the contract honest for future heavier
    /// implementations that might hit the archive or network.
    private func resolveToolCalls(
        thisRound: [PendingToolCall],
        totalToolCalls: Int,
        factRegistry: FactResolverRegistry?
    ) async throws -> (exchanges: [ToolExchange], overBudget: Bool) {
        try Task.checkCancellation()
        let overBudget = (totalToolCalls + thisRound.count) > Self.maxToolCallsPerTurn
        var exchanges: [ToolExchange] = []
        exchanges.reserveCapacity(thisRound.count)
        for pending in thisRound {
            try Task.checkCancellation()
            exchanges.append(ToolExchange(
                toolUseID: pending.id,
                toolName: pending.name,
                inputJSON: pending.inputJSON,
                resultJSON: await resultJSON(for: pending, overBudget: overBudget, factRegistry: factRegistry)
            ))
        }
        return (exchanges, overBudget)
    }

    /// One tool call's result envelope.
    ///
    /// Over budget and no-owner.registry both emit the same envelope shape the
    /// owner.registry uses, so the model sees one consistent absence format
    /// end-to-end.
    ///
    /// Otherwise the call routes through `CompactToolRouter` so the
    /// polymorphic tool names (`get_session`, `get_today`, etc.) the model
    /// sees in the schema can be translated back to the underlying
    /// fact-catalog keys. Action tools and `lookup_fact` flow through to the
    /// owner.registry.
    ///
    /// resolveTool is async. Sync facts still
    /// resolve inline (microseconds); the `.awaitable` ones (web search,
    /// HealthKit, geo) suspend this loop instead of parking the main thread
    /// behind a semaphore bridge.
    private func resultJSON(
        for pending: PendingToolCall,
        overBudget: Bool,
        factRegistry: FactResolverRegistry?
    ) async -> String {
        if overBudget {
            return FactValue.missing(
                reason: .rateLimited, detail: "tool budget exceeded for this turn"
            ).toolResultJSON
        }
        guard let registry = factRegistry else {
            return FactValue.missing(reason: .internalError, detail: "no resolver registered").toolResultJSON
        }
        let router = CompactToolRouter(registry: registry)
        return await router.resolveTool(name: pending.name, argsJSON: pending.inputJSON).toolResultJSON
    }

    /// Resolve the live turn position by id so a
    /// failure removal can't delete the wrong (shifted) turn.
    func handleStreamFailure(error: Error, turnID: UUID) async {
        owner.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let index = owner.liveTurnIndex(for: turnID),
           owner.turns[index].role == .assistant, owner.turns[index].text.isEmpty {
            owner.turns.remove(at: index)
        }
        owner.store.save(owner.turns)
    }

    /// Rewrite the assistant turn's provider/model
    /// badge after a fallback or escalation answers from a different
    /// provider than the one originally selected. Without this, the
    /// chat bubble shows "Apple Intelligence" even when Claude
    /// actually produced the response. The visible badge must match
    /// the visible text.
    /// Resolve the live turn position by id so the
    /// badge rewrite lands on the turn we actually filled, not a shifted
    /// neighbor.
    func rewriteAssistantTurnProvider(
        turnID: UUID,
        providerID: ProviderID,
        modelID: String
    ) {
        guard let index = owner.liveTurnIndex(for: turnID) else { return }
        owner.turns[index].providerID = providerID
        owner.turns[index].modelID = modelID
        owner.store.save(owner.turns)
    }

    /// Before a fallback or escalation re-runs the turn, cut the failed
    /// provider's partial reply back to what voice has already spoken (the
    /// speakable cursor; nothing when the cursor was never advanced), so the
    /// new answer does not read as the old fragment followed by a fresh reply.
    private func discardUnspokenPartialText(turnID: UUID) {
        guard let index = owner.liveTurnIndex(for: turnID) else { return }
        let spoken = owner.speakableTextCursor[turnID] ?? 0
        owner.turns[index].text = String(owner.turns[index].text.prefix(spoken))
    }

    /// A provider's default model, or its first if none is flagged default.
    private static func defaultModel(of provider: AIProvider) -> ModelOption? {
        provider.availableModels.first(where: { $0.isDefault }) ?? provider.availableModels.first
    }

    /// Build the ordered fallback list for the generic
    /// provider-failure path. The user's spec: "if I don't have an
    /// API key or credit then it should move to the next one."
    /// Order:
    ///   1. Other configured non-Apple providers (the user paid for
    ///      these too — try them before falling to free)
    ///   2. Apple Intelligence (always last — it's the free fallback,
    ///      and routing to it without user intent is fine here
    ///      because the user already saw their primary fail)
    /// `after` is excluded so we don't re-try the just-failed provider.
    ///
    /// Never falls back to a cloud the user hasn't consented to for PHI — the
    /// generic failure path honours the same per-provider consent gate as the
    /// routed dispatch (send / voiceBypassDecision / midTier /
    /// auto-fact-extraction all do). Apple is consent-exempt, which is why it
    /// is appended as the tail rather than filtered in the loop. A provider
    /// switched off in Settings is skipped as well.
    func orderedFallbackProviders(after primary: AIProvider) -> [(AIProvider, ModelOption)] {
        var result: [(AIProvider, ModelOption)] = []
        for provider in owner.registry.allProviders
            where provider.id != primary.id && provider.id != .apple && provider.isAvailable
                && ProviderRegistry.isEnabled(provider.id)
                && !AppDependencies.current.providers.providerConsentTracker.requiresConsent(provider.id) {
            if let model = Self.defaultModel(of: provider) { result.append((provider, model)) }
        }
        if owner.registry.apple.isAvailable, primary.id != .apple,
           let appleModel = Self.defaultModel(of: owner.registry.apple) {
            result.append((owner.registry.apple, appleModel))
        }
        return result
    }

    /// Walk the fallback chain. Returns true on the
    /// first success. Cancellation aborts the chain (treated as
    /// success — user intent is "stop"). Each fallback's error is
    /// logged but NOT surfaced to the user; only the original
    /// caller's error gets surfaced if every fallback also fails.
    func tryFallbacks(
        _ chain: [(AIProvider, ModelOption)],
        outbound: [ChatTurn],
        tools: [ToolSpec],
        factRegistry: FactResolverRegistry?,
        turnID: UUID,
        voiceMode: Bool
    ) async -> Bool {
        for (provider, model) in chain {
            let handled = await runFallback(
                provider: provider, model: model, outbound: outbound, tools: tools,
                factRegistry: factRegistry, turnID: turnID, voiceMode: voiceMode
            )
            if handled { return true }
        }
        return false
    }

    /// One link of the chain. True when it answered (or the user cancelled).
    ///
    /// On success, re-stamp the bubble's provider/model badge to
    /// reflect the actual answering provider rather than the one originally
    /// selected. The badge is what the user reads in the chat transcript ("•
    /// Apple Intelligence"); it MUST match where the visible text came from.
    private func runFallback(
        provider: AIProvider,
        model: ModelOption,
        outbound: [ChatTurn],
        tools: [ToolSpec],
        factRegistry: FactResolverRegistry?,
        turnID: UUID,
        voiceMode: Bool
    ) async -> Bool {
        let supportsTools = !tools.isEmpty && provider.id != .apple
        let prompt = await fallbackSystemPrompt(
            provider: provider, supportsTools: supportsTools, voiceMode: voiceMode
        )
        do {
            debugLog("[Assistant] fallback → \(provider.id.rawValue):\(model.apiID)")
            discardUnspokenPartialText(turnID: turnID)
            try await runToolUseLoop(
                provider: provider, model: model, outbound: outbound, systemPrompt: prompt,
                tools: supportsTools ? tools : [],
                factRegistry: supportsTools ? factRegistry : nil, turnID: turnID
            )
            rewriteAssistantTurnProvider(turnID: turnID, providerID: provider.id, modelID: model.apiID)
            return true
        } catch is CancellationError {
            return true // user-cancelled — treat as resolved
        } catch {
            debugLog("[Assistant] fallback \(provider.id.rawValue) also failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Each fallback gets its own composed system prompt — Apple
    /// wants compactRender, paid providers want the full tool-use
    /// shape. Match the renderer to the provider.
    ///
    /// `voiceMode` is captured at `dispatch()` entry and threaded in;
    /// `nextSendIsVoice` has been cleared by the time we reach here so reading
    /// it would silently lose the voice-brevity overlay.
    ///
    /// Same recent-user-messages pass as the main dispatch path
    /// so the composer's `UserCorrectionDetector` can read correction signals.
    private func fallbackSystemPrompt(
        provider: AIProvider,
        supportsTools: Bool,
        voiceMode: Bool
    ) async -> String {
        let contextRendered = await fallbackContextRender(provider: provider, supportsTools: supportsTools)
        AssistantSystemPrompt.pendingRecentUserMessages = owner.turns.suffix(6)
            .filter { $0.role == .user }
            .map(\.text)
        let prompt = await AssistantSystemPrompt.compose(
            userFacts: owner.snapshotUserFacts(),
            priorSummary: owner.priorSummary,
            contextRendered: contextRendered,
            compactAppReference: true,
            voiceMode: voiceMode,
            toolMode: supportsTools
        )
        AssistantSystemPrompt.pendingRecentUserMessages = []
        return prompt
    }

    /// Match the main dispatch path: cloud providers
    /// skip compactRender (tools deliver the data); only Apple
    /// gets the rendered dump because it has a tighter context
    /// window and benefits from being pre-briefed. Without this,
    /// a fallback from Apple → cloud pays the compactRender
    /// tax twice (once at the originally-attempted Apple turn,
    /// again on every cloud fallback) AND blows the Anthropic
    /// prompt cache by feeding the dynamic dump into the system
    /// prompt instead of `<live_state>` in the user message.
    ///
    /// A no-tools fallback can be a CLOUD provider; ambient
    /// street-level location goes to the cloud only during an active workout
    /// (disclosure-matched gate, same rule as `renderLiveStateForCloud`).
    /// Apple keeps it: the render never leaves the device there.
    private func fallbackContextRender(provider: AIProvider, supportsTools: Bool) async -> String {
        guard !supportsTools else { return "" }
        let ctx = await owner.contextSource.currentContext()
        return ctx.compactRender(includeAmbientLocation: provider.id == .apple || ctx.liveWorkout != nil)
    }

    /// Three-state outcome so the caller can distinguish
    /// "escalation succeeded" from "escalation attempted but failed
    /// (its error message is already on screen)" from "couldn't even
    /// try escalation (caller should surface the original error)."
    /// A `Bool?` would collapse the second and third cases into
    /// `false`, causing the caller to OVERWRITE the inner failure's
    /// message with the original Apple guardrail message — masking
    /// the actually-actionable problem ("OpenAI auth failed: bad key")
    /// behind the unhelpful "Apple safety filter blocked" copy.
    enum EscalationOutcome {
        case succeeded
        case attemptedAndFailed
        case notAttempted
    }

    /// Only Apple guardrails escalate. The target is the Deep-tier mapping,
    /// which is the user's selected provider: when a cloud model is selected
    /// and routing sent this turn to Apple, the same turn is re-sent to that
    /// cloud model under the full system prompt, content rules included. When
    /// Apple itself is the selected provider the mapping collapses to Apple,
    /// nothing is attempted and the refusal stands: Apple's answer is not
    /// retried in a form built to get past its filter.
    func escalateOnAppleRefusal(
        failedProvider: AIProvider,
        outbound: [ChatTurn],
        systemPrompt: String,
        tools: [ToolSpec],
        factRegistry: FactResolverRegistry?,
        turnID: UUID,
        voiceMode: Bool
    ) async -> EscalationOutcome {
        guard failedProvider.id == .apple else { return .notAttempted }
        let mapping = TierProviderMapper.mapping(for: .deep, registry: owner.registry)
        if mapping.provider.id == .apple || !mapping.provider.isAvailable
            || !ProviderRegistry.isEnabled(mapping.provider.id) {
            return .notAttempted
        }
        debugLog("[Assistant] Auto-escalating Apple guardrail → \(mapping.provider.id.rawValue):\(mapping.model.apiID)")
        return await runEscalatedTurn(
            mapping: mapping,
            outbound: outbound,
            systemPrompt: await escalationSystemPrompt(supportsTools: !tools.isEmpty, voiceMode: voiceMode),
            tools: tools,
            factRegistry: factRegistry,
            turnID: turnID
        )
    }

    /// Rebuild the system prompt for the escalation provider's tool-use mode.
    /// Apple was no-tools (compactRender path); the paid provider supports
    /// tools. The existing renderer composes either shape.
    ///
    /// Recent user messages are handed to the composer's
    /// correction detector, then cleared.
    ///
    /// Escalation always targets a cloud provider, so the
    /// ambient-location line obeys the workout-only disclosure gate.
    private func escalationSystemPrompt(supportsTools: Bool, voiceMode: Bool) async -> String {
        AssistantSystemPrompt.pendingRecentUserMessages = owner.turns.suffix(6)
            .filter { $0.role == .user }
            .map(\.text)
        let context = await owner.contextSource.currentContext()
        let prompt = await AssistantSystemPrompt.compose(
            userFacts: owner.snapshotUserFacts(),
            priorSummary: owner.priorSummary,
            contextRendered: context.compactRender(includeAmbientLocation: context.liveWorkout != nil),
            compactAppReference: false,
            voiceMode: voiceMode,
            toolMode: supportsTools
        )
        AssistantSystemPrompt.pendingRecentUserMessages = []
        return prompt
    }

    /// Re-run the turn against the escalation provider.
    ///
    /// On success, re-stamp the bubble's badge to reflect the
    /// escalation provider (Claude / OpenAI / etc.) instead of "Apple
    /// Intelligence."
    ///
    /// A cancellation mid-escalation counts as success: the user asked us to
    /// stop, so neither error should surface. A genuine escalation-provider
    /// failure (auth, rate limit, bad model id, network) surfaces INSTEAD of
    /// the original Apple guardrail — it's the actionable one ("Authentication
    /// failed. Check your API key.").
    private func runEscalatedTurn(
        mapping: TierProviderMapper.Mapping,
        outbound: [ChatTurn],
        systemPrompt: String,
        tools: [ToolSpec],
        factRegistry: FactResolverRegistry?,
        turnID: UUID
    ) async -> EscalationOutcome {
        do {
            discardUnspokenPartialText(turnID: turnID)
            try await runToolUseLoop(
                provider: mapping.provider, model: mapping.model, outbound: outbound,
                systemPrompt: systemPrompt, tools: tools,
                factRegistry: factRegistry, turnID: turnID
            )
            rewriteAssistantTurnProvider(
                turnID: turnID, providerID: mapping.provider.id, modelID: mapping.model.apiID
            )
            return .succeeded
        } catch is CancellationError {
            return .succeeded
        } catch {
            await handleStreamFailure(error: error, turnID: turnID)
            return .attemptedAndFailed
        }
    }

    /// Mark a stream as finished. The `generation` arg lets us no-op when
    /// an OLD stream's tear-down arrives after a newer send has already
    /// started — without this guard, the stale tear-down would set
    /// `owner.isStreaming = false` and `owner.streamTask = nil`, dropping the user's
    /// new in-flight request from the view-model's bookkeeping.
    /// Also drains any message that was queued by `send(text:)` while the
    /// stream was in flight, so a follow-up the user typed/spoke during
    /// the previous response doesn't get lost.
    func finishStream(generation: Int) async {
        guard generation == owner.streamGeneration else {
            debugLog("[Assistant] finishStream skipped — stream gen \(generation) is stale (current=\(owner.streamGeneration))")
            return
        }
        owner.isStreaming = false
        owner.streamTask = nil

        // Drain queued send. We move it to a local first because dispatch()
        // will bump owner.streamGeneration / reset owner.isStreaming on its own; if it
        // re-enters this same path on failure, we don't want to loop on the
        // same queued message.
        if let pending = owner.pendingSendOnFinish {
            owner.pendingSendOnFinish = nil
            debugLog("[Assistant] draining queued send: \(pending.text.count) chars")
            owner.send(text: pending.text, fromVoice: pending.fromVoice)
        }
    }
}
