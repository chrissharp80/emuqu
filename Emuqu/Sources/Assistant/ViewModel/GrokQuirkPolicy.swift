import Foundation

// `GrokQuirkPolicy` and the `ChatTurn` helpers it uses, split out of
// `AssistantViewModel+Tools.swift`. The policy encodes provider-
// specific workarounds and is independent of the tool-dispatch extension;
// `private` at file scope would be invisible to the call
// site, which lives in a different file.

// MARK: - Grok quirk policy

/// Grok-only failure-mode handling for `runToolUseLoop`:
/// the announce-but-don't-call
/// retry/rewind and the end-of-turn fallback substitution. Both are
/// gated by provider.id so we don't touch Anthropic / OpenAI / Apple /
/// Gemini paths where the pattern doesn't happen.
@MainActor
struct GrokQuirkPolicy {
    private let owner: AssistantViewModel
    private let provider: AIProvider
    /// Hold the
    /// stable turn id and resolve the live position at flush time, so a
    /// shifted array can't make the fallback substitution clobber the
    /// wrong turn.
    private let turnID: UUID

    // "Calling X" loop guard. Some providers (observed
    // with grok-4-1-fast-reasoning on a walk session) emit complete
    // text responses that announce a tool call ("Calling
    // get_workout_live snapshot for current HR now.") without
    // actually emitting a tool_use block. The stream completes,
    // `thisRound.isEmpty` is true, and the loop returns. The user
    // sees the announcement, asks again, the model produces the
    // same announcement again — six round-trips before it broke
    // out. Detection-and-retry below: if the round ends text-only
    // AND the text matches an announce-but-don't-do pattern AND
    // the user's preceding turn asked for live data, inject a
    // nudge user-turn and re-run. Capped at 2 retries.
    private var announceWithoutCallRetries = 0
    private let maxAnnounceWithoutCallRetries = 2

    init(owner: AssistantViewModel, provider: AIProvider, turnID: UUID) {
        self.owner = owner
        self.provider = provider
        self.turnID = turnID
    }

    /// Round ended text-only: detect the announce-but-don't-do pattern
    /// and, when it fires, rewind the announcement off the visible turn
    /// and return the synthetic nudge turn for the caller to append and
    /// retry with. Returns nil when the round should exit normally.
    ///
    /// The retry/rewind is gated to Grok only. Other providers
    /// (Anthropic / OpenAI / Apple / Gemini) don't show the
    /// announce-but-don't-do pattern; running the rewind on them risks
    /// emptying perfectly-good text. Per user instruction: the quirk was
    /// Grok's, so leave every other provider path alone.
    ///
    /// Resolves the live turn by id.
    mutating func announceWithoutCallNudge(
        outbound: [ChatTurn],
        buffer: StreamTextBuffer
    ) -> ChatTurn? {
        let roundText = owner.liveTurnIndex(for: turnID).map {
            String(owner.turns[$0].text.dropFirst(buffer.roundStartTextLen))
        } ?? ""
        guard provider.id == .grok,
              announceWithoutCallRetries < maxAnnounceWithoutCallRetries,
              AssistantViewModel.looksLikeAnnounceButDidntCall(roundText),
              let userTurn = outbound.last(where: { $0.role == .user }),
              AssistantViewModel.lastUserAskedForLiveData(userTurn.text)
        else { return nil }
        announceWithoutCallRetries += 1
        debugLog("[Assistant] announce-but-no-call detected (retry \(announceWithoutCallRetries)/\(maxAnnounceWithoutCallRetries)) — text=\(roundText.prefix(120))")
        // Rewind the announcement off the visible turn so the user doesn't see
        // "Calling X" and the eventual real answer back-to-back.
        buffer.rewindToRoundStart()
        return ChatTurn(role: .user, text: Self.nudgeText)
    }

    /// The synthetic user-role correction appended so the model gets the
    /// feedback on the next round-trip.
    private static let nudgeText = "Your previous reply said you'd call a tool but didn't emit the tool_use block — the user only saw an empty announcement. CALL THE TOOL NOW (silently) and answer with the actual numbers, no preamble."

    // Final safety net for Grok-only failure modes:
    // (a) model emits empty text and never calls a tool, leaving
    //     the user with a blank chat bubble, OR
    // (b) model emits an announce-but-don't-do text ("Calling
    //     get_workout_live snapshot for current HR now") and the
    //     retry/rewind above couldn't coerce it into compliance,
    //     leaving the bogus announce text as the visible turn.
    // Both were observed in a real chat session. For Grok specifically, substitute
    // a useful fallback when the turn ends in one of these
    // states. Gated by provider.id so we don't touch Anthropic /
    // OpenAI / Apple / Gemini paths where the pattern doesn't
    // happen — per the user's leave-other-paths-alone rule.
    func substituteFallbackIfTurnEndedBlankOrAnnounced() {
        // Resolve the live turn by id so the
        // substitution can't overwrite a different turn after the array
        // shifted (this runs in a `defer`, well after the array may have
        // been mutated by a clear / regenerate / removal).
        guard provider.id == .grok, let index = owner.liveTurnIndex(for: turnID) else { return }
        let raw = owner.turns[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsSubstitute = raw.isEmpty || AssistantViewModel.looksLikeAnnounceButDidntCall(raw)
        if needsSubstitute {
            owner.turns[index].text = "Sorry — I didn't finish that answer. Mind asking again, or rephrasing it?"
            owner.store.save(owner.turns)
            debugLog("[Assistant] grok fallback substituted (raw=\"\(raw.prefix(80))\")", level: .warning)
        }
    }
}

// MARK: - Helpers for the chat UI

extension ChatTurn {
    /// SF Symbol used for the role indicator in the chat bubble.
    var roleSymbol: String {
        role == .user ? "person.fill" : (providerID?.symbolName ?? "sparkles")
    }
}
