import Foundation

// Conversation summarization, token-aware truncation, auto-fact extraction and
// the announce-but-don't-call detector, split out of
// `AssistantViewModel+Tools.swift`. These shape what the model is
// *given*; the tool-use dispatch loop left behind acts on what it returns.

extension AssistantViewModel {
    // MARK: - Conversation summarization

    /// Generates a short summary of the dropped turns, merged with any existing
    /// summary, and stores it as the new `priorSummary`. Called inline before
    /// the actual user message is sent so the next response benefits.
    /// Bounded — never blocks more than ~5 seconds; on failure we keep going
    /// without a summary update. Better to lose a bit of context than block
    /// the user's actual question.
    func updateSummaryWith(
        droppedTurns: [ChatTurn],
        provider: AIProvider,
        model: ModelOption,
        contextRendered _: String
    ) async {
        let stream = provider.send(
            messages: [ChatTurn(role: .user, text: summarizationPrompt(droppedTurns))],
            model: model,
            contextRendered: "",
            systemPrompt: Self.summarizerSystem
        )
        // Bound at 5 seconds — summarization is best-effort.
        guard let collected = await Self.collect(stream, timeoutSec: 5) else { return }
        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        summarizedThroughTurnID = droppedTurns.last?.id
        priorSummary = trimmed
        UserDefaults.standard.set(trimmed, forKey: Self.summaryKey)
    }

    /// The dropped turns not yet folded into `priorSummary`. `dropped` is
    /// every turn older than the send window, so without this each send past
    /// the budget would re-summarise the same turns.
    func unsummarizedTurns(in dropped: [ChatTurn]) -> [ChatTurn] {
        guard let marker = summarizedThroughTurnID,
              let index = dropped.firstIndex(where: { $0.id == marker }) else { return dropped }
        return Array(dropped[(index + 1)...])
    }

    /// Use a tight system prompt for summarization — don't pull in the data
    /// context.
    private static let summarizerSystem = """
        You compress chat history with a clear pruning bias toward what survives the conversation: bugs, decisions, user preferences, medical / training facts. You DROP transient telemetry (HR, pace, grade, location, weather) since the user has live \
        tools for that. Output the summary text ONLY, no preamble, no markdown.
        """

    /// The compression instruction, with the existing summary and the dropped
    /// turns folded in.
    private func summarizationPrompt(_ droppedTurns: [ChatTurn]) -> String {
        let merged = priorSummary.map { "Previous summary:\n\($0)\n\nNew turns to fold in:\n" }
            ?? "Turns to summarize:\n"
        // Filtered again here, not only in `truncateForSend`.
        //
        // Summarisation is a SECOND way a turn's content reaches a provider,
        // and a policy enforced only at the caller is a policy that survives
        // exactly until someone adds a third caller. `truncateForSend` already
        // withholds these from `dropped`; this makes the guarantee local to the
        // function that builds the outbound text.
        let droppedText = droppedTurns
            .filter { !$0.localOnly }
            .map { ($0.role == .user ? "User: " : "Assistant: ") + $0.text }
            .joined(separator: "\n\n")
        return merged + droppedText + "\n\n" + Self.summarizationInstruction
    }

    /// The fixed tail of the summarization prompt — byte-stable across turns.
    private static let summarizationInstruction = """
    Write a single concise paragraph (≤120 words) capturing what the user shared, \
    what they asked about, and what the assistant advised. Plain text only — no \
    headings, no markdown.

    **PRUNING RULES (Feature 4, bug list 2026-05-05):**
    - DROP stale live telemetry: specific HR values, pace numbers, grade percentages, \
      GPS coordinates, road names, weather readings. The user's app has live tools \
      for those — they're not worth carrying in summary.
    - PRESERVE persistent content: bug reports the user mentioned, feature requests, \
      decisions ("we decided to keep coherence breathing"), preferences ("user dislikes \
      terracotta button color"), open questions, anything the user explicitly said to \
      remember.
    - PRESERVE user-stated medical / training context: injuries, illness, medications, \
      training goals, race dates. These outlive the conversation.
    - Note when the user said "save this as a bug" or "add this feature" — those \
      should be tracked via assistant.artifacts.add (long-term store), but mention \
      them in the summary so the next conversation starts informed.
    """

    // MARK: - Token-aware truncation

    /// Approximate token budget for conversation history per provider.
    /// Reserves headroom for system prompt + data context + response.
    static func conversationTokenBudget(for provider: ProviderID) -> Int {
        switch provider {
        case .apple: 1200 // ~1.2K of history; rest goes to context + response
        case .deepseek: 60000 // 128K window, generous history budget
        case .anthropic, .openai, .gemini, .grok:
            80000 // 200K-2M windows, plenty of room
        }
    }

    /// Drop oldest turns until the remaining bytes fit the provider's token budget.
    /// Returns `(kept, dropped)` so the caller can summarize the dropped tail.
    /// History to send, trimmed to the provider's budget. Always keeps the
    /// most recent turn (the user's pending question).
    ///
    /// Local-only turns are withheld first, so they cannot consume budget and
    /// are never reported as `dropped` — `dropped` feeds summarisation, which
    /// is a second outbound path. See `ChatTurn.localOnly`. Empty assistant
    /// turns (a stopped or blocked reply) are withheld too: Anthropic and
    /// Gemini reject an empty assistant message.
    static func truncateForSend(
        _ turns: [ChatTurn],
        provider: ProviderID
    ) -> (kept: [ChatTurn], dropped: [ChatTurn]) {
        let budget = conversationTokenBudget(for: provider)

        let turns = turns.filter { !$0.localOnly && !isEmptyAssistantTurn($0) }
        guard !turns.isEmpty else { return ([], []) }

        // Walk from newest to oldest, accumulating tokens. Stop when we'd exceed.
        var kept: [ChatTurn] = []
        var totalTokens = 0
        for turn in turns.reversed() {
            let cost = estimateTokens(turn.text) + 4 // +4 for role/separator overhead
            if totalTokens + cost > budget, !kept.isEmpty {
                break
            }
            kept.insert(turn, at: 0)
            totalTokens += cost
        }
        let droppedCount = turns.count - kept.count
        let dropped = droppedCount > 0 ? Array(turns.prefix(droppedCount)) : []
        return (kept, dropped)
    }

    /// An assistant turn with no visible text: a reply stopped before its
    /// first token or blocked with no content.
    static func isEmptyAssistantTurn(_ turn: ChatTurn) -> Bool {
        turn.role == .assistant && turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Cheap token estimate. ~4 characters per token is the standard back-of-envelope
    /// for English; close enough for budgeting decisions. Don't use for billing.
    static func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    // MARK: - Auto-fact extraction

    /// Runs after a response completes when the user has enabled auto-extraction.
    /// Asks the cheapest available model to identify any new persistent facts
    /// about the user from the recent exchange and adds them to the store.
    /// Strict JSON output makes parsing reliable; on parse failure we no-op.
    /// Free on Apple, ~$0.0005/turn on Haiku.
    ///
    /// Defense in depth: extraction re-sends the user's
    /// message content to the provider. The active provider has
    /// necessarily passed the consent gate for the turn itself, but
    /// if consent was revoked mid-session (debug "Forget consent" /
    /// schema bump) this background call must not slip through.
    func runAutoFactExtraction(userText: String, assistantText: String) async {
        // Prefer Apple (free + private) for extraction; fall back to whatever
        // the user has configured.
        let apple = registry.apple.isAvailable
        let provider: AIProvider = apple ? registry.apple : registry.activeProvider
        let model: ModelOption = apple ? AppleFoundationProvider.model : registry.activeModel
        guard !AppDependencies.current.providers.providerConsentTracker.requiresConsent(provider.id) else {
            debugLog("[Assistant] fact extraction skipped — \(provider.id.rawValue) has no data-sharing consent")
            return
        }
        let prompt = extractionPrompt(userText: userText, assistantText: assistantText)
        let stream = provider.send(
            messages: [ChatTurn(role: .user, text: prompt)], model: model, contextRendered: "",
            systemPrompt: "You extract structured facts. Output only the requested JSON."
        )
        guard let collected = await Self.collect(stream, timeoutSec: 8),
              let facts = Self.parseExtractedFacts(collected) else { return }
        await MainActor.run { self.store(extractedFacts: facts) }
    }

    /// Add every candidate that survives the auto-extract shape filter.
    @MainActor
    private func store(extractedFacts facts: [String]) {
        for fact in facts {
            let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.factPassesAutoExtractFilter(trimmed) else { continue }
            factsStore.add(trimmed)
        }
    }

    /// The extraction instruction, with the exchange and the already-known
    /// facts inlined so the model can skip repeats.
    private func extractionPrompt(userText: String, assistantText: String) -> String {
        let knownFacts = factsStore.facts.map { "- \($0.text)" }.joined(separator: "\n")
        return """
        Look at the user's latest message and the assistant's reply. Identify any NEW persistent \
        facts about the USER that should be remembered across future conversations — things like \
        ongoing health conditions, training goals, life events, preferences for how the assistant \
        should respond. Skip anything already in "Known facts". Skip transient or one-off mentions.

        User message:
        \(userText)

        Assistant reply:
        \(assistantText)

        Known facts (do NOT repeat these):
        \(knownFacts.isEmpty ? "(none)" : knownFacts)

        Output STRICT JSON only. No code fences, no preamble. Format:
        {"facts": ["...", "..."]}
        Use an empty array if nothing new is worth remembering.
        """
    }

    /// Drain a stream's text deltas, giving up after `timeoutSec`. Nil on any
    /// failure — extraction is best-effort and never surfaces an error.
    private static func collect(
        _ stream: AsyncThrowingStream<AIStreamEvent, Error>,
        timeoutSec: UInt64
    ) async -> String? {
        try? await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await drainTextDeltas(stream) }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSec * 1_000_000_000)
                throw AIProviderError.cancelled
            }
            let first = try await group.next()
            group.cancelAll()
            return first
        }
    }

    private static func drainTextDeltas(_ stream: AsyncThrowingStream<AIStreamEvent, Error>) async throws -> String {
        var local = ""
        for try await event in stream {
            if case let .textDelta(chunk) = event { local.append(chunk) }
        }
        return local
    }

    /// Parse `{"facts": [...]}`, stripping code fences the model may have
    /// added despite instructions. Nil when the payload isn't that shape.
    private static func parseExtractedFacts(_ collected: String) -> [String]? {
        var s = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
            if let closeRange = s.range(of: "```", options: .backwards) {
                s = String(s[..<closeRange.lowerBound])
            }
        }
        guard let data = s.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["facts"] as? [String]
    }

    /// Auto-extract filter logic.
    /// Drops:
    ///   • Empty / over-long candidates
    ///   • Questions ("Should I…", "How do I…", text ending with `?`) —
    ///     conversational artifacts, not persistent facts about the user
    ///   • App-state observations ("the user opened the app",
    ///     "this conversation", "in this chat", "the model said") — these
    ///     leak the chat surface back into "memory" instead of capturing
    ///     real user facts
    ///   • Self-referential meta-text the extractor sometimes
    ///     hallucinates ("known facts", "facts:")
    /// `UserFactsStore.add` handles case-insensitive duplicate
    /// detection so this filter focuses on shape, not content overlap.
    static func factPassesAutoExtractFilter(_ text: String) -> Bool {
        guard !text.isEmpty, text.count < 240, text.count > 6, !text.hasSuffix("?") else { return false }
        let lower = text.lowercased()
        if questionPrefixes.contains(where: lower.hasPrefix) { return false }
        return !appStateMarkers.contains(where: lower.contains)
    }

    private static let questionPrefixes = [
        "how ", "what ", "why ", "when ", "where ",
        "should i", "can i", "do i ", "is it ", "are you "
    ]

    /// `"the user "` catches third-person speak about the user — the extractor
    /// confusing itself about who it's describing.
    private static let appStateMarkers = [
        "the user ",
        "this conversation",
        "this chat",
        "in this session",
        "the assistant ",
        "the model ",
        "known facts",
        "facts:",
        "the app ",
        "flow recovery "
    ]

    // MARK: - Prompt-audit encoders
    //
    // Provider-agnostic serialisers used by the audit
    // hook in `runToolUseLoop`. We deliberately use these instead of
    // each provider's wire-format encoder because the audit's purpose
    // is "what did we ASK?" not "what did the API server receive?".
    // The provider's own transforms (cache markers, `<live_state>`
    // splice, Anthropic block-form) happen below this layer; the
    // audit captures the inputs handed across the boundary.

    // MARK: - Announce-but-don't-call detection

    /// True if the round's text response looks like the model
    /// announced a tool call without actually issuing one. We match
    /// short, prefix-anchored phrases so we don't false-positive on
    /// e.g. "Calling that out as an issue" (longer sentence, different
    /// verb sense). Pattern set tracked against real grok outputs
    /// from a walk session.
    static func looksLikeAnnounceButDidntCall(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.count < 200 else { return false }
        if strongAnnounceTriggers.contains(where: trimmed.contains) { return true }
        guard trimmed.count <= 48 else { return false }
        return weakAnnounceTriggers.contains(where: trimmed.hasPrefix)
    }

    /// STRONG triggers — unambiguous tool announcements (they name a live tool
    /// or a fetch). If the model said any of these and then didn't call a
    /// tool, it's an announce-without-call regardless of length.
    private static let strongAnnounceTriggers = [
        "calling get_workout_live",
        "calling live snapshot",
        "calling the live snapshot",
        "calling live_snapshot",
        "pulling fresh",
        "pulling the live",
        "pulling a live",
        "getting the live",
        "fetching live",
        "fetching the live"
    ]

    /// WEAK triggers — generic "let me …" openers. These ALSO begin many
    /// perfectly good complete answers ("Let me check your sleep trend — it's
    /// been climbing all week"). They only count as announce-without-call when
    /// the text is essentially JUST the announcement, which is why the caller
    /// guards on a short length: a real answer that merely opens with "let me
    /// check" is never clobbered.
    private static let weakAnnounceTriggers = [
        "let me grab",
        "let me check",
        "let me pull",
        "let me get",
        "i'll call",
        "i'll grab",
        "i'll fetch",
        "i'll pull"
    ]

    /// True if the last user turn looked like a request for live /
    /// current data — the only context in which announce-but-don't-do
    /// is a bug worth retrying for. Stress / personal / casual chat
    /// where the model says "Let me check on that" shouldn't trigger
    /// a forced tool call.
    static func lastUserAskedForLiveData(_ userText: String) -> Bool {
        let t = userText.lowercased()
        return liveDataSignals.contains(where: t.contains)
    }

    private static let liveDataSignals = [
        "what's my", "whats my", "what is my",
        "right now", "current", "currently", "live ",
        " hr", "heart rate", "tsb", "atl", "ctl", "rmssd", "pace",
        "where am i", "what street", "how am i doing", "training load"
    ]

    /// The shapes the prompt-audit bundle serialises to. Local to the audit —
    /// deliberately not the wire types, so a provider-format change can't
    /// silently alter what the audit records.
    private struct AuditMessage: Encodable {
        let role: String
        let text: String
    }

    private struct AuditToolCall: Encodable {
        let name: String
        let arguments: String
        let result: String
    }

    private struct AuditToolRound: Encodable {
        let round: Int
        let calls: [AuditToolCall]
    }

    private struct AuditBundle: Encodable {
        let conversation: [AuditMessage]
        let toolRounds: [AuditToolRound]
    }

    static func auditEncodeMessages(_ outbound: [ChatTurn], toolRounds: [[ToolExchange]]) -> String {
        let bundle = AuditBundle(
            conversation: outbound.map {
                AuditMessage(role: $0.role == .user ? "user" : "assistant", text: $0.text)
            },
            toolRounds: toolRounds.enumerated().map { idx, round in
                AuditToolRound(
                    round: idx + 1,
                    calls: round.map {
                        AuditToolCall(name: $0.toolName, arguments: $0.inputJSON, result: $0.resultJSON)
                    }
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = attempt("assistant.toolBundle.encode", { try encoder.encode(bundle) }),
              let s = String(data: data, encoding: .utf8) else { return "[encode failed]" }
        return s
    }

    static func auditEncodeTools(_ tools: [ToolSpec]) -> String {
        guard !tools.isEmpty else { return "" }
        struct AuditTool: Encodable {
            let name: String
            let description: String
        }
        // Full tool spec is huge; the audit page shows just name +
        // one-line description so the user can answer "which tools
        // did the model have access to?" without scrolling 30 KB.
        let summary = tools.map { spec in
            AuditTool(name: spec.name, description: spec.description)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = attempt("assistant.toolSummary.encode", { try encoder.encode(summary) }), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "[encode failed]"
    }
}

// MARK: - Stream text buffer

/// Round-local streaming text state for `runToolUseLoop`.
/// One instance per provider round:
/// owns the 33 ms publish throttle, the speakable-cursor advance, and
/// the pre-tool-use rewind against the round-start snapshot.
@MainActor
final class StreamTextBuffer {
    private let owner: AssistantViewModel
    /// Store the reserved turn's stable id, not a positional index
    /// (a positional index corrupts the wrong turn mid-stream). The
    /// live array position is re-resolved at every read/write (see
    /// `currentIndex`) so a stream still in flight after the array
    /// shifted (clear / regenerate / removal) can never write into the
    /// wrong turn.
    private let turnID: UUID

    /// Live array position of the reserved turn, or nil if it's been
    /// removed. Every flush/read goes through this — never a cached Int.
    private var currentIndex: Int? { owner.liveTurnIndex(for: turnID) }

    /// Snapshot the turn's text length at round start. If the model
    /// emits text then decides to call a tool, that pre-tool-use
    /// text was "thinking aloud" against the prompt rule and must
    /// be rewound so voice doesn't speak "based on your data..."
    /// and then call a tool (the streaming glitch).
    let roundStartTextLen: Int

    // Streaming token publish throttle. Provider
    // streams emit tokens at 50–100/sec. Mutating `turns[index].text`
    // per token fires SwiftUI body re-evaluation on every
    // observer of the view model — chat view, input bar,
    // toolbar Menu, error banner. That render storm is what
    // makes the keyboard feel stuck (main run loop saturated).
    //
    // Chunks accumulate in a local buffer and publish at
    // most every 33 ms (~30 Hz). The visible text still
    // updates smoothly to the human eye but the publish rate
    // is 5-10× lower. Pre-tool-use rewind logic still fires
    // against the published text length, so its semantics
    // don't change.
    private var pendingChunks = ""
    private var lastPublishAt = Date.distantPast
    private let publishIntervalMs: Double = 33

    init(owner: AssistantViewModel, turnID: UUID) {
        self.owner = owner
        self.turnID = turnID
        if let index = owner.liveTurnIndex(for: turnID) {
            self.roundStartTextLen = owner.turns[index].text.count
        } else {
            self.roundStartTextLen = 0
        }
    }

    /// Buffer a streamed text delta and publish through the throttle.
    /// `thisRoundIsEmpty` is the caller's `thisRound.isEmpty` at event
    /// time — pre-tool-use turns skip the cursor advance.
    func append(chunk: String, thisRoundIsEmpty: Bool) {
        pendingChunks.append(chunk)
        flush(thisRoundIsEmpty: thisRoundIsEmpty)
    }

    /// Appends pendingChunks to the live turn, resets the buffer, and
    /// re-runs the speakable-cursor advance check on the just-published
    /// delta.
    ///
    /// Resolve the live turn by id. If it's been removed
    /// (cleared / regenerated), drop the buffered text rather than appending
    /// it to whatever now occupies a stale index.
    ///
    /// Voice latency fix: the speakable cursor advances when the
    /// just-published batch contained a sentence-ender. Pushing per-character
    /// was triggering 500+ Combine publisher updates per response (each
    /// re-evaluates SwiftUI views observing the chat). Publishes are batched
    /// now, so the cursor advance is naturally batched too. Pre-tool-use turns
    /// (thisRound non-empty) skip the cursor — the tool may rewind that text.
    func flush(force: Bool = false, thisRoundIsEmpty: Bool) {
        guard !pendingChunks.isEmpty else { return }
        let elapsedMs = Date().timeIntervalSince(lastPublishAt) * 1000
        guard force || elapsedMs >= publishIntervalMs else { return }
        guard let index = currentIndex else {
            pendingChunks = ""
            return
        }
        guard let publishable = takePublishableText(force: force) else { return }
        owner.turns[index].text.append(publishable)
        if thisRoundIsEmpty, publishable.contains(where: { CoachVoiceGuard.sentenceTerminators.contains($0) }) {
            owner.speakableTextCursor[turnID] = owner.turns[index].text.count
        }
        lastPublishAt = Date()
        owner.store.save(owner.turns)
    }

    /// The FDA output perimeter, applied BEFORE the text becomes visible.
    ///
    /// The guard must not run after the
    /// user has already read the text. `CoachVoiceGuard` can only judge a whole
    /// sentence (its deflections replace the sentence a match sits in), so the
    /// buffer publishes complete sentences and holds the incomplete tail back
    /// until its terminator arrives. On `force` (round end) the tail is
    /// published too, scrubbed.
    ///
    /// The cost of holding a partial sentence is a slightly chunkier reveal;
    /// the cost of not holding it is that "you may have atrial fibrillation"
    /// renders token by token and is replaced only once the stream finishes.
    /// The voice speakable-cursor advances off the same published text, so the
    /// spoken path inherits the same protection.
    ///
    /// Returns nil when there is nothing publishable yet (an incomplete first
    /// sentence), leaving `pendingChunks` intact for the next flush.
    private func takePublishableText(force: Bool) -> String? {
        if force {
            let scrubbed = scrubbing(pendingChunks)
            pendingChunks = ""
            return scrubbed.isEmpty ? nil : scrubbed
        }
        let split = CoachVoiceGuard.splitAtLastSentenceBoundary(pendingChunks)
        guard !split.complete.isEmpty else { return nil }
        pendingChunks = split.tail
        return scrubbing(split.complete)
    }

    /// Scrub, and record any interception so the incident is auditable. The
    /// cheap `containsProhibitedLanguage` pre-check keeps the overwhelmingly
    /// common clean case to one regex sweep instead of a rewrite pass.
    private func scrubbing(_ text: String) -> String {
        guard CoachVoiceGuard.containsProhibitedLanguage(text) else { return text }
        let result = CoachVoiceGuard.scrub(text)
        for trigger in result.triggers {
            owner.recordCoachVoiceInterception(reason: trigger.reason)
        }
        return result.scrubbed
    }

    /// Round ended text-only → advance the voice speakable cursor to
    /// the full current text length (see the round-end policy comments
    /// in `applyRoundEndTextPolicy`).
    func advanceSpeakableCursorToCurrentEnd() {
        // Resolve the live turn by id.
        guard let index = currentIndex else { return }
        owner.speakableTextCursor[turnID] = owner.turns[index].text.count
    }

    /// Rewind any text emitted after the round-start snapshot (the
    /// pre-tool-use "thinking aloud" rewind; also reused by the Grok
    /// announce-retry path).
    func rewindToRoundStart() {
        // Resolve the live turn by id.
        guard let index = currentIndex else { return }
        let current = owner.turns[index].text
        if current.count > roundStartTextLen {
            owner.turns[index].text = String(current.prefix(roundStartTextLen))
            owner.store.save(owner.turns)
        }
    }
}
