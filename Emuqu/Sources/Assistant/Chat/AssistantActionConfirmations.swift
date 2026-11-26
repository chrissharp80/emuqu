import Foundation

// MARK: - AssistantActionConfirmations
//
// The second step of a destructive assistant action: forgetting a memory
// fact, clearing memory, removing a contact. The model's tool call alone
// never runs one. Content the model read (a web page, a pasted email, a
// search result) can steer it into any call and into quoting any three words
// of the user's message, so a quote proves nothing about intent. The first
// call only records the request here, with a question the app wrote. When
// the reply ends, the app shows that question under it itself
// (`showPending`, `ChatTurn.confirmationPrompt`): the model's own wording is
// not what the user agrees to, since a steered model could ask about
// something else and collect the "yes". The action runs when the model
// repeats the same call AND the user's very next message, which only the
// user can write, is a short, explicit "yes" sent directly under the app's
// question. A different reply, a later turn, a question that was never
// shown, or `lifetime` passing, and the request lapses. One request is
// pending at a time; a new one replaces it.
// Writes whose content the model supplies (a memory fact, a contact, an
// address, a route name) take the same step when that content is not in the
// user's own latest message (`DestructiveActionContext.gateUnlessUserStated`).

/// A destructive action the assistant has asked the user to confirm.
struct PendingAssistantAction: Equatable, Sendable {
    /// The fact-catalog action key, e.g. `assistant.memory.clear`.
    let action: String
    /// What the action targets (a fact id, a contact name), lowercased.
    let target: String
    /// The user message that was the latest one when the request was made.
    let requestTurnID: UUID
    let requestedAt: Date
    /// What the app asks the user, in their language.
    let question: String
    /// The reply the app showed `question` under; nil until it has.
    var promptTurnID: UUID?
}

@MainActor
final class AssistantActionConfirmations {
    enum Outcome: Equatable, Sendable {
        /// The user's latest message confirms this exact request: run it.
        case confirmed
        /// Recorded as pending: the user has to be asked.
        case awaitingConfirmation
        /// No user message to anchor a request to, so nothing can confirm it.
        case noUserMessage
    }

    /// How long a request waits for the user's reply.
    nonisolated static let lifetime: TimeInterval = 10 * 60

    private(set) var pending: PendingAssistantAction?

    /// Nonisolated so a test case can hold its own instance.
    nonisolated init() {}

    /// Confirms the request when the user's latest message is an explicit
    /// "yes" sent directly after the message during which the same request
    /// was recorded; otherwise records (or re-records) it as pending.
    func evaluate(action: String, target: String, question: String, turns: [ChatTurn], now: Date = Date()) -> Outcome {
        guard let latest = turns.last(where: { $0.role == .user }) else {
            pending = nil
            return .noUserMessage
        }
        let key = target.lowercased()
        if confirms(action: action, target: key, turns: turns, now: now) {
            pending = nil
            return .confirmed
        }
        pending = PendingAssistantAction(action: action, target: key, requestTurnID: latest.id, requestedAt: now, question: question)
        return .awaitingConfirmation
    }

    /// The pending request matches and has not expired, the app showed its
    /// question under the reply just before the latest user message, that
    /// reply answered the message the request was made during, and the
    /// latest message says yes.
    private func confirms(action: String, target: String, turns: [ChatTurn], now: Date) -> Bool {
        guard let pending, pending.action == action, pending.target == target,
              now.timeIntervalSince(pending.requestedAt) <= Self.lifetime,
              let replyIndex = turns.lastIndex(where: { $0.role == .user }), replyIndex >= 2
        else { return false }
        let (prompt, request) = (turns[replyIndex - 1], turns[..<(replyIndex - 1)].last { $0.role == .user })
        guard prompt.role == .assistant, prompt.id == pending.promptTurnID, request?.id == pending.requestTurnID else { return false }
        return AffirmationReply.isExplicitYes(turns[replyIndex].text)
    }

    /// When a reply ends: shows the question of a request made during this
    /// turn under the reply, the last turn when it answers the latest user
    /// message. Nothing is shown when the reply is missing (a failed or
    /// stopped stream); the request then cannot be confirmed. Returns
    /// whether a question was shown.
    @discardableResult
    func showPending(in turns: inout [ChatTurn]) -> Bool {
        guard var request = pending, request.promptTurnID == nil,
              let replyIndex = turns.indices.last, turns[replyIndex].role == .assistant,
              turns.last(where: { $0.role == .user })?.id == request.requestTurnID
        else { return false }
        turns[replyIndex].confirmationPrompt = request.question
        request.promptTurnID = turns[replyIndex].id
        pending = request
        return true
    }
}

// MARK: - AffirmationReply

/// Whether a chat message is a short, explicit "yes": at most `maxWords`
/// words, opening with an affirmation in one of the app's languages, and
/// with no negation or hedge anywhere in it. "Yes, clear it" and "ja bitte"
/// confirm; "yes but not now", "no", "summarize this article" and a pasted
/// paragraph that happens to contain "yes" do not.
enum AffirmationReply {
    static let maxWords = 5

    static func isExplicitYes(_ text: String) -> Bool {
        let words = tokens(text)
        guard let first = words.first, words.count <= maxWords else { return false }
        guard !words.contains(where: { negations.contains($0) }) else { return false }
        let opening = words.prefix(2).joined(separator: " ")
        return affirmations.contains(first) || affirmations.contains(opening)
    }

    /// Lowercased words, split on whitespace, punctuation and symbols.
    static func tokens(_ text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        return text.lowercased().components(separatedBy: separators).filter { !$0.isEmpty }
    }

    /// One word, or a two-word opening. Each entry appears once: a Set
    /// literal with a duplicate traps at runtime.
    private static let affirmations: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "confirm", "confirmed", "correct", "affirmative",
        "do it", "go ahead", "please do",
        "ja", "já", "jawohl", "klar", "bestätigen", "bestätigt", "bevestig", "japp", "bekräfta", "bekræft", "bekreft",
        "sí", "si", "claro", "confirmo", "adelante", "vale", "sim",
        "oui", "confirme", "confirmé", "d accord", "vas y",
        "sì", "certo", "confermo", "conferma",
        "kyllä", "joo", "vahvista",
        "да", "подтверждаю", "نعم", "はい", "네", "예", "是", "是的", "好的", "确认", "对"
    ]

    private static let negations: Set<String> = [
        "no", "not", "don", "dont", "never", "cancel", "stop", "wait", "but",
        "nein", "nicht", "aber", "nee", "niet", "maar", "nej", "nei", "ikke", "ekki", "inte", "men",
        "non", "pas", "mais", "pero", "ma", "não", "nao", "ei", "mutta",
        "нет", "не", "но", "لا", "いいえ", "아니", "아니요", "不", "别"
    ]
}
