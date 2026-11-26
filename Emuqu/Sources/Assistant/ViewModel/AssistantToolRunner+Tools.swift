import Combine
import Foundation
import os.log
import SwiftUI

// The tool-use loop of a turn: dispatching the model's tool calls and feeding
// their results back.

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
    /// Real coaching turns rarely use more than 4–6 tools; a higher
    /// ceiling just gives misbehaving models room to
    /// wander. Eight covers every real coaching path from the list above and
    /// keeps pathological turns bounded at 8 × ~1 s.
    static let maxToolCallsPerTurn = 8

    /// The tools that change the user's data or the app's state: the
    /// MUTATION TOOLS of the system prompt's tool overlay, plus the artifact
    /// writes. A turn that ran one is not started over on another model.
    static let mutatingToolNames: Set<String> = [
        "routes_library_rename", "routes_library_save_workout", "routes_library_engage",
        "assistant_contacts_add", "assistant_contacts_remove", "assistant_email_compose",
        "assistant_memory_add", "assistant_memory_remove", "assistant_memory_clear", "assistant_memory_restore",
        "assistant_artifacts_add", "assistant_artifacts_update_status",
        "location_set_address", "directions_routeTo", "directions_clear"
    ]

    /// Whether `error` is the user's Stop: `CancellationError`, or
    /// `AIProviderError.cancelled` while the task is cancelled, which is how
    /// a provider stream reports the same Stop (`ProviderStream.failure`).
    static func isStop(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard case AIProviderError.cancelled? = error as? AIProviderError else { return false }
        return Task.isCancelled
    }

    /// Whether any resolved tool call so far was a mutating one.
    static func ranMutatingTool(_ toolRounds: [[ToolExchange]]) -> Bool {
        toolRounds.joined().contains { mutatingToolNames.contains($0.toolName) }
    }

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
    ///
    /// A failure that another model could answer, after this turn already ran
    /// a tool that changes something (`mutatingToolNames`), is not handed on:
    /// it is rethrown as `PickedModelFailure`, which no fallback catches. A
    /// fallback starts the turn over from the user's message and would run
    /// that tool again (a second contact, a second staged email, the route
    /// re-engaged).
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
            let done = try await runRoundKeepingActionsOnThisModel(
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

    /// `runOneRound`, with a failure another model could answer turned into
    /// `PickedModelFailure` once the turn has run a mutating tool (see
    /// `runToolUseLoop`).
    private func runRoundKeepingActionsOnThisModel(
        _ round: RoundContext,
        state: inout ToolLoopState,
        grokQuirks: inout GrokQuirkPolicy
    ) async throws -> Bool {
        do {
            return try await runOneRound(round, state: &state, grokQuirks: &grokQuirks)
        } catch let error as AIProviderError where error.isFallbackable && Self.ranMutatingTool(state.toolRounds) {
            throw PickedModelFailure(providerID: round.provider.id, underlying: error)
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
        try requireConsentForTools(of: round.provider)
        return try await recordResolutions(thisRound, factRegistry: round.factRegistry, state: &state)
    }

    /// Tool calls run only while the provider that asked for them still has
    /// data-sharing consent and is switched on. Web search, weather and
    /// route lookups send the model's arguments to outside services, so a
    /// withdrawal during the turn stops them as well as the next request.
    private func requireConsentForTools(of provider: AIProvider) throws {
        try Self.requireConsentForTools(of: provider.id, consent: owner.services.providerConsentTracker)
        guard owner.registry.isEnabled(provider.id) else {
            debugLog("[Assistant] tool calls not run — \(provider.id.rawValue) was switched off", level: .warning)
            throw AIProviderError.consentWithdrawn(provider.id)
        }
    }

    static func requireConsentForTools(of provider: ProviderID, consent: ProviderConsentTracker) throws {
        guard consent.requiresConsent(provider) else { return }
        debugLog("[Assistant] tool calls not run — \(provider.rawValue) has no data-sharing consent", level: .warning)
        throw AIProviderError.consentWithdrawn(provider)
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
        let liveState = await owner.contextSource.currentContext().renderLiveStateForCloud()
        let audit = owner.services.llmRequestAudit
        let sink: @Sendable (Data) -> Void = { body in Task { @MainActor in audit.setSentBody(body, for: auditID) } }
        let stream = ProviderRequestAudit.$sentBodySink.withValue(sink) {
            round.provider.send(
                messages: state.outbound, model: round.model, contextRendered: liveState,
                systemPrompt: round.systemPrompt, tools: round.tools, toolRounds: state.toolRounds
            )
        }
        var thisRound: [PendingToolCall] = []
        defer { buffer.flush(force: true, thisRoundIsEmpty: thisRound.isEmpty) }
        do {
            try await drain(stream, round: round, state: state, auditID: auditID, buffer: buffer, into: &thisRound)
        } catch {
            recordAuditFailure(error, auditID: auditID)
            throw error
        }
        return thisRound
    }

    /// Every event of one round's stream, through `handle`; throws on
    /// cancellation or a provider error.
    private func drain(
        _ stream: AsyncThrowingStream<AIStreamEvent, Error>,
        round: RoundContext,
        state: ToolLoopState,
        auditID: UUID,
        buffer: StreamTextBuffer,
        into thisRound: inout [PendingToolCall]
    ) async throws {
        for try await event in stream {
            try Task.checkCancellation()
            handle(
                event, provider: round.provider, auditID: auditID,
                budgetExhausted: state.budgetExhausted, buffer: buffer, thisRound: &thisRound
            )
        }
        try Task.checkCancellation()
    }

    /// A round the provider failed shows as "Failed" on the prompt-audit
    /// page (`LLMRequestAudit.setError`). A cancelled round is not a failure.
    private func recordAuditFailure(_ error: Error, auditID: UUID) {
        guard !(error is CancellationError), !Task.isCancelled else { return }
        let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        owner.services.llmRequestAudit.setError(description, for: auditID)
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
    /// The caller passes the live-state block (`renderLiveStateForCloud()`) to
    /// every provider round: today's and yesterday's recovery, HRV RMSSD and
    /// mean HR lines, plus — only while a workout is recording — the
    /// "📍 LOCATION:" line the system prompt tells the model to read. It is a
    /// few lines, not the heavy session dump, and it rides in the uncached
    /// `<live_state>` tail, keeping the Anthropic / Gemini prompt-prefix cache
    /// hot while giving the model the volatile data it's told to use.
    ///
    /// Privacy: the location line is emitted only while a workout is actively
    /// recording (LiveWorkoutBroker snapshot non-nil) — matching the
    /// ProviderConsentSheet disclosure. The recovery / HRV / HR lines go to the
    /// consented provider on every round.
    private func recordPromptAudit(
        provider: AIProvider,
        model: ModelOption,
        outbound: [ChatTurn],
        systemPrompt: String,
        tools: [ToolSpec],
        toolRounds: [[ToolExchange]]
    ) -> UUID {
        owner.services.llmRequestAudit.record(
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
            owner.services.llmRequestAudit.append(textDelta: chunk, to: auditID)
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
        owner.services.llmCacheTelemetry.record(
            provider: provider.id.rawValue, input: input, output: output,
            cachedRead: cached, cacheCreate: cacheCreate
        )
        owner.services.llmRequestAudit.setUsage(
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
    /// Chat did render it, but replacing is correct — the model itself threw
    /// it away by deciding to call a tool. Voice may already have spoken whole
    /// sentences of it (the buffer advances the cursor per sentence until the
    /// first tool_use arrives); the rewind pulls the cursor back so the next
    /// round is still spoken from its start.
    ///
    /// The number check runs after the rewind, on the text that stays.
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
    /// Runs on EVERY round-end, after the caller's rewind of a tool-use
    /// round, so it checks only the text that stays visible (a pre-tool-use
    /// lead-in has already been cut).
    ///
    /// Use the verifier's pre-built corrected text instead of
    /// splicing ranges here. The verifier matches against its own
    /// normalized text (spelled-out → digits), so splicing those ranges
    /// into the original would corrupt words mid-way. Its
    /// `correctedText` is the original text with only the claimed spans
    /// replaced, so we just swap the whole string.
    ///
    /// Resolve the live turn position by id so
    /// a shifted array (clear / regenerate / removal) can't make this
    /// verify-and-rewrite land on the wrong turn.
    ///
    /// Live-workout claims (HR, power, α1) are checked first, against the
    /// broker's snapshot (`MetricsVerifier.verify(_:againstLive:)`; nothing
    /// while no workout records), and the app-state pass runs on their
    /// corrected text.
    private func verifyAppStateNumbers(turnID: UUID) {
        guard let assistantIndex = owner.liveTurnIndex(for: turnID) else { return }
        let original = owner.turns[assistantIndex].text
        let live = MetricsVerifier.verify(original, againstLive: owner.services.liveWorkoutBroker.currentSnapshot())
        let text = MetricsVerifier.correctedText(from: original, applying: live) ?? original
        let result = MetricsVerifier.verifyAppStateClaims(text, against: owner.services.verifiedAppState)
        let discrepancies = live + result.discrepancies
        guard !discrepancies.isEmpty else { return }
        debugLog(MetricsVerifier.formatForLog(discrepancies), level: .warning)
        MetricsVerifier.recordCorrections(discrepancies)
        owner.turns[assistantIndex].text = result.correctedText ?? text
        owner.store.save(owner.turns)
    }

    /// Tool-resolution + budget stage of
    /// `runToolUseLoop`. Resolves each pending call through
    /// `CompactToolRouter` (or emits the budget / no-owner.registry missing
    /// envelope) and reports whether this round crossed the per-turn
    /// budget. The budget is per call: the calls that still fit under
    /// `maxToolCallsPerTurn` resolve, and only the ones past it (the 9th
    /// onward) get the budget-exceeded envelope.
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
        let budgetLeft = max(0, Self.maxToolCallsPerTurn - totalToolCalls)
        var exchanges: [ToolExchange] = []
        exchanges.reserveCapacity(thisRound.count)
        for (offset, pending) in thisRound.enumerated() {
            try Task.checkCancellation()
            exchanges.append(ToolExchange(
                toolUseID: pending.id,
                toolName: pending.name,
                inputJSON: pending.inputJSON,
                resultJSON: await resultJSON(for: pending, overBudget: offset >= budgetLeft, factRegistry: factRegistry)
            ))
        }
        return (exchanges, thisRound.count > budgetLeft)
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
    ///
    /// An empty assistant turn is removed. One that kept text is marked
    /// incomplete (`ChatTurn.incomplete`): the bubble says so, and history
    /// assembly leaves it out of the next request.
    func handleStreamFailure(error: Error, turnID: UUID) async {
        owner.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let index = owner.liveTurnIndex(for: turnID), owner.turns[index].role == .assistant {
            if owner.turns[index].text.isEmpty {
                owner.turns.remove(at: index)
            } else {
                owner.turns[index].incomplete = true
            }
        }
        owner.store.save(owner.turns)
    }

    /// How a fallback attempt ended. `tryFallbacks` moves on only past
    /// `.failed`, so a chain ends with the first other ending, or with
    /// `.failed` when every fallback failed.
    enum FallbackEnding {
        /// The fallback finished and left text in the turn.
        case answered
        /// The user stopped it.
        case stopped
        /// It ended the chain (its safety stop, or a failure after it ran a
        /// mutating tool); the error is shown.
        case blocked
        /// It failed; the next fallback may answer.
        case failed
    }

    /// Before a fallback re-runs the turn, take the failed provider's partial
    /// reply out of the bubble and return it, so the fallback's answer
    /// replaces it instead of following it. The speakable cursor goes back to
    /// the start with the text. Voice cannot unsay what it has already spoken,
    /// but it follows the cursor back, drops any unspoken tail of the
    /// fragment, and speaks the fallback's answer from its first sentence.
    /// Nil when the turn is gone. Does not save.
    private func setAsidePartialText(turnID: UUID) -> String? {
        guard let index = owner.liveTurnIndex(for: turnID) else { return nil }
        let partial = owner.turns[index].text
        owner.turns[index].text = ""
        owner.speakableTextCursor[turnID] = 0
        return partial
    }

    /// Settle the live turn once a fallback has run (`settle`), then save.
    /// Does nothing when the turn is gone.
    private func settleFallback(
        _ ending: FallbackEnding,
        failedPartial: String?,
        provider: AIProvider,
        model: ModelOption,
        turnID: UUID
    ) {
        guard let failedPartial, let index = owner.liveTurnIndex(for: turnID) else { return }
        Self.settle(&owner.turns[index], after: ending, failedPartial: failedPartial, providerID: provider.id, modelID: model.apiID)
        owner.store.save(owner.turns)
    }

    /// The reserved turn once a fallback has run. The failed provider's
    /// partial reply (`failedPartial`) was taken out of it first, so the
    /// bubble shows one answer under the badge of the provider that wrote it.
    ///
    /// - `.answered`: the fallback's answer stays and the badge is re-stamped
    ///   to the fallback. Without that the bubble would show "Apple
    ///   Intelligence" over text Claude wrote.
    /// - `.stopped`: the same when the fallback had shown text; otherwise the
    ///   partial reply comes back.
    /// - `.blocked`, `.failed`: the fallback's own partial text goes and the
    ///   partial reply comes back, under the badge it had.
    static func settle(
        _ turn: inout ChatTurn,
        after ending: FallbackEnding,
        failedPartial: String,
        providerID: ProviderID,
        modelID: String
    ) {
        let fallbackTextStands = switch ending {
        case .answered: true
        case .stopped: !AssistantViewModel.isEmptyAssistantTurn(turn)
        case .blocked, .failed: false
        }
        if fallbackTextStands {
            turn.providerID = providerID
            turn.modelID = modelID
        } else {
            turn.text = failedPartial
        }
    }

    /// A provider's default model, or its first if none is flagged default.
    private static func defaultModel(of provider: AIProvider) -> ModelOption? {
        provider.availableModels.first(where: { $0.isDefault }) ?? provider.availableModels.first
    }

    /// Build the ordered fallback list for the generic
    /// provider-failure path: a missing API key or credit moves the turn
    /// to the next provider.
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
    /// routed dispatch (send / appleVoiceBypass / midTier /
    /// auto-fact-extraction all do). Apple is consent-exempt, which is why it
    /// is appended as the tail rather than filtered in the loop. A provider
    /// switched off in Settings is skipped as well.
    func orderedFallbackProviders(after primary: AIProvider) -> [(AIProvider, ModelOption)] {
        var result: [(AIProvider, ModelOption)] = []
        for provider in owner.registry.allProviders
            where provider.id != primary.id && provider.id != .apple && provider.isAvailable
                && owner.registry.isEnabled(provider.id)
                && !owner.services.providerConsentTracker.requiresConsent(provider.id) {
            if let model = Self.defaultModel(of: provider) { result.append((provider, model)) }
        }
        if owner.registry.apple.isAvailable, primary.id != .apple,
           let appleModel = Self.defaultModel(of: owner.registry.apple) {
            result.append((owner.registry.apple, appleModel))
        }
        return result
    }

    /// Walk the fallback chain. Returns the first ending other than
    /// `.failed`: an answer, the user's Stop (which aborts the chain), or a
    /// fallback's safety stop, already shown. Each fallback's error is logged
    /// but NOT surfaced to the user; `.failed` means every fallback failed,
    /// and the caller then shows the original error.
    func tryFallbacks(
        _ chain: [(AIProvider, ModelOption)],
        outbound: [ChatTurn],
        tools: [ToolSpec],
        factRegistry: FactResolverRegistry?,
        turnID: UUID,
        voiceMode: Bool
    ) async -> FallbackEnding {
        for (provider, model) in chain {
            let ending = await runFallback(
                provider: provider, model: model, outbound: outbound, tools: tools,
                factRegistry: factRegistry, turnID: turnID, voiceMode: voiceMode
            )
            if ending != .failed { return ending }
        }
        return .failed
    }

    /// One link of the chain.
    ///
    /// The failed provider's partial reply is taken out of the bubble before
    /// the fallback runs (`setAsidePartialText`), so the fallback's answer
    /// replaces it instead of being appended to it, and it is put back when
    /// the fallback leaves nothing in its place (`settle`). On success the
    /// bubble's provider/model badge is re-stamped to the fallback: the badge
    /// is what the user reads in the chat transcript ("• Apple
    /// Intelligence"), and it MUST match where the visible text came from.
    /// A failed fallback never leaves its own partial text behind, and one
    /// that finishes with no text has not answered
    /// (`endingOfFinishedFallback`).
    private func runFallback(
        provider: AIProvider,
        model: ModelOption,
        outbound: [ChatTurn],
        tools: [ToolSpec],
        factRegistry: FactResolverRegistry?,
        turnID: UUID,
        voiceMode: Bool
    ) async -> FallbackEnding {
        let failedPartial = setAsidePartialText(turnID: turnID)
        do {
            try await runFallbackLoop(
                provider: provider, model: model, outbound: outbound, tools: tools,
                factRegistry: factRegistry, turnID: turnID, voiceMode: voiceMode
            )
            let ending = endingOfFinishedFallback(provider: provider, turnID: turnID)
            settleFallback(ending, failedPartial: failedPartial, provider: provider, model: model, turnID: turnID)
            return ending
        } catch let error where Self.isStop(error) {
            settleFallback(.stopped, failedPartial: failedPartial, provider: provider, model: model, turnID: turnID)
            return .stopped
        } catch {
            let ending = Self.ending(ofFailedFallback: error)
            settleFallback(ending, failedPartial: failedPartial, provider: provider, model: model, turnID: turnID)
            return await endFailedFallback(error, ending: ending, provider: provider, turnID: turnID)
        }
    }

    /// The fallback's own run: its system prompt, then the tool loop, which
    /// streams its answer into the reserved turn.
    ///
    /// Each fallback gets the history re-cut to ITS budget
    /// (`fallbackOutbound`), not the primary's: an Apple primary's 1,200-token
    /// window would otherwise starve a cloud fallback.
    private func runFallbackLoop(
        provider: AIProvider,
        model: ModelOption,
        outbound: [ChatTurn],
        tools: [ToolSpec],
        factRegistry: FactResolverRegistry?,
        turnID: UUID,
        voiceMode: Bool
    ) async throws {
        let supportsTools = !tools.isEmpty && provider.id != .apple
        let prompt = await fallbackSystemPrompt(provider: provider, supportsTools: supportsTools, voiceMode: voiceMode)
        debugLog("[Assistant] fallback → \(provider.id.rawValue):\(model.apiID)")
        try await runToolUseLoop(
            provider: provider, model: model,
            outbound: fallbackOutbound(for: provider, turnID: turnID, primaryOutbound: outbound), systemPrompt: prompt,
            tools: supportsTools ? tools : [],
            factRegistry: supportsTools ? factRegistry : nil, turnID: turnID
        )
    }

    /// `.answered` for a fallback whose tool loop finished, or `.failed` when
    /// it left the reserved turn empty: an empty reply is no answer, so the
    /// next fallback may give one and, if none does, the primary's error is
    /// shown over its partial reply.
    private func endingOfFinishedFallback(provider: AIProvider, turnID: UUID) -> FallbackEnding {
        guard let index = owner.liveTurnIndex(for: turnID),
              AssistantViewModel.isEmptyAssistantTurn(owner.turns[index]) else { return .answered }
        debugLog("[Assistant] fallback \(provider.id.rawValue) came back empty")
        return .failed
    }

    /// `.blocked` for a safety stop (`AIProviderError.isBlockedReply`) and for
    /// a failure after the fallback ran a mutating tool (`PickedModelFailure`,
    /// from `runToolUseLoop`), `.failed` for any other error a fallback threw.
    private static func ending(ofFailedFallback error: Error) -> FallbackEnding {
        if error is PickedModelFailure { return .blocked }
        guard let providerError = error as? AIProviderError, providerError.isBlockedReply else { return .failed }
        return .blocked
    }

    /// A fallback that threw (`ending` is `.blocked` or `.failed`), once its
    /// own partial text has gone and the failed provider's partial reply is
    /// back. A safety stop ends the chain as the primary's would: it is shown
    /// through `handleStreamFailure`, which marks that partial reply
    /// incomplete, so the request is never sent on to the next vendor. A
    /// failure after the fallback ran a mutating tool ends it the same way,
    /// so the next fallback does not run that tool again. Any other failure
    /// is logged, and `.failed` moves on to the next fallback.
    private func endFailedFallback(
        _ error: Error,
        ending: FallbackEnding,
        provider: AIProvider,
        turnID: UUID
    ) async -> FallbackEnding {
        guard ending == .blocked else {
            debugLog("[Assistant] fallback \(provider.id.rawValue) also failed: \(error.localizedDescription)")
            return .failed
        }
        debugLog("[Assistant] fallback \(provider.id.rawValue) ended the chain: \(error.localizedDescription)")
        await handleStreamFailure(error: error, turnID: turnID)
        return .blocked
    }

    /// The history before the reserved turn, truncated to `provider`'s own
    /// token budget. Falls back to the primary's outbound when the reserved
    /// turn is gone (cleared / regenerated mid-turn).
    private func fallbackOutbound(for provider: AIProvider, turnID: UUID, primaryOutbound: [ChatTurn]) -> [ChatTurn] {
        guard let index = owner.liveTurnIndex(for: turnID) else { return primaryOutbound }
        return AssistantViewModel.truncateForSend(Array(owner.turns[..<index]), provider: provider.id).kept
    }

    /// Each fallback gets its own composed system prompt — Apple
    /// wants compactRender, paid providers want the full tool-use
    /// shape. Match the renderer to the provider.
    ///
    /// `voiceMode` is captured at `dispatch()` entry and threaded in;
    /// `nextSendIsVoice` has been cleared by the time we reach here so reading
    /// it would silently lose the voice-brevity overlay.
    ///
    /// Composed by the main dispatch path's own
    /// `AssistantTurnRouter.composeSystemPromptForTurn`, so the composer's
    /// `UserCorrectionDetector` reads the same recent user messages.
    private func fallbackSystemPrompt(
        provider: AIProvider,
        supportsTools: Bool,
        voiceMode: Bool
    ) async -> String {
        let contextRendered = await fallbackContextRender(provider: provider, supportsTools: supportsTools)
        return await owner.router.composeSystemPromptForTurn(
            rendered: contextRendered, voiceMode: voiceMode, toolMode: supportsTools
        )
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
        if owner.actionConfirmations.showPending(in: &owner.turns) { owner.store.save(owner.turns) }

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
