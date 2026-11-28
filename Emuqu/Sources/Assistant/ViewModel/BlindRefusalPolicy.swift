import Foundation

/// A refusal is honest only after a lookup came back empty. A model that
/// answers "I don't have that data" without calling a single tool has not
/// looked: the app holds every night, workout and walk the user recorded,
/// and the catalog can reach them. When a round ends that way, the app runs
/// `find_data` on the user's question itself, takes the refusal off the
/// screen and sends the model what the search found, once per turn.
@MainActor
enum BlindRefusalPolicy {
    /// Phrases a refusal of the user's own data takes. The prompt prescribes
    /// the first; the rest are what models write instead, in the languages
    /// the app ships.
    static let refusalMarkers: [String] = [
        "don't have that data", "do not have that data", "don't have that information", "do not have that information",
        "don't have data", "don't have any data", "don't have access to", "no data available", "don't have the data",
        "can't see that data", "isn't available in the app", "not available in the app",
        "no tengo esos datos", "no tengo datos", "je n'ai pas ces données", "je n'ai pas de données",
        "habe ich keine daten", "diese daten habe ich nicht", "non ho questi dati", "non ho dati",
        "não tenho esses dados", "não tenho dados", "このデータはありません", "データがありません", "我没有这些数据", "没有数据"
    ]

    /// Whether `text` refuses the user's data.
    static func isRefusal(_ text: String) -> Bool {
        let normalized = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return refusalMarkers.contains { normalized.contains($0) }
    }

    /// The re-ask, or nil when the round may stand: it is not a refusal, a
    /// tool already ran this turn, or the turn was re-asked once already.
    static func reask(roundText: String, question: String?, lookedUp: Bool, registry: FactResolverRegistry?) async -> ChatTurn? {
        guard isRefusal(roundText), !lookedUp, let question, !question.isEmpty else { return nil }
        guard let registry else { return ChatTurn(role: .user, text: instruction) }
        let found = await CompactToolRouter(registry: registry).resolveTool(name: "find_data", argsJSON: queryJSON(question))
        return ChatTurn(role: .user, text: instruction + "\n\nfind_data for the user's question returned:\n" + found.toolResultJSON)
    }

    /// `{"query": question}`, escaped by the encoder.
    static func queryJSON(_ question: String) -> String {
        guard let data = attempt("blindRefusal.query.encode", { try JSONEncoder().encode(["query": question]) }) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static let instruction = """
        You said you don't have that data without calling any tool. The app holds every night, workout and walk the user recorded. \
        Call the tools that answer the question now (by date for a specific day, recent with a period for several nights) and answer with the numbers, \
        no preamble. Say the data isn't there only if the tools return nothing for it.
        """
}
