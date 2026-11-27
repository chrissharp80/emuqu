import Foundation

// MARK: - Categorical autonomic-state claims (output side)
//
// Kept apart from `MedicalTermLexicon.swift`, which the copy linter parses for
// `neverInStaticCopy`; this concept is output-only and not in that group.
extension MedicalTermLexicon {
    /// Categorical claims about an autonomic or recovery *state*.
    ///
    /// The rest of the perimeter is built around regulated nouns — diagnosis,
    /// injury, FDA, named conditions — and says nothing about categorical
    /// certainty, which is the other half of App Review Guideline 1.4.1.
    /// "Clear parasympathetic dominance", "true recovery state" and "Your body
    /// is in solid recovery mode" are the shapes this catches.
    ///
    /// The concept is the *certainty*, not the topic. Explaining parasympathetic
    /// activity is fine and the app does it at length; declaring that the user
    /// IS in a given autonomic state on the strength of one HRV-derived number
    /// is not, because nothing downstream can substantiate it.
    static let categoricalAutonomicState = Concept(
        id: "categorical-autonomic-state",
        latin: [
            "(?:clear|strong|true|definite|unmistakable|obvious)\\s+(?:parasympathetic|sympathetic|vagal|autonomic)\\s+dominance",
            "true\\s+(?:recovery|fatigue|stress|fitness)\\s+state",
            "in\\s+(?:solid|full|complete|prime|deep)\\s+recovery\\s+mode",
            // Case-sensitive on purpose: the claim is the emphasis
            // ("This IS your recovery state"). The lexicon compiles
            // case-insensitively, and without `(?-i:…)` this matched the
            // ordinary "This is your recovery score for today".
            "(?-i:[Tt]his\\s+IS\\s+your)",
            "dominance\\s+(?:parasympathique|sympathique|vagale)\\s+(?:claire|nette|franche)",
            "v[ée]ritable\\s+[ée]tat\\s+de\\s+r[ée]cup[ée]ration",                          // fr
            "dominancia\\s+(?:parasimp[áa]tica|simp[áa]tica|vagal)\\s+(?:clara|evidente)",
            "verdadero\\s+estado\\s+de\\s+recuperaci[óo]n",                                  // es
            "domin[âa]ncia\\s+(?:parassimp[áa]tica|simp[áa]tica|vagal)\\s+(?:clara|evidente)",
            "verdadeiro\\s+estado\\s+de\\s+recupera[çc][ãa]o",                               // pt-BR
            "dominanza\\s+(?:parasimpatica|simpatica|vagale)\\s+(?:chiara|netta)",
            "vero\\s+stato\\s+di\\s+recupero",                                               // it
            "(?:klare|eindeutige)\\s+(?:parasympathische|sympathische|vagale)\\s+dominanz",
            "echter\\s+erholungszustand",                                                    // de
            "(?:duidelijke|onmiskenbare)\\s+(?:parasympathische|sympathische|vagale)\\s+dominantie",
            "echte\\s+herstelstatus",                                                        // nl
            "(?:tydelig|klar)\\s+(?:parasympatisk|sympatisk|vagal)\\s+dominans",
            "(?:ekte|reel)\\s+restitusjonstilstand",                                         // da, nb
            "(?:tydlig|klar)\\s+(?:parasympatisk|sympatisk|vagal)\\s+dominans",
            "verkligt\\s+[åa]terh[äa]mtningstillst[åa]nd",                                   // sv
            "(?:selke[äa]|selv[äa])\\s+(?:parasympaattinen|sympaattinen)\\s+hallitsevuus",
            "todellinen\\s+palautumistila",                                                  // fi
            "(?:sk[ýy]r|greinileg)\\s+(?:parasympat[íi]sk|sympat[íi]sk)\\s+yfirr[áa][ðd]",   // is
            "(?:явное|чёткое|четкое)\\s+(?:парасимпатическое|симпатическое)\\s+преобладание",
            "истинное\\s+состояние\\s+восстановления"                                        // ru
        ],
        unbounded: [
            "明らかな副交感神経優位", "明らかな交感神経優位", "真の回復状態",
            "明显的副交感优势", "明显的交感优势", "真正的恢复状态",
            "명확한 부교감 우세", "명확한 교감 우세", "진정한 회복 상태",
            "هيمنة واضحة", "حالة تعافٍ حقيقية"
        ]
    )
}
