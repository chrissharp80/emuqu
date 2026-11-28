import Foundation

/// What the tool loop does with numbers a reply states that the turn's data
/// doesn't hold (`ReplyNumberGrounding`): asks once for a reply built from
/// the data, and if the numbers stay, cuts the sentences that state them.
@MainActor
enum ReplyGroundingCheck {
    static func reask(naming numbers: [ReplyNumberGrounding.StatedNumber]) -> ChatTurn {
        let listed = numbers.map(\.text).joined(separator: ", ")
        return ChatTurn(role: .user, text: """
            Your reply stated numbers that are not in any data you were given this turn: \(listed). \
            Call the tools that hold them and answer again using only values the tools return \
            (a difference or percent change of two returned values is fine). For an average, total, lowest or highest over several days, or a trend, \
            call analyze_data and state its values instead of computing them. If the data does not have a value, say so instead of stating one. No preamble.
            """)
    }

    /// `reply` without the sentences that state any of `numbers`. A reply
    /// left with nothing says it couldn't finish rather than going blank.
    static func removingSentences(stating numbers: [ReplyNumberGrounding.StatedNumber], from reply: String) -> String {
        let flagged = Set(numbers.map(\.text))
        let kept = ReplyNumberGrounding.replySentences(reply).filter { sentence in
            !ReplyNumberGrounding.statedNumbers(in: sentence).contains { flagged.contains($0.text) }
        }
        let text = kept.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty else { return text }
        return String(localized: "Sorry — I didn't finish that answer. Mind asking again, or rephrasing it?", bundle: LanguageManager.appBundle)
    }
}
