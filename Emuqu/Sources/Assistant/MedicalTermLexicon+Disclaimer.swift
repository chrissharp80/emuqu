import Foundation

// MARK: - Negated disclaimers (output side and copy linter)
//
// "Emuqu is not FDA-approved", "ne diagnostique aucune affection", "未经 FDA
// 批准", "診断を行いません": the app's own disclaimer, and the model repeating
// it, names a clearance, a diagnosis or a treatment in order to deny it. A
// negated disclaimer is not a claim. For those three concepts only, a match
// inside a negated clause is exempt in `CoachVoiceGuard`. The static copy
// linter has no such exemption: app copy that states the disclaimer is
// cleared by its allowlist instead.
//
// Every other concept stays scrubbed when denied: "This isn't AFib" rules a
// condition out and "There's no sign of overtraining" is a finding about the
// user, so the guard still replaces those sentences.
//
// A negated clause runs from the negation to the next clause break (a
// sentence end, a semicolon, a "but" or "and" word, or a comma that opens a
// new clause), so "Emuqu isn't a medical device, but it is FDA-cleared" and
// "Emuqu isn't a medical device, it is FDA-cleared" are still claims. Where
// the negation follows the verb or the object (German "behandelt deine
// Erkrankung nicht", Dutch, the Nordic languages, Icelandic) the clause is the
// whole stretch between breaks; where it closes the sentence (Japanese,
// Korean) the clause runs back from it.
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

    /// Where a negated clause ends: a sentence end, a semicolon, a "but" or
    /// "and" word, or a comma that opens a new clause. Not a bare "en" (Dutch
    /// "and", Icelandic "but"), which is also the Nordic article.
    static let clauseBreak = Concept(
        id: "clause-break",
        latin: clauseWords + arabicClauseStarts,
        unbounded: clauseMarks + commaClauseStarts + connectiveClauseEnds
    )

    /// The "but" and "and" words.
    private static let clauseWords: [String] = [
        "but", "however", "yet", "although", "though", "whereas", "and",
        "aber", "jedoch", "doch", "sondern", "und", "sowie",
        "mais", "cependant", "pourtant", "et",
        "pero", "sino", "aunque", "y", "mas", "por[ée]m", "contudo", "e",
        "ma", "per[òo]", "tuttavia", "maar", "echter", "men", "og", "och",
        "mutta", "vaan", "ja", "но", "однако", "и", "а",
        // Icelandic "en" (but) only after a comma: bare, it is the Nordic article.
        ",\\s*en"
    ]

    /// Sentence ends, semicolons and the "but" words of the unspaced scripts.
    private static let clauseMarks: [String] = [
        "[.!?;。！？；]", "但", "然而", "而且", "しかし", "けれど", "が、", "하지만", "그러나", "لكن"
    ]

    /// A comma joining a new clause: one followed by a subject and a finite
    /// verb, by a finite verb alone in the languages that drop the subject,
    /// or by a subject pronoun alone in Russian, which drops the copula. A
    /// comma inside a list ("not medical advice, diagnosis, or treatment",
    /// "does not diagnose, treat, or cure") opens no clause and stays inside
    /// the negation. Relative pronouns that open a restrictive clause after a
    /// comma (German "das", Russian "которое", Nordic "som") are left out: "kein
    /// Medizinprodukt, das von der FDA zugelassen ist" denies the approval.
    private static let commaClauseStarts: [String] = [
        // en
        ",(?=\\s*(?:(?:it|this|that|which|emuqu|we|i|you|they|he|she)\\s+(?:is|are|was|were|has|have|had|does|do|did|can|will|would|could|may|might|must|holds|carries)"
            + "|(?:it|that|we|i|you|they)['’](?:s|re|m|ve|ll|d)|is|are|was|were|has|have|had)\\b)",
        // de
        ",(?=\\s*(?:(?:es|er|sie|das|dies|emuqu|wir|ich|du|man)\\s+(?:ist|sind|war|waren|wird|wurde|werden|hat|haben|hatte|kann|können|darf|besitzt|trägt|verfügt)"
            + "|ist|sind|wird|wurde|hat|haben|besitzt|verfügt)\\b)",
        // fr
        ",(?=\\s*(?:(?:il|elle|ils|elles|on|cela|ça|ceci|emuqu|nous|je|qui)\\s+(?:est|sont|était|a|ont|avait|peut|sera|reste|dispose|possède|détient)"
            + "|c['’](?:est|était)|j['’]ai|est|sont|était|possède|dispose)\\b)",
        // es, pt-BR, it: the subject is usually dropped
        ",(?=\\s*(?:(?:él|ella|esto|eso|emuqu|que)\\s+)?(?:es|está|son|están|fue|ha|han|tiene|posee|cuenta)\\b)",
        ",(?=\\s*(?:(?:ele|ela|isso|isto|o\\s+emuqu|emuqu|que)\\s+)?(?:é|está|são|estão|foi|tem|possui|conta)\\b)",
        ",(?=\\s*(?:(?:esso|essa|lui|lei|questo|ciò|emuqu|che)\\s+)?(?:è|sono|ha|hanno|era|fu|risulta|possiede|dispone)\\b)",
        // nl
        ",(?=\\s*(?:(?:het|dit|dat|emuqu|we|wij|ik|hij|zij|ze|jij)\\s+(?:is|zijn|was|waren|wordt|werd|heeft|hebben|had|kan)|zijn|wordt|werd|heeft)\\b)",
        // da, nb, sv
        ",(?=\\s*(?:(?:det|den|han|hun|hon|vi|jeg|jag|emuqu)\\s+(?:er|är|var|har|kan|blev|ble|blir|bliver)|er|är|har|blev|ble|blir|bliver)\\b)",
        // fi
        ",(?=\\s*(?:(?:se|ne|me|emuqu|joka|mikä)\\s+(?:on|ovat|oli|olivat|voi|saa|sai)|sillä\\s+on|ovat|olivat)\\b)",
        // is
        ",(?=\\s*(?:(?:það|hann|hún|við|ég|emuqu)\\s+(?:er|eru|var|voru|hefur|hafa|getur|fékk|hlaut)|eru|hefur)\\b)",
        // ru
        ",(?=\\s*(?:он|она|оно|они|это|мы|я|emuqu|является|являются|был|была|было|имеет|имеют|может|прош[её]л|получил\\w*|одобрен[аоы]?)\\b)",
        // zh-Hans: the subject is optional
        "[,，](?=\\s*(?:它|其|我们|我|你|该应用|该|这款应用|这|此|emuqu)?\\s*(?:已经|已|获得|获|通过|是|属于|拥有|经过|得到|可以|能够|能|会))",
        // ar: a pronoun, particle or predicate after the Arabic comma
        "[،,](?=\\s*(?:(?:هو|هي|إنه|إنها|فهو|فهي|قد|لقد|تم|يعد|يعتبر|يحمل)\\b|حاصل|حائز|معتمد|مرخص))"
    ]

    /// Japanese and Korean put the negation last, so a claim joined BEFORE it
    /// by a connective ("FDA承認済みで、医療機器ではありません", "FDA 승인을
    /// 받았고, 의료기기가 아닙니다") is a clause of its own. Not "し、", whose
    /// verbs usually share the final negation ("診断し、治療することはできません"),
    /// nor the postpositions "について、", "として、", "において、", "によって、".
    private static let connectiveClauseEnds: [String] = [
        "(?:で|(?<!つい|とし|おい|よっ)て|り)、",
        "(?:았|었|였|했|있|이)(?:고|으며|며)(?=[,\\s])"
    ]

    /// Arabic writes "and" (و) and "so" (ف) joined to the next word, so the
    /// "and" break above never sees it. A clause opened by one of them: a
    /// pronoun, a particle, a predicate ("وحاصل على موافقة FDA"), or a verb in
    /// the present ("ويشخص"). Not every word starting with و: "والدواء" is
    /// inside "إدارة الغذاء والدواء", and "ولا" opens a negation of its own.
    private static let arabicClauseStarts: [String] = [
        "و(?:هو|هي|هم|هما|نحن|إن\\w*|أن\\w*|لكن\\w*|قد|لقد|تم|سوف|حاصل\\w*|حائز\\w*|معتمد\\w*|مرخص\\w*|مصرح\\w*|ي\\w+)",
        "ف(?:هو|هي|إن\\w*|قد)", "بل"
    ]

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
