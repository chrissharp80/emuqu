import Foundation

/// The regulated-language vocabulary shared by both halves of the FDA
/// perimeter: `MedicalQueryGuard` (what the user asks, before anything leaves
/// the device) and `CoachVoiceGuard` (what the assistant says, before it
/// reaches eyes or speakers).
///
/// ## Why one shared vocabulary
///
/// Separate regex lists per guard drift apart: a model can then say "this
/// looks like atrial fibrillation" past an OUTPUT guard that lacks a term
/// only the build-time list knows.
///
/// Every pattern also has to cover every shipped language. The app ships
/// sixteen non-English localizations at 100% catalogue coverage, and the
/// assistant answers in the user's language. A guard that only reads English
/// is not a guard with a gap — for those users it is not a guard at all.
///
/// ## What this is
///
/// One `Concept` per regulated idea, each carrying an alternation that covers
/// English plus every shipped locale (ar, da, de, es, fi, fr, is, it, ja, ko,
/// nb, nl, pt-BR, ru, sv, zh-Hans). Both guards compose their rules from it, so
/// adding a term to one adds it to both, and `scripts/check_perimeter_sync.sh`
/// fails the build if the build-time linter's list grows a term the runtime
/// lexicon cannot match.
///
/// ## Matching notes
///
/// Patterns are matched case-insensitively against the ORIGINAL text, never a
/// folded copy, so match ranges stay aligned with the string being rewritten.
/// Accented forms are therefore spelled out in the alternation
/// (`m[ée]decin`, `l[aä][ek]ar[e]?`) rather than handled by diacritic folding.
///
/// Word boundaries are applied only to Latin-script alternatives. `\b` is
/// defined by word characters, and CJK text has no inter-word boundaries — a
/// `\b` around `心房細動` never matches in running Japanese. CJK and Arabic
/// alternatives are matched as bare substrings, which is correct for those
/// scripts and is why they live in a separate group.
enum MedicalTermLexicon {
    /// One regulated idea, in every language the app ships.
    struct Concept {
        /// Stable identifier used by the sync gate and by telemetry.
        let id: String
        /// Latin-script alternatives, wrapped in word boundaries when matched.
        let latin: [String]
        /// Scripts with no word boundaries (CJK, Arabic). Matched as substrings.
        let unbounded: [String]

        init(id: String, latin: [String], unbounded: [String] = []) {
            self.id = id
            self.latin = latin
            self.unbounded = unbounded
        }

        /// The full alternation for this concept as a single regex source.
        var pattern: String {
            var branches: [String] = []
            if !latin.isEmpty {
                branches.append("\\b(?:" + latin.joined(separator: "|") + ")\\b")
            }
            if !unbounded.isEmpty {
                branches.append("(?:" + unbounded.joined(separator: "|") + ")")
            }
            return "(?:" + branches.joined(separator: "|") + ")"
        }
    }

    // MARK: - Cardiac rhythm (App Store 1.4.1 / regulated diagnosis)

    static let atrialFibrillation = Concept(
        id: "atrial-fibrillation",
        latin: [
            "a-?fib", "atrial\\s+fib(?:rillation)?",
            "fibrillation\\s+auriculaire",            // fr
            "fibrilaci[oó]n\\s+auricular",            // es
            "fibrila[çc][ãa]o\\s+atrial",            // pt-BR
            "fibrillazione\\s+atriale",               // it
            "vorhofflimmern",                         // de
            "boezemfibrilleren", "atriumfibrilleren", // nl
            "atrieflimren", "atrieflimmer",           // da, nb
            "f[öo]rmaksflimmer",                      // sv
            "eteisv[äa]rin\\w*",                     // fi
            "g[áa]ttatif(?:i|s)?",                    // is
            "фибрилляци\\w*\\s+предсерди\\w*", "мерцательн\\w*\\s+аритми\\w*", // ru
            // The French abbreviation in capitals only: lower-case "fa" is Italian "ago".
            "(?:de\\s+la|d['’]une|une|ma|en)\\s+(?-i:FA)"
        ],
        unbounded: ["心房細動", "心房颤动", "房颤", "심방세동", "الرجفان الأذيني", "رجفان أذيني", "رجفان اذيني"]
    )

    static let arrhythmia = Concept(
        id: "arrhythmia",
        // RESPIRATORY SINUS ARRHYTHMIA IS NORMAL PHYSIOLOGY, and the app
        // describes it in its own methodology copy, in every shipped locale.
        //
        // The exclusion below is needed on EVERY alternative, not just the
        // English one: without it a legitimate explanation of respiratory
        // sinus arrhythmia is deflected by `CoachVoiceGuard` and refused
        // outright by `MedicalQueryGuard`. German escapes by accident:
        // `Sinusarrhythmie` compounds, so the `\b` in front of `arrhythmie`
        // finds no boundary. Every locale that writes the qualifier as a
        // separate word needs the guard.
        //
        // The guard is a lookaround per alternative rather than a shared
        // exclusion list because the qualifier's POSITION differs by language:
        // English and Russian put it before the noun, the Romance languages and
        // Arabic after it, and CJK prefixes it without a space.
        // `CoachVoiceGuardTests.testSinusArrhythmiaIsNotDeflectedInAnyLocale`
        // pins all seventeen.
        latin: [
            "(?<!sinus\\s)arrhythmias?",
            "arythmies?(?!\\s+sinusales?)",             // fr
            "arritmias?(?!\\s+sinusal(?:es)?)",         // es, pt-BR
            "aritmias?(?!\\s+sinusal(?:e|es)?)",        // it, pt-BR
            "(?<!sinus)arrhythmie", "herzrhythmusst[öo]rung(?:en)?", // de
            "(?<!sinus)aritmie", "hartritmestoornis(?:sen)?",   // nl
            "(?<!sinus)arytmi(?:er)?", "hjerterytmeforstyrrelse(?:r)?", // da, nb
            "hj[äa]rtrytmrubbning(?:ar)?",            // sv
            "(?<!sinus)rytmih[äa]iri\\w*",           // fi
            "hjartsl[áa]ttartruflun(?:ir|um|ar)?",          // is
            // Russian also calls it "дыхательная аритмия" without the word sinus.
            "(?<!синусовая\\s)(?<!синусовой\\s)(?<!дыхательная\\s)(?<!дыхательной\\s)аритми[яи]"  // ru
        ],
        unbounded: [
            // 呼吸性不整脈 is the everyday Japanese name for the same physiology.
            "(?<!洞性)(?<!呼吸性)不整脈",                          // ja
            "(?<!窦性)心律失常",                        // zh-Hans
            "(?<!동성)(?<!동성 )부정맥",                 // ko
            "عدم انتظام ضربات القلب(?! التنفسي| الجيبي)"  // ar
        ]
    )

    /// Named cardiac and vascular conditions.
    ///
    /// Covers the conditions as a family rather than an ad-hoc denylist: it
    /// makes no sense for "atrial flutter", "heart block", "bradycardia" and
    /// "tachycardia" to pass both the build-time linter and the runtime guard
    /// while "atrial fibrillation" is blocked. Naming a specific cardiac
    /// condition to a user is the regulated act; which one it is should not
    /// decide whether the perimeter holds.
    static let namedCardiacCondition = Concept(
        id: "named-cardiac-condition",
        latin: [
            "atrial\\s+flutter", "heart\\s+block", "bradycardias?", "tachycardias?",
            "myocardial\\s+infarction", "heart\\s+attack", "cardiac\\s+(?:arrest|event)",
            "isch(?:a?e)mi[ac]", "angina", "hypertension", "hypotension", "high\\s+blood\\s+pressure",
            "flutter\\s+auriculaire", "bloc\\s+auriculo[- ]ventriculaire", "bradycardie", "tachycardie",
            "infarctus", "crise\\s+cardiaque", "hypertension\\s+art[ée]rielle",   // fr
            "aleteo\\s+auricular", "bloqueo\\s+card[íi]aco", "bradicardia", "taquicardia",
            "infarto", "ataque\\s+card[íi]aco", "attacco\\s+(?:cardiaco|di\\s+cuore)", "hipertensi[óo]n", "hipotensi[óo]n", // es, pt-BR, it
            "hipertens[ãa]o", "hipotens[ãa]o", "i(?:per|po)tensione",
            "vorhofflattern", "herzblock", "bradykardie\\w*", "tachykardie\\w*", "hohe[rn]?\\s+blutdruck\\w*",
            "herzinfarkt", "herzstillstand", "bluthochdruck",                      // de
            "boezemflutter", "hartblok",              // bradycardie, tachycardie: as fr
            "hartaanval", "hartstilstand", "hoge\\s+bloeddruk",                    // nl
            "atrieflagren", "atrieflutter", "hjerteblok", "bradykardi\\w*", "takykardi\\w*",
            "forh[øo]jet\\s+blodtryk", "h[øo]jt\\s+blodtryk", "h[øo]yt\\s+blodtrykk",
            "hjerteanfald", "hjerteinfarkt", "hjertestop", "hjertestans",           // da, nb
            "f[öo]rmaksfladder", "hj[äa]rtblock", "h[öo]gt\\s+blodtryck",     // bradykardi, takykardi: as da, nb
            "hj[äa]rtinfarkt", "hj[äa]rtstopp",                                     // sv
            "eteislepatus", "sydänkatkos", "korke\\w*\\s+verenpaine\\w*", "verenpainetau\\w*",
            "syd[äa]ninfarkti\\w*", "syd[äa]npys[äa]hdy\\w*", "syd[äa]nkohtau\\w*", // fi
            "hjarta[áa]f\\w*", "hjartastopp\\w*", "h[áa][þt]r[ýy]sting\\w*", "h[æa]gsl[áa]tt\\w*", "hra[ðd]sl[áa]tt\\w*", // is
            // Case endings spelled out: a bare stem never matches "инфаркта" inside `\\b`.
            "трепетание\\s+предсердий", "брадикарди[яиюей]", "тахикарди[яиюей]",
            "инфаркт(?:а|е|у|ом|ы)?", "остановк[аиуе]\\s+сердца", "гипертони[яиюей]", "сердечн\\w+\\s+приступ\\w*" // ru
        ],
        unbounded: [
            "心房粗動", "心房扑动", "심방조동",
            "徐脈", "頻脈", "心筋梗塞", "心停止", "心臓発作",
            "心动过缓", "心动过速", "心肌梗死", "心脏骤停", "心脏病发作",
            "서맥", "빈맥", "심근경색", "심정지", "심장마비",
            "高血圧", "低血圧", "高血压", "低血压", "고혈압", "저혈압", "ارتفاع ضغط الدم", "انخفاض ضغط الدم",
            "الرفرفة الأذينية", "بطء القلب", "تسرع القلب", "نوبة قلبية", "احتشاء عضلة القلب"
        ]
    )

    /// The acute subset of `namedCardiacCondition`, deliberately overlapping it.
    ///
    /// "Am I having a heart attack?" must be refused before it reaches a cloud
    /// provider, but the whole `namedCardiacCondition` concept cannot simply
    /// be wired into the input guard: it also holds
    /// `bradycardias?`, `tachycardias?` and `hypertension`, and an endurance
    /// athlete asking whether their resting heart rate counts as bradycardia is
    /// asking an ordinary training question. Refusing that would block a
    /// legitimate question, not add a safeguard.
    ///
    /// So the acute presentations — the ones where the right answer is "call
    /// your local emergency number", and which nobody asks about their training
    /// data — are their own concept. It is a strict subset, kept separate rather
    /// than carved out, so the output side is untouched.
    static let acuteCardiacEvent = Concept(
        id: "acute-cardiac-event",
        latin: [
            "myocardial\\s+infarction", "heart\\s+attack", "cardiac\\s+(?:arrest|event)",
            "infarctus", "crise\\s+cardiaque",                    // fr
            "infarto", "ataque\\s+card[íi]aco", "attacco\\s+(?:cardiaco|di\\s+cuore)", // es, pt-BR, it
            "herzinfarkt", "herzstillstand",                      // de
            "hartaanval", "hartstilstand",                        // nl
            "hjerteanfald", "hjerteinfarkt", "hjertestop", "hjertestans", // da, nb
            "hj[äa]rtinfarkt", "hj[äa]rtstopp",                   // sv
            "syd[äa]ninfarkti\\w*", "syd[äa]npys[äa]hdy\\w*", "syd[äa]nkohtau\\w*", // fi
            "hjarta[áa]f\\w*", "hjartastopp\\w*",                // is
            "инфаркт(?:а|е|у|ом|ы)?", "остановк[аиуе]\\s+сердца", "сердечн\\w+\\s+приступ\\w*" // ru
        ],
        unbounded: [
            "心筋梗塞", "心停止", "心臓発作", "心肌梗死", "心脏骤停", "心脏病发作",
            "심근경색", "심정지", "심장마비",
            "نوبة قلبية", "احتشاء عضلة القلب"
        ]
    )

    /// Stroke and pulmonary embolism.
    ///
    /// Both are squarely inside the perimeter: they are diagnoses, and they
    /// are the two an anxious user is most likely to raise alongside a
    /// heart-rate reading.
    ///
    /// The English word `stroke` is NOT here on its own, and that is
    /// deliberate. In this codebase it is overwhelmingly a swimming metric or a
    /// drawing call — `stroke rate`, `total strokes`, `stroke width`. A bare
    /// `\bstroke\b` would rewrite the assistant's answer about a pool session
    /// into a cardiac deflection, which is a worse failure than the one it
    /// prevents. Only disambiguated forms are matched.
    ///
    /// The same trap exists in Swedish, Danish and Norwegian, where `stroke` is
    /// a naturalised loanword; those locales are covered by their native terms
    /// (`hjärnblödning`, `hjerneslag`, `slaganfall`) instead.
    static let neurovascularEvent = Concept(
        id: "neurovascular-event",
        latin: [
            // Not "a stroke of luck", nor the swim metric ("you had a stroke rate of 34").
            "(?:signs?|symptoms?|risk|onset|warning)\\s+of\\s+(?:an?\\s+)?stroke(?!\\s+(?:rate|count|length|cycle|index|technique|drill|rhythm|plan|type))",
            "(?:detects?|predicts?|prevents?|warns?\\s+(?:you\\s+)?(?:of|about|before))\\s+(?:an?\\s+)?strokes?(?!\\s+(?:rate|count|length|cycle|index|technique|drill|rhythm|plan|type))",
            "(?:having|had|have)\\s+a\\s+stroke(?!\\s+(?:of\\s|rate|count|length|cycle|index|technique|drill|rhythm|plan))", "stroke\\s+(?:symptoms|victim)",
            "mini[- ]stroke", "transient\\s+ischemic\\s+attack",
            "cerebrovascular", "pulmonary\\s+embolism", "blood\\s+clots?",
            "deep\\s+vein\\s+thrombosis",
            "accident\\s+vasculaire\\s+c[ée]r[ée]bral", "avc", "embolie\\s+pulmonaire", // avc: fr, pt-BR
            "caillot\\s+de\\s+sang",                            // fr
            "derrame\\s+cerebral", "accidente\\s+cerebrovascular", "ictus",
            "embolia\\s+pulmonar", "co[áa]gulo\\s+de\\s+sangre", "(?:tive|tendo|tenho|teve|ter)\\s+um\\s+derrame", // es, pt-BR
            "embolia\\s+polmonare", "coagulo\\s+di\\s+sangue",  // it
            "schlaganf[äa]ll\\w*", "lungenembolie\\w*", "blutgerinnsel\\w*", // de
            "beroerte", "herseninfarct", "longembolie", "bloedstolsel", // nl
            "hjerneslag", "hjerneblødning", "blodprop", "lungeemboli",  // da, nb
            "hj[äa]rnbl[öo]dning", "slaganfall", "blodpropp", "lungemboli", // sv
            // A swim stroke is "simtag" in Swedish; "en stroke" after having it is the illness.
            "(?:har|hade|f[åa]tt|fick|f[åa]r)\\s+(?:jag\\s+|du\\s+)?(?:haft\\s+)?en\\s+stroke(?![-\\w])",
            "aivohalvau\\w*", "aivoinfarkti\\w*", "keuhkoembolia\\w*", "verihyytym[äa]\\w*",  // fi
            "heilabl[óo][ðd]f\\w*", "bl[óo][ðd]tapp\\w*",          // is
            "инсульт(?:а|е|у|ом|ы)?", "тромбоэмболи[яиюей]", "тромб(?:а|е|у|ом|ы)?" // ru
        ],
        unbounded: [
            "脳卒中", "脳梗塞", "肺塞栓", "血栓",
            // 中风险 is "medium risk", not a stroke.
            "脑卒中", "中风(?!险)", "脑梗死", "肺栓塞",
            "뇌졸중", "뇌경색", "폐색전", "혈전",
            "سكتة دماغية", "سكتة الدماغية", "جلطة", "انسداد رئوي"
        ]
    )

    static let irregularHeartbeat = Concept(
        id: "irregular-heartbeat",
        latin: [
            "irregular\\s+(?:heart\\s*)?(?:beat|rhythm|pulse)",
            "heart\\s+(?:is\\s+)?beating\\s+irregularly?",
            "(?:skipped|skipping|skip)\\s+beats?", "palpitations?",
            // Not the app's own beat-cleaning copy ("un battement irrégulier ou mal
            // détecté", "trop de battements irréguliers à proximité"): an artefact.
            "(?<!trop\\sde\\s)battements?\\s+irr[ée]guliers?(?!\\s+(?:ou|o|or|e|et)\\s+(?:mal|mis|rilevat\\w*)|\\s+(?:[àa]\\s+proximit[ée]|cerca|por\\s+perto|nelle\\s+vicinanze))", "rythme\\s+cardiaque\\s+irr[ée]gulier", // fr
            "palpitaciones", "(?<!demasiados\\s)latidos?\\s+irregulares?(?!\\s+(?:ou|o|or|e|et)\\s+(?:mal|mis|rilevat\\w*)|\\s+(?:[àa]\\s+proximit[ée]|cerca|por\\s+perto|nelle\\s+vicinanze))", // es
            "palpita[çc][õo]es", "batimentos?\\s+irregulares?(?!\\s+demais)(?!\\s+(?:ou|o|or|e|et)\\s+(?:mal|mis|rilevat\\w*)|\\s+(?:[àa]\\s+proximit[ée]|cerca|por\\s+perto|nelle\\s+vicinanze))", // pt-BR
            "palpitazioni", "(?<!troppi\\s)battit[oi]\\s+irregolar[ei](?!\\s+(?:ou|o|or|e|et)\\s+(?:mal|mis|rilevat\\w*)|\\s+(?:[àa]\\s+proximit[ée]|cerca|por\\s+perto|nelle\\s+vicinanze))", // it
            // Not bare Herzklopfen, hjertebanken, hjärtklappning or 두근거림: each is
            // also the pounding heart of a climb, which is exertion (see the Spoken file).
            "unregelm[äa][ßs]iger\\s+herzschlag", "unregelm[äa][ßs]igen\\s+herzschlag\\w*", // de
            "hartkloppingen", "onregelmatige\\s+hartslag",     // nl
            "uregelm[æae]ss?ig\\s+hjerterytme",                // da, nb
            "oregelbunden\\s+hj[äa]rtrytm",                    // sv
            "syd[äa]mentykytys\\w*", "eps[äa]s[äa][äa]nn[öo]llinen\\s+syke", // fi
            "hjartsl[áa]ttar[óo]regl\\w*",                    // is
            "учащ[её]нное\\s+сердцебиение", "перебои\\s+в\\s+сердце" // ru
        ] + spokenIrregularHeartbeat,
        unbounded: ["動悸", "心悸", "心跳不规律", "심계항진", "خفقان"] + spokenIrregularHeartbeatUnbounded
    )

    // MARK: - Diagnosis, treatment, regulatory claims

    static let diagnosis = Concept(
        id: "diagnosis",
        latin: [
            // The lookaheads keep the SOFTWARE sense out.
            // The app ships a Troubleshooting feature called "Diagnostics"
            // ("Export Diagnostic Log", "Archive Diagnostics", "System
            // Diagnostics") in seventeen locales, and without these the guard
            // deflects the assistant explaining how to send a support log.
            "diagnos(?:e|is|es|ed|ing)(?!\\w)(?!\\s+(?:log|logs|data|tool|tools|bundle))",
            "undiagnosed",
            // The verb, not the adjective in "affirmations diagnostiques": the present needs an object.
            "diagnostiqu(?:er|é|ée|és|ées)", "diagnostiqu(?:e|ent)\\s+(?:les|la|le|l['’]|un|une|des|vos|votre|aucun\\w*|rien)\\b",
            // Romance word order puts the software noun first ("journal de diagnostic").
            "(?<!\\sde\\s)diagnostic(?!s?\\s+(?:log|logs|data|tool|tools|bundle|from|depuis|avanc[ée]|syst[èe]me|d['’]archive|complet))", // fr
            "(?<!\\sde\\s)(?<!log\\s)(?<!registro\\s)(?<!dato\\s)diagn[óo]stic[oa]s?(?!\\s+(?:del\\s+archivo|do\\s+arquivo|de\\s+sistema|del\\s+sistema|do\\s+sistema|di\\s+sistema|archivio|avanzad[oa]|avan[çc]ad[oa]|desde|em\\s+configura|da\\s+impostazioni))",
            "diagnosticar",                           // es, pt-BR
            "diagnosi", "diagnosticare",              // it
            // Same software-sense lookahead as the English pattern above, or
            // this bare form re-matches "diagnose log" and undoes it.
            "diagnose(?!\\s+(?:log|logs|data|tool|tools|bundle))", "diagnostizier(?:en|t)", // de, nl, da, nb
            "diagnos(?:er)?(?!\\s+fr[åa]n\\s+inst[äa]llningar)", // sv
            "diagnoos\\w*", "diagnosoi\\w*",          // fi
            // Verb forms only: "Avanceret diagnosticering" is the app's software diagnostics.
            "diagnosticer(?:er|e|ede|et)", "diagnostiser(?:er|e|te|t|ar|ade|at|a)", // da, nb, sv
            // Icelandic `greining` means ANALYSIS as much as diagnosis, and the
            // app's own Icelandic UI uses it that way ("Greining" = Analysis,
            // "Greiningu lokið" = Analysis complete). A bare match deflected
            // the assistant every time it mentioned an analysis. The medical
            // sense is compounded.
            "sj[úu]kd[óo]msgreining\\w*", "l[æa]knisgreining\\w*",   // is
            "диагноз\\w*", "диагностир\\w*"            // ru
        ],
        // Not the software sense: the app's own "診断ログ", "系统诊断", "진단 도구", "سجل التشخيص".
        unbounded: [
            "(?<!システム)(?<!アーカイブ)(?<!詳細な)診断(?!ログ|ツール|情報|データ)",
            "(?<!고급 )(?<!아카이브 )(?<!시스템 )진단(?! ?(?:로그|도구|정보|데이터))",
            "(?<!高级)(?<!存档)(?<!系统)诊断(?!日志|工具|信息|数据)",
            "(?<!سجل ال)(?<!سجلات ال)(?<!أدوات ال)تشخيص(?!ي|ات| النظام)", "يشخص"
        ]
    )

    static let cure = Concept(
        id: "cure",
        latin: [
            "cur(?:e|es|ed|ing)", "curative",
            "gu[ée]rir", "gu[ée]rison",               // fr
            // Not a bare `"cura"`: Italian "prenditi cura" is "take care",
            // and a bare match deflected ordinary coaching. The cure sense is
            // "a cure for…" or an adjective only a cure takes.
            "curar",                                  // es, pt-BR
            "(?:la|una|a|uma)\\s+cura\\s+(?:para|per|de|di|contro|contra)",
            "cura\\s+(?:definitiva|milagrosa|miracolosa)", // es, pt-BR, it
            // Not bare "heilen" / "genezen", which also mean "heal": the cure names a disease.
            "(?:krankheit|erkrankung)\\w*\\s+(?:zu\\s+)?heilen", "heilt\\s+(?:deine|ihre|die)\\s+(?:krankheit|erkrankung)\\w*",
            "heilung\\s+(?:von|der|deiner|ihrer)\\s+(?:krankheit|erkrankung)\\w*", "heilmittel\\w*", // de
            "(?:ziekte|aandoening)\\s+(?:te\\s+)?genezen", "geneest\\s+(?:je|jouw|uw|de)\\s+(?:ziekte|aandoening)",
            "genezing\\s+van\\s+(?:je\\s+|de\\s+|uw\\s+)?(?:ziekte|aandoening)", // nl
            // Not a bare `"bota"` (Spanish/Portuguese "boot", Portuguese "puts").
            "helbrede", "helbredelse", "botemedel",   // da/nb, sv
            "helbreder\\s+(?:\\w+\\s+)?(?:sygdom|sykdom)\\w*",
            "botar?\\s+(?:din\\s+|en\\s+)?\\w*sjukdom\\w*", // sv
            // NOT a bare `"parantaa"`, which is the ordinary Finnish verb
            // "to improve". Bare, it matches four shipped strings
            // ("parantaa untani" = improve my sleep, "parantaa tarkkuutta" =
            // improves accuracy) and would deflect any Finnish reply
            // saying a session improves endurance. The cure sense needs a
            // disease as its object; the noun `parannuskeino` (remedy) is
            // unambiguous on its own. Same trap as the sinus-arrhythmia
            // lookbehind: a term that is regulated in English and everyday in
            // another language.
            // The `\\w*` matters: the whole alternation is wrapped in `\\b…\\b`, so an
            // alternative that stops mid-word ("sairaude" inside "sairauden")
            // never matches. Finnish inflects heavily; the suffix has to be
            // part of the pattern.
            "parantaa\\s+(?:sairau|tauti|taudi|vaiva)\\w*", "parannuskeino", // fi
            "l[æa]kning", "l[æa]kna[rð]?\\s+(?:\\w+\\s+)?sj[úu]kd[óo]m\\w*", // is
            "вылечить", "излечение",                  // ru
            "(?:вылеч|излеч)\\w*\\s+(?:\\w+\\s+)?(?:болезн\\w*|заболевани\\w*|бессонниц\\w*|диабет\\w*|депресси\\w*|гипертони\\w*)",
            // The verb with a disease as its object: Italian "cura il recupero" is "look after your recovery".
            "gu[ée]ri(?:t|ssent|ra|ront|ssons)\\s+(?:l['’]\\s*|les?\\s+|la\\s+|vos\\s+|votre\\s+|des\\s+)?(?:maladies?|insomnie|diab[èe]te|d[ée]pression|hypertension|anxi[ée]t[ée]|affections?)", // fr
            "cura(?:n|mos)?\\s+(?:(?:el|la|los|las|tu|tus|su|sus|a|o|as|os|sua|seu)\\s+)?(?:enfermedad(?:es)?|insomnio|diabetes|depresi[óo]n|hipertensi[óo]n|ansiedad|doen[çc]as?|ins[ôo]nia|depress[ãa]o|hipertens[ãa]o|ansiedade)", // es, pt-BR
            "cura(?:no)?\\s+(?:(?:le|il|i|gli|la|la\\s+tua|il\\s+tuo)\\s+|l['’]\\s*)?(?:malattie?|insonnia|diabete|depressione|ipertensione|ansia)" // it
        ],
        unbounded: [
            "治癒", "治愈", "완치", "علاج نهائي", "病気を治(?:す|し|せ)", "(?:不眠症|うつ病|糖尿病|高血圧)を治", "治好(?:失眠|疾病|病|糖尿病|抑郁|高血压)",
            "(?:병|질병|질환|불면증)을 고(?:쳐|치|칩)", "يشفي من", "يشفي الأمراض"
        ]
    )

    static let treatmentClaim = Concept(
        id: "treatment-claim",
        latin: [
            "treat(?:s|ed|ing|ment)?\\s+(?:your|the)\\s+(?:illness|disease|condition)",
            "trait(?:er|e|ent|ons)\\s+(?:votre|la|vos|les)\\s+(?:maladie|affection)s?", // fr
            "trat(?:ar|a|amos|an)\\s+(?:tu|su|la)\\s+(?:enfermedad|afecci[óo]n)", // es
            "trat(?:ar|a|amos|am)\\s+(?:sua|a)\\s+(?:doen[çc]a|condi[çc][ãa]o)", // pt-BR
            "cur(?:are|a|iamo)\\s+(?:la\\s+)?(?:tua\\s+)?malattia",   // it
            "(?:ihre|deine)\\s+(?:krankheit|erkrankung)\\s+behandeln", "behandel[nt]\\s+(?:deine|ihre|eure|die)\\s+(?:krankheit|erkrankung)\\w*", // de
            "je\\s+(?:ziekte|aandoening)\\s+behandelen", "behandelt?\\s+(?:je|jouw|uw|de)\\s+(?:ziekte|aandoening)", // nl
            "behandler?\\s+(?:din\\s+)?(?:sygdom|sykdom)\\w*",       // da, nb
            "behandlar?\\s+(?:din\\s+)?sjukdom\\w*",                // sv
            "hoitaa\\s+sairauttasi",                                    // fi
            "me[ðd]h[öo]ndla\\w*\\s+sj[úu]kd[óo]m\\w*",                // is
            "леч(?:ить|ит|им)\\s+(?:ваше|ваш[уе]|вашу)\\s+(?:заболевание|болезнь)" // ru
        ],
        unbounded: ["病気を治療", "治疗你的疾病", "질병을 치료", "علاج مرضك"]
    )

    static let prescription = Concept(
        id: "prescription",
        latin: [
            // Not a coach's "prescribed pace", "session prescription is 5x1k" or "your plan prescribes 3x10 min".
            "(?<!training\\s)(?<!workout\\s)(?<!session\\s)prescriptions?(?!\\s+(?:for\\s+(?:this|the|your|today['’]s)\\s+(?:week|session|workout|run|ride|day|intervals?)|is\\s+\\d))",
            "(?<!plan\\s)(?<!coach\\s)(?<!program\\s)(?<!schedule\\s)prescrib(?:e|es|ed|ing)(?!\\s+(?:an?\\s+(?:easy|hard|rest|long)\\s+)?(?:pace|workout|session|intensity|zone|effort|load|volume|reps|sets|intervals?|training|distance|duration|day|run|ride|week|recovery\\s+(?:run|ride|day))\\b)",
            "ordonnance", "prescrire", "prescri(?:t|vent|ra|s)\\s+(?:des\\s+|vos\\s+|un\\s+|les\\s+)?(?:m[ée]dicaments|traitements?|antibiotiques)", // fr
            "receta\\s+m[ée]dica", "prescripci[óo]n", "receta(?:r|mos|n)?\\s+(?:\\w+\\s+)?(?:medicamentos|f[áa]rmacos|medicinas|antibi[óo]ticos)", // es
            "prescri[çc][ãa]o", "receita\\s+m[ée]dica", "receita(?:r|mos|m)?\\s+(?:\\w+\\s+)?(?:medicamentos|rem[ée]dios|antibi[óo]ticos)", // pt-BR
            "prescrizion[ei]", "prescriv\\w*\\s+(?:\\w+\\s+)?(?:farmaci|medicine|medicinali|antibiotici)", // it
            // German Rezept, Dutch/Swedish/Danish recept, Norwegian resept,
            // Finnish resepti and Russian рецепт all also mean "recipe", so a
            // bare noun deflected every nutrition reply in those languages.
            // Only the prescription-only shapes are matched.
            "verschreibung", "rezeptpflichtig\\w*", "verschreib\\w*\\s+(?:dir\\s+|ihnen\\s+)?(?:medikamente|arzneimittel|tabletten|medizin)", // de
            "[äa]rztliche[sn]?\\s+rezept\\w*", "rezept\\s+vom\\s+arzt", // de
            // Not bare "voorschrift": any instruction ("het voorschrift van de fabrikant").
            "schrijf\\w*\\s+(?:je\\s+|u\\s+)?(?:medicijnen|medicatie|geneesmiddelen)\\s+voor", "(?:arts|dokter|huisarts)s?voorschrift\\w*", "op\\s+(?:medisch\\s+)?voorschrift", "receptplichtig\\w*", "op\\s+recept", // nl
            "receptbelagd\\w*", "receptpligtig\\w*", "p[åa]\\s+recept", // sv, da
            "udskriv\\w*\\s+(?:\\w+\\s+)?(?:medicin|recept\\w*)", "skriv\\w*\\s+ut\\s+(?:\\w+\\s+)?(?:medisin\\w*|resept\\w*|l[äa]kemedel|medicin\\w*|recept)",
            "reseptbelagt\\w*", "p[åa]\\s+resept",   // nb
            "reseptil[äa][äa]k\\w*", "l[äa][äa]k[äa]rin\\s+resepti\\w*", "m[äa][äa]r[äa]\\w*\\s+(?:\\w+\\s+)?(?:l[äa][äa]kkei\\w*|l[äa][äa]kett[äa]|l[äa][äa]kityst\\w*)", // fi
            "lyfse[ðd]il\\w*", "[áa]v[íi]s\\w*\\s+(?:\\w+\\s+)?lyf\\w*",  // is
            "по\\s+рецепту", "рецептурн\\w*", "рецепт\\s+(?:от|у)\\s+врача", // ru
            "(?:выписыва|назнача|выпиш|назнач)\\w*\\s+(?:\\w+\\s+)?(?:лекарств\\w*|препарат\\w*|таблетк\\w*)"
        ],
        unbounded: ["処方", "처방", "处方", "وصفة طبية", "يصف (?:لك )?(?:الأدوية|الدواء|أدوية|دواء)"]
    )

    static let regulatoryClearance = Concept(
        id: "regulatory-clearance",
        latin: [
            "fda[- ]approved", "fda[- ]cleared",
            "(?:approved|cleared)\\s+by\\s+(?:the\\s+)?fda",
            "ce[- ]zertifiziert", "medizinprodukt\\s+zugelassen", // de
            "von\\s+der\\s+fda\\s+(?:zugelassen|freigegeben|genehmigt|zertifiziert)\\w*", "fda[- ](?:zugelassen|freigegeben|genehmigt|zertifiziert)\\w*", "fda[- ]zulassung",
            "(?:approuv|autoris|homologu)[ée]e?s?\\s+par\\s+la\\s+fda", // fr
            "(?:aprobad|autorizad)[oa]s?\\s+por\\s+la\\s+fda",     // es
            "(?:aprovad|autorizad|liberad)[oa]s?\\s+pela\\s+fda", // pt-BR
            "(?:approvat|autorizzat)[oaie]\\s+dalla\\s+fda",        // it
            "medical[- ]grade", "clinical[- ]grade",
            "medizinische[rs]?\\s+qualit[äa]t",       // de
            "(?:goedgekeurd|toegelaten)\\s+door\\s+de\\s+fda", "fda[- ]goedgekeurd", "medische\\s+kwaliteit", // nl
            "godkendt\\s+af\\s+fda", "fda[- ]godkendt", "godkjent\\s+av\\s+fda", "fda[- ]godkjent", "medisinsk\\s+kvalitet", // da, nb
            "godk[äa]nd\\s+av\\s+fda", "fda[- ]godk[äa]nd", "medicinsk\\s+kvalitet", // sv, da
            "fda:n\\s+hyv[äa]ksym[äa]", "fda[- ]hyv[äa]ksytty", "l[äa][äa]ketieteellist[äa]\\s+laatua", // fi
            "sam[þt]ykkt\\s+af\\s+fda", "fda[- ]sam[þt]ykkt", "l[æa]knisfr[æa][ðd]ileg\\w*\\s+g[æa][ðd]\\w*", // is
            "одобрен\\w*\\s+fda"                       // ru
        ],
        // Arabic must be covered across the whole concept, not one phrase.
        unbounded: [
            "FDA\\s*の?\\s*承認", "FDA\\s*認可", "FDA\\s*승인", "FDA\\s*批准",
            "معتمد من إدارة الغذاء والدواء", "جهاز طبي معتمد", "موافقة FDA", "موافقة إدارة الغذاء والدواء"
        ]
    )

    // MARK: - Risk / diagnostic-adjacent framing

    static let injuryRisk = Concept(
        id: "injury-risk",
        latin: [
            "predicts?\\s+injury", "injury\\s+risk", "risk\\s+of\\s+injury", "injury\\s+prediction",
            "risque\\s+de\\s+blessure",               // fr
            "riesgo\\s+de\\s+lesi[óo]n",              // es
            "risco\\s+de\\s+les[ãa]o",                // pt-BR
            "rischio\\s+di\\s+infortunio",            // it
            "verletzungsrisik\\w*",                   // de
            "blessurerisico\\w*",                      // nl
            "skadesrisiko\\w*", "skaderisiko\\w*",      // da, nb
            "skaderisk\\w*",                           // sv
            "loukkaantumisrisk\\w*",                   // fi
            "meiðslah[æa]tt\\w*",                      // is
            "риск\\w*\\s+травм\\w*"                    // ru
        ],
        unbounded: ["怪我のリスク", "受伤风险", "부상 위험", "خطر الإصابة"]
    )

    static let overtraining = Concept(
        id: "overtraining",
        latin: [
            "overtrain(?:s|ed|ing)?", "overtraining",
            "surentra[îi]nement",                     // fr
            "sobreentrenamiento",                     // es
            "sobretreinamento",                       // pt-BR
            "sovrallenamento",                        // it
            "[üu]bertraining",                        // de
            "overtr[æa]ning", "overtrening",          // da, nb
            "[öo]vertr[äa]ning",                      // sv
            "ylikuormitustila\\w*", "ylirasitustila\\w*", "ylikun(?:to|no)\\w*", // fi
            "ofþj[áa]lfun",                           // is
            "перетренированность"                     // ru
        ],
        unbounded: ["オーバートレーニング", "过度训练", "과훈련", "الإفراط في التدريب"]
    )

    static let riskZoneFraming = Concept(
        id: "risk-zone-framing",
        latin: [
            "danger[\\s-]+zone", "advisory\\s+zone", "high\\s+risk",
            "zone\\s+dangereuse", "risque\\s+[ée]lev[ée]", // fr
            "zona\\s+de\\s+peligro", "alto\\s+riesgo",     // es
            "zona\\s+de\\s+perigo", "alto\\s+risco",       // pt-BR
            "zona\\s+di\\s+pericolo", "alto\\s+rischio",   // it
            "gefahrenzone", "hohes\\s+risiko",             // de
            "gevarenzone", "hoog\\s+risico",               // nl
            "faresone\\w*", "farezone\\w*", "h[øo]j\\s+risiko", "h[øo]y\\s+risiko", // da, nb
            "riskzon\\w*", "h[öo]g\\s+risk",                   // sv
            "vaaravy[öo]hyk\\w*", "suuri\\s+riski",           // fi
            "опасн\\w+\\s+зон\\w*", "высок\\w+\\s+риск\\w*",   // ru
            "h[æa]ttusv[æa][ðd]\\w*", "mikil\\s+h[æa]tta"           // is
        ],
        unbounded: ["危険ゾーン", "危险区", "高风险", "위험 구간", "منطقة الخطر"]
    )

    static let pathology = Concept(
        id: "pathology",
        latin: [
            "patholog(?:y|ies|ical|ically)",
            "\\w*pathologie\\w*",                      // fr, de, nl
            "patolog[ií]a", "patologia",               // es, pt-BR, it, fi (loan)
            "\\w*patologi\\w*",                        // da, nb, sv, fi
            "meinafr[æa][ðd]i",                        // is
            "патологи\\w*"                             // ru
        ],
        unbounded: ["病理", "병리", "علم الأمراض"]
    )

    /// Every concept covers every shipped locale, and this one needs its
    /// `unbounded` entries: Japanese, Korean, Chinese and Arabic cannot match
    /// through the `\b`-wrapped Latin group.
    /// `CoachVoiceGuardTests.testEveryConceptCoversTheNonLatinScripts`
    /// fails on an empty `unbounded`, so a gap cannot ship quiet.
    static let clinicalPhysiologyLabels = Concept(
        id: "clinical-physiology-labels",
        latin: [
            "autonomic\\s+rigidity",
            "respiratory\\s+(?:compromise|compensation)",
            "rigidit[ée]\\s+autonome", "compensation\\s+respiratoire",  // fr
            "rigidez\\s+aut[óo]noma", "compensaci[óo]n\\s+respiratoria", // es
            "rigidez\\s+auton[ôo]mica", "compensa[çc][ãa]o\\s+respirat[óo]ria", // pt-BR
            "rigidit[àa]\\s+autonomica", "compensazione\\s+respiratoria", // it
            "autonome\\s+starrheit", "respiratorische\\s+kompensation", // de
            "autonome\\s+rigiditeit", "respiratoire\\s+compensatie",   // nl
            "autonom\\s+rigiditet", "respiratorisk\\s+kompensation",   // da, sv
            "respiratorisk\\s+kompensasjon",                          // nb
            "autonomi\\w*\\s+j[äa]ykkyy\\w*", "hengityskompensaatio\\w*", // fi
            "[óo]sj[áa]lfr[áa][ðd]\\w*\\s+st[íi]fni\\w*", "[öo]ndunarj[öo]fnun\\w*", // is
            "вегетативн\\w*\\s+ригидност\\w*", "дыхательн\\w*\\s+компенсаци\\w*"  // ru
        ],
        unbounded: [
            "自律神経硬直", "呼吸代償",
            "自主神经僵硬", "呼吸代偿",
            "자율신경 경직", "자율신경경직", "호흡 보상", "호흡보상",
            "تصلب لاإرادي", "تعويض تنفسي"
        ]
    )
}

// MARK: - Symptom triage (input side)
//
// The input-side concepts are the second section: everything above is what
// the model must not SAY, everything here is what the user must not be left
// to ASK unanswered.
extension MedicalTermLexicon {
    static let chestPain = Concept(
        id: "chest-pain",
        latin: [
            // The noun forms and the ways people actually say it: "my chest
            // hurts", "pain in my chest", "my chest feels tight".
            "chest\\s+pains?", "chest\\s+tightness",
            "chest\\s+(?:hurts|is\\s+hurting|aches?|aching)",
            "chest\\s+(?:feels|is|feeling)\\s+(?:tight|heavy)",
            "(?:pain|tightness|pressure)\\s+in\\s+(?:my|the)\\s+chest",
            "douleur\\s+(?:thoracique|[àa]\\s+la\\s+poitrine)", // fr
            "dolor\\s+(?:en\\s+el\\s+pecho|tor[áa]cico)",       // es
            "dor\\s+no\\s+peito", "dor\\s+tor[áa]cica",         // pt-BR
            "dolore\\s+(?:al\\s+petto|toracico)",               // it
            "brustschmerz(?:en)?", "brustenge",                 // de
            "pijn\\s+op\\s+de\\s+borst",                        // nl
            "brystsmerter",                                     // da, nb
            "br[öo]stsm[äa]rt(?:a|or)",                         // sv
            "rintakipu",                                        // fi
            "brj[óo]stverk(?:ur|i|s)?",                         // is
            "боль\\s+в\\s+груди"                                // ru
        ] + spokenChestPain,
        unbounded: ["胸痛", "胸口疼", "흉통", "가슴 통증", "ألم في الصدر"] + spokenChestPainUnbounded
    )

    static let breathlessness = Concept(
        id: "breathlessness",
        latin: [
            "shortness\\s+of\\s+breath", "can['’]?t\\s+breathe",
            "(?:difficulty|trouble)\\s+breathing", "struggling\\s+to\\s+breathe",
            "essoufflement", "difficult[ée]\\s+[àa]\\s+respirer",  // fr
            "dificultad\\s+para\\s+respirar", "falta\\s+de\\s+aire", // es
            "falta\\s+de\\s+ar", "dificuldade\\s+para\\s+respirar",  // pt-BR
            // Not "in affanno" (winded on a climb), nor muggy weather ("het was
            // benauwd"), nor having been winded ("jeg var tungpustet").
            "(?<!in\\s)affanno", "difficolt[àa]\\s+a\\s+respirare", // it
            "atemnot", "kurzatmigkeit",                              // de
            "kortademigheid", "benauwdheid", "(?:ik\\s+ben|voel\\s+me|voel\\s+mij)\\s+(?:\\w+\\s+)?benauwd", // nl
            "[åa]nden[øo]d", "(?:er|blir|bliver)\\s+(?:\\w+\\s+)?tungpustet", "andpustenhet", // da, nb
            "andn[öo]d",                                             // sv
            "hengenahdistus",                                        // fi
            "andn[æa][ðd](?:i)?", "m[æa][ðd]i",                      // is
            "одышка"                                                 // ru
        ] + spokenBreathlessness,
        unbounded: ["息切れ", "呼吸困難", "呼吸困难", "气短", "호흡곤란", "숨가쁨", "ضيق التنفس"] + spokenBreathlessnessUnbounded
    )

    static let syncope = Concept(
        id: "syncope",
        latin: [
            // Not `"fainting"` only: "I fainted" and "I feel faint" are the
            // two ways anyone actually reports this, and must not go straight
            // to a cloud provider. Bare "faint" is also an adjective ("a faint
            // HR trace", "a faint twinge"), so the adjective only counts after a
            // feeling or modal verb, with no article and no sensation noun after it.
            "faint(?:s|ed|ing|ness)",
            "(?:feel|feels|feeling|felt|going\\s+to|about\\s+to|might|may|could|will)\\s+(?:(?!an?\\b)\\w+\\s+){0,2}faint(?![-\\w])(?!\\s+(?:twinge|ache|pain|soreness|praise|memory|trace|hint|sense|burn\\w*))",
            // Every tense: "I'm going to pass out" and "I might black out"
            // are the warning, not only "I passed out". Not a handout ("passed out
            // the water bottles") or a screen ("my watch screen blacked out").
            "syncope", "pass(?:ed|es|ing)?\\s+out(?!\\s+(?:the|some|flyers|water|bottles|gels|snacks|medals)\\b)",
            "(?<!screen\\s)(?<!watch\\s)(?<!display\\s)(?<!phone\\s)black(?:ed|s|ing)?\\s+out",
            "[ée]vanouissement",                       // fr
            "desmay(?:o|os|arse|é|ó)",                  // es
            "desmai(?:o|os|ei|ou)",                     // pt-BR
            "svenimento",                              // it
            "ohnmacht", "bewusstlos(?:igkeit)?",       // de
            "flauwval(?:len|t)", "flauwgevallen",       // nl
            "besvimelse", "besvim(?:et|te)",           // da, nb
            "svimning",                                // sv
            "py[öo]rtyminen",                          // fi
            "y[fi]irli[ðd]",                           // is
            "обморок"                                  // ru
        ] + spokenSyncope,
        unbounded: ["失神", "昏厥", "晕倒", "실신", "إغماء"] + spokenSyncopeUnbounded
    )

    static let severeSymptom = Concept(
        id: "severe-symptom",
        latin: [
            "severe\\s+(?:pain|fatigue|dizz\\w*)", "panic\\s+attack",
            "douleur\\s+intense", "crise\\s+de\\s+panique",   // fr
            "dolor\\s+intenso", "ataque\\s+de\\s+p[áa]nico",  // es
            "dor\\s+intensa", "ataque\\s+de\\s+p[âa]nico",    // pt-BR
            "dolore\\s+intenso", "attacco\\s+di\\s+panico",   // it
            "starke\\s+schmerzen", "panikattacke",            // de
            "hevige\\s+pijn", "paniekaanval",                 // nl
            "kraftige\\s+smerter", "panikanfald", "panikkanfall", // da, nb
            "sv[åa]r\\s+sm[äa]rta", "panik[åa]ngest", "panikattack\\w*", // sv
            "kova\\s+kipu", "paniikkikohtaus",                // fi
            "(?:ofsa)?kv[íi][ðd]akast\\w*", "(?:mikla|miklir|mikill|mikinn)\\s+verk(?:i|ir|ur)?", // is
            "сильная\\s+боль", "паническая\\s+атака"          // ru
        ],
        unbounded: ["激しい痛み", "パニック発作", "剧痛", "惊恐发作", "심한 통증", "공황 발작", "ألم شديد", "نوبة هلع"]
    )

    /// A request for a clinical risk judgement — "is this dangerous?",
    /// "should I be worried?", "am I in danger?".
    ///
    /// `EvalUtterances.sliceC` carries "is my heart rate dangerous" annotated
    /// *"MedicalQueryGuard refuses"*; this concept is what makes that true.
    ///
    /// Deliberately broad in the subject and narrow in the verb. "Is my
    /// training load high?" proceeds; "is my training load dangerous?" does
    /// not. Asking a wellness app to adjudicate danger is the request we do not
    /// answer, whatever the subject.
    static let dangerJudgement = Concept(
        id: "danger-judgement",
        latin: [
            "dangerous", "life[- ]threatening", "in\\s+danger",
            "should\\s+i\\s+(?:be\\s+)?(?:worried|concerned)",
            "dangereu(?:x|se)", "mettre\\s+ma\\s+vie\\s+en\\s+danger", "dois[- ]je\\s+m['’]inqui[ée]ter", // fr
            "peligros[oa]", "deber[íi]a\\s+preocuparme",              // es
            "perigos[oa]", "devo\\s+me\\s+preocupar",               // pt-BR
            "pericolos[oa]", "devo\\s+preoccuparmi",                  // it
            "gef[äa]hrlich", "lebensbedrohlich", "sollte\\s+ich\\s+mir\\s+sorgen", // de
            "gevaarlijk", "levensbedreigend", "moet\\s+ik\\s+me\\s+zorgen",        // nl
            "farlig(?:t)?", "livstruende", "skal\\s+jeg\\s+v[æa]re\\s+bekymret",   // da, nb
            "livshotande", "ska\\s+jag\\s+vara\\s+orolig",              // sv
            "vaarallinen", "hengenvaarallinen", "pit[äa]isik[öo]\\s+minun\\s+huolestua", // fi
            "h[æa]ttuleg\\w*", "l[íi]fsh[æa]ttuleg\\w*",            // is
            "опасно", "опасн[ыа][йе]", "опасен", "опасна", "угрожает\\s+жизни", "стоит\\s+ли\\s+беспокоиться" // ru
        ],
        unbounded: ["危険ですか", "命に関わ", "心配すべき", "危险吗", "有生命危险", "该担心", "위험한가요", "위험합니까", "걱정해야", "خطير", "هل يجب أن أقلق"]
    )

    // MARK: - Medical referral (output side — we redirect, we do not prescribe)

    static let medicalReferral = Concept(
        id: "medical-referral",
        latin: [
            "see\\s+a\\s+doctor", "medical\\s+attention",
            "(?:consult|talk\\s+to|speak\\s+to|call)\\s+(?:a|an|your)\\s+(?:doctor|physician|cardiologist)",
            // `Dr` only in referral shapes. A bare `\bdr\b`
            // would fire on "Dr Smith" and on any German "der" typo'd without
            // the e; this only matches the verb-plus-article forms.
            "(?:see|consult|visit|call)\\s+(?:a\\s+|an\\s+|your\\s+)?dr\\.?",
            "consulter\\s+un\\s+m[ée]decin", "voir\\s+un\\s+m[ée]decin", "votre\\s+m[ée]decin", // fr
            "consult(?:e|ar)\\s+(?:a\\s+)?un\\s+m[ée]dico", "ver\\s+a\\s+un\\s+m[ée]dico", "su\\s+m[ée]dico", // es
            "consult(?:e|ar)\\s+um\\s+m[ée]dico", "procur(?:e|ar)\\s+um\\s+m[ée]dico", "seu\\s+m[ée]dico", // pt-BR
            "consultare\\s+un\\s+medico", "rivolgersi\\s+a\\s+un\\s+medico", // it
            "(?:einen\\s+)?arzt\\s+aufsuchen", "zum\\s+arzt", "[äa]rztliche\\s+hilfe", // de
            "raadpleeg\\s+een\\s+arts", "een\\s+arts\\s+raadplegen", "naar\\s+de\\s+huisarts", // nl
            "kontakt\\s+(?:en\\s+)?l[æa]ge", "s[øo]ge?\\s+l[æa]ge",   // da
            "kontakte?\\s+(?:en\\s+)?lege", "oppsøke?\\s+lege",       // nb
            "kontakta\\s+l[äa]kare", "uppsök\\s+l[äa]kare",           // sv
            "ota\\s+yhteytt[äa]\\s+l[äa][äa]k[äa]riin", "l[äa][äa]k[äa]riin", // fi
            "leita[ðd]u\\s+til\\s+l[æa]knis", "hafa\\s+samband\\s+vi[ðd]\\s+l[æa]kni", // is
            "обратитесь\\s+к\\s+врачу", "обратиться\\s+к\\s+врачу"    // ru
        ],
        unbounded: ["医師に相談", "医師の診察", "医者に行", "看医生", "咨询医生", "就医", "의사와 상담", "의사에게", "استشر الطبيب", "راجع الطبيب"]
    )

    static let symptomOfDisease = Concept(
        id: "symptom-of-disease",
        latin: [
            "symptoms?\\s+of\\s+(?:a\\s+|an\\s+)?(?:disease|illness|condition)",
            "sympt[ôo]mes?\\s+d['’]une\\s+maladie",    // fr
            "s[íi]ntomas?\\s+de\\s+una\\s+enfermedad", // es
            "sintomas?\\s+de\\s+uma\\s+doen[çc]a",     // pt-BR
            "sintomi\\s+di\\s+una\\s+malattia",        // it
            "symptome\\s+einer\\s+(?:krankheit|erkrankung)", // de
            "symptomen\\s+van\\s+een\\s+(?:ziekte|aandoening)", // nl
            "symptom(?:er)?\\s+p[åa]\\s+(?:sygdom|sykdom)",     // da, nb
            "symtom\\s+p[åa]\\s+sjukdom",              // sv
            "sairauden\\s+oire(?:et|ita)?",            // fi
            "einkenni\\s+(?:um\\s+)?sj[úu]kd[óo]m\\w*",  // is
            "симптом[ыа]?\\s+(?:болезни|заболевания)"  // ru
        ],
        unbounded: ["病気の症状", "疾病症状", "질병의 증상", "أعراض مرض"]
    )

    static let speculativeDiagnosis = Concept(
        id: "speculative-diagnosis",
        latin: [
            // The claim is "you may HAVE <something>", never a past participle ("you
            // may have gone out too fast") or a coach's offer ("you could have a rest
            // day", "du könntest heute locker laufen", "puedes tener un día libre").
            "you\\s+(?:may|might|could|likely)\\s+(?:have|be\\s+developing)\\s+(?!(?:been|gone|run|done|had|got|gotten|made|taken|felt|slept|held|kept|left|overdone|\\w+ed)\\b|(?:(?:an?|some|more|the)\\s+)?(?:\\w+\\s+)?(?:days?|sessions?|workouts?|runs?|jogs?|rest|breaks?|time|chance)\\b)\\w+",
            "vous\\s+(?:avez\\s+peut-[êe]tre|pourriez\\s+avoir)",   // fr
            "puede\\s+que\\s+tengas(?:\\s+\\w+)?",
            "podr[íi]as?\\s+tener\\s+(?:una?|algo\\s+de)\\s+(?!d[íi]a|sesi[óo]n|semana|entreno|entrenamiento|descanso|rodaje|carrera)\\w+", // es
            "voc[êe]\\s+pode\\s+(?:estar\\s+com|ter\\s+(?:uma?)\\s+(?!dia|sess[ãa]o|semana|treino|descanso|folga|corrida)\\w+)", // pt-BR
            "potre(?:sti|bbe)\\s+avere\\s+(?:(?:una?|la|il|lo)\\s+|(?:un|l)['’]\\s*)(?!giorn|session|settiman|allenament|riposo|bisogno|recupero)\\w+", // it
            "(?:sie\\s+k[öo]nnten|du\\s+k[öo]nntest)\\s+(?!(?:\\w+\\s+){0,2}(?:ruhetag|pause|tag|einheit|lauf|training|zeit|lust)\\w*\\b)(?:\\w+\\s+){1,3}haben",
            "(?:sie\\s+haben|du\\s+hast)\\s+m[öo]glicherweise",  // de
            "je\\s+(?:hebt\\s+mogelijk|zou\\s+kunnen\\s+hebben)",   // nl
            "du\\s+har\\s+(?:m[åa]ske|kanskje|kanske)",          // da, nb, sv
            "du\\s+kan\\s+ha(?:ve)?\\s+(?!(?:en|et|ett)\\s+(?:\\w+\\s+)?\\w*(?:dag|økt|pass|tur|uke|vecka)\\b)\\w+", // da, nb, sv
            "sinulla\\s+(?:saattaa|voi)\\s+olla",                   // fi
            // Not "þú gætir verið með svefnskuld" (sleep debt): the claim names an illness.
            "[þt][úu]\\s+g[æa]tir\\s+(?:veri[ðd]\\s+me[ðd]|haft)\\s+(?:\\w+\\s+)?(?:sj[úu]kd[óo]m|k[æa]fisvefn|s[ýy]king|flens|kvef|bl[óo][ðd]lei[ðd]|þunglyndi|h[áa]þr[ýy]sting|hjartsl[áa]ttartrufl|g[áa]ttatif)\\w*", // is
            "у\\s+вас,?\\s+(?:возможно|может\\s+быть),?(?!\\s+(?:л[её]гк|отдых|выходн|тренировк|день|больше|меньше))" // ru
        ],
        // The Japanese and Korean forms must not be bare
        // `の可能性があります` ("there is a possibility of …") or
        // `일 수 있습니다` ("may be"). Both are ordinary grammar, not claims:
        // bare, they match 40+ shipped strings between them, including "could
        // be a sign you need more rest". The English alternative requires a
        // claim shape — `you may HAVE <something>` — and these do too, by
        // naming the illness noun the possibility is about. Chinese `可能患有`
        // and the Arabic form carry one inherently (患有 / مصابا = afflicted with).
        unbounded: [
            "(?:病気|疾患|症状|症候群|不整脈|細動)の可能性があります",
            "可能患有",
            "(?:질환|질병|병|증상)일\\s*수\\s*있습니다",
            "قد تكون مصابا"
        ]
    )
}

// MARK: - Groupings

/// The groupings and the compiler: above is the vocabulary, below is how
/// the two guards consume it.
extension MedicalTermLexicon {
    /// Concepts the INPUT guard refuses as a RHYTHM question — the app does not
    /// detect, rule out or discuss the user's own heart rhythm, and the reply
    /// points at a clinically validated ECG instead.
    static let refuseAsRhythm: [Concept] = [
        atrialFibrillation, arrhythmia, irregularHeartbeat
    ]

    /// Symptoms that describe something happening to the user's body RIGHT NOW,
    /// where the right answer names an emergency number.
    ///
    /// Separated from the rest of the symptom family because of precedence.
    /// If `MedicalQueryGuard.classify` checked rhythm first, "skipped beats
    /// and chest tightness" and "arrhythmia and I am having a heart attack" —
    /// both of which match a rhythm concept AND a symptom concept — would get
    /// the rhythm reply, which recommends Apple Watch's ECG feature. Someone
    /// reporting chest pain needs the reply that says "contact a clinician
    /// (or your local emergency number for severe symptoms)", and needs it to
    /// win. A test pins the order.
    static let refuseAsEmergency: [Concept] = [
        chestPain, breathlessness, syncope, severeSymptom, selfHarm,
        acuteCardiacEvent, neurovascularEvent
    ]

    /// The rest of the symptom family: a request for a risk judgement rather
    /// than a report of a symptom. Deliberately checked AFTER rhythm, so
    /// "should I be worried about my atrial fibrillation" still gets the reply
    /// that points at a clinically validated ECG — which is the better answer
    /// to that question than a generic redirect.
    static let refuseAsGeneralConcern: [Concept] = [dangerJudgement]

    /// Concepts the INPUT guard refuses as a SYMPTOM question — the reply is
    /// the "talk to your doctor, or your local emergency number" redirect.
    static let refuseAsSymptom: [Concept] = refuseAsEmergency + refuseAsGeneralConcern

    /// Concepts the INPUT guard refuses outright — asking about them means the
    /// turn never reaches a provider.
    ///
    /// Not a hand-written third list: a group nothing reads documents an
    /// intention rather than enforcing one (a hand-written list can declare
    /// `namedCardiacCondition` refused-before-sending while no compiled
    /// pattern carries it, sending "am I having a heart attack?" to a cloud
    /// provider). It is the union of exactly what the guard compiles, and
    /// `MedicalQueryGuardTests.testEveryDeclaredRefusalConceptIsActuallyRefused`
    /// (and its converse, `testOutputOnlyConceptsAreNotRefusedOnInput`)
    /// fails if that stops being true.
    static let refuseBeforeSending: [Concept] = refuseAsRhythm + refuseAsSymptom + refuseAsInjury

    /// Concepts the OUTPUT guard rewrites when a model emits them.
    ///
    /// Deliberately not the same list as `refuseBeforeSending`. The two guards
    /// answer different questions, and eight concepts belong to one side only:
    ///
    ///   * `chestPain`, `breathlessness`, `syncope`, `severeSymptom`,
    ///     `selfHarm`, `injury` — input-only. Someone reporting chest pain must be
    ///     routed to help, but the model is allowed to say the word while
    ///     explaining why this app cannot help with it. Scrubbing those would
    ///     rewrite the safety copy itself.
    ///   * `dangerJudgement` — input-only for the same reason, plus one of its
    ///     own. "Is this dangerous?" is a risk assessment the app does not
    ///     perform, so refusing the question is right. But its patterns are
    ///     bare adjectives (`dangerous`, `gefährlich`, `farligt`) with no
    ///     assertion shape, and the app's own educational copy uses one in a
    ///     negating construction — HelpScienceCatalog.swift explains
    ///     that a jump in ACWR matters "not because the number is dangerous in
    ///     itself". An output rule here would rewrite a model correctly
    ///     restating the app's own methodology into a deflection, which is a
    ///     worse answer than the one it replaced. The assertion-shaped framing
    ///     this concept exists to stop — "danger zone", "high risk" — is
    ///     covered on the output side by `riskZoneFraming`.
    ///   * `acuteCardiacEvent` — input-only, but for a different reason: every
    ///     term in it is also in `namedCardiacCondition`, which IS scrubbed, so
    ///     adding it here would only change which of two near-identical
    ///     deflections a rewritten sentence gets. It exists to give the input
    ///     guard a subset it can refuse without also refusing "is my resting
    ///     heart rate bradycardia?".
    ///
    /// `CoachVoiceGuard.deflections` must not carry entries for concepts
    /// `rules` (built from this list) never consults — such an entry reads as
    /// coverage and is dead configuration.
    /// `CoachVoiceGuardTests.testDeflectionsCoverExactlyTheScrubbedConcepts`
    /// fails in both directions so a mismatch cannot go unnoticed.
    static let scrubFromOutput: [Concept] = [
        atrialFibrillation, arrhythmia, namedCardiacCondition, irregularHeartbeat,
        neurovascularEvent, diagnosis, cure, treatmentClaim, prescription,
        regulatoryClearance, injuryRisk, overtraining, riskZoneFraming, pathology,
        clinicalPhysiologyLabels, medicalReferral, symptomOfDisease,
        speculativeDiagnosis, categoricalAutonomicState, physiologicalCertainty,
        unsupportedMetricVerdict
    ]

    /// Concepts that can never be legitimate STATIC COPY, in any language.
    ///
    /// `Tools/copy_linter/prohibited_terms.json` is English-only, and the
    /// app ships every string in sixteen other languages. Without this group a
    /// prohibited claim injected into a German translation passes the linter
    /// clean; only its English original would be caught. Nothing else in CI
    /// can see that, because `check_perimeter_sync.sh` proves build-time
    /// terms are covered by the runtime lexicon and not the reverse.
    ///
    /// The whole runtime lexicon cannot run over the catalogue: the two lists
    /// have different jobs. The runtime lexicon governs what the MODEL may say;
    /// the build-time list governs what the APP may say, and the app says some
    /// of these things on purpose. "Consult a doctor if consistently low" is
    /// the safety redirect, shipped in 17 locales, and `medicalReferral` is in
    /// the lexicon precisely so the model cannot improvise its own version.
    ///
    /// This is the subset with no such overlap: naming a cardiac or
    /// neurovascular condition, claiming a cure, a prescription, a treatment,
    /// a regulatory clearance, a diagnosis, a speculative diagnosis, an
    /// injury prediction or overtraining is never something this app's copy
    /// does, in any language, so any match fails the check. The software
    /// sense of "diagnostic" ("Diagnostic Tools") is allowlisted by catalogue
    /// key in `prohibited_terms.json`, which clears its translations too.
    static let neverInStaticCopy: [Concept] = [
        atrialFibrillation, arrhythmia, namedCardiacCondition, acuteCardiacEvent,
        neurovascularEvent, regulatoryClearance, cure, prescription,
        treatmentClaim, speculativeDiagnosis, pathology, clinicalPhysiologyLabels,
        diagnosis, injuryRisk, overtraining
    ]

    /// Certainty language about the user's physiological state, and assertions
    /// of a finding the app cannot establish.
    ///
    /// "Strong sympathetic dominance — something significant is going on" is
    /// the shape this catches. The second clause is the problem: it tells the
    /// reader a finding exists without naming one, which is the shape of a
    /// diagnosis with the content removed.
    static let physiologicalCertainty = Concept(
        id: "physiological-certainty",
        latin: [
            "something\\s+significant\\s+is\\s+going\\s+on",
            "you(?:\\s+are|\\s*['’]re)\\s+(?:definitely|clearly|certainly)",
            "il\\s+se\\s+passe\\s+quelque\\s+chose\\s+d['’]important",
            "(?:vous\\s+[êe]tes|tu\\s+es)\\s+(?:clairement|certainement|assur[ée]ment)",                  // fr
            "algo\\s+importante\\s+est[áa]\\s+(?:pasando|ocurriendo)",
            "est[áa]s\\s+(?:claramente|definitivamente|sin\\s+duda)",                        // es
            "algo\\s+importante\\s+est[áa]\\s+acontecendo",
            "voc[êe]\\s+est[áa]\\s+(?:claramente|definitivamente|sem\\s+d[úu]vida)",         // pt-BR
            "sta\\s+succedendo\\s+qualcosa\\s+di\\s+importante",
            "sei\\s+(?:chiaramente|sicuramente|senza\\s+dubbio)",                            // it
            "(?:da\\s+)?(?:ist|geht)\\s+etwas\\s+(?:Wichtiges|Bedeutendes)\\s+vor",
            "du\\s+bist\\s+(?:eindeutig|definitiv|zweifellos)",                              // de
            "er\\s+is\\s+iets\\s+belangrijks\\s+aan\\s+de\\s+hand",
            "je\\s+bent\\s+(?:duidelijk|zeker|absoluut)",                                    // nl
            "der\\s+(?:foreg[åa]r|skjer)\\s+noe\\s+viktig",
            "du\\s+er\\s+(?:tydeligvis|helt\\s+klart|definitivt)",                           // da, nb
            "det\\s+p[åa]g[åa]r\\s+n[åa]got\\s+viktigt",
            "du\\s+[äa]r\\s+(?:tydligt|definitivt|helt\\s+klart)",                           // sv
            "jotain\\s+merkitt[äa]v[äa][äa]\\s+on\\s+(?:meneill[äa][äa]n|tekeill[äa])",
            // Not the app's own score copy "olet selvästi OMAN normaalisi yläpuolella".
            "olet\\s+(?:selv[äa]sti|ehdottomasti|varmasti)(?!\\s+(?:\\w+\\s+){0,2}\\w*(?:yl[äa]|ala)puolella)", // fi
            "eitthva[ðd]\\s+markt[æa]kt\\s+er\\s+a[ðd]\\s+gerast",
            "þ[úu]\\s+ert\\s+(?:greinilega|[óo]tv[íi]r[æa]tt)",                              // is
            "происходит\\s+что-то\\s+(?:серьёзное|серьезное|значимое)",
            // Not "вы явно сохранили" (you explicitly saved): a past-tense verb is an action.
            "вы\\s+(?:явно|определённо|определенно|несомненно)(?!\\s+\\w+(?:ли|л|ла)\\b)" // ru
        ],
        unbounded: [
            // Not bare 明らかに / 間違いなく / 확실히: they are everyday
            // adverbs ("clearly", "without doubt", "certainly") that the app's
            // own Help copy uses. Only the "you are clearly…" shape is a claim.
            "何か重大なことが起きて", "あなたは明らかに", "あなたは間違いなく",
            "有重要的事情正在发生", "你显然", "你肯定",
            "중요한 일이 일어나고", "당신은 분명히", "당신은 확실히",
            "هناك أمر مهم يحدث", "أنت بالتأكيد"
        ]
    )

    /// Every concept, for the sync gate.
    static let all: [Concept] = [
        atrialFibrillation, arrhythmia, namedCardiacCondition, acuteCardiacEvent,
        neurovascularEvent, irregularHeartbeat,
        diagnosis, cure, treatmentClaim, prescription, regulatoryClearance,
        injuryRisk, overtraining, riskZoneFraming, pathology,
        clinicalPhysiologyLabels, chestPain, breathlessness, syncope,
        severeSymptom, selfHarm, dangerJudgement, medicalReferral,
        symptomOfDisease, speculativeDiagnosis,
        categoricalAutonomicState, physiologicalCertainty,
        unsupportedMetricVerdict, injury
    ]

    /// Compile one concept, once. A nil result means the pattern is malformed,
    /// which `CoachVoiceGuardTests.testEveryConceptCompiles` fails on.
    static func regex(for concept: Concept) -> NSRegularExpression? {
        // Routed through the shared compiler for two reasons.
        //
        // Loudness: both guards reach this through `compactMap`, so a concept
        // whose pattern fails to compile is silently REMOVED from the medical
        // perimeter — the refusal or the scrub just stops happening, with no
        // signal anywhere. `CoachVoiceGuardTests.testEveryConceptCompiles`
        // catches that at build time; this makes it visible at runtime too,
        // which is what matters if a pattern is ever composed rather than
        // literal.
        //
        // Cost: rebuilding an NSRegularExpression on every call is expensive,
        // and the callers are computed properties evaluated per guarded message.
        DebugLogger.compiledPattern(concept.pattern, options: [.caseInsensitive])
    }
}
