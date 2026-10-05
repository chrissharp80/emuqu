//
//  CoachVoiceGuardTests.swift
//  EmuquTests
//
//  CoachVoiceGuard is the runtime half of the FDA
//  perimeter — the control that stands between a third-party language model and
//  a regulated medical claim reaching the user. It had no test file at all, and
//  its class doc described a wiring that did not exist (`AIProvider` calling it,
//  partial-stream interception in a `ChatViewModel` that is not a type in this
//  codebase). This file asserts the behaviour and the wiring, so the next
//  person to read the doc comment is reading something a test agrees with.
//

@testable import Emuqu
import XCTest

final class CoachVoiceGuardTests: XCTestCase {
    // MARK: - Coverage of the concept set

    /// Every concept the guard claims to scrub must actually have a rule and a
    /// compiled regex behind it. A lexicon entry with no deflection would
    /// otherwise pass through silently.
    func testEveryScrubbedConceptHasARule() {
        let ruleIDs = Set(CoachVoiceGuard.rules.map(\.id))
        for concept in MedicalTermLexicon.scrubFromOutput {
            XCTAssertTrue(ruleIDs.contains(concept.id), "No scrub rule for concept: \(concept.id)")
        }
        XCTAssertEqual(ruleIDs.count, MedicalTermLexicon.scrubFromOutput.count)
    }

    // MARK: - Volume

    /// Every prohibited sentence is rewritten, however many there are.
    ///
    /// A per-rule rewrite cap in `applyRule` (32, then log and give up) leaves
    /// the remainder delivered verbatim: on this input that is 64 triggers and
    /// 136 sentences of "you may have atrial fibrillation". The only reason for
    /// a cap is a self-matching deflection spinning the main actor;
    /// `testNoDeflectionTripsAnyRule` proves that cannot happen, and `scrub`
    /// does not re-scan, so there is nothing to bound. This test is the reason
    /// the cap must not come back.
    func testEveryProhibitedSentenceIsRewrittenAtVolume() {
        let sentenceCount = 200
        let input = Array(repeating: "You may have atrial fibrillation.",
                          count: sentenceCount).joined(separator: " ")

        let result = CoachVoiceGuard.scrub(input)

        XCTAssertEqual(result.triggers.count, sentenceCount,
                       "One trigger per prohibited sentence, with no quota.")
        XCTAssertFalse(
            CoachVoiceGuard.containsProhibitedLanguage(result.scrubbed),
            "Scrubbed output still contains prohibited language — some sentences leaked."
        )
    }

    /// Mixed clean and prohibited sentences: the clean ones survive untouched
    /// and in place. Proves the sentence map is not simply blanking the reply.
    func testCleanSentencesAreLeftByteIdenticalAtVolume() {
        var parts: [String] = []
        for index in 0 ..< 100 {
            parts.append("Your RMSSD trend for week \(index) is steady.")
            parts.append("You may have atrial fibrillation.")
        }
        let result = CoachVoiceGuard.scrub(parts.joined(separator: " "))

        XCTAssertEqual(result.triggers.count, 100)
        for index in 0 ..< 100 {
            XCTAssertTrue(
                result.scrubbed.contains("Your RMSSD trend for week \(index) is steady."),
                "Clean sentence \(index) was altered or dropped."
            )
        }
    }

    /// A phrase split across a sentence terminator is detected by the
    /// whole-text pre-check but matches no individual sentence. The guard must
    /// fail closed rather than hand back a phrase it just proved it detects.
    func testPhraseStraddlingATerminatorFailsClosed() {
        let input = "Given this pattern you should see a\ndoctor about it."

        XCTAssertTrue(CoachVoiceGuard.containsProhibitedLanguage(input),
                      "Precondition: the whole-text check must see this phrase.")

        let result = CoachVoiceGuard.scrub(input)

        XCTAssertTrue(result.didIntercept)
        XCTAssertFalse(result.scrubbed.contains("doctor"),
                       "Straddling phrase was delivered: \(result.scrubbed)")
    }

    /// And the fallback is surgical, not a blanket wipe: only the sentences the
    /// match actually spans are replaced. A straddling phrase in the middle of a
    /// long reply should not cost the user the rest of the answer.
    func testStraddlingFallbackKeepsTheSentencesAroundIt() {
        let input = "Your RMSSD is steady this week. "
            + "Given the pattern you should see a\ndoctor about it. "
            + "Sleep duration was 7h20m."

        let result = CoachVoiceGuard.scrub(input)

        XCTAssertTrue(result.didIntercept)
        XCTAssertFalse(CoachVoiceGuard.containsProhibitedLanguage(result.scrubbed))
        XCTAssertTrue(result.scrubbed.contains("Your RMSSD is steady this week."),
                      "Leading clean sentence was discarded: \(result.scrubbed)")
        XCTAssertTrue(result.scrubbed.contains("Sleep duration was 7h20m."),
                      "Trailing clean sentence was discarded: \(result.scrubbed)")
    }

    /// Stray punctuation between sentences must not cost the user the clean
    /// sentences around a scrubbed one.
    ///
    /// `endOfSegment` scans terminators and whitespace in two separate loops so
    /// that `". ."` reads as two boundaries. Mutating that fold
    /// showed it moves only where stray punctuation lands — no word is ever
    /// gained or lost — so the mutation was withdrawn as equivalent. What this
    /// test does pin is the property that survives that analysis: whatever the
    /// punctuation between them, the sentences either side of the excision are
    /// still delivered.
    func testATerminatorAfterWhitespaceDoesNotExtendThePreviousSentence() {
        let input = "Your RMSSD is steady this week. "
            + "Given the pattern you should see a doctor about it. "
            + ". Sleep duration was 7h20m."

        let result = CoachVoiceGuard.scrub(input)

        XCTAssertTrue(result.didIntercept)
        XCTAssertFalse(CoachVoiceGuard.containsProhibitedLanguage(result.scrubbed))
        XCTAssertTrue(
            result.scrubbed.contains("Sleep duration was 7h20m."),
            "the stray period opened a new sentence; the clean one after it must survive: \(result.scrubbed)"
        )
        XCTAssertTrue(
            result.scrubbed.contains("Your RMSSD is steady this week."),
            "the leading clean sentence must survive too: \(result.scrubbed)"
        )
    }

    /// `scrub` must never return text its own pre-check would reject. Both go
    /// through `firstMatchingEntry`; this asserts the property rather than the
    /// implementation.
    func testScrubbedOutputNeverTripsThePreCheck() {
        let inputs = [
            "You may have atrial fibrillation.",
            "This is a symptom of disease. Rest well.",
            "See a doctor! Your HRV is fine? You may have COVID.",
            "あなたは心房細動の可能性があります。",
            "Deberías consultar a un médico.",
            "You are in the danger zone and at high risk of injury."
        ]
        for input in inputs {
            let result = CoachVoiceGuard.scrub(input)
            XCTAssertFalse(
                CoachVoiceGuard.containsProhibitedLanguage(result.scrubbed),
                "scrub left prohibited language in: \(result.scrubbed)"
            )
        }
    }

    /// The deflection table and the scrub list must agree in BOTH directions.
    ///
    /// The forward direction was covered above and passed,
    /// while `deflections` carried an entry for `danger-judgement`, a concept
    /// that is deliberately input-only (see `MedicalTermLexicon.scrubFromOutput`).
    /// `rules` is built by mapping `scrubFromOutput`, so that entry was never
    /// read. It looked like output coverage of "is this dangerous?" and was
    /// nothing of the kind — the exact shape of defect this suite exists to
    /// catch, sitting inside the file the suite tests.
    func testDeflectionsCoverExactlyTheScrubbedConcepts() {
        let scrubbed = Set(MedicalTermLexicon.scrubFromOutput.map(\.id))
        for key in CoachVoiceGuard.deflections.keys {
            XCTAssertTrue(
                scrubbed.contains(key),
                """
                Deflection for '\(key)' is dead configuration: no concept with that id \
                is in MedicalTermLexicon.scrubFromOutput, so CoachVoiceGuard.rules never \
                consults it. Either add the concept to scrubFromOutput or delete the \
                deflection.
                """
            )
        }
    }

    /// Every concept must reach the four non-Latin scripts the app ships.
    ///
    /// `Concept.latin` alternatives are wrapped in `\b`, which never matches
    /// inside Japanese, Korean, Chinese or Arabic running text, so a concept
    /// with an empty `unbounded` group is absent from four locales however long
    /// its Latin list is. `clinicalPhysiologyLabels` had none at all and
    /// `regulatoryClearance` had no Arabic, in a file whose header says every
    /// concept covers every shipped locale. Prose cannot hold that claim up;
    /// this can.
    func testEveryConceptCoversTheNonLatinScripts() {
        func scripts(in text: String) -> Set<String> {
            var found: Set<String> = []
            for scalar in text.unicodeScalars {
                switch scalar.value {
                case 0xAC00 ... 0xD7AF, 0x1100 ... 0x11FF: found.insert("Hangul")
                case 0x0600 ... 0x06FF: found.insert("Arabic")
                case 0x3040 ... 0x30FF, 0x4E00 ... 0x9FFF: found.insert("CJK")
                default: break
                }
            }
            return found
        }

        for concept in MedicalTermLexicon.all {
            let covered = concept.unbounded.reduce(into: Set<String>()) {
                $0.formUnion(scripts(in: $1))
            }
            for script in ["Hangul", "Arabic", "CJK"] {
                XCTAssertTrue(
                    covered.contains(script),
                    """
                    Concept '\(concept.id)' has no \(script) alternative. Latin \
                    alternatives are \\b-wrapped and cannot match in that script, so \
                    this concept does not exist for those users.
                    """
                )
            }
        }
    }

    /// `stroke` is a swimming metric in this app before it is a diagnosis —
    /// `stroke rate`, `total strokes`. `neurovascularEvent` matches only
    /// disambiguated forms, and this is why.
    func testSwimStrokeVocabularyIsNotScrubbed() {
        let clean = [
            "Your stroke rate averaged 34 per minute across the session.",
            "Total strokes for the swim: 1,240.",
            "A longer stroke at the same rate means more distance per pull."
        ]
        for text in clean {
            let result = CoachVoiceGuard.scrub(text)
            XCTAssertFalse(result.didIntercept, "Swim vocabulary was scrubbed: \(text)")
            XCTAssertEqual(result.scrubbed, text)
        }
    }

    // MARK: - Precedence and anchoring

    /// `scrub` documents "first matching rule wins". Reversing it to
    /// `compiled.last` left every test passing, so the documented behaviour
    /// was not behaviour — it was a comment.
    func testFirstMatchingRuleWinsForASentenceThatTripsTwo() {
        // "you may have" is speculative-diagnosis; "atrial fibrillation" is its
        // own concept. Both match; the earlier entry in scrubFromOutput wins.
        let order = MedicalTermLexicon.scrubFromOutput.map(\.id)
        let afib = try? XCTUnwrap(order.firstIndex(of: MedicalTermLexicon.atrialFibrillation.id))
        let speculative = try? XCTUnwrap(order.firstIndex(of: MedicalTermLexicon.speculativeDiagnosis.id))
        guard let afib, let speculative else { return XCTFail("concept missing from scrubFromOutput") }
        XCTAssertLessThan(afib, speculative, "Precondition: atrial-fibrillation is the earlier rule.")

        let result = CoachVoiceGuard.scrub("You may have atrial fibrillation.")

        XCTAssertEqual(result.triggers.count, 1)
        XCTAssertTrue(
            result.triggers[0].reason.contains(MedicalTermLexicon.atrialFibrillation.id),
            """
            The earlier rule must win. Got '\(result.triggers[0].reason)'. Rule order \
            decides which deflection the user reads, so it is behaviour, not detail.
            """
        )
    }

    /// Latin alternatives are wrapped in `\b`. Without the anchoring `cure`
    /// matches inside "obscure", "secure", "accurate", "procedure" and
    /// "curated", so the guard rewrites ordinary sentences — and nothing else in
    /// the suite notices (mutation M12).
    func testWordBoundariesKeepOrdinaryVocabularyOutOfTheGuard() {
        let ordinary = [
            "Your accuracy was obscure but the trend is secure.",
            "The procedure is accurate.",
            "A curated plan for this week.",
            "That was a stroke of luck.",
            "Analysis complete."
        ]
        for text in ordinary {
            let result = CoachVoiceGuard.scrub(text)
            XCTAssertFalse(result.didIntercept, "Ordinary sentence was deflected: \(text)")
            XCTAssertEqual(result.scrubbed, text)
        }
    }

    /// Respiratory sinus arrhythmia is normal physiology and the app explains it
    /// in its own methodology copy, in every locale. The `(?<!sinus\s)` guard
    /// must be on every locale's alternative, not only the English one.
    func testSinusArrhythmiaIsNotDeflectedInAnyLocale() {
        let benign = [
            "en": "Respiratory sinus arrhythmia is a normal finding.",
            "es": "La arritmia sinusal respiratoria es un hallazgo normal.",
            "fr": "L'arythmie sinusale respiratoire est un phénomène normal.",
            "it": "L'aritmia sinusale respiratoria è un reperto normale.",
            "pt-BR": "A arritmia sinusal respiratória é um achado normal.",
            "de": "Die respiratorische Sinusarrhythmie ist ein normaler Befund.",
            "nl": "Respiratoire sinusaritmie is normaal.",
            "da": "Respiratorisk sinusarytmi er normalt.",
            "fi": "Hengitysperäinen sinusrytmihäiriö on normaalia.",
            "ja": "呼吸性洞性不整脈は正常な所見です。",
            "ko": "호흡성 동성 부정맥은 정상 소견입니다.",
            "zh-Hans": "呼吸性窦性心律失常是正常现象。",
            "ru": "Дыхательная синусовая аритмия — нормальное явление.",
            "ar": "عدم انتظام ضربات القلب التنفسي أمر طبيعي."
        ]
        for (locale, sentence) in benign {
            XCTAssertFalse(
                CoachVoiceGuard.scrub(sentence).didIntercept,
                "[\(locale)] normal physiology was deflected: \(sentence)"
            )
        }
    }

    /// And the exclusion must not have disarmed the rule itself.
    func testARealRhythmClaimIsStillDeflectedInEveryLocale() {
        let claims = [
            "en": "You have an arrhythmia.",
            "es": "Tienes una arritmia.",
            "fr": "Vous avez une arythmie.",
            "it": "Hai un'aritmia.",
            "de": "Sie haben eine Arrhythmie.",
            "nl": "U heeft een aritmie.",
            "da": "Du har arytmi.",
            "fi": "Sinulla on rytmihäiriö.",
            "ja": "不整脈があります。",
            "ko": "부정맥이 있습니다.",
            "zh-Hans": "您有心律失常。",
            "ru": "У вас аритмия.",
            "ar": "لديك عدم انتظام ضربات القلب."
        ]
        for (locale, sentence) in claims {
            XCTAssertTrue(
                CoachVoiceGuard.scrub(sentence).didIntercept,
                "[\(locale)] a rhythm claim was delivered: \(sentence)"
            )
        }
    }

    /// Phrasings the perimeter must catch.
    func testPreviouslyEvasivePhrasingsAreCaught() {
        let evasions = [
            "You may have *atrial* fibrillation.",
            "You may have **atrial fibrillation**.",
            "See a Dr about this.",
            "You are in the danger-zone.",
            "Your risk of injury is elevated.",
            "You overtrain.",
            "Emuqu is approved by the FDA."
        ]
        for text in evasions {
            XCTAssertTrue(
                CoachVoiceGuard.scrub(text).didIntercept,
                "Still evades the output perimeter: \(text)"
            )
        }
    }

    /// Terms that are regulated in English and everyday in another language.
    ///
    /// Two were shipping. The sinus-arrhythmia exclusion
    /// existed only in English (see above), and `cure`'s Finnish alternative
    /// was a bare `parantaa`, which is the ordinary verb "to improve": four
    /// shipped Finnish strings matched it, and any reply saying a session
    /// improves endurance would have been deflected. Both were found by
    /// running the multilingual lexicon over the string catalogue, which is a
    /// check nothing in CI performs.
    func testEverydayVocabularyIsNotDeflectedInAnyLocale() {
        let everyday = [
            "fi (improve)": "Miten voin parantaa untani tänä yönä?",
            "fi (improve 2)": "Esteetön näkymä taivaalle ulkona parantaa tarkkuutta.",
            "fi (improve 3)": "Kakkosalueen peruskestävyys parantaa mitokondrioiden tiheyttä.",
            "is (analysis)": "Greiningu lokið.",
            "en (diagnostics)": "Export the diagnostic log and share it with support.",
            "ko (ordinary 'may be')": "휴식이 더 필요하다는 신호일 수 있습니다.",
            "ja (ordinary 'possibility')": "設定で HRmax の更新をご検討ください。改善の可能性があります。",
            "es (diagnostics)": "Diagnósticos del archivo",
            "is (analysis 2)": "Greining tilbúin."
        ]
        for (label, sentence) in everyday {
            XCTAssertFalse(
                CoachVoiceGuard.scrub(sentence).didIntercept,
                "[\(label)] everyday vocabulary was deflected: \(sentence)"
            )
        }
    }

    /// …and the regulated sense in the same language still is.
    func testTheRegulatedSenseStillFiresInFinnish() {
        XCTAssertTrue(CoachVoiceGuard.scrub("Tämä parantaa sairauden.").didIntercept)
        XCTAssertTrue(CoachVoiceGuard.scrub("Tämä on parannuskeino.").didIntercept)
    }

    /// The CJK speculative-diagnosis forms must still fire when they name an
    /// illness, which is the shape the English alternative has always required.
    func testSpeculativeDiagnosisStillFiresInCJKWhenItNamesAnIllness() {
        XCTAssertTrue(CoachVoiceGuard.scrub("不整脈の可能性があります。").didIntercept)
        XCTAssertTrue(CoachVoiceGuard.scrub("질환일 수 있습니다.").didIntercept)
        XCTAssertTrue(CoachVoiceGuard.scrub("您可能患有心脏病。").didIntercept)
    }

    /// Every concept in the lexicon must compile. A malformed alternation would
    /// make `MedicalTermLexicon.regex(for:)` return nil and remove that concept
    /// from both guards without any signal.
    func testEveryConceptCompiles() {
        for concept in MedicalTermLexicon.all {
            XCTAssertNotNil(
                MedicalTermLexicon.regex(for: concept),
                "Concept \(concept.id) has a malformed pattern: \(concept.pattern)"
            )
        }
    }

    /// No deflection may itself trip a rule. If one did, `applyRule` would
    /// rewrite its own output until it hit the iteration cap — on the main
    /// actor, at streaming rate.
    func testNoDeflectionRematchesItsOwnRule() {
        for rule in CoachVoiceGuard.rules {
            guard let regex = MedicalTermLexicon.regex(for: rule.concept) else { continue }
            let range = NSRange(rule.deflection.startIndex..., in: rule.deflection)
            XCTAssertNil(
                regex.firstMatch(in: rule.deflection, range: range),
                "Deflection for \(rule.id) matches its own rule and would loop: \(rule.deflection)"
            )
        }
    }

    /// And no deflection may trip ANY other rule either — rules run in
    /// sequence, so rule B rewriting rule A's replacement is the same failure
    /// one step removed.
    func testNoDeflectionTripsAnyRule() {
        for rule in CoachVoiceGuard.rules {
            XCTAssertFalse(
                CoachVoiceGuard.containsProhibitedLanguage(rule.deflection),
                "Deflection for \(rule.id) trips some rule: \(rule.deflection)"
            )
        }
    }

    // MARK: - English behaviour

    func testSpeculativeDiagnosisIsRewritten() {
        let result = CoachVoiceGuard.scrub("Your HRV is low. You may have an infection. Rest up.")
        XCTAssertTrue(result.didIntercept)
        XCTAssertFalse(result.scrubbed.contains("may have an infection"))
        XCTAssertTrue(result.scrubbed.contains("Your HRV is low."))
        XCTAssertTrue(result.scrubbed.contains("Rest up."))
    }

    func testMedicalReferralIsDeflected() {
        let result = CoachVoiceGuard.scrub("That reading is unusual. You should see a doctor.")
        XCTAssertTrue(result.didIntercept)
        XCTAssertFalse(result.scrubbed.lowercased().contains("see a doctor"))
        XCTAssertTrue(result.scrubbed.contains("healthcare professional"))
    }

    /// Terms the build-time linter forbids; the runtime guard must know every
    /// one of them too.
    func testTermsThatUsedToEvadeTheRuntimeGuard() {
        let cases = [
            "This pattern looks like atrial fibrillation.",
            "That is an arrhythmia.",
            "My diagnosis is that you are run down.",
            "This suggests an underlying pathology.",
            "Emuqu is FDA-cleared for this.",
            "This is a medical-grade measurement.",
            "Here is a prescription for your recovery.",
            "This will cure your fatigue.",
            "You are in the high risk band.",
            "Your injury risk is elevated."
        ]
        for text in cases {
            XCTAssertTrue(
                CoachVoiceGuard.scrub(text).didIntercept,
                "Should have been intercepted: \(text)"
            )
        }
    }

    func testCleanCoachingTextIsUntouched() {
        let clean = [
            "Your HRV is 12% above your baseline this week. Good day to push.",
            "Sleep was short at 5h40m. Consider an easier session.",
            "Recent load is above your usual range — a lighter session helps you absorb the work.",
            "Your RMSSD averaged 48 ms across the window."
        ]
        for text in clean {
            let result = CoachVoiceGuard.scrub(text)
            XCTAssertFalse(result.didIntercept, "False positive on: \(text)")
            XCTAssertEqual(result.scrubbed, text)
        }
    }

    // MARK: - Multilingual behaviour

    /// The output side, in every shipped locale. A model answering a German
    /// user answers in German, so an English-only guard would miss it.
    func testProhibitedOutputIsInterceptedInEveryShippedLocale() {
        let byLocale: [(locale: String, text: String)] = [
            ("ar", "قد يكون لديك الرجفان الأذيني. استشر الطبيب."),
            ("da", "Du har måske atrieflimren. Kontakt en læge."),
            ("de", "Sie könnten Vorhofflimmern haben. Bitte einen Arzt aufsuchen."),
            ("es", "Puede que tengas fibrilación auricular. Consulta a un médico."),
            ("fi", "Sinulla saattaa olla eteisvärinä. Ota yhteyttä lääkäriin."),
            ("fr", "Vous avez peut-être une fibrillation auriculaire. Consultez un médecin."),
            ("is", "Þú gætir verið með gáttatif. Leitaðu til læknis."),
            ("it", "Potresti avere una fibrillazione atriale. Consultare un medico."),
            ("ja", "心房細動の可能性があります。医師に相談してください。"),
            ("ko", "심방세동일 수 있습니다. 의사와 상담하세요."),
            ("nb", "Du kan ha atrieflimmer. Kontakt lege."),
            ("nl", "Je hebt mogelijk boezemfibrilleren. Raadpleeg een arts."),
            ("pt-BR", "Você pode ter fibrilação atrial. Consulte um médico."),
            ("ru", "У вас возможно фибрилляция предсердий. Обратитесь к врачу."),
            ("sv", "Du kan ha förmaksflimmer. Kontakta läkare."),
            ("zh-Hans", "你可能患有心房颤动。请咨询医生。")
        ]
        for entry in byLocale {
            XCTAssertTrue(
                CoachVoiceGuard.scrub(entry.text).didIntercept,
                "\(entry.locale): prohibited output was not intercepted — \(entry.text)"
            )
        }
    }

    /// A CJK reply has no ASCII sentence terminators. Before the CJK terminators
    /// were added to `sentenceTerminators`, one match expanded to the WHOLE
    /// message and blanked the entire answer.
    func testCJKReplyLosesOnlyTheOffendingSentence() {
        let text = "睡眠は7時間30分でした。心房細動の可能性があります。今日は軽めにしましょう。"
        let result = CoachVoiceGuard.scrub(text)
        XCTAssertTrue(result.didIntercept)
        XCTAssertTrue(result.scrubbed.contains("睡眠は7時間30分でした"), "Clean leading sentence was destroyed")
        XCTAssertTrue(result.scrubbed.contains("今日は軽めにしましょう"), "Clean trailing sentence was destroyed")
    }

    /// Ordinary non-English coaching must survive untouched.
    func testCleanNonEnglishCoachingIsUntouched() {
        let clean = [
            "Deine HRV liegt 12 % über deinem Ausgangswert. Guter Tag für eine harte Einheit.",
            "Ton sommeil a duré 7 h 20. La charge récente est au-dessus de ta plage habituelle.",
            "Tu sueño fue de 7 horas. Hoy puedes entrenar con normalidad.",
            "昨夜の睡眠は7時間20分でした。今日は普通に練習できます。"
        ]
        for text in clean {
            XCTAssertFalse(CoachVoiceGuard.scrub(text).didIntercept, "False positive on: \(text)")
        }
    }

    // MARK: - Streaming split (the fix for "scrubbed after it was on screen")

    func testSplitHoldsBackAnIncompleteSentence() {
        let split = CoachVoiceGuard.splitAtLastSentenceBoundary("All good. You may have")
        XCTAssertEqual(split.complete, "All good.")
        XCTAssertEqual(split.tail, " You may have")
    }

    func testSplitPublishesNothingUntilTheFirstTerminator() {
        let split = CoachVoiceGuard.splitAtLastSentenceBoundary("You may have an infe")
        XCTAssertEqual(split.complete, "")
        XCTAssertEqual(split.tail, "You may have an infe")
    }

    func testSplitHandlesCJKTerminators() {
        let split = CoachVoiceGuard.splitAtLastSentenceBoundary("睡眠は良好でした。心房細")
        XCTAssertEqual(split.complete, "睡眠は良好でした。")
        XCTAssertEqual(split.tail, "心房細")
    }

    /// A decimal point is not a sentence end: the deflection must replace the
    /// whole sentence, not glue onto "22.".
    func testDecimalPointDoesNotSplitASentence() {
        let result = CoachVoiceGuard.scrub("With RMSSD at 22.5 you may have atrial fibrillation.")
        XCTAssertTrue(result.didIntercept)
        XCTAssertFalse(result.scrubbed.contains("22."), "the number belongs to the replaced sentence — got: \(result.scrubbed)")
        let split = CoachVoiceGuard.splitAtLastSentenceBoundary("Your RMSSD is 22.")
        XCTAssertEqual(split.complete, "", "a trailing digit-dot may still be a decimal point")
    }

    /// Replay a token stream the way `StreamTextBuffer` does — publish only
    /// complete sentences, scrub them, keep the tail — and assert the
    /// prohibited phrase is never present in what has been published so far.
    /// Appending every delta to the visible turn and rewriting the message at
    /// the end publishes the phrase mid-stream.
    func testProhibitedPhraseIsNeverPublishedDuringStreaming() {
        let deltas = ["Your HRV is low", ". You may ", "have atrial fib", "rillation", ". Rest today", "."]
        var pending = ""
        var published = ""
        for delta in deltas {
            pending += delta
            let split = CoachVoiceGuard.splitAtLastSentenceBoundary(pending)
            guard !split.complete.isEmpty else { continue }
            pending = split.tail
            published += CoachVoiceGuard.scrub(split.complete).scrubbed
            XCTAssertFalse(
                published.lowercased().contains("atrial fib"),
                "Prohibited phrase became visible mid-stream: \(published)"
            )
        }
        published += CoachVoiceGuard.scrub(pending).scrubbed
        XCTAssertFalse(published.lowercased().contains("atrial fib"))
        XCTAssertTrue(published.contains("Your HRV is low."))
        XCTAssertTrue(published.contains("Rest today."))
    }

    // MARK: - Performance envelope

    /// `scrub` runs per completed sentence at streaming rate, and it compiles
    /// twenty-plus regexes. The pre-check
    /// exists so the clean path stays cheap; this pins that it is.
    func testCleanTextPreCheckIsCheap() {
        let sentence = "Your HRV averaged 48 ms across the analysis window and sleep was 7h20m."
        // The timing has no committed baseline, so it reports but cannot
        // fail; the clean verdict is what this test asserts.
        XCTAssertFalse(CoachVoiceGuard.containsProhibitedLanguage(sentence), "a clean sentence must pass the pre-check")
        measure {
            for _ in 0 ..< 2000 {
                _ = CoachVoiceGuard.containsProhibitedLanguage(sentence)
            }
        }
    }

    // MARK: - Offensive language

    /// A sentence with a slur or explicit sexual term is replaced whole, and
    /// the sentences around it survive.
    func testOffensiveSentenceIsReplacedAndTheRestKept() {
        let input = "Nice run today. You ran like a retarded snail. Rest tomorrow."
        let result = CoachVoiceGuard.scrub(input)
        XCTAssertEqual(result.triggers.count, 1)
        XCTAssertFalse(result.scrubbed.localizedCaseInsensitiveContains("retarded"))
        XCTAssertTrue(result.scrubbed.hasPrefix("Nice run today. "))
        XCTAssertTrue(result.scrubbed.hasSuffix(" Rest tomorrow."))
        XCTAssertTrue(result.scrubbed.contains(CoachVoiceGuard.offensiveLanguageRule.deflection))
    }

    /// Spacing, case and plural variants are still caught.
    func testOffensiveVariantsAreCaught() {
        for sentence in ["What a BLOW JOB.", "Those cunts.", "Motherfucker, go faster."] {
            XCTAssertTrue(CoachVoiceGuard.containsProhibitedLanguage(sentence), sentence)
        }
    }

    /// The list stays tight: everyday words that contain or resemble an entry,
    /// and ordinary words in shipped languages, pass untouched.
    func testOffensiveFilterLeavesOrdinaryVocabularyAlone() {
        let clean = [
            "Your cumulative load is up 12%.",
            "Flame retardant fabric is heavier.",
            "Add some spices to recovery meals.",
            "Récupération en retard aujourd'hui.",
            "Handstands build shoulder stability.",
            "That was a damn good tempo run."
        ]
        for sentence in clean {
            let result = CoachVoiceGuard.scrub(sentence)
            XCTAssertEqual(result.scrubbed, sentence, sentence)
            XCTAssertFalse(result.didIntercept, sentence)
        }
    }

    /// The offensive deflection must not trip any rule, or a replaced sentence
    /// would itself be flagged.
    func testOffensiveDeflectionIsClean() {
        XCTAssertFalse(CoachVoiceGuard.containsProhibitedLanguage(CoachVoiceGuard.offensiveLanguageRule.deflection))
        XCTAssertNotNil(MedicalTermLexicon.regex(for: OffensiveTermLexicon.offensiveLanguage))
    }
}
