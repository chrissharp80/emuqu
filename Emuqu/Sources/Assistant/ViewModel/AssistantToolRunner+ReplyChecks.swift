import Foundation

// The checks a reply gets when a round ends with text and no tool call:
// Grok's announce-without-call nudge, a refusal made without a lookup, and
// numbers the turn's data doesn't hold.

extension AssistantToolRunner {
    /// A round that ended with text and no tool call: the Grok announce
    /// nudge, else a re-ask when the text refuses data no tool was asked for
    /// (`BlindRefusalPolicy`), else a check of every number it states against
    /// the turn's data (`ReplyNumberGrounding`). Nil lets the turn end.
    func textOnlyRoundNudge(
        _ round: RoundContext,
        state: inout ToolLoopState,
        buffer: StreamTextBuffer,
        grokQuirks: inout GrokQuirkPolicy
    ) async -> ChatTurn? {
        if let nudge = grokQuirks.announceWithoutCallNudge(outbound: state.outbound, buffer: buffer) { return nudge }
        if let nudge = await blindRefusalNudge(round, state: &state, buffer: buffer) { return nudge }
        return await ungroundedNumbersNudge(round, state: &state, buffer: buffer)
    }

    /// The re-ask for a refusal made without a lookup (`BlindRefusalPolicy`), once per turn.
    private func blindRefusalNudge(_ round: RoundContext, state: inout ToolLoopState, buffer: StreamTextBuffer) async -> ChatTurn? {
        guard !state.reaskedBlindRefusal, let index = owner.liveTurnIndex(for: round.turnID) else { return nil }
        let lookedUp = !state.toolRounds.isEmpty || (round.provider.id == .apple && owner.services.appleToolDispatcher.calledAToolThisAttempt)
        guard let reask = await BlindRefusalPolicy.reask(
            roundText: String(owner.turns[index].text.dropFirst(buffer.roundStartTextLen)),
            question: state.outbound.last { $0.role == .user }?.text, lookedUp: lookedUp, registry: round.factRegistry
        ) else { return nil }
        state.reaskedBlindRefusal = true
        debugLog("[Assistant] refusal without a lookup; re-asking with the catalog search")
        buffer.rewindToRoundStart()
        return reask
    }

    /// Numbers the reply states that the turn's data doesn't hold
    /// (`ReplyNumberGrounding`): re-asked once naming them; if the new reply
    /// still states them, the sentences that do are cut.
    private func ungroundedNumbersNudge(_ round: RoundContext, state: inout ToolLoopState, buffer: StreamTextBuffer) async -> ChatTurn? {
        guard let index = owner.liveTurnIndex(for: round.turnID) else { return nil }
        let replyText = String(owner.turns[index].text.dropFirst(buffer.roundStartTextLen))
        let ungrounded = ReplyNumberGrounding.ungrounded(in: replyText, sources: await groundingSources(round, state: state))
        guard !ungrounded.isEmpty else { return nil }
        debugLog("[Assistant] \(ungrounded.count) number(s) in the reply not found in the turn's data")
        if !state.reaskedUngrounded {
            state.reaskedUngrounded = true
            buffer.rewindToRoundStart()
            return ReplyGroundingCheck.reask(naming: ungrounded)
        }
        let kept = ReplyGroundingCheck.removingSentences(stating: ungrounded, from: replyText)
        owner.turns[index].text = String(owner.turns[index].text.prefix(buffer.roundStartTextLen)) + kept
        owner.store.save(owner.turns)
        return nil
    }

    /// The user's data the model was given this turn: the live state, the
    /// conversation and every tool result, Apple's in-session ones included.
    /// The system prompt is left out: its example numbers would ground a reply
    /// that copied them. So are the loop's own re-asks, which name the numbers
    /// they question.
    private func groundingSources(_ round: RoundContext, state: ToolLoopState) async -> [String] {
        let liveState = await owner.contextSource.currentContext().renderLiveStateForCloud()
        let results = state.toolRounds.flatMap { $0.map(\.resultJSON) }
        let apple = round.provider.id == .apple ? owner.services.appleToolDispatcher.resultsThisAttempt : []
        return [liveState] + state.conversation.map(\.text) + results + apple
    }
}
