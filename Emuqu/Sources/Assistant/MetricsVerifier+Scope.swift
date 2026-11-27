import Foundation

// What decides a claim's referent beyond its own sentence: the structure of
// the reply around it. A bullet under "Night before (Nov 25)", a table cell in
// a "Yesterday" column, or the second line of a sentence wrapped across two
// lines is about what that structure names. Foundation's sentence rules end a
// sentence at every line break, so a check that read only the sentence took
// such a claim for today's value and rewrote it.
extension MetricsVerifier {
    /// What one line of a reply is, as far as the scope of a claim goes.
    enum ScopeLineKind: Equatable {
        case blank
        /// A markdown heading ("## Night before").
        case heading
        /// A line that is only bold text, used as a heading ("**Nov 25**").
        case label
        /// Text ending in a colon that introduces what follows ("On Nov 25:").
        case leadIn
        case listItem
        case tableRow
        /// The "|---|---|" line under a table's header row.
        case tableRule
        case text
    }

    struct ScopeLine {
        /// The line without its terminator.
        let range: NSRange
        let kind: ScopeLineKind
        let indent: Int
    }

    /// The text the scopes are read in, and the spans around the claim at
    /// `range` that name what it is about. The text is `ns` with each soft
    /// line break read as a space, the same length, so every range indexes
    /// `ns` too.
    static func enclosingStructure(of range: NSRange, in ns: NSString) -> (text: NSString, scopes: [NSRange]) {
        let lines = scopeLines(in: ns)
        return (softWrapJoined(ns, lines: lines), referentScopes(of: range, lines: lines, in: ns))
    }

    /// `enclosingStructure`'s text alone: `ns` with soft line breaks read as
    /// spaces, for a reader that walks every sentence of it.
    static func softWrapped(_ ns: NSString) -> NSString {
        softWrapJoined(ns, lines: scopeLines(in: ns))
    }

    static func scopeLines(in ns: NSString) -> [ScopeLine] {
        var lines: [ScopeLine] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines]) { line, range, _, _ in
            let text = line ?? ""
            let indent = text.prefix { $0 == " " || $0 == "\t" }.count
            lines.append(ScopeLine(range: range, kind: lineKind(text), indent: indent))
        }
        return lines
    }

    /// Checked in order: a list item ending in a colon is still a list item.
    private static let lineKindPatterns: [(ScopeLineKind, String)] = [
        (.heading, #"^#{1,6}\s"#),
        (.tableRule, #"^\|?\s*:?-{2,}:?\s*(?:\|\s*:?-{2,}:?\s*)*\|?$"#),
        (.tableRow, #"^\|"#),
        (.listItem, #"^(?:[-*+•]|\d{1,3}[.)])\s+"#),
        (.label, #"^(?:\*\*|__)[^*_]+(?:\*\*|__)\s*:?$"#),
        (.leadIn, #":$"#)
    ]

    static func lineKind(_ line: String) -> ScopeLineKind {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .blank }
        let whole = NSRange(location: 0, length: (trimmed as NSString).length)
        return lineKindPatterns.first { _, pattern in
            DebugLogger.compiledPattern(pattern, options: [])?.firstMatch(in: trimmed, range: whole) != nil
        }?.0 ?? .text
    }

    /// `ns` with every line break inside a wrapped sentence made a space.
    private static func softWrapJoined(_ ns: NSString, lines: [ScopeLine]) -> NSString {
        let joined = NSMutableString(string: ns)
        for (previous, line) in zip(lines, lines.dropFirst()) where continues(line, after: previous, in: ns) {
            let gap = NSRange(location: NSMaxRange(previous.range), length: line.range.location - NSMaxRange(previous.range))
            joined.replaceCharacters(in: gap, with: String(repeating: " ", count: gap.length))
        }
        return joined
    }

    /// A plain line right under a text line or list item that did not end
    /// its sentence carries that sentence on.
    private static func continues(_ line: ScopeLine, after previous: ScopeLine, in ns: NSString) -> Bool {
        guard line.kind == .text, previous.kind == .text || previous.kind == .listItem else { return false }
        let end = ns.substring(with: previous.range).trimmingCharacters(in: .whitespaces).last
        return end.map { !".!?:".contains($0) } ?? false
    }

    /// The heading over the claim, the lead-in its list or table hangs from,
    /// the list items it is nested under, and in a table its column's header
    /// and its row's first cell.
    private static func referentScopes(of range: NSRange, lines: [ScopeLine], in ns: NSString) -> [NSRange] {
        guard let index = lines.lastIndex(where: { $0.range.location <= range.location }) else { return [] }
        let line = lines[index]
        let above = Array(lines[..<index])
        return [sectionHeading(above), leadIn(of: line, above: above)].compactMap { $0 }
            + parentItems(of: line, above: above)
            + tableScopes(of: range, line: line, above: above, in: ns)
    }

    /// The nearest heading or bold label above: it names everything under it
    /// until the next one.
    private static func sectionHeading(_ above: [ScopeLine]) -> NSRange? {
        above.last { $0.kind == .heading || $0.kind == .label }?.range
    }

    /// For a list item or table row, the first line above its list or table
    /// ("Night before (Nov 25)", "Last week:"). For a plain line, a lead-in
    /// or label right above it.
    private static func leadIn(of line: ScopeLine, above: [ScopeLine]) -> NSRange? {
        let structured: Set<ScopeLineKind> = [.listItem, .tableRow, .tableRule]
        guard structured.contains(line.kind) else {
            let previous = above.last { $0.kind != .blank }
            return previous.flatMap { $0.kind == .leadIn || $0.kind == .label ? $0.range : nil }
        }
        let skipped = structured.union([.blank])
        return above.last { !skipped.contains($0.kind) && !($0.kind == .text && $0.indent > 0) }?.range
    }

    /// The items a nested list item sits under, each less indented than the
    /// last.
    private static func parentItems(of line: ScopeLine, above: [ScopeLine]) -> [NSRange] {
        guard line.kind == .listItem, line.indent > 0 else { return [] }
        var parents: [NSRange] = []
        var limit = line.indent
        for candidate in above.reversed() where candidate.kind == .listItem && candidate.indent < limit {
            parents.append(candidate.range)
            limit = candidate.indent
            if limit == 0 { break }
        }
        return parents
    }

    /// In a table row, the header cell of the claim's column and the row's
    /// first cell, which names the row. The column is the one the claim ends
    /// in: a match starts at its label ("| Recovery | 55 |"), and the label's
    /// column header ("Metric") says nothing about whose value the number is.
    private static func tableScopes(of range: NSRange, line: ScopeLine, above: [ScopeLine], in ns: NSString) -> [NSRange] {
        guard line.kind == .tableRow else { return [] }
        let column = pipeOffsets(in: line.range, of: ns).filter { $0 < NSMaxRange(range) }.count
        let run = above.reversed().prefix { $0.kind == .tableRow || $0.kind == .tableRule }
        let header = run.last.flatMap { first in run.dropLast().last?.kind == .tableRule ? first : nil }
        return [header.flatMap { cell(column, of: $0.range, in: ns) }, cell(1, of: line.range, in: ns)].compactMap { $0 }
    }

    private static func pipeOffsets(in line: NSRange, of ns: NSString) -> [Int] {
        (line.location..<NSMaxRange(line)).filter { ns.character(at: $0) == 0x7C }
    }

    /// The text of cell `column` (1 for the cell after the leading pipe).
    private static func cell(_ column: Int, of line: NSRange, in ns: NSString) -> NSRange? {
        let pipes = pipeOffsets(in: line, of: ns)
        guard column >= 1, column < pipes.count else { return nil }
        return NSRange(location: pipes[column - 1] + 1, length: pipes[column] - pipes[column - 1] - 1)
    }

    /// `text` with markdown emphasis, code ticks and table pipes made spaces,
    /// the same length, so "**Recovery score:** 55" and "| TSB | -5 |" match
    /// the claim patterns as "Recovery score: 55" and "TSB -5" do, and every
    /// range still indexes `text`.
    static func maskedForMatching(_ text: String) -> String {
        let masked: Set<Character> = ["*", "_", "`", "|"]
        return String(text.map { masked.contains($0) ? " " : $0 })
    }
}
