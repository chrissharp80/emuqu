import Foundation

// MARK: - Self-harm (input side)
//
// The concept the input guard tests first, answered with the crisis reply
// (`MedicalQueryGuard.selfHarmReply`) rather than any model's words. Kept in
// its own file because it carries intent phrasing for every shipped
// language. Input-only: the model may say these words while pointing someone
// at help, so `scrubFromOutput` does not list this concept.
extension MedicalTermLexicon {
    /// Saying one means to die or to harm oneself, in every shipped language:
    /// the nouns ("suicide", "self-harm") and the first-person intent
    /// phrasings ("I want to die", "I want to kill myself", "I don't want to
    /// live anymore", "end my life", "I want to hurt myself").
    ///
    /// Exercise talk borrows the same verbs: "I'm dying after that run",
    /// "this hill is killing me", "a killer workout", "das Training bringt
    /// mich um", "esta cuesta me está matando", "死にそう", "累死了". So the
    /// verb alone never matches: each phrasing needs the speaker's own wish
    /// ("want to", "will", "quiero", "haluan", "хочу", "たい", "싶"), the
    /// reflexive "myself" form in a first person that idioms do not use, or a
    /// fixed phrase ("end my life", "take my own life") with no workout sense.
    /// "Hurt myself" counts only as a wish: "I hurt myself" is an injury,
    /// which the injury reply answers.
    static let selfHarm = Concept(
        id: "self-harm",
        latin: [
            // "Suicide sprints" (and runs, drills, shuttles, lines) are a
            // common conditioning drill, so that shape is excluded; the plural
            // "suicides" never matches inside `\b…\b`. The lookahead lives on
            // the one pattern that matches English, French and Dutch alike.
            "suicidal", "su[ïi]cide(?!\\s+(?:sprints?|runs?|drills?|shuttles?|lines?)\\b)",
            "kill\\s+myself", "end\\s+my\\s+life",
            // "The hill I want to die on" is a stand someone takes.
            "(?:want\\s+to|wanna)\\s+die(?!\\s+on\\b)",
            "self[-\\s]?harm(?:ing)?",
            // Not "hurt myself" or "cut myself": in a training app those are
            // mostly injuries and kitchen accidents, not a crisis. Wanting to
            // is a different sentence.
            "(?:harm|harming|cutting)\\s+myself(?!\\s+(?:some\\s+)?slack)", "(?:want\\s+to|wanna)\\s+hurt\\s+myself",
            // iOS types a curly apostrophe by default.
            "(?:don['’]?t|do\\s+not)\\s+want\\s+to\\s+(?:live|be\\s+alive|be\\s+here\\s+anymore)",
            "wish\\s+i\\s+(?:was|were)\\s+dead", "take\\s+my\\s+own\\s+life", "(?:want\\s+to|wanna|going\\s+to|gonna)\\s+end\\s+it\\s+all",
            "(?:take|taking|took)\\s+an?\\s+overdose",
            "overdos(?:e|ing)\\s+on\\s+(?:pills|meds|medication|tablets)",
            // Stems end in `\\w*` so inflections ("suicidas", "самоубийство")
            // and compounds ("Selbstmordgedanken") match inside `\\b…\\b`.
            // `(?!e)` leaves English "suicide(s)" to the drill-aware pattern.
            "me\\s+suicider",                          // fr
            "su[ïi]c[íi]d(?!e)\\w*",                    // es, it, pt-BR, fr, nl
            "selbstmord\\w*", "suizid\\w*",            // de
            "zelfmoord\\w*",                           // nl
            "selvmord\\w*",                            // da, nb
            "sj[äa]lvmord\\w*",                        // sv
            "itsemurh\\w*",                            // fi
            "sj[áa]lfsv[íi]g\\w*",                     // is
            "суицид\\w*", "самоубийств\\w*",          // ru
            "покончить\\s+с\\s+собой",                 // ru
            // de: "ich will sterben", "ich will nicht mehr leben", "ich will
            // mich umbringen", "ich bringe mich um", "mir etwas antun".
            // "Das bringt mich um" (third person) is the workout idiom.
            "(?:will|m[öo]chte|moechte)\\s+(?:(?:nur\\s+noch|einfach)\\s+)?(?:sterben|tot\\s+sein|nicht\\s+mehr\\s+leben)",
            "nicht\\s+mehr\\s+leben\\s+(?:will|m[öo]chte)",
            "(?:will|m[öo]chte|moechte)\\s+mich\\s+(?:umbringen|t[öo]ten|selbst\\s+verletzen|ritzen)",
            "ich\\s+bringe\\s+mich\\s+um", "mich\\s+umzubringen",
            "mein(?:em)?\\s+leben\\s+(?:beenden|ein\\s+ende\\s+(?:setzen|machen))",
            "mir\\s+das\\s+leben\\s+(?:zu\\s+)?nehmen", "mir\\s+(?:etwas|was)\\s+an(?:zu)?tun", "selbstverletz\\w*",
            // es: "quiero morir(me)", "quiero matarme", "no quiero vivir",
            // "quitarme la vida". "Me muero", "me está matando" are idioms.
            "(?:quiero|ganas\\s+de)\\s+morir(?:me)?(?!\\s+en\\s+el\\s+intento)", "me\\s+quiero\\s+(?:morir|matar)",
            "(?:quiero|ganas\\s+de|pienso\\s+en|pensando\\s+en)\\s+matarme",
            "no\\s+quiero\\s+(?:seguir\\s+)?vivir", "quitarme\\s+la\\s+vida", "(?:acabar|terminar)\\s+con\\s+mi\\s+vida",
            "(?:quiero|ganas\\s+de)\\s+hacerme\\s+da[ñn]o", "me\\s+quiero\\s+hacer\\s+da[ñn]o", "autolesi\\w*",
            // pt-BR: "quero morrer", "quero me matar", "não quero mais viver".
            "(?:quero|vontade\\s+de)\\s+morrer", "(?:quero|vontade\\s+de|pensando\\s+em|penso\\s+em)\\s+me\\s+matar",
            "n[ãa]o\\s+quero\\s+(?:mais\\s+viver|viver\\s+mais)", "tirar\\s+(?:a\\s+)?minha\\s+(?:pr[óo]pria\\s+)?vida",
            "acabar\\s+com\\s+(?:a\\s+)?minha\\s+vida", "(?:quero|vontade\\s+de)\\s+me\\s+(?:machucar|ferir|cortar)",
            "automutil\\w*",                           // pt-BR, fr
            // fr: "je veux mourir", "envie de mourir", "je veux me tuer", "je
            // ne veux plus vivre", "mettre fin à mes jours". "Ça me tue" is
            // the idiom.
            "(?:veux|voudrais|envie\\s+de)\\s+(?:mourir|me\\s+tuer|me\\s+faire\\s+du\\s+mal)",
            "veux\\s+plus\\s+vivre", "mettre\\s+fin\\s+[àa]\\s+(?:mes\\s+jours|ma\\s+vie)", "en\\s+finir\\s+avec\\s+(?:la|ma)\\s+vie",
            // it: "voglio morire", "voglio uccidermi", "non voglio più vivere",
            // "farla finita" (not "farla finita con" something).
            "(?:voglio|vorrei)\\s+(?:morire|uccidermi|ammazzarmi|farmi\\s+del\\s+male)", "mi\\s+voglio\\s+(?:uccidere|ammazzare)",
            "non\\s+voglio\\s+pi[ùu]\\s+vivere", "farla\\s+finita(?!\\s+con\\b)", "togliermi\\s+la\\s+vita",
            // nl: "ik wil dood", "ik wil niet meer leven", "mezelf van kant
            // maken". "Ik ga dood" is the idiom.
            "(?:wil|zou\\s+willen)\\s+(?:dood(?:gaan)?|sterven)", "wil\\s+niet\\s+meer\\s+leven",
            "mezelf\\s+(?:van\\s+kant\\s+maken|iets\\s+aan\\s*doen)", "wil\\s+mezelf\\s+(?:doden|pijn\\s+doen)",
            "einde\\s+aan\\s+mijn\\s+leven", "mijn\\s+leven\\s+be[ëe]indigen", "zelfbeschadig\\w*",
            // da, nb: "jeg vil dø", "vil ikke leve mere/mer", "vil tage mit
            // eget liv", "vil ta livet av meg". "Bakken tar livet av meg" is
            // the idiom.
            "(?:vil|lyst\\s+til\\s+(?:at|[åa]))\\s+dø",
            "vil\\s+ikke\\s+leve\\s+(?:mere|mer|længere|lenger)",
            "(?:vil|lyst\\s+til\\s+(?:at|[åa]))\\s+(?:sl[åa]\\s+mig\\s+selv\\s+ihjel|ta\\s+livet\\s+av\\s+meg|skade\\s+(?:mig|meg)\\s+selv)",
            "ta(?:ge)?\\s+mitt?\\s+eget\\s+liv", "selvskad\\w*",
            // sv: "jag vill dö", "vill inte leva längre", "vill ta livet av mig".
            "(?:vill|lust\\s+att)\\s+dö", "vill\\s+inte\\s+leva\\s+(?:längre|mer)",
            "(?:vill|tänker)\\s+(?:ta\\s+livet\\s+av\\s+mig|skada\\s+mig\\s+själv)", "ta\\s+mitt\\s+eget\\s+liv", "självskad\\w*",
            // fi: "haluan kuolla", "en halua enää elää", "haluan tappaa itseni".
            // "Mäki tappaa minut" is the idiom.
            "haluan\\s+kuolla", "en\\s+halua\\s+(?:enää\\s+)?elää",
            "(?:haluan|aion)\\s+(?:tappaa\\s+itseni|satuttaa\\s+itseäni|vahingoittaa\\s+itseäni)", "lopettaa\\s+elämäni", "itsetuho\\w*",
            // is: "ég vil deyja", "mig langar að deyja", "vil ekki lifa lengur".
            "(?:vil|langar\\s+a[ðd])\\s+deyja", "vil\\s+ekki\\s+lifa\\s+lengur",
            "(?:vil|langar\\s+a[ðd])\\s+(?:drepa\\s+mig|ska[ðd]a\\s+mig|mei[ðd]a\\s+mig)", "taka\\s+mitt\\s+eigi[ðd]\\s+l[íi]f",
            // ru: "хочу умереть", "не хочу жить", "хочу убить себя". "Меня
            // убивает" is the idiom.
            "хоч(?:у|ется)\\s+умереть", "не\\s+хочу\\s+(?:больше\\s+)?жить", "жить\\s+не\\s+хочу",
            "хоч(?:у|ется)\\s+(?:убить\\s+себя|причинить\\s+себе\\s+(?:вред|боль))",
            "покончить\\s+с\\s+жизнью", "лишить\\s+себя\\s+жизни", "самоповрежд\\w*"
        ] + selfHarmRumination,
        unbounded: [
            "自殺", "自杀", "자살", "انتحار",
            // ja: "死にたい", "消えたい", "生きたくない". "死にそう" and
            // "死ぬほど" are the idioms.
            "死にたい", "消えたい", "生きていたくない", "生きたくない", "自分を傷つけたい", "命を絶ちたい", "自傷", "リストカット",
            // zh-Hans: "我想死", "不想活了", "活不下去". "累死了", "要了我的命"
            // are the idioms; "不想活动" (don't want to exercise) is why
            // "不想活" needs its "了" or "再".
            "我想死", "好想死", "想去死", "不想活了", "不想再活", "活不下去", "结束自己的生命", "结束我的生命", "想伤害自己", "自残", "轻生",
            // ko: "죽고 싶어", "살고 싶지 않아", "자해". "죽겠다" and
            // "죽을 것 같아" are the idioms. Substrings, so the spaced and
            // unspaced spellings are both listed.
            "죽고 싶", "죽고싶", "살고 싶지 않", "살고싶지 않", "살고 싶지않", "살고싶지않", "자해", "목숨을 끊", "삶을 끝내",
            "나를 해치고 싶", "자신을 해치고 싶", "스스로를 해치고 싶", "자신을 해치고싶",
            // ar: "أريد أن أموت", "أقتل نفسي", "لا أريد أن أعيش". "يقتلني"
            // (it is killing me) is the idiom. With and without the hamza,
            // which many people leave off when typing.
            "أريد أن أموت", "أريد ان أموت", "اريد ان اموت", "أريد الموت", "اريد الموت", "أتمنى الموت", "اتمنى الموت",
            "أقتل نفسي", "اقتل نفسي", "لا أريد أن أعيش", "لا اريد ان اعيش", "إنهاء حياتي", "انهاء حياتي", "أنهي حياتي", "انهي حياتي",
            "أؤذي نفسي", "اؤذي نفسي", "إيذاء نفسي", "ايذاء نفسي"
        ] + selfHarmRuminationUnbounded
    )

    /// Ongoing and spoken forms: thinking about it ("I keep thinking about
    /// killing myself", "no dejo de pensar en morirme"), contractions and
    /// dropped accents ("I dont wanna live", "langre"), and the fixed
    /// phrases people use for not wanting to live ("better off dead", "keine
    /// Lust mehr zu leben", "жить не хочется", "活着没意思").
    ///
    /// "Killing myself" alone is training talk ("I'm killing myself on these
    /// intervals"), so it counts only after a thought or a wish ("about",
    /// "of", "feel like", "considering"). Hurting or cutting oneself needs the
    /// thought itself ("thinking about", "feel like"): "worried about hurting
    /// myself on the descent" is a fear of injury, and "cutting myself some
    /// slack" is rest. "Ending it" alone is a session cut short; only "ending
    /// it all" counts.
    static let selfHarmRumination: [String] = [
        "(?:about|of|considering|contemplating|planning|plan\\s+on|feel\\s+like|felt\\s+like)\\s+killing\\s+myself",
        "(?:(?:thinking|thought|thoughts|think)\\s+(?:about|of)|feel\\s+like|felt\\s+like)\\s+"
            + "(?:hurting|harming|cutting)\\s+myself(?!\\s+(?:some\\s+)?slack)",
        "(?:about|of|considering|contemplating)\\s+(?:ending\\s+(?:my\\s+life|it\\s+all)|taking\\s+my\\s+(?:own\\s+)?life)",
        "ending\\s+it\\s+all", "(?:be|been|i['’]?d\\s+be)\\s+better\\s+off\\s+dead", "no\\s+reason\\s+to\\s+live",
        "(?:don['’]?t|do\\s+not)\\s+(?:wanna|want\\s+to)\\s+(?:live|be\\s+alive|exist)",
        // es
        "(?:pensar|pienso|pensando|pensado)\\s+en\\s+(?:matarme|morirme|quitarme\\s+la\\s+vida|hacerme\\s+da[ñn]o)",
        "no\\s+quiero\\s+seguir\\s+viviendo", "(?:quisiera|ojal[áa])\\s+(?:morirme|estar\\s+muert[oa])",
        // fr: "en finir avec" something is a session; "en finir" alone is not.
        "pens(?:e|er|ais|ant)\\s+[àa]\\s+(?:me\\s+tuer|mourir|en\\s+finir|me\\s+faire\\s+du\\s+mal|me\\s+suicider)",
        "(?:veux|voudrais|envie\\s+d['’]?)\\s*en\\s+finir\\b(?!\\s+avec\\b)", "(?:plus|pas)\\s+envie\\s+de\\s+vivre",
        // de
        "keine\\s+lust\\s+mehr\\s+(?:zu|auf\\s+das)\\s+leben", "nicht\\s+mehr\\s+am\\s+leben\\s+sein",
        // it
        "(?:pens(?:o|are|ando))\\s+(?:di|a)\\s+(?:uccidermi|ammazzarmi|togliermi\\s+la\\s+vita|farla\\s+finita(?!\\s+con\\b))",
        // pt-BR
        "(?:pensar|pensei|pensando|penso)\\s+em\\s+(?:morrer|me\\s+matar|tirar\\s+(?:a\\s+)?minha\\s+vida)",
        // nl
        "mezelf\\s+van\\s+kant\\s+te\\s+maken", "mezelf\\s+(?:te\\s+)?(?:doden|ombrengen)",
        // da, nb: the reflexive "mig/meg selv" is not the idiom "slår mig ihjel".
        "sl[åa]\\s+(?:mig|meg)\\s+selv\\s+ihjel",
        "(?:vil|lyst\\s+til\\s+at|t[æa]nker\\s+p[åa]\\s+at)\\s+tage\\s+livet\\s+af\\s+mig",
        "(?:tenker|t[æa]nker|tenkt|t[æa]nkt)\\s+p[åa]\\s+(?:at|[åa])\\s+(?:ta\\s+livet\\s+av\\s+meg|d[øo]|skade\\s+(?:mig|meg)\\s+selv)",
        // sv
        "t[äa]nker\\s+p[åa]\\s+att\\s+(?:ta\\s+livet\\s+av\\s+mig|d[öo]|skada\\s+mig\\s+sj[äa]lv)",
        "vill\\s+inte\\s+leva\\s+l[äa]ngre",
        // fi, is
        "tappaa\\s+itseni", "itseni\\s+tappami\\w*",
        "(?:hugsa|hugsa[ðd]|hugsar)\\s+um\\s+a[ðd]\\s+(?:drepa\\s+mig|deyja|svipta\\s+mig\\s+l[íi]fi)", "svipta\\s+mig\\s+l[íi]fi",
        // ru
        "(?:думаю|думать|думала?)\\s+(?:о\\s+том,?\\s+(?:чтобы|как)\\s+)?(?:убить\\s+себя|умереть|покончить)",
        "жить\\s+не\\s+хочется", "не\\s+хочется\\s+жить", "поконч\\w*\\s+с\\s+собой"
    ]

    static let selfHarmRuminationUnbounded: [String] = [
        "死のうと", "死んでしまいたい", "消えてしまいたい", "生きるのがつらい", "生きるのが辛い", "リスカ",   // ja
        "活着没意思", "活着没有意义", "结束生命", "想要伤害自己",                                       // zh-Hans
        "죽어버리고 싶", "죽어 버리고 싶", "사라지고 싶", "살기 싫",                                     // ko
        "قتل نفسي", "لا أريد العيش", "لا اريد العيش", "أنتحر", "انتحر"                                    // ar
    ]
}
