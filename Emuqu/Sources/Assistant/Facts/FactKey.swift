import Foundation

// MARK: - FactKey
//
// Parsed, structured representation of a dotted key path, e.g.
//   "session.by_date(YYYY-MM-DD).alpha1.mean"
//   "walks.count(last_7d)"
//   "user.profile.max_hr"
//
// Paths are always dot-separated tokens. Some tokens carry parameters
// in parentheses (date, ordinal, ID, filter predicate). The parser
// splits without choking on dots inside parameter values.
//
// Keeping the catalog as strings (parseable by this struct) means both
// the LLM and the resolver agree on the exact same key grammar — no
// hand-shaking layer between them. The LLM can also discover the
// grammar from a single example because it's fully regular.
struct FactKey: Equatable, Hashable {
    /// Ordered tokens — e.g. ["session", "by_date(YYYY-MM-DD)", "alpha1", "mean"].
    let tokens: [Token]

    struct Token: Equatable, Hashable {
        let name: String
        let argument: String?  // nil for scalar names, non-nil for parameterised (e.g. "YYYY-MM-DD")

        init(name: String, argument: String? = nil) {
            self.name = name
            self.argument = argument
        }

        var rendered: String {
            argument.map { "\(name)(\($0))" } ?? name
        }
    }

    var rendered: String { tokens.map(\.rendered).joined(separator: ".") }

    /// Parse a dotted key string. Returns nil on malformed input
    /// (unbalanced parens, empty tokens). Dots inside parentheses are part of
    /// a parameter, so only depth-zero dots split tokens.
    static func parse(_ raw: String) -> FactKey? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let pieces = splitOnTopLevelDots(trimmed) else { return nil }
        let tokens = pieces.compactMap { parseToken($0) }
        guard tokens.count == pieces.count, !tokens.isEmpty else { return nil }
        return FactKey(tokens: tokens)
    }

    /// The dot-separated pieces, ignoring dots nested inside parentheses.
    /// Nil when the parens are unbalanced or a piece comes out empty.
    private static func splitOnTopLevelDots(_ s: String) -> [String]? {
        var pieces: [String] = []
        var buffer = ""
        var depth = 0
        for char in s {
            let isSeparator = (char == "." && depth == 0)
            if isSeparator, !flushPiece(&buffer, into: &pieces) { return nil }
            if isSeparator { continue }
            guard let newDepth = adjustDepth(depth, for: char) else { return nil }
            depth = newDepth
            buffer.append(char)
        }
        guard depth == 0 else { return nil }
        if !buffer.isEmpty { pieces.append(buffer) }
        return pieces
    }

    /// False on an empty piece — `a..b` and a leading dot are both malformed.
    private static func flushPiece(_ buffer: inout String, into pieces: inout [String]) -> Bool {
        guard !buffer.isEmpty else { return false }
        pieces.append(buffer)
        buffer.removeAll(keepingCapacity: true)
        return true
    }

    /// Nil when a `)` would take the depth negative — unbalanced parens.
    private static func adjustDepth(_ depth: Int, for char: Character) -> Int? {
        if char == "(" { return depth + 1 }
        guard char == ")" else { return depth }
        return depth > 0 ? depth - 1 : nil
    }

    private static func parseToken(_ raw: String) -> Token? {
        guard !raw.isEmpty else { return nil }
        if let openIdx = raw.firstIndex(of: "("), raw.last == ")" {
            let name = String(raw[..<openIdx])
            let argStart = raw.index(after: openIdx)
            let argEnd = raw.index(before: raw.endIndex)
            let arg = String(raw[argStart ..< argEnd])
            guard !name.isEmpty else { return nil }
            return Token(name: name, argument: arg)
        }
        return Token(name: raw)
    }
}

// MARK: - KeyPath helpers for readers

extension FactKey {
    /// Convenience to walk the token list from the front. Returns the
    /// first token (the namespace) and the rest as a sub-key for
    /// recursive dispatch in resolvers.
    func split() -> (head: Token, tail: FactKey?)? {
        guard let first = tokens.first else { return nil }
        let rest = Array(tokens.dropFirst())
        return (first, rest.isEmpty ? nil : FactKey(tokens: rest))
    }
}
