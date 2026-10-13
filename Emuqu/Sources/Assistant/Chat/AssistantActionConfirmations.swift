import Foundation

// MARK: - AssistantActionConfirmations
//
// The second step of a destructive assistant action: forgetting a memory
// fact, clearing memory, removing a contact. The model's tool call alone
// never runs one. Content the model read (a web page, a pasted email, a
// search result) can steer it into any call and into quoting any three words
// of the user's message, so a quote proves nothing about intent. The first
// call only records the request here and hands the model a question for the
// user. The action runs when the model repeats the same call AND the user's
// very next message, which only the user can write, is a short, explicit
// "yes". A different reply, a later turn, or `lifetime` passing, and the
// request lapses. One request is pending at a time; a new one replaces it.

/// A destructive action the assistant has asked the user to confirm.
struct PendingAssistantAction: Equatable, Sendable {
    /// The fact-catalog action key, e.g. `assistant.memory.clear`.
    let action: String
    /// What the action targets (a fact id, a contact name), lowercased.
    let target: String
    /// The user message that was the latest one when the request was made.
    let requestTurnID: UUID
    let requestedAt: Date
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
    func evaluate(action: String, target: String, turns: [ChatTurn], now: Date = Date()) -> Outcome {
        let userTurns = turns.filter { $0.role == .user }
        guard let latest = userTurns.last else {
            pending = nil
            return .noUserMessage
        }
        let key = target.lowercased()
        if confirms(action: action, target: key, userTurns: userTurns, now: now) {
            pending = nil
            return .confirmed
        }
        pending = PendingAssistantAction(action: action, target: key, requestTurnID: latest.id, requestedAt: now)
        return .awaitingConfirmation
    }

    /// The pending request matches, has not expired, was made during the
    /// user message just before the latest one, and the latest one says yes.
    private func confirms(action: String, target: String, userTurns: [ChatTurn], now: Date) -> Bool {
        guard let pending, pending.action == action, pending.target == target,
              now.timeIntervalSince(pending.requestedAt) <= Self.lifetime,
              userTurns.count >= 2, userTurns[userTurns.count - 2].id == pending.requestTurnID,
              let reply = userTurns.last
        else { return false }
        return AffirmationReply.isExplicitYes(reply.text)
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
        "ja", "jawohl", "klar", "bestätigen", "bestätigt", "bevestig", "japp", "bekräfta", "bekræft", "bekreft",
        "sí", "si", "claro", "confirmo", "adelante", "vale", "sim",
        "oui", "confirme", "confirmé", "d accord", "vas y",
        "sì", "certo", "confermo", "conferma",
        "kyllä", "joo", "vahvista",
        "да", "подтверждаю", "نعم", "はい", "네", "예", "是", "是的", "好的", "确认", "对"
    ]

    private static let negations: Set<String> = [
        "no", "not", "don", "dont", "never", "cancel", "stop", "wait", "but",
        "nein", "nicht", "aber", "nee", "niet", "maar", "nej", "ikke", "inte", "men",
        "non", "pas", "mais", "pero", "ma", "não", "nao", "ei", "mutta",
        "нет", "не", "но", "لا", "いいえ", "아니", "아니요", "不", "别"
    ]
}
