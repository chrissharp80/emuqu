import Foundation

// MARK: - Injury reports (input side)
//
// Someone telling Flo they are hurt is asking for help, and the help this app
// can give is the local emergency number. Before this concept existed,
// "I fell and hurt my ankle, get me to a hospital" passed the input guard and
// the model answered with a walking route. The guard now answers first, with
// `MedicalQueryGuard.injuryReply`.
//
// The patterns describe an injury happening to the speaker: first-person
// reports ("I'm hurt", "I fell"), a body part that was hurt, broken, twisted or
// sprained, bleeding, being unable to walk, or asking for an ambulance. They
// avoid the everyday senses of the same words: "fell asleep", "fell behind",
// "broke my PR", "cut myself some slack", "my legs hurt after the run" and
// "bleeding edge" all proceed.
//
// Input-only, like the symptom family: the model may say these words while
// explaining what to do, so `scrubFromOutput` does not list this concept.
extension MedicalTermLexicon {
    static let injury = Concept(
        id: "injury",
        latin: englishInjury + europeanInjury + nordicInjury + [
            "я\\s+(?:получил|получила)\\s+травму", "я\\s+травмировал(?:ся|ась)",  // ru
            "я\\s+(?:упал|упала|ранен|ранена)", "у\\s+меня\\s+(?:идёт|идет)\\s+кровь",
            "не\\s+могу\\s+(?:идти|ходить|наступить)", "подвернула?\\s+(?:ногу|лодыжку|стопу|колено)",
            "растяжени[ея]\\s+связок", "сотрясени[ея]\\s+мозга"
        ],
        unbounded: [
            "怪我をした", "けがをした", "怪我した", "転んだ", "転倒した", "血が出", "歩けない", "捻挫", "骨折", "足をひねった", // ja
            "我受伤了", "受伤了", "摔倒了", "摔伤", "在流血", "流血了", "走不了路", "不能走路", "扭伤", "崴了脚", "崴脚", // zh-Hans
            "다쳤", "넘어졌", "피가 나", "걸을 수 없", "못 걷", "삐었", "염좌", "골절", "뼈가 부러", // ko
            "أنا مصاب", "تعرضت لإصابة", "أصبت بإصابة", "سقطت", "وقعت على الأرض", "أنزف", "لا أستطيع المشي", "التواء في", "كسر في" // ar
        ]
    )

    /// English. "Fell" and "fallen" exclude the idioms that are not falls.
    private static let englishInjury: [String] = [
        "i(?:['’]?m|\\s+am)\\s+(?:(?:badly|really|seriously|very)\\s+)?(?:hurt|injured|bleeding)",
        "i(?:['’]?ve|\\s+have)?\\s+(?:just\\s+)?(?:been|got|gotten)\\s+(?:(?:badly|really|seriously)\\s+)?(?:hurt|injured)",
        "(?:hurt|injured)\\s+myself", "cut\\s+myself(?!\\s+(?:some\\s+)?slack)",
        "(?:hurt|injured|broke|broken|twisted|sprained|rolled|fractured|dislocated)\\s+my\\s+"
            + "(?:ankle|knee|leg|foot|hip|wrist|arm|back|neck|head|shoulder|hand|ribs?|collarbone|elbow|toe|finger)s?",
        "(?:ankle|knee|leg|foot|wrist|arm|hip|bone)\\s+(?:is|might\\s+be|may\\s+be|could\\s+be|feels)\\s+"
            + "(?:broken|sprained|twisted|fractured|dislocated)",
        "i\\s+(?:just\\s+)?(?:fell|took\\s+a\\s+(?:bad\\s+)?fall|had\\s+a\\s+(?:bad\\s+)?fall)" + notAFall,
        "i(?:['’]ve|\\s+have)\\s+(?:just\\s+)?fallen" + notAFall,
        "(?:crashed|came\\s+off|fell\\s+off)\\s+(?:my|the)\\s+(?:bike|bicycle)",
        "sprain(?:ed)?", "concussion", "bleeding(?!\\s+edge)", "ambulance",
        "(?:can['’]?t|cannot|can\\s+not|unable\\s+to)\\s+(?:walk|put\\s+weight|move\\s+my)"
    ]

    /// The idioms "fell asleep / behind / apart / short / in love / for it /
    /// off the pace" are not injuries.
    private static let notAFall =
        "(?!\\s+(?:asleep|behind|apart|short|in\\s+love|for|off\\s+the\\s+(?:pace|wagon)))"

    /// Body parts after "je me suis cassé / tordu / foulé la …", so the
    /// idiom "je me suis cassé la tête" (racked my brain) proceeds.
    private static let frenchBodyPart = "(?:jambe|cheville|bras|poignet|pied|genou|c[ôo]te|main|doigt)"

    /// Body parts after "me he roto / me torcí el …", so "me he roto el
    /// récord" and "me rompí la cabeza" (racked my brain) proceed.
    private static let spanishBodyPart = "(?:tobillo|pierna|brazo|mu[ñn]eca|pie|rodilla|costilla|mano|dedo)"

    /// French, Spanish, Portuguese (Brazil), Italian, German, Dutch. Breaks
    /// and twists name a body part, so "broke the record" idioms proceed.
    private static let europeanInjury: [String] = [
        "je\\s+suis\\s+(?:gravement\\s+)?bless[ée]e?", "je\\s+suis\\s+tomb[ée]e?(?!\\s+amoureu)",  // fr
        "je\\s+me\\s+suis\\s+(?:bless[ée]e?|fait\\s+mal)",
        "je\\s+me\\s+suis\\s+(?:cass[ée]e?|tordue?|foul[ée]e?)\\s+(?:la|le|un|une)\\s+" + frenchBodyPart,
        "je\\s+saigne", "je\\s+ne\\s+peux\\s+(?:plus|pas)\\s+marcher", "entorse",
        "estoy\\s+(?:herid[oa]|lesionad[oa]|sangrando)", "esguince",                          // es
        "me\\s+(?:he\\s+)?(?:lesionado|lastimado|hecho\\s+da[ñn]o|ca[íi]do)", "me\\s+(?:lesion[ée]|lastim[ée]|caí)",
        "me\\s+(?:he\\s+roto|he\\s+torcido|romp[íi]|torc[íi])\\s+(?:el|la|un|una)\\s+" + spanishBodyPart,
        "no\\s+puedo\\s+(?:caminar|andar)",
        "estou\\s+(?:ferid[oa]|machucad[oa]|sangrando)", "me\\s+machuquei", "eu\\s+ca[íi]",     // pt-BR
        "levei\\s+um\\s+tombo", "n[ãa]o\\s+consigo\\s+andar",
        "(?:tor[çc]i|quebrei)\\s+(?:o|a)\\s+(?:tornozelo|joelho|p[ée]|bra[çc]o|pulso|dedo|perna|m[ãa]o|costela)",
        "sono\\s+(?:ferit[oa]|cadut[oa])", "sto\\s+sanguinando", "distorsione",                 // it
        "mi\\s+sono\\s+(?:fatt[oa]\\s+male|ferit[oa])",
        "mi\\s+sono\\s+(?:rott[oa]|stort[oa])\\s+(?:il|la|un|una)\\s+(?:caviglia|gamba|braccio|polso|piede|ginocchio|costola|mano|dito)",
        "non\\s+riesco\\s+a\\s+camminare",
        "ich\\s+bin\\s+(?:schwer\\s+)?verletzt", "ich\\s+habe\\s+mich\\s+verletzt",            // de
        "ich\\s+bin\\s+(?:gest[üu]rzt|hingefallen|umgeknickt)", "ich\\s+blute",
        "ich\\s+kann\\s+nicht\\s+(?:mehr\\s+)?(?:gehen|auftreten)", "verstaucht", "gehirnersch[üu]tterung",
        "(?:bein|arm|kn[öo]chel|fu[ßs]|handgelenk|rippe)\\s+(?:ist\\s+)?gebrochen",
        "ik\\s+ben\\s+(?:gewond|gevallen)", "ik\\s+heb\\s+me\\s+(?:bezeerd|pijn\\s+gedaan)",   // nl
        "ik\\s+bloed", "ik\\s+kan\\s+niet\\s+lopen", "verstuikt", "verzwikt", "hersenschudding"
    ]

    /// Danish, Norwegian Bokmål, Swedish, Finnish, Icelandic. "Fell asleep"
    /// is excluded where it shares the verb.
    private static let nordicInjury: [String] = [
        "jeg\\s+er\\s+kommet\\s+til\\s+skade", "jeg\\s+er\\s+faldet(?!\\s+i\\s+s[øo]vn)",         // da
        "jeg\\s+har\\s+sl[åa]et\\s+mig", "jeg\\s+bl[øo]der", "jeg\\s+kan\\s+ikke\\s+g[åa]",
        "forstuvet", "hjernerystelse",
        "jeg\\s+er\\s+skadet", "jeg\\s+har\\s+(?:skadet\\s+meg|sl[åa]tt\\s+meg)",                  // nb
        "jeg\\s+(?:har\\s+)?falt(?!\\s+i\\s+s[øo]vn)", "forstuet", "vrikket",
        "jag\\s+(?:[äa]r|har\\s+blivit)\\s+skadad", "jag\\s+har\\s+skadat\\s+mig",                 // sv
        "jag\\s+(?:f[öo]ll|har\\s+fallit|ramlade|har\\s+ramlat)(?!\\s+i\\s+s[öo]mn)",
        "jag\\s+bl[öo]der", "jag\\s+kan\\s+inte\\s+g[åa]", "stukat", "stukad", "vrickat", "hj[äa]rnskakning",
        "olen\\s+(?:loukkaantunut|kaatunut)", "loukkasin\\s+(?:jalkani|polveni|nilkkani|k[äa]teni|selk[äa]ni|p[äa][äa]ni)", "kaaduin", "vuodan\\s+verta",    // fi
        "en\\s+(?:pysty|voi)\\s+k[äa]vel(?:em[äa][äa]n|l[äa])", "nyrj[äa]ht\\w*", "aivot[äa]r[äa]hdys",
        "[ée]g\\s+er\\s+(?:slasa[ðd]ur|sl[öo]su[ðd])", "[ée]g\\s+meiddi\\s+mig", "[ée]g\\s+datt",   // is
        "[ée]g\\s+get\\s+ekki\\s+gengi[ðd]", "þa[ðd]\\s+bl[æa][ðd]ir", "togna[ðd]i", "heilahristing\\w*"
    ]

    /// Concepts the INPUT guard answers with the injury reply: call the local
    /// emergency number if it could be serious, and see a clinician otherwise.
    static let refuseAsInjury: [Concept] = [injury]
}
