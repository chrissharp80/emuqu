import Foundation

// MARK: - Spoken symptom reports (input side)
//
// The clinical nouns ("dolor en el pecho", "Brustschmerz", "одышка") are how a
// doctor writes a symptom; people say it in the first person: "me duele el
// pecho", "ich bekomme keine Luft", "не могу дышать", "胸が痛い". These are
// those everyday forms, one list per concept, appended to the concept they
// report (`chestPain`, `breathlessness`, `syncope`, `irregularHeartbeat`), so
// the guard answers them with the same fixed reply as the noun.
//
// They follow the lexicon's own matching: case-insensitive, accents spelled
// out as classes (`[ée]`, `[ãa]`) so text typed or transcribed without them
// still matches, and curly apostrophes folded by `MedicalQueryGuard.classify`.
//
// The tense rule, which is what keeps exercise talk out:
//   * Chest pain, fainting and collapsing count in any tense. Chest pain or a
//     faint during exercise is a red flag whenever it happened, so "I
//     collapsed during my run" gets the reply.
//   * Breathlessness counts as a present inability ("I can't breathe", "no
//     puedo respirar") or as a symptom phrase ("short of breath"). Being out
//     of breath is what a hard effort feels like, so a past or hedged account
//     of one ("I could barely breathe on that last interval", "I was out of
//     breath", "my lungs are burning on this climb", "fiquei sem ar na
//     subida") reaches the model.
//   * A body or a metric that "collapses" is a pace or a plan ("my pace
//     collapsed", "mon allure s'est effondrée"), so collapsing needs the
//     speaker as its subject.
//   * An irregular heartbeat needs the irregularity ("my heart is racing
//     irregularly"): a racing or pounding heart on a climb is exertion.
extension MedicalTermLexicon {
    static let spokenChestPain: [String] = [
        "chest\\s+(?:(?:is|feels|keeps)\\s+)?(?:(?:really|so|very|kind\\s+of|kinda|a\\s+bit|a\\s+little)\\s+)?"
            + "(?:hurts?|hurting|aches?|aching|tight|heavy|painful)",
        "(?:pressure|weight|tightness|squeezing)\\s+(?:on|in|across)\\s+(?:my|the)\\s+chest",
        "me\\s+duele(?:\\s+(?:mucho|bastante|un\\s+poco))?\\s+(?:el|en\\s+el)\\s+pecho", "pecho\\s+me\\s+duele",   // es
        "(?:dolor|presi[óo]n|opresi[óo]n|punzadas?)\\s+(?:en\\s+el|de)\\s+pecho",
        "mal\\s+(?:[àa]|dans)\\s+la\\s+poitrine", "poitrine\\s+(?:me\\s+fait\\s+mal|me\\s+serre|est\\s+serr[ée]e)", // fr
        "(?:oppression|pression|serrement|poids)\\s+(?:dans|sur|[àa])\\s+la\\s+poitrine",
        "tut\\s+(?:mir\\s+)?(?:die|meine)\\s+brust\\s+weh", "brust\\s+(?:tut\\s+(?:mir\\s+)?weh|schmerzt|ist\\s+eng)", // de
        "(?:druck|enge|stechen|schmerzen|engegef[üu]hl)\\s+(?:in|auf)\\s+der\\s+brust",
        "male\\s+al\\s+petto", "fa\\s+male\\s+il\\s+petto", "petto\\s+mi\\s+fa\\s+male",                           // it
        "(?:dolori?|peso|oppressione|pressione|fitta)\\s+(?:al|nel|sul)\\s+petto",
        "peito\\s+(?:est[áa]\\s+|t[áa]\\s+)?(?:doendo|apertado)", "d[óo]i\\s+(?:o|meu)\\s+peito",                  // pt-BR
        "(?:press[ãa]o|aperto)\\s+no\\s+peito",
        "borst\\s+doet\\s+(?:(?:zo|erg|heel)\\s+)?pijn", "(?:druk|beklemming|steken)\\s+op\\s+(?:de|mijn)\\s+borst", // nl
        "borstpijn",
        "ondt\\s+i\\s+brystet", "brystet\\s+g[øo]r\\s+ondt", "trykken\\s+for\\s+brystet",                         // da
        "vondt\\s+i\\s+brystet", "brystet\\s+gj[øo]r\\s+vondt", "(?:trykk|smerter?)\\s+i\\s+brystet",              // nb
        "ont\\s+i\\s+br[öo]stet", "br[öo]stet\\s+g[öo]r\\s+ont", "(?:tryck|sm[äa]rt(?:a|or))\\s+(?:i|över)\\s+br[öo]stet", // sv
        "rintaan\\s+sattuu", "rintakipu\\w*", "rintaa\\s+(?:puristaa|painaa|kivist[äa][äa])",                      // fi
        "(?:kipua|puristusta)\\s+rinnassa", "rinnassa\\s+(?:on\\s+)?(?:kipua|puristusta)",
        "verk\\s+[íi]\\s+brj[óo]stinu", "(?:[þt]r[ýy]stingur|[þt]yngsli)\\s+[íi]\\s+brj[óo]stinu",               // is
        "болит\\s+(?:в\\s+)?груд[ьи]", "груд[ьи]\\s+(?:болит|давит|сжимает)", "боли\\s+в\\s+груди",              // ru
        "(?:давит|колет|сдавливает|сжимает)\\s+(?:в\\s+)?груд[ьи]", "в\\s+груди\\s+(?:болит|давит|колет)"
    ]

    static let spokenChestPainUnbounded: [String] = [
        "胸が痛", "胸が苦し", "胸が締め付け", "胸がしめつけ", "胸の痛み", "胸が圧迫",                            // ja
        "胸口痛", "胸口很痛", "胸口好痛", "胸口很疼", "胸疼", "胸闷", "胸口闷", "胸口发紧", "胸部疼痛",                                             // zh-Hans
        "가슴이 아파", "가슴이 아프", "가슴이 너무 아파", "가슴이 많이 아파", "가슴이 조여", "가슴이 조이",
        "가슴통증", "가슴에 통증",                            // ko
        "صدري يؤلمني", "يؤلمني صدري", "صدري يوجعني", "ألم في صدري", "الم في صدري", "الم في الصدر", "ضغط على صدري" // ar
    ]

    static let spokenBreathlessness: [String] = [
        "(?:can['’]?t|cannot|can\\s+not|unable\\s+to)\\s+(?:breathe?|catch\\s+my\\s+breath|get\\s+(?:any\\s+|enough\\s+)?air)",
        "(?:it['’]?s|is)\\s+(?:(?:really|so|very)\\s+)?(?:hard|difficult)\\s+to\\s+breathe", "short\\s+of\\s+breath",
        "no\\s+puedo\\s+(?:respirar|recuperar\\s+el\\s+aire)", "me\\s+falta\\s+(?:el\\s+)?aire",                  // es
        "me\\s+cuesta\\s+respirar", "me\\s+(?:estoy\\s+)?ahog(?:o|ando)",
        "(?:peux|peut|arrive)\\s+(?:pas|plus)\\s+(?:[àa]\\s+)?respirer", "du\\s+mal\\s+[àa]\\s+respirer",          // fr
        "manque\\s+d['’]air", "souffle\\s+court", "je\\s+suffoque",
        "(?:bekomme?|kriege?|krieg)\\s+keine\\s+luft", "keine\\s+luft\\s+(?:mehr\\s+)?(?:bekomme|kriege)",        // de
        "kann\\s+nicht\\s+(?:mehr\\s+)?atmen", "luftnot", "ich\\s+ersticke",
        "non\\s+riesco\\s+a\\s+(?:respirare|prendere\\s+(?:fiato|aria))", "fiato\\s+corto",                       // it
        "mi\\s+manca\\s+(?:il\\s+respiro|il\\s+fiato|l['’]aria)", "fatica\\s+a\\s+respirare", "sto\\s+soffocando",
        "n[ãa]o\\s+(?:consigo|t[ôo]\\s+conseguindo|estou\\s+conseguindo)\\s+respirar", "(?:t[ôo]|estou|tou)\\s+sem\\s+ar", // pt-BR
        "dificuldade\\s+(?:pra|de)\\s+respirar", "(?:t[ôo]|estou)\\s+sufocando",
        "kan\\s+niet\\s+(?:meer\\s+)?ademen", "krijg\\s+geen\\s+(?:lucht|adem)", "kortademig",                    // nl
        "kan\\s+ikke\\s+(?:f[åa]\\s+vejret|tr[æa]kke\\s+vejret|[åa]nde)", "f[åa]r\\s+ikke\\s+(?:luft|vejret)",    // da
        "(?:f[åa]r|kan)\\s+ikke\\s+puste", "klarer\\s+ikke\\s+[åa]\\s+puste",                                    // nb
        "kan\\s+inte\\s+andas", "f[åa]r\\s+(?:inte|ingen)\\s+luft", "sv[åa]rt\\s+att\\s+andas",                  // sv
        "en\\s+saa\\s+henke[äa]", "en\\s+pysty\\s+hengitt[äa]m[äa][äa]n", "hengitt[äa]minen\\s+on\\s+vaikeaa",   // fi
        "hengenahdistu\\w*",
        "get\\s+ekki\\s+anda[ðd]", "n[æa]\\s+ekki\\s+andanum", "f[æa]\\s+ekki\\s+loft",                          // is
        "не\\s+могу\\s+(?:дышать|вздохнуть|отдышаться)", "не\\s+хватает\\s+воздуха", "задыхаюсь",               // ru
        "(?:тяжело|трудно)\\s+дышать", "одышк\\w*"
    ]

    static let spokenBreathlessnessUnbounded: [String] = [
        "息ができ", "息が出来", "息が苦し", "息苦し", "呼吸ができ", "呼吸が苦し", "息が吸えない",                  // ja
        "喘不过气", "喘不上气", "无法呼吸", "不能呼吸", "呼吸不了", "吸不上气", "透不过气", "上不来气",               // zh-Hans
        "숨을 못 쉬", "숨을 못쉬", "숨을 쉴 수 없", "숨을 쉴 수가 없", "숨쉬기 힘들", "숨 쉬기 힘들",
        "숨쉬기가 힘들", "숨쉬기 어렵", "숨쉬기가 어렵", "숨이 막히", "숨이 막혀",          // ko
        "لا أستطيع التنفس", "لا استطيع التنفس", "ما أقدر أتنفس", "ما اقدر اتنفس", "صعوبة في التنفس", "ضيق في التنفس", "أختنق" // ar
    ]

    static let spokenSyncope: [String] = [
        "i\\s+(?:just\\s+|nearly\\s+|almost\\s+)?collapsed", "(?:he|she|someone|somebody)\\s+(?:just\\s+)?collapsed",
        "i(?:['’]?m|\\s+am)\\s+(?:going\\s+to|gonna|about\\s+to)\\s+collapse",
        "i\\s+(?:might|could|think\\s+i(?:['’]ll|\\s+will))\\s+collapse", "(?:lost|losing)\\s+consciousness",
        "desmay(?:e|a|ado|ada|ando|ar|arme|aron)", "perd[íi]\\s+el\\s+conocimiento", "me\\s+desplom[ée]",         // es
        "[ée]vanou(?:i|ie|is|it|ir|issement)s?", "perdu\\s+connaissance", "perdre\\s+connaissance",              // fr
        "fait\\s+un\\s+malaise", "me\\s+suis\\s+effondr[ée]e?", "tomb[ée]e?\\s+dans\\s+les\\s+pommes",
        "ohnm[äa]chtig\\w*", "bin\\s+(?:\\w+\\s+){0,2}(?:zusammengebrochen|umgekippt|kollabiert)",               // de
        "kippe\\s+(?:gleich\\s+)?um",
        "svenut[oa]", "svenire", "perso\\s+(?:i\\s+sensi|conoscenza)",                   // it
        "sono\\s+(?:\\w+\\s+)?collassat[oa]",
        "desmai(?:ar|ando|ada|ado|e)", "perdi\\s+(?:a\\s+)?(?:consci[êe]ncia|os\\s+sentidos)",                    // pt-BR
        "(?:val|viel|vielen)\\s+(?:bijna\\s+)?flauw", "flauw\\s+(?:gevallen|vallen)", "bewusteloos",               // nl
        "in\\s+elkaar\\s+gezakt", "buiten\\s+bewustzijn",
        "besvim(?:e|er|t)", "mistede\\s+bevidstheden",
        "(?:jeg|han|hun)\\s+(?:\\w+\\s+)?(?:faldt|falt|segnet)\\s+om\\b(?!\\s+(?:natten|kvelden|aftenen|morgenen))",                            // da, nb
        "svimte\\s+av", "mistet\\s+bevisstheten",
        "svimma(?:de|r)?", "tappade\\s+medvetandet", "jag\\s+(?:\\w+\\s+)?kollapsade",                           // sv
        "py[öo]r(?:ty|ry)\\w*", "menetin\\s+tajun\\w*", "lyyhistyin",                                            // fi
        "le[ií][ðd]\\s+yfir\\s+mig", "l[íi][ðd]ur\\s+yfir\\s+mig", "missti\\s+me[ðd]vitund",                     // is
        "обмор\\w*", "(?:потерял(?:а)?|теряю)\\s+сознание"                                                        // ru
    ]

    static let spokenSyncopeUnbounded: [String] = [
        "気を失", "気絶", "意識を失", "倒れた", "倒れました", "倒れてしま",                                       // ja
        "昏倒", "晕过去", "昏过去", "失去意识", "失去了意识", "昏迷",                                                    // zh-Hans
        "기절했", "기절해", "의식을 잃", "쓰러졌",                                                              // ko
        "اغماء", "أغمي علي", "اغمي علي", "فقدت الوعي", "فقدان الوعي"                                             // ar
    ]

    static let spokenIrregularHeartbeat: [String] = [
        "heart\\s+(?:is\\s+|keeps\\s+|was\\s+)?(?:racing|pounding|beating|thumping|fluttering|going)\\s+"
            + "(?:irregularly|erratically|out\\s+of\\s+rhythm|all\\s+over\\s+the\\s+place)",
        "heart\\s+(?:is\\s+|keeps\\s+)?(?:skipping|fluttering)",
        "coraz[óo]n\\s+(?:me\\s+)?late\\s+(?:de\\s+forma\\s+|muy\\s+)?(?:irregular|descontrolado|desacompasado)",  // es
        "c(?:œ|oe)ur\\s+bat\\s+(?:de\\s+fa[çc]on\\s+|de\\s+mani[èe]re\\s+)?irr[ée]guli[èe]re?(?:ment)?",           // fr
        "herz\\s+(?:schl[äa]gt|rast|pocht)\\s+(?:ganz\\s+)?(?:unregelm[äa][ßs]ig|unrhythmisch)",                  // de
        "herz\\s+stolpert", "herzstolpern",
        "cuore\\s+(?:mi\\s+)?batte\\s+(?:in\\s+modo\\s+)?(?:irregolare|irregolarmente)", "cuore\\s+perde\\s+(?:dei\\s+)?colpi", // it
        "cora[çc][ãa]o\\s+(?:est[áa]\\s+|t[áa]\\s+)?(?:batendo|bate)\\s+(?:de\\s+forma\\s+)?(?:irregular|descompassado)", // pt-BR
        "hart\\s+(?:slaat|klopt)\\s+(?:heel\\s+)?onregelmatig", "hart\\s+slaat\\s+(?:een\\s+slag\\s+)?over",      // nl
        "hjerte(?:t)?\\s+sl[åa]r\\s+uregelm[æae]ss?ig(?:t)?", "hjertet\\s+hopper\\s+over",                       // da, nb
        "hj[äa]rtat\\s+(?:sl[åa]r\\s+oregelbundet|hoppar\\s+[öo]ver)",                                          // sv
        "syd[äa]n\\s+(?:ly[öo]|hakkaa)\\s+ep[äa]s[äa][äa]nn[öo]llisesti", "muljahtel\\w*",                       // fi
        "hjarta[ðd]\\s+sl[æa]r\\s+[óo]reglulega",                                                                // is
        "сердце\\s+(?:бь[её]тся|стучит)\\s+(?:неровно|нерегулярно|с\\s+перебоями)", "сердце\\s+(?:замирает|пропускает\\s+удары)" // ru
    ]

    static let spokenIrregularHeartbeatUnbounded: [String] = [
        "脈が乱れ", "脈が飛", "脈拍が乱れ", "鼓動が不規則",                                                       // ja
        "心跳不齐", "(?<!窦性)心律不齐", "心跳很乱",                                                                     // zh-Hans
        "심장이 불규칙", "맥박이 불규칙",                                                                         // ko
        "قلبي ينبض بشكل غير منتظم", "نبضات قلبي غير منتظمة", "دقات قلبي غير منتظمة", "ضربات قلبي غير منتظمة"       // ar
    ]
}
