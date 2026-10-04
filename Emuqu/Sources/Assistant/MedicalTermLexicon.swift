import Foundation

/// The regulated-language vocabulary shared by both halves of the FDA
/// perimeter: `MedicalQueryGuard` (what the user asks, before anything leaves
/// the device) and `CoachVoiceGuard` (what the assistant says, before it
/// reaches eyes or speakers).
///
/// ## Why this file exists
///
/// The two guards were written months apart and each carried its own private
/// regex list. `MedicalQueryGuard` knew two patterns; `CoachVoiceGuard` knew
/// twelve; `Tools/copy_linter/prohibited_terms.json` knew twenty-one. Nothing
/// reconciled them, and `CoachVoiceGuard`'s own header said so out loud:
/// *"Keeping these in sync is a manual responsibility — there is no runtime
/// cross-check."* The practical result was that a model could answer
/// "this looks like atrial fibrillation" and the OUTPUT guard had no pattern
/// for it, because "arrhythmia" lived only on the build-time list.
///
/// Worse, every pattern in all three places was English. The app ships sixteen
/// non-English localizations at 100% catalogue coverage, and the assistant
/// answers in the user's language. A guard that only reads English is not a
/// guard with a gap — for those users it is not a guard at all.
/// `MedicalQueryGuardTests` documented half of this as a known gap
/// (`testKnownGap_NonEnglishAFibCurrentlySlips`) and asserted nothing.
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
            "eteisv[äa]rin[äa]",                      // fi
            "g[áa]ttatif(?:i|s)?",                    // is
            "фибрилляция\\s+предсердий", "мерцательная\\s+аритмия" // ru
        ],
        unbounded: ["心房細動", "心房颤动", "房颤", "심방세동", "الرجفان الأذيني"]
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
            "(?<!sinus)rytmih[äa]iri[öo]",            // fi
            "hjartsl[áa]ttartruflun(?:ir|um|ar)?",          // is
            "(?<!синусовая\\s)(?<!синусовой\\s)аритми[яи]"  // ru
        ],
        unbounded: [
            "(?<!洞性)不整脈",                          // ja
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
            "ischemi[ac]", "isch[ae]emia", "angina", "hypertension", "hypotension",
            "flutter\\s+auriculaire", "bloc\\s+auriculo[- ]ventriculaire", "bradycardie", "tachycardie",
            "infarctus", "crise\\s+cardiaque", "hypertension\\s+art[ée]rielle",   // fr
            "aleteo\\s+auricular", "bloqueo\\s+card[íi]aco", "bradicardia", "taquicardia",
            "infarto", "ataque\\s+card[íi]aco", "hipertensi[óo]n", "hipotensi[óo]n", // es, pt-BR, it
            "vorhofflattern", "herzblock", "bradykardie", "tachykardie",
            "herzinfarkt", "herzstillstand", "bluthochdruck",                      // de
            "boezemflutter", "hartblok", "bradycardie", "tachycardie",
            "hartaanval", "hartstilstand", "hoge\\s+bloeddruk",                    // nl
            "atrieflagren", "atrieflutter", "hjerteblok", "bradykardi", "takykardi",
            "hjerteanfald", "hjerteinfarkt", "hjertestop", "hjertestans",           // da, nb
            "f[öo]rmaksfladder", "hj[äa]rtblock", "bradykardi", "takykardi",
            "hj[äa]rtinfarkt", "hj[äa]rtstopp",                                     // sv
            "eteislepatus", "sydänkatkos", "bradykardia", "takykardia",
            "syd[äa]ninfarkti", "syd[äa]npys[äa]hdys",                              // fi
            "hjartaáfall", "hjartastopp",                                           // is
            "трепетание\\s+предсердий", "брадикардия", "тахикардия",
            "инфаркт", "остановка\\s+сердца", "гипертония"                        // ru
        ],
        unbounded: [
            "心房粗動", "心房扑动", "심방조동",
            "徐脈", "頻脈", "心筋梗塞", "心停止",
            "心动过缓", "心动过速", "心肌梗死", "心脏骤停",
            "서맥", "빈맥", "심근경색", "심정지",
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
    /// asking an ordinary training question. Refusing that would be a
    /// regression, not a safeguard.
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
            "infarto", "ataque\\s+card[íi]aco",                   // es, pt-BR, it
            "herzinfarkt", "herzstillstand",                      // de
            "hartaanval", "hartstilstand",                        // nl
            "hjerteanfald", "hjerteinfarkt", "hjertestop", "hjertestans", // da, nb
            "hj[äa]rtinfarkt", "hj[äa]rtstopp",                   // sv
            "syd[äa]ninfarkti", "syd[äa]npys[äa]hdys",            // fi
            "hjartaáfall", "hjartastopp",                         // is
            "инфаркт", "остановка\\s+сердца"                      // ru
        ],
        unbounded: [
            "心筋梗塞", "心停止", "心肌梗死", "心脏骤停",
            "심근경색", "심정지",
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
            // The lookahead keeps "a stroke of luck" / "a stroke of genius" out.
            // Idiom is the other half of this word's polysemy problem, after the
            // swimming metric.
            "(?:having|had|have)\\s+a\\s+stroke(?!\\s+of\\s)", "stroke\\s+(?:symptoms|victim)",
            "mini[- ]stroke", "transient\\s+ischemic\\s+attack",
            "cerebrovascular", "pulmonary\\s+embolism", "blood\\s+clot",
            "deep\\s+vein\\s+thrombosis",
            "accident\\s+vasculaire\\s+c[ée]r[ée]bral", "embolie\\s+pulmonaire",
            "caillot\\s+de\\s+sang",                            // fr
            "derrame\\s+cerebral", "accidente\\s+cerebrovascular", "ictus",
            "embolia\\s+pulmonar", "co[áa]gulo\\s+de\\s+sangre", // es, pt-BR
            "embolia\\s+polmonare", "coagulo\\s+di\\s+sangue",  // it
            "schlaganfall", "lungenembolie", "blutgerinnsel",     // de
            "beroerte", "herseninfarct", "longembolie", "bloedstolsel", // nl
            "hjerneslag", "hjerneblødning", "blodprop", "lungeemboli",  // da, nb
            "hj[äa]rnbl[öo]dning", "slaganfall", "blodpropp", "lungemboli", // sv
            "aivohalvaus", "aivoinfarkti", "keuhkoembolia", "verihyytym[äa]",  // fi
            "heilabl[óo][ðd]fall", "bl[óo][ðd]tappi",             // is
            "инсульт", "тромбоэмболия", "тромб"                   // ru
        ],
        unbounded: [
            "脳卒中", "脳梗塞", "肺塞栓", "血栓",
            "脑卒中", "中风", "脑梗死", "肺栓塞",
            "뇌졸중", "뇌경색", "폐색전", "혈전",
            "سكتة دماغية", "جلطة", "انسداد رئوي"
        ]
    )

    static let irregularHeartbeat = Concept(
        id: "irregular-heartbeat",
        latin: [
            "irregular\\s+(?:heart\\s*)?(?:beat|rhythm|pulse)",
            "heart\\s+(?:is\\s+)?beating\\s+irregularly?",
            "skipped?\\s+beats?", "palpitations?",
            "palpitations?", "battements?\\s+irr[ée]guliers?", "rythme\\s+cardiaque\\s+irr[ée]gulier", // fr
            "palpitaciones", "latidos?\\s+irregulares?",       // es
            "palpita[çc][õo]es", "batimentos?\\s+irregulares?", // pt-BR
            "palpitazioni", "battito\\s+irregolare",           // it
            "herzklopfen", "unregelm[äa][ßs]iger\\s+herzschlag", // de
            "hartkloppingen", "onregelmatige\\s+hartslag",     // nl
            "hjertebanken", "uregelm[æa]ssig\\s+hjerterytme",  // da, nb
            "hj[äa]rtklappning", "oregelbunden\\s+hj[äa]rtrytm", // sv
            "syd[äa]mentykytys", "eps[äa]s[äa][äa]nn[öo]llinen\\s+syke", // fi
            "hjartsl[áa]ttar[óo]regla",                        // is
            "учащ[её]нное\\s+сердцебиение", "перебои\\s+в\\s+сердце" // ru
        ],
        unbounded: ["動悸", "心悸", "心跳不规律", "심계항진", "두근거림", "خفقان"]
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
            "diagnostiqu(?:er|é|ée)",
            "diagnostic(?!s?\\s+(?:log|logs|data|tool|tools|bundle))",   // fr
            "diagn[óo]stic[oa]s?(?!\\s+(?:del\\s+archivo|do\\s+arquivo|de\\s+sistema))",
            "diagnosticar",                           // es, pt-BR
            "diagnosi", "diagnosticare",              // it
            // Same software-sense lookahead as the English pattern above, or
            // this bare form re-matches "diagnose log" and undoes it.
            "diagnose(?!\\s+(?:log|logs|data|tool|tools|bundle))", "diagnostizier(?:en|t)", // de, nl, da, nb
            "diagnos(?:er)?",                         // sv
            "diagnoosi",                              // fi
            // Icelandic `greining` means ANALYSIS as much as diagnosis, and the
            // app's own Icelandic UI uses it that way ("Greining" = Analysis,
            // "Greiningu lokið" = Analysis complete). A bare match deflected
            // the assistant every time it mentioned an analysis. The medical
            // sense is compounded.
            "sj[úu]kd[óo]msgreining\\w*", "l[æa]knisgreining\\w*",   // is
            "диагноз", "диагностир"                   // ru
        ],
        unbounded: ["診断", "진단", "诊断", "تشخيص"]
    )

    static let cure = Concept(
        id: "cure",
        latin: [
            "cures?", "cured",
            "gu[ée]rir", "gu[ée]rison",               // fr
            // Not a bare `"cura"`: Italian "prenditi cura" is "take care",
            // and a bare match deflected ordinary coaching. The cure sense is
            // "a cure for…" or an adjective only a cure takes.
            "curar",                                  // es, pt-BR
            "(?:la|una|a|uma)\\s+cura\\s+(?:para|per|de|di|contro|contra)",
            "cura\\s+(?:definitiva|milagrosa|miracolosa)", // es, pt-BR, it
            "heilen", "heilung",                      // de
            "genezen", "genezing",                    // nl
            // Not a bare `"bota"` (Spanish/Portuguese "boot", Portuguese "puts").
            "helbrede", "helbredelse", "botemedel",   // da/nb, sv
            "bota\\s+(?:din\\s+|en\\s+)?\\w*sjukdom\\w*", // sv
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
            "l[æa]kning",                             // is
            "вылечить", "излечение"                   // ru
        ],
        unbounded: ["治癒", "治愈", "완치", "علاج نهائي"]
    )

    static let treatmentClaim = Concept(
        id: "treatment-claim",
        latin: [
            "treat(?:s|ed|ing|ment)?\\s+(?:your|the)\\s+(?:illness|disease|condition)",
            "traiter\\s+(?:votre|la)\\s+(?:maladie|affection)",       // fr
            "tratar\\s+(?:tu|su|la)\\s+(?:enfermedad|afecci[óo]n)",   // es
            "tratar\\s+(?:sua|a)\\s+(?:doen[çc]a|condi[çc][ãa]o)",    // pt-BR
            "curare\\s+(?:la\\s+)?(?:tua\\s+)?malattia",            // it
            "(?:ihre|deine)\\s+(?:krankheit|erkrankung)\\s+behandeln", // de
            "je\\s+(?:ziekte|aandoening)\\s+behandelen",              // nl
            "behandle\\s+(?:din\\s+)?(?:sygdom|sykdom)",              // da, nb
            "behandla\\s+(?:din\\s+)?sjukdom",                        // sv
            "hoitaa\\s+sairauttasi",                                    // fi
            "me[ðd]h[öo]ndla\\s+sj[úu]kd[óo]m",                        // is
            "лечить\\s+(?:ваше|ваш[уе])\\s+(?:заболевание|болезнь)"   // ru
        ],
        unbounded: ["病気を治療", "治疗你的疾病", "질병을 치료", "علاج مرضك"]
    )

    static let prescription = Concept(
        id: "prescription",
        latin: [
            "prescriptions?", "prescribe[ds]?",
            "ordonnance", "prescrire",                // fr
            "receta\\s+m[ée]dica", "prescripci[óo]n", // es
            "prescri[çc][ãa]o", "receita\\s+m[ée]dica", // pt-BR
            "prescrizione",                           // it
            // German Rezept, Dutch/Swedish/Danish recept, Norwegian resept,
            // Finnish resepti and Russian рецепт all also mean "recipe", so a
            // bare noun deflected every nutrition reply in those languages.
            // Only the prescription-only shapes are matched.
            "verschreibung", "rezeptpflichtig\\w*",   // de
            "[äa]rztliche[sn]?\\s+rezept\\w*", "rezept\\s+vom\\s+arzt", // de
            "voorschrift", "receptplichtig\\w*", "op\\s+recept", // nl
            "receptbelagd\\w*", "receptpligtig\\w*", "p[åa]\\s+recept", // sv, da
            "reseptbelagt\\w*", "p[åa]\\s+resept",   // nb
            "reseptil[äa][äa]k\\w*", "l[äa][äa]k[äa]rin\\s+resepti\\w*", // fi
            "lyfse[ðd]ill",                           // is
            "по\\s+рецепту", "рецептурн\\w*", "рецепт\\s+(?:от|у)\\s+врача" // ru
        ],
        unbounded: ["処方", "처방", "处方", "وصفة طبية"]
    )

    static let regulatoryClearance = Concept(
        id: "regulatory-clearance",
        latin: [
            "fda[- ]approved", "fda[- ]cleared",
            "(?:approved|cleared)\\s+by\\s+(?:the\\s+)?fda",
            "ce[- ]zertifiziert", "medizinprodukt\\s+zugelassen", // de
            "approuv[ée]\\s+par\\s+la\\s+fda",        // fr
            "aprobado\\s+por\\s+la\\s+fda",           // es
            "aprovado\\s+pela\\s+fda",                // pt-BR
            "approvato\\s+dalla\\s+fda",              // it
            "medical[- ]grade", "clinical[- ]grade",
            "medizinische[rs]?\\s+qualit[äa]t",       // de
            "одобрено\\s+fda"                         // ru
        ],
        // Arabic must be covered across the whole concept, not one phrase.
        unbounded: [
            "FDA承認", "FDA認可", "FDA 승인", "FDA批准",
            "معتمد من إدارة الغذاء والدواء", "جهاز طبي معتمد"
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
            "verletzungsrisiko",                      // de
            "blessurerisico",                         // nl
            "skadesrisiko", "skaderisiko",            // da, nb
            "skaderisk",                              // sv
            "loukkaantumisriski",                     // fi
            "meiðslah[æa]tta",                        // is
            "риск\\s+травмы"                          // ru
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
            "ylikuormitustila", "ylirasitustila",     // fi
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
            "faresone", "farezone", "h[øo]j\\s+risiko", "h[øo]y\\s+risiko", // da, nb
            "riskzon", "h[öo]g\\s+risk",                   // sv
            "vaaravy[öo]hyke", "suuri\\s+riski",           // fi
            "опасная\\s+зона", "высокий\\s+риск"           // ru
        ],
        unbounded: ["危険ゾーン", "危险区", "高风险", "위험 구간", "منطقة الخطر"]
    )

    static let pathology = Concept(
        id: "pathology",
        latin: [
            "pathology", "pathologies",
            "pathologie",                              // fr, de, nl
            "patolog[ií]a", "patologia",               // es, pt-BR, it
            "patologi",                                // da, nb, sv
            "patologia",                               // fi (loan)
            "meinafr[æa][ðd]i",                        // is
            "патология"                                // ru
        ],
        unbounded: ["病理", "병리", "علم الأمراض"]
    )

    /// Every concept covers every shipped locale, and this one needs its
    /// `unbounded` entries: Japanese, Korean, Chinese and Arabic cannot match
    /// through the `\b`-wrapped Latin group.
    /// `MedicalTermLexiconTests.testEveryConceptCoversTheNonLatinScripts`
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
            "autonominen\\s+j[äa]ykkyys", "hengityskompensaatio",      // fi
            "[óo]sj[áa]lfr[áa][ðd]\\s+st[íi]fni", "[öo]ndunarj[öo]fnun", // is
            "вегетативная\\s+ригидность", "дыхательная\\s+компенсация"  // ru
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
// These live in an extension rather than the enum body to keep the enum
// under SwiftLint's 500-line `type_body_length`, and the input-side concepts
// are the natural second section: everything above is what the model must not
// SAY, everything here is what the user must not be left to ASK unanswered.
extension MedicalTermLexicon {
    static let chestPain = Concept(
        id: "chest-pain",
        latin: [
            "chest\\s+pain", "chest\\s+tightness",
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
        ],
        unbounded: ["胸痛", "胸口疼", "흉통", "가슴 통증", "ألم في الصدر"]
    )

    static let breathlessness = Concept(
        id: "breathlessness",
        latin: [
            "shortness\\s+of\\s+breath", "can'?t\\s+breathe",
            "(?:difficulty|trouble)\\s+breathing", "struggling\\s+to\\s+breathe",
            "essoufflement", "difficult[ée]\\s+[àa]\\s+respirer",  // fr
            "dificultad\\s+para\\s+respirar", "falta\\s+de\\s+aire", // es
            "falta\\s+de\\s+ar", "dificuldade\\s+para\\s+respirar",  // pt-BR
            "affanno", "difficolt[àa]\\s+a\\s+respirare",            // it
            "atemnot", "kurzatmigkeit",                              // de
            "kortademigheid", "benauwd(?:heid)?",                    // nl
            "[åa]nden[øo]d", "tungpustet", "andpustenhet",           // da, nb
            "andn[öo]d",                                             // sv
            "hengenahdistus",                                        // fi
            "andn[æa][ðd](?:i)?", "m[æa][ðd]i",                      // is
            "одышка"                                                 // ru
        ],
        unbounded: ["息切れ", "呼吸困難", "呼吸困难", "气短", "호흡곤란", "숨가쁨", "ضيق التنفس"]
    )

    static let syncope = Concept(
        id: "syncope",
        latin: [
            // Not `"fainting"` only: "I fainted" and "I feel faint" are the
            // two ways anyone actually reports this, and must not go straight
            // to a cloud provider.
            "faint(?:s|ed|ing)?", "syncope", "passed?\\s+out", "blacked?\\s+out",
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
        ],
        unbounded: ["失神", "昏厥", "晕倒", "실신", "إغماء"]
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
            "sv[åa]r\\s+sm[äa]rta", "panik[åa]ngest",         // sv
            "kova\\s+kipu", "paniikkikohtaus",                // fi
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
            "dangereu(?:x|se)", "mettre\\s+ma\\s+vie\\s+en\\s+danger", "dois[- ]je\\s+m'inqui[ée]ter", // fr
            "peligros[oa]", "deber[íi]a\\s+preocuparme",              // es
            "perigos[oa]", "devo\\s+me\\s+preocupar",               // pt-BR
            "pericolos[oa]", "devo\\s+preoccuparmi",                  // it
            "gef[äa]hrlich", "lebensbedrohlich", "sollte\\s+ich\\s+mir\\s+sorgen", // de
            "gevaarlijk", "levensbedreigend", "moet\\s+ik\\s+me\\s+zorgen",        // nl
            "farlig(?:t)?", "livstruende", "skal\\s+jeg\\s+v[æa]re\\s+bekymret",   // da, nb
            "farligt", "livshotande", "ska\\s+jag\\s+vara\\s+orolig",              // sv
            "vaarallinen", "hengenvaarallinen", "pit[äa]isik[öo]\\s+minun\\s+huolestua", // fi
            "h[æa]ttulegt", "l[íi]fsh[æa]ttulegt",                     // is
            "опасно", "опасн[ыа][йе]", "угрожает\\s+жизни", "стоит\\s+ли\\s+беспокоиться" // ru
        ],
        unbounded: ["危険ですか", "命に関わ", "心配すべき", "危险吗", "有生命危险", "该担心", "위험한가요", "위험합니까", "걱정해야", "خطير", "هل يجب أن أقلق"]
    )

    static let selfHarm = Concept(
        id: "self-harm",
        latin: [
            // "Suicide sprints" (and runs, drills, shuttles, lines) are a
            // common conditioning drill, so that shape is excluded; the plural
            // "suicides" never matches inside `\b…\b`. The lookahead lives on
            // the one pattern that matches English, French and Dutch alike.
            "suicidal", "su[ïi]cide(?!\\s+(?:sprints?|runs?|drills?|shuttles?|lines?)\\b)",
            "kill\\s+myself", "end\\s+my\\s+life", "want\\s+to\\s+die",
            "self[-\\s]?harm(?:ing)?",
            // Not "hurt myself" or "cut myself": in a training app those are
            // mostly injuries and kitchen accidents, not a crisis.
            "(?:harm|harming|cutting)\\s+myself",
            // iOS types a curly apostrophe by default.
            "(?:don['’]?t|do\\s+not)\\s+want\\s+to\\s+(?:live|be\\s+alive|be\\s+here\\s+anymore)",
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
            "покончить\\s+с\\s+собой"                  // ru
        ],
        unbounded: ["自殺", "自杀", "자살", "انتحار"]
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
            "kontakt\\s+(?:en\\s+)?l[æa]ge", "s[øo]g\\s+l[æa]ge",     // da
            "kontakt\\s+lege", "oppsøk\\s+lege",                      // nb
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
            "sympt[ôo]mes?\\s+d'une\\s+maladie",       // fr
            "s[íi]ntomas?\\s+de\\s+una\\s+enfermedad", // es
            "sintomas?\\s+de\\s+uma\\s+doen[çc]a",     // pt-BR
            "sintomi\\s+di\\s+una\\s+malattia",        // it
            "symptome\\s+einer\\s+(?:krankheit|erkrankung)", // de
            "symptomen\\s+van\\s+een\\s+(?:ziekte|aandoening)", // nl
            "symptom(?:er)?\\s+p[åa]\\s+(?:sygdom|sykdom)",     // da, nb
            "symtom\\s+p[åa]\\s+sjukdom",              // sv
            "sairauden\\s+oire(?:et|ita)?",            // fi
            "симптом[ыа]?\\s+(?:болезни|заболевания)"  // ru
        ],
        unbounded: ["病気の症状", "疾病症状", "질병의 증상", "أعراض مرض"]
    )

    static let speculativeDiagnosis = Concept(
        id: "speculative-diagnosis",
        latin: [
            "you\\s+(?:may|might|could|likely)\\s+(?:have|be\\s+developing)\\s+\\w+",
            "vous\\s+(?:avez\\s+peut-[êe]tre|pourriez\\s+avoir)",   // fr
            "puede(?:s)?\\s+(?:que\\s+)?tener(?:\\s+\\w+)?", "podr[íi]as?\\s+tener", // es
            "voc[êe]\\s+pode\\s+(?:ter|estar\\s+com)",              // pt-BR
            "potresti\\s+avere", "potrebbe\\s+avere",               // it
            "sie\\s+(?:k[öo]nnten|haben\\s+m[öo]glicherweise)", "du\\s+k[öo]nntest",  // de
            "je\\s+(?:hebt\\s+mogelijk|zou\\s+kunnen\\s+hebben)",   // nl
            "du\\s+(?:har\\s+m[åa]ske|kan\\s+have)",                // da
            "du\\s+(?:kan\\s+ha|har\\s+kanskje)",                   // nb
            "du\\s+(?:kan\\s+ha|har\\s+kanske)",                    // sv
            "sinulla\\s+(?:saattaa|voi)\\s+olla",                   // fi
            "у\\s+вас\\s+(?:возможно|может\\s+быть)"                // ru
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
            "(?:病気|疾患|症状|不整脈|細動)の可能性があります",
            "可能患有",
            "(?:질환|질병|병|증상)일\\s*수\\s*있습니다",
            "قد تكون مصابا"
        ]
    )
}

// MARK: - Groupings

/// The groupings and the compiler live in an extension rather than in the
/// enum body to keep the enum under SwiftLint's 500-line `type_body_length`;
/// the honest split is along the seam that already exists: above is the
/// vocabulary, below is how the two guards consume it.
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
    /// `MedicalQueryGuardTests.testCompiledPatternsMatchTheDeclaredGroups`
    /// fails if that stops being true.
    static let refuseBeforeSending: [Concept] = refuseAsRhythm + refuseAsSymptom

    /// Concepts the OUTPUT guard rewrites when a model emits them.
    ///
    /// Deliberately not the same list as `refuseBeforeSending`. The two guards
    /// answer different questions, and seven concepts belong to one side only:
    ///
    ///   * `chestPain`, `breathlessness`, `syncope`, `severeSymptom`,
    ///     `selfHarm` — input-only. Someone reporting chest pain must be
    ///     routed to help, but the model is allowed to say the word while
    ///     explaining why this app cannot help with it. Scrubbing those would
    ///     rewrite the safety copy itself.
    ///   * `dangerJudgement` — input-only for the same reason, plus one of its
    ///     own. "Is this dangerous?" is a risk assessment the app does not
    ///     perform, so refusing the question is right. But its patterns are
    ///     bare adjectives (`dangerous`, `gefährlich`, `farligt`) with no
    ///     assertion shape, and the app's own educational copy uses one in a
    ///     negating construction — HelpContent+ScienceArticles.swift explains
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
    /// app ships 59,650 translated string units. Without this group a
    /// prohibited claim injected into a German translation passes the linter
    /// clean; only its English original would be caught. Nothing else in CI
    /// can see that, because `check_perimeter_sync.sh` proves build-time
    /// terms are covered by the runtime lexicon and not the reverse.
    ///
    /// The obvious fix — run the whole runtime lexicon over the catalogue —
    /// does not work, and the reason is worth writing down. The two lists have
    /// different jobs. The runtime lexicon governs what the MODEL may say;
    /// the build-time list governs what the APP may say, and the app says some
    /// of these things on purpose. "Consult a doctor if consistently low" is
    /// the safety redirect, shipped in 17 locales, and `medicalReferral` is in
    /// the lexicon precisely so the model cannot improvise its own version.
    /// Pointing one at the other produced 45 matches, all of them the app's own
    /// copy or its Diagnostics feature name.
    ///
    /// This is the subset with no such overlap: naming a cardiac or
    /// neurovascular condition, claiming a cure, a prescription, a treatment,
    /// a regulatory clearance, or a speculative diagnosis is never something
    /// this app's copy does, in any language. Measured against every locale in
    /// the catalogue at the time of writing: zero matches. So it can be a hard
    /// gate rather than a budget.
    static let neverInStaticCopy: [Concept] = [
        atrialFibrillation, arrhythmia, namedCardiacCondition, acuteCardiacEvent,
        neurovascularEvent, regulatoryClearance, cure, prescription,
        treatmentClaim, speculativeDiagnosis, pathology, clinicalPhysiologyLabels
    ]

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
            "you\\s+(?:are|'re)\\s+(?:definitely|clearly|certainly)",
            "il\\s+se\\s+passe\\s+quelque\\s+chose\\s+d'important",
            "vous\\s+[êe]tes\\s+(?:clairement|certainement|assur[ée]ment)",                  // fr
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
            "olet\\s+(?:selv[äa]sti|ehdottomasti|varmasti)",                                 // fi
            "eitthva[ðd]\\s+markt[æa]kt\\s+er\\s+a[ðd]\\s+gerast",
            "þ[úu]\\s+ert\\s+(?:greinilega|[óo]tv[íi]r[æa]tt)",                              // is
            "происходит\\s+что-то\\s+(?:серьёзное|серьезное|значимое)",
            "вы\\s+(?:явно|определённо|определенно|несомненно)"                              // ru
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
        unsupportedMetricVerdict
    ]

    /// Compile one concept, once. A nil result means the pattern is malformed,
    /// which `MedicalTermLexiconTests.testEveryConceptCompiles` fails on.
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
