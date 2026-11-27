import Foundation

// MARK: - Negated disclaimers (output side and copy linter)
//
// "Emuqu is not FDA-approved", "ne diagnostique aucune affection", "未经 FDA
// 批准", "診断を行いません": the app's own disclaimer, and the model repeating
// it, names a clearance, a diagnosis or a treatment in order to deny it. A
// negated disclaimer is not a claim. For those three concepts only, a match
// inside a negated clause is exempt, in `CoachVoiceGuard` and in
// `Tools/copy_linter/lint.py`, which reads the same patterns from this file.
//
// Every other concept stays scrubbed when denied: "This isn't AFib" rules a
// condition out and "There's no sign of overtraining" is a finding about the
// user, so the guard still replaces those sentences.
//
// A negated clause runs from the negation to the next clause break (a
// sentence end, a semicolon, or a "but" or "and" word), so "Emuqu isn't a
// medical device, but it is FDA-cleared" is still a claim. Where the negation
// follows the verb or the object (German "behandelt deine Erkrankung nicht",
// Dutch, the Nordic languages, Icelandic) the clause is the whole stretch
// between breaks; where it closes the sentence (Japanese, Korean) the clause
// runs back from it.
extension MedicalTermLexicon {
    /// The concepts a negated clause exempts.
    static let disclaimableClaims: [Concept] = [regulatoryClearance, diagnosis, treatmentClaim]

    /// A negation that opens the clause it denies.
    static let negationAhead = Concept(
        id: "negation-ahead",
        latin: [
            // "No," and "Non," open an answer, not a denial.
            "not", "\\w+n['’]t", "never", "neither", "nor", "no(?!\\s*,)", "cannot", "without",  // en, es
            "ne", "n['’]", "ni", "aucun\\w*", "jamais", "sans",                                  // fr
            "nunca", "tampoco", "sin",                                                         // es
            "n[ãa]o", "nem", "nenhum\\w*", "sem",                                              // pt-BR
            "non(?!\\s*,)", "nessun\\w*", "senza",                                         // it
            "ei", "eik[äa]", "eiv[äa]t", "ilman",                                             // fi: not "en", "et" (Spanish "en", French "et")
            "не", "ни", "нет", "без",                                                          // ru
            "و?(?:لا|ليس|ليست|لم|لن|غير)"                                                      // ar
        ],
        unbounded: ["不", "未", "没有", "并非", "无法", "非"]
    )

    /// A negation that may come after what it denies, so its whole clause is
    /// the negated one: "Emuqu behandelt deine Erkrankung nicht".
    static let negationInClause = Concept(
        id: "negation-in-clause",
        latin: [
            "nicht", "kein\\w*", "weder", "nie", "niemals", "ohne",                            // de: not "noch" (still)
            "niet", "geen", "nooit", "zonder",                                                // nl
            "ikke", "inte", "ingen", "inga", "inget", "intet", "hverken", "varken", "aldrig", "aldri", "uden", "uten", "utan", // da, nb, sv
            "ekki", "hvorki", "né", "aldrei", "án"                                             // is: accented, not English "an"
        ],
        unbounded: []
    )

    /// A negation that closes the clause it denies: Japanese and Korean.
    static let negationBehind = Concept(
        id: "negation-behind",
        latin: [],
        unbounded: [
            "ません", "ではない", "ではなく", "じゃない", "しない", "しておらず", "おらず", "ず[、。]", "ないです",
            "않", "없습니다", "없으며", "아닙니다", "아니며", "아니고", "아닌", "못합니다", "못하며"
        ]
    )

    /// Where a negated clause ends: a sentence end, a semicolon, or a "but"
    /// or "and" word. Not a bare "en" (Dutch "and", Icelandic "but"), which
    /// is also the Nordic article.
    static let clauseBreak = Concept(
        id: "clause-break",
        latin: [
            "but", "however", "yet", "although", "though", "whereas", "and",
            "aber", "jedoch", "doch", "sondern", "und", "sowie",
            "mais", "cependant", "pourtant", "et",
            "pero", "sino", "aunque", "y", "mas", "por[ée]m", "contudo", "e",
            "ma", "per[òo]", "tuttavia", "maar", "echter", "men", "og", "och",
            "mutta", "vaan", "ja", "но", "однако", "и", "а",
            // Icelandic "en" (but) only after a comma: bare, it is the Nordic article.
            ",\\s*en"
        ],
        unbounded: ["[.!?;。！？；]", "但", "然而", "而且", "しかし", "けれど", "が、", "하지만", "그러나", "لكن"]
    )

    /// The first match of `regex` in `text` that is a claim: outside every
    /// negated clause when `concept` is disclaimable, any match otherwise.
    static func claimMatch(of regex: NSRegularExpression, concept id: String, in text: String) -> NSTextCheckingResult? {
        let whole = NSRange(text.startIndex..., in: text)
        guard disclaimableIDs.contains(id) else { return regex.firstMatch(in: text, range: whole) }
        let spans = negatedSpans(in: text)
        return regex.matches(in: text, range: whole).first { match in
            !spans.contains { NSLocationInRange(match.range.location, $0) }
        }
    }

    /// The stretches of `text` a negation denies.
    static func negatedSpans(in text: String) -> [NSRange] {
        guard let ahead = negationAheadRegex, let inClause = negationInClauseRegex,
              let behind = negationBehindRegex, let breaks = clauseBreakRegex else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        let cuts = breaks.matches(in: text, range: whole).map(\.range)
        let clauseStart = { (location: Int) in cuts.last { NSMaxRange($0) <= location }.map(NSMaxRange) ?? 0 }
        let clauseEnd = { (location: Int) in cuts.first { $0.location >= location }?.location ?? whole.length }
        return spans(of: ahead, in: text) { ($0.location, clauseEnd(NSMaxRange($0))) }
            + spans(of: inClause, in: text) { (clauseStart($0.location), clauseEnd(NSMaxRange($0))) }
            + spans(of: behind, in: text) { (clauseStart($0.location), NSMaxRange($0)) }
    }

    /// One span per match of `negation`, from the bounds `span` gives it.
    private static func spans(of negation: NSRegularExpression, in text: String, span: (NSRange) -> (Int, Int)) -> [NSRange] {
        negation.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            let (start, end) = span(match.range)
            return NSRange(location: start, length: max(0, end - start))
        }
    }

    private static let disclaimableIDs = Set(disclaimableClaims.map(\.id))
    private static let negationAheadRegex = regex(for: negationAhead)
    private static let negationInClauseRegex = regex(for: negationInClause)
    private static let negationBehindRegex = regex(for: negationBehind)
    private static let clauseBreakRegex = regex(for: clauseBreak)
}
