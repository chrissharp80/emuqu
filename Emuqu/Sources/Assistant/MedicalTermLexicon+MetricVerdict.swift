import Foundation

// One concept, in its own file.
//
// `MedicalTermLexicon.swift` sits just under the 1000-line file limit, and a
// concept carrying sixteen locales is ~60 lines. Splitting is what this repo
// does at a budget edge, and this concept is the natural seam: it is the only
// one about METRIC AUTHORITY rather than medical vocabulary.
//
// `MedicalTermLexicon.all` and `.scrubFromOutput` still list it, so
// `check_perimeter_sync.sh` and `CoachVoiceGuardTests` see it exactly as
// before — an extension does not hide a `static let` from either.

extension MedicalTermLexicon {
    /// Verdicts a metric cannot support: ranking one reading as more "real"
    /// than another, promoting a wellness threshold to a clinical one, or
    /// claiming a signal predicts an outcome.
    ///
    /// `categoricalAutonomicState` covers
    /// asserting a STATE ("clear parasympathetic dominance"). It has nothing to
    /// say about the adjacent move, which is asserting a metric's AUTHORITY —
    /// the shapes this catches:
    ///
    ///   • "Organized Recovery — the gold standard. Your ANS is consolidated
    ///     and load-bearing." The 0.75 anchor comes from graded-exercise
    ///     protocols and is not a resting readiness scale.
    ///   • "~0.5: Random noise — high RMSSD here is a mirage." Telling the
    ///     reader their own best metric is fake, on an unvalidated band.
    ///   • "SpO2 below 95% … that's a clinical safety threshold." Apple states
    ///     these readings are not intended for medical use.
    ///   • Vitals as "an early warning system for illness" and the resp-rate /
    ///     temperature pair as "a strong predictor that you're fighting
    ///     something".
    ///   • Morning cause titles that named an illness ("Possible Immune
    ///     Response") or forecast one, and directives that presume one
    ///     ("monitor for symptoms", "stay home"). English only for now,
    ///     like the two illness-forecast alternatives above them.
    ///
    /// Each appeared in two to four places, and the copies drifted — which is
    /// the argument for a pattern rather than an edit. The app is still free to
    /// describe every one of these signals; it may not rank them as truth.
    static let unsupportedMetricVerdict = Concept(
        id: "unsupported-metric-verdict",
        latin: [
            "(?:increases|increase|increasing|boosts|boost|boosting|maximizes|maximises|maximizing|maximising|raises|raise|raising)\\s+(?:your\\s+)?HF\\s+power",
            "(?:strongly\\s+suggests?|strong(?:ly)?\\s+indicat\\w*|clear(?:ly)?\\s+indicat\\w*|is\\s+a\\s+sign\\s+that)",
            "(?:likely|probably)\\s+(?:getting\\s+sick|ill|coming\\s+down\\s+with)",
            "(?:often|usually|typically)\\s+precede[sd]?\\s+(?:illness|infection|symptoms)",
            // Illness framing (App Store 1.4.1): cause titles and vitals copy
            // that named or forecast an illness the app cannot observe.
            "likely\\s+(?:\\w+\\s+)?illness",
            "possible\\s+(?:illness|immune)",
            "monitor(?:ing)?\\s+(?:yourself\\s+)?for\\s+(?:any\\s+)?(?:\\w+\\s+)?symptoms?",
            "before\\s+(?:cold|flu)",
            "early\\s+illness",
            "stay(?:ing)?\\s+home",
            "illness\\s+coming\\s+on",
            "fighting\\s+(?:something|off\\s+(?:illness|infection|a\\s+(?:cold|bug)))",
            "precede[sd]?\\s+(?:\\w+\\s+)?(?:illness|infection|symptoms)",
            "(?:strongly|clearly|markedly)\\s+dominant",
            "fully\\s+recovered",
            "load[- ]bearing",
            "clinical\\s+safety",
            "mirage",
            "(?:genuine|real|true)\\s+(?:organi[sz]ed\\s+)?recovery",
            "early[- ]warning\\s+system",
            "strong\\s+predictor",
            // Evidence superlatives: naming a metric or a strap as the
            // reference method. The app's own copy no longer makes these claims.
            "gold[\\s-]+standard", "ecg[\\s-]+grade", "most\\s+validated",
            "best\\s+single\\s+predictor",
            "[ée]talon[\\s-]+or", "qualit[ée]\\s+ecg",                                        // fr
            "est[áa]ndar\\s+de\\s+oro", "patr[óo]n\\s+oro",                                  // es
            "padr[ãa]o[\\s-]+ouro",                                                          // pt-BR
            "standard\\s+aureo",                                                            // it
            "goldstandard", "ekg[\\s-]+qualit[äa]t",                                          // de
            "gouden\\s+standaard",                                                          // nl
            "guldstandard", "gullstandard",                                                  // da, sv, nb
            "kultainen\\s+standardi",                                                       // fi
            "gullsta[ðd]al\\w*",                                                            // is
            "золот(?:ой|ым|ого)\\s+стандарт\\w*",                                            // ru
            "porteur\\s+de\\s+charge", "s[ée]curit[ée]\\s+clinique", "v[ée]ritable\\s+r[ée]cup[ée]ration",
            "syst[èe]me\\s+d'alerte\\s+pr[ée]coce", "pr[ée]dicteur\\s+puissant",                    // fr
            "seguridad\\s+cl[íi]nica", "recuperaci[óo]n\\s+real", "espejismo",
            "sistema\\s+de\\s+alerta\\s+temprana", "fuerte\\s+predictor",                           // es
            "seguran[çc]a\\s+cl[íi]nica", "recupera[çc][ãa]o\\s+real", "miragem",
            "sistema\\s+de\\s+alerta\\s+precoce", "forte\\s+preditor",                              // pt-BR
            "sicurezza\\s+clinica", "recupero\\s+reale", "miraggio",
            "sistema\\s+di\\s+allerta\\s+precoce", "forte\\s+predittore",                           // it
            "klinische\\s+sicherheit", "echte\\s+erholung", "trugbild",
            "fr[üu]hwarnsystem", "starker\\s+pr[äa]diktor",                                         // de
            "klinische\\s+veiligheid", "echt\\s+herstel", "luchtspiegeling",
            "vroegtijdig\\s+waarschuwingssysteem", "sterke\\s+voorspeller",                         // nl
            "klinisk\\s+sikkerhed", "[æa]gte\\s+restitution", "tidligt\\s+varslingssystem",         // da
            "klinisk\\s+sikkerhet", "ekte\\s+restitusjon", "tidlig\\s+varslingssystem",             // nb
            "klinisk\\s+s[äa]kerhet", "verklig\\s+[åa]terh[äa]mtning", "tidigt\\s+varningssystem",  // sv
            "kliininen\\s+turvallisuus", "todellinen\\s+palautuminen",
            "varhaisen\\s+varoituksen\\s+j[äa]rjestelm[äa]",                                        // fi
            "kl[íi]n[íi]skt\\s+[öo]ryggi", "raunveruleg\\s+endurheimt",                             // is
            "клиническ(?:ий|ая|ой)\\s+порог\\s+безопасности", "истинное\\s+восстановление",
            "система\\s+раннего\\s+предупреждения", "сильный\\s+предиктор"                          // ru
        ],
        unbounded: [
            "臨床的安全域", "真の回復", "早期警告システム", "強力な予測因子", "ゴールドスタンダード",
            "临床安全阈值", "真正的恢复", "早期预警系统", "强预测因子", "金标准",
            "임상적 안전 기준", "진정한 회복", "조기 경보 시스템", "강력한 예측 인자", "골드 스탠다드",
            "عتبة الأمان السريري", "التعافي الحقيقي", "نظام الإنذار المبكر", "المعيار الذهبي"
        ]
    )
}
