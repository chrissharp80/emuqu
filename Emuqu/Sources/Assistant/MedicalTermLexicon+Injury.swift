import Foundation

// MARK: - Injury reports (input side)
//
// Someone telling Flo they are hurt is asking for help, and the help this app
// can give is the local emergency number. Without this concept, "I fell and
// hurt my ankle, get me to a hospital" would pass the input guard and the
// model would answer with a walking route; the guard answers first, with
// `MedicalQueryGuard.injuryReply`.
//
// The patterns describe an injury happening to the speaker: first-person
// reports ("I'm hurt", "I fell"), a body part that was hurt, broken, twisted or
// sprained, bleeding, being unable to walk, or asking for an ambulance. They
// avoid the everyday senses of the same words: "fell asleep", "fell behind",
// "broke my PR", "cut myself some slack", "my legs hurt after the run" and
// "bleeding edge" all proceed. The English and CJK injury nouns count only in
// a report shape (the app's own Help suggests typing "I have a stress
// fracture" as a memory fact); several other locales still list a bare noun
// (entorse, esguince, distorsione, hjernerystelse …), so a general question
// that names one is answered with the injury reply.
//
// Pain follows the same tense rule as the spoken symptom reports: a joint that
// hurts now ("my knee hurts, should I push through it?") is an injury report
// mid-workout, and one that gave way is one in any tense. Pain placed after a
// session or as a pattern ("my knee hurts after long runs", "when I run"), and
// legs or muscles that hurt (soreness), reach the model.
//
// Input-only, like the symptom family: the model may say these words while
// explaining what to do, so `scrubFromOutput` does not list this concept.
extension MedicalTermLexicon {
    static let injury = Concept(
        id: "injury",
        latin: englishInjury + europeanInjury + nordicInjury + jointPain + [
            "я\\s+(?:получил|получила)\\s+травму", "я\\s+травмировал(?:ся|ась)",  // ru
            "я\\s+(?:упал|упала|ранен|ранена)", "у\\s+меня\\s+(?:идёт|идет)\\s+кровь",
            // "Идти" is also "go": "не могу идти на тренировку" is a schedule.
            "не\\s+могу\\s+(?:идти(?!\\s+(?:на|в|к|сегодня|завтра)\\b)|ходить|наступить)", "подвернула?\\s+(?:ногу|лодыжку|стопу|колено)",
            "растяжени[ея]\\s+связок", "сотрясени[ея]\\s+мозга"
        ],
        unbounded: [
            "怪我をした", "けがをした", "怪我した", "転んだ", "転倒した", "血が出", "歩けない", "捻挫(?:した|して|しま)",
            "骨折(?:した|して|しま)", "足をひねった", // ja
            "我受伤了", "受伤了", "摔倒了", "摔伤", "在流血", "流血了", "走不了路", "不能走路", "扭伤了", "骨折了", "崴了脚", "崴脚", // zh-Hans
            "다쳤", "넘어졌", "피가 나", "걸을 수 없", "못 걷", "삐었", "염좌가 (?:생겼|왔)", "골절(?:됐|되었|된 것 같)", "뼈가 부러", // ko
            // "سقطت" is also "it fell" ("سقطت درجة التعافي"), and "أنا مصاب ب…"
            // is "I have <an illness>", so both need the injury shape.
            "أنا مصاب(?!\\s*ب)", "تعرضت لإصابة", "أصبت بإصابة", "سقطت(?=\\s+(?:على|من|أثناء|وأنا|و)|\\s*[.!؟?،]|\\s*$)",
            "وقعت على الأرض", "أنزف", "لا أستطيع المشي", "التواء في", "كسر في" // ar
        ] + jointPainUnbounded
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
        // "Came off the bike" is also a triathlon transition.
        "(?:crashed|fell\\s+off)\\s+(?:my|the)\\s+(?:bike|bicycle)(?!\\s+(?:computer|app|gps|light|lock)\\b)",
        "came\\s+off\\s+my\\s+(?:bike|bicycle)",
        // The nouns only in a report shape, so "how long does a sprain take to
        // heal?" and "what is concussion protocol?" reach the model.
        "sprained", "concussed",
        "(?:i\\s+(?:think\\s+i\\s+)?(?:have|got|had)|i['’]?ve\\s+got|it['’]?s|might\\s+be|may\\s+be|could\\s+be)\\s+"
            + "(?:a\\s+)?(?:sprain|concussion)",
        "(?:is|are|it['’]?s|keeps?|won['’]?t\\s+stop|started)\\s+bleeding", "bleeding\\s+(?:badly|heavily|a\\s+lot)",
        "(?:call|need|get|send)\\s+(?:me\\s+)?(?:an?\\s+)?ambulance",
        "(?:can['’]?t|cannot|can\\s+not|unable\\s+to)\\s+(?:walk|put\\s+(?:any\\s+)?weight(?!\\s+on\\s+the\\s+bar)|move\\s+my)"
    ]

    /// The idioms "fell asleep / behind / apart / short / in love / for it /
    /// off pace / off the plan / out of shape / into a rut / down the
    /// rankings", and "a fall in fitness", are not injuries.
    private static let notAFall =
        "(?!\\s+(?:asleep|behind|apart|short|in\\s+love|for|off\\s+(?:the\\s+)?(?:pace|plan|wagon|schedule|routine)|out\\s+of"
        + "|into|down\\s+the\\s+(?:rankings|standings|leaderboard)|back|ill|sick|victim|from\\s+the\\s+top|in\\s+(?:fitness|form|pace)))"

    /// Body parts after "je me suis cassé / tordu / foulé la …", so the
    /// idiom "je me suis cassé la tête" (racked my brain) proceeds.
    private static let frenchBodyPart = "(?:jambe|cheville|bras|poignet|pied|genou|c[ôo]te|main|doigt)"

    /// Body parts after "me he roto / me torcí el …", so "me he roto el
    /// récord" and "me rompí la cabeza" (racked my brain) proceed.
    private static let spanishBodyPart = "(?:tobillo|pierna|brazo|mu[ñn]eca|pie|rodilla|costilla|mano|dedo)"

    /// French, Spanish, Portuguese (Brazil), Italian, German, Dutch. Breaks
    /// and twists name a body part, so "broke the record" idioms proceed.
    private static let europeanInjury: [String] = [
        "je\\s+suis\\s+(?:gravement\\s+)?bless[ée]e?", "je\\s+suis\\s+tomb[ée]e?(?!\\s+(?:amoureu\\w*|sur|malade|d['’]accord|en\\s+panne|dans\\s+le\\s+pi[èe]ge))", // fr: not "tombé sur" (came across)
        "je\\s+me\\s+suis\\s+(?:bless[ée]e?|fait\\s+mal)",
        "je\\s+me\\s+suis\\s+(?:cass[ée]e?|tordue?|foul[ée]e?)\\s+(?:la|le|un|une)\\s+" + frenchBodyPart,
        "je\\s+saigne", "je\\s+ne\\s+peux\\s+(?:plus|pas)\\s+marcher", "entorse",
        "estoy\\s+(?:herid[oa]|lesionad[oa]|sangrando)", "esguince",                          // es
        "me\\s+(?:he\\s+)?(?:lesionado|lastimado|hecho\\s+da[ñn]o|ca[íi]do)", "me\\s+(?:lesion[ée]|lastim[ée]|caí)",
        "me\\s+(?:he\\s+roto|he\\s+torcido|romp[íi]|torc[íi])\\s+(?:el|la|un|una)\\s+" + spanishBodyPart,
        "no\\s+puedo\\s+(?:caminar|andar(?!\\s+en\\s+(?:bici|bicicleta|moto)))", // "andar en bici" is riding
        "estou\\s+(?:ferid[oa]|machucad[oa]|sangrando)", "me\\s+machuquei", "eu\\s+ca[íi](?!\\s+(?:no\\s+sono|na\\s+real|na\\s+armadilha))", // pt-BR
        "levei\\s+um\\s+tombo", "n[ãa]o\\s+consigo\\s+andar(?!\\s+de\\s+(?:bike|bici|bicicleta|moto))",
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
        "ik\\s+bloed", "ik\\s+kan\\s+niet\\s+(?:meer\\s+lopen|lopen(?=\\s*(?:$|[.,!?]|meer|op\\s+mijn)))", "verstuikt", "verzwikt", "hersenschudding" // lopen is also "run"
    ]

    /// Danish, Norwegian Bokmål, Swedish, Finnish, Icelandic. "Fell asleep"
    /// is excluded where it shares the verb.
    private static let nordicInjury: [String] = [
        "jeg\\s+er\\s+kommet\\s+til\\s+skade", "jeg\\s+er\\s+faldet(?!\\s+i\\s+s[øo]vn)",         // da
        "jeg\\s+har\\s+sl[åa]et\\s+mig", "jeg\\s+bl[øo]der", "jeg\\s+kan\\s+ikke\\s+g[åa](?!\\s+(?:til|p[åa]|ud|ut|i\\s+dag|med|hjem|en\\s+tur)\\b)", // gå is also "go"
        "forstuvet", "hjernerystelse",
        "jeg\\s+er\\s+skadet", "jeg\\s+har\\s+(?:skadet\\s+meg|sl[åa]tt\\s+meg)",                  // nb
        "jeg\\s+(?:har\\s+)?falt(?!\\s+i\\s+s[øo]vn)", "forstuet", "vrikket",
        "jag\\s+(?:[äa]r|har\\s+blivit)\\s+skadad", "jag\\s+har\\s+skadat\\s+mig",                 // sv
        "jag\\s+(?:f[öo]ll|har\\s+fallit|ramlade|har\\s+ramlat)(?!\\s+i\\s+s[öo]mn)",
        "jag\\s+bl[öo]der", "jag\\s+kan\\s+inte\\s+g[åa](?!\\s+(?:till|p[åa]|ut|i\\s+dag|med|hem|en\\s+tur)\\b)", "stukat", "stukad", "vrickat", "hj[äa]rnskakning",
        "olen\\s+(?:loukkaantunut|kaatunut)", "loukkasin\\s+(?:jalkani|polveni|nilkkani|k[äa]teni|selk[äa]ni|p[äa][äa]ni)", "kaaduin", "vuodan\\s+verta",    // fi
        "en\\s+(?:pysty|voi)\\s+k[äa]vel(?:em[äa][äa]n|l[äa])", "nyrj[äa]ht\\w*", "aivot[äa]r[äa]hdys",
        "[ée]g\\s+er\\s+(?:slasa[ðd]ur|sl[öo]su[ðd])", "[ée]g\\s+meiddi\\s+mig", "[ée]g\\s+datt",   // is
        "[ée]g\\s+get\\s+ekki\\s+gengi[ðd]", "þa[ðd]\\s+bl[æa][ðd]ir", "togna[ðd]i", "heilahristing\\w*"
    ]

    /// A joint that hurts now or gave way. Not legs or muscles (soreness), and
    /// not pain placed after a session or given as a pattern.
    private static let notSoreness =
        "(?!\\s*,?\\s+(?:\\w+\\s+){0,3}(?:after|since|from|yesterday|last|a\\s+(?:bit|little)|when|whenever|every|sometimes|"
        + "después|desde|cuando|ayer|un\\s+poco|après|depuis|quand|hier|un\\s+peu|nach|seit|wenn|gestern|beim|etwas|"
        + "dopo|quando|ieri|un\\s+po|depois|ontem|um\\s+pouco|na|sinds|als|gisteren|een\\s+beetje|"
        + "efter|etter|siden|sedan|når|när|igår|i\\s+går|lidt|litt|lite|после|с\\s+тех|когда|вчера|немного)\\b)"

    private static let jointPain: [String] = [
        "my\\s+(?:ankle|knee|hip|foot|wrist|neck|shoulder|achilles|heel|elbow|toe)s?\\s+(?:(?:really|suddenly|now|still)\\s+)?"
            + "(?:hurts|is\\s+(?:really\\s+)?hurting|is\\s+killing\\s+me)" + notSoreness,
        "my\\s+(?:ankle|knee|hip|back)s?\\s+(?:just\\s+)?(?:gave\\s+(?:way|out)|buckled|popped|locked\\s+up)",
        "me\\s+duele(?:\\s+mucho)?\\s+(?:el|la)\\s+(?:tobillo|rodilla|cadera|pie|mu[ñn]eca|cuello|hombro|tal[óo]n)" + notSoreness, // es
        "j['’]ai\\s+(?:tr[èe]s\\s+)?mal\\s+(?:au|[àa]\\s+la|[àa]\\s+l['’])\\s*(?:genou|cheville|pied|poignet|hanche|cou|[ée]paule|talon)" + notSoreness, // fr
        "mein(?:e)?\\s+(?:knie|kn[öo]chel|fu[ßs]|handgelenk|h[üu]fte|schulter|ferse)\\s+(?:tut\\s+(?:so\\s+)?weh|schmerzt)" + notSoreness, // de
        "(?:knie|kn[öo]chel)\\s+(?:ist\\s+)?weggeknickt",
        "mi\\s+fa\\s+(?:molto\\s+)?male\\s+(?:il|la)\\s+(?:ginocchio|caviglia|piede|polso|anca|spalla|tallone)" + notSoreness, // it
        "(?:meu|minha)\\s+(?:joelho|tornozelo|p[ée]|pulso|quadril|ombro|calcanhar)\\s+(?:est[áa]|t[áa])\\s+doendo" + notSoreness, // pt-BR
        "mijn\\s+(?:knie|enkel|voet|pols|heup|schouder|hiel)\\s+doet\\s+(?:zo\\s+|erg\\s+)?pijn" + notSoreness, // nl
        "(?:ondt|vondt|ont)\\s+i\\s+(?:kn[æa]et|kneet|kn[äa]t|anklen|ankelen|fotleden|h[øo]ften|h[öo]ften|skulderen|axeln)" + notSoreness, // da, nb, sv
        "(?:polveen|nilkkaan|lonkkaan|olkap[äa][äa]h[äa]n)\\s+sattuu" + notSoreness, // fi
        "болит\\s+(?:колено|лодыжка|голеностоп|запястье|плечо|пятка)" + notSoreness, "колено\\s+подкосилось" // ru
    ]

    /// No word boundaries, so a fixed lookbehind keeps "after the run, my
    /// knee hurts" out: 後 / 后 / 후 directly before the joint.
    private static let jointPainUnbounded: [String] = [
        "(?<!後)(?<!後、)(?<!後で)(?<!後に)(?<!あと)(?:膝|足首|手首|股関節|かかと)が(?:急に)?痛(?:い|くて|む)", "膝が抜けた", // ja
        "(?<!后)(?<!后，)(?:膝盖|脚踝|手腕|髋关节|脚后跟)(?:很|好|突然)?(?:疼|痛)", // zh-Hans
        "(?<!후에 )(?<!후 )(?<!나서 )(?:무릎|발목|손목|고관절)이 (?:너무 |갑자기 )?아파", // ko
        "(?:ركبتي|كاحلي) (?:تؤلمني|يؤلمني)(?!\\s+بعد)", "(?:تؤلمني|يؤلمني) (?:ركبتي|كاحلي)(?!\\s+بعد)" // ar
    ]

    /// Concepts the INPUT guard answers with the injury reply: call the local
    /// emergency number if it could be serious, and see a clinician otherwise.
    static let refuseAsInjury: [Concept] = [injury]
}
