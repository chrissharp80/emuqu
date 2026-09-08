//
//  MedicalQueryGuardTests.swift
//  EmuquTests
//
//  The MedicalQueryGuard is the second leg of the
//  AFib / arrhythmia / symptom-triage block (the first leg is the system
//  prompt's MEDICAL BOUNDARY section). Without unit tests, regex changes
//  to the guard could silently un-block triggers that App Review and the
//  FDA wellness-vs-SaMD line both care about.
//
//  This corpus covers (a) the literal trigger forms, (b)
//  spelling / formatting variants that should still trip the regex,
//  (c) common evasion attempts (l33t, multilingual,
//  context-injection), and (d) negative cases that must NOT trip the
//  guard so the assistant remains useful for fitness coaching.
//

@testable import Emuqu
import XCTest

final class MedicalQueryGuardTests: XCTestCase {

    // MARK: - Arrhythmia / AFib pattern

    func testAFibLiteralFormsAreRefused() {
        let positives = [
            "do I have AFib?",
            "do I have a-fib?",
            "could this be atrial fibrillation",
            "is my heart beating irregularly",
            "I think I have an irregular heartbeat",
            "irregular heart rhythm",
            "irregular pulse last night",
            "skipped beats this morning",
            "skipped beat",
            "having palpitations",
            "palpitation after dinner",
            "is my arrhythmia getting worse"
        ]
        for input in positives {
            let outcome = MedicalQueryGuard.evaluate(input)
            switch outcome {
            case .refuse(let reply):
                XCTAssertEqual(reply, MedicalQueryGuard.arrhythmiaReply,
                               "Expected arrhythmia refusal for: \(input)")
            case .proceed:
                XCTFail("Expected refusal for arrhythmia phrasing: \(input)")
            }
        }
    }

    func testAFibCaseInsensitive() {
        for input in ["DO I HAVE AFIB", "AfIb", "Atrial Fibrillation"] {
            if case .proceed = MedicalQueryGuard.evaluate(input) {
                XCTFail("Case-insensitive arrhythmia match failed for: \(input)")
            }
        }
    }

    // MARK: - Symptom-triage pattern

    func testSymptomTriageRefused() {
        let positives = [
            "I have chest pain",
            "shortness of breath after walking",
            "I can't breathe",
            "difficulty breathing since this morning",
            "trouble breathing after the run",
            "struggling to breathe",
            "I keep fainting",
            "I had syncope yesterday",
            "I passed out at work",
            "blacked out after exercise",
            "severe pain in my chest",
            "severe fatigue all day",
            // Note: regex pattern is `severe\s+(pain|fatigue|dizz)\b`. The
            // literal `dizz` matches only at a word boundary — "severe dizz"
            // works ("severe dizz" + EOL); "severe dizziness" doesn't because
            // "dizz" inside "dizziness" has no boundary. Test the boundary
            // form so we exercise the dizz branch without false expectations.
            "severe dizz",
            "panic attack symptoms",
            "I want to kill myself",
            "feeling suicidal"
        ]
        for input in positives {
            let outcome = MedicalQueryGuard.evaluate(input)
            switch outcome {
            case .refuse(let reply):
                XCTAssertEqual(reply, MedicalQueryGuard.symptomReplyTemplate,
                               "Expected symptom-triage refusal for: \(input)")
            case .proceed:
                XCTFail("Expected refusal for symptom phrasing: \(input)")
            }
        }
    }

    // MARK: - Negative cases — these MUST proceed

    func testFitnessCoachingProceeds() {
        let negatives = [
            "what's my recovery score today",
            "how did I sleep last night",
            "should I do an interval session",
            "explain my HRV trend",
            "what does DFA alpha 1 mean",
            "show me my last workout",
            "I feel tired",                  // generic — no symptom keyword
            "I'm feeling stressed",          // generic
            "regular training schedule",     // 'regular' not 'irregular'
            "regularly checking my HRV",     // wordboundary protects 'regular'
            "what's my resting heart rate",  // 'heart rate' not 'irregular'
            "is my heart rate higher than usual today"
        ]
        for input in negatives {
            if case .refuse = MedicalQueryGuard.evaluate(input) {
                XCTFail("False positive: should not refuse fitness query: \(input)")
            }
        }
    }

    // MARK: - Edge cases

    func testEmptyInputProceeds() {
        if case .refuse = MedicalQueryGuard.evaluate("") {
            XCTFail("Empty input must proceed (not refuse)")
        }
        if case .refuse = MedicalQueryGuard.evaluate("   \n\t  ") {
            XCTFail("Whitespace-only input must proceed")
        }
    }

    func testRefusalReplyMatchesSystemPromptCopy() {
        // If this fails, the system prompt at AIProvider.swift's MEDICAL
        // BOUNDARY block has drifted from the guard's hardcoded copy.
        // Check with: rg "doesn't detect AFib" FlowRecovery/Sources/Assistant/Providers/
        XCTAssertTrue(MedicalQueryGuard.arrhythmiaReply.contains("Apple Watch"))
        XCTAssertTrue(MedicalQueryGuard.arrhythmiaReply.contains("ECG"))
        XCTAssertTrue(MedicalQueryGuard.arrhythmiaReply.contains("isn't a medical device"))
        XCTAssertTrue(MedicalQueryGuard.symptomReplyTemplate.contains("Talk to your doctor"))
        // Not `contains("911")`. The copy says "your local
        // emergency number": the app ships in sixteen non-English locales and
        // 911 is the wrong number in most of the countries they are spoken in.
        XCTAssertTrue(MedicalQueryGuard.symptomReplyTemplate.contains("emergency number"))
    }

    // MARK: - Multilingual coverage
    //
    // The app ships sixteen non-English localizations at 100%
    // catalogue coverage and the assistant answers in the user's language, so
    // an English-only guard does not exist for sixteen of seventeen shipped
    // languages. The vocabulary comes from `MedicalTermLexicon` and this
    // asserts it — with a failing branch, not an `if case .refuse { return }`
    // that passes whether the guard works, is broken, or is deleted.

    /// One rhythm phrasing per shipped locale. If a translation is wrong the
    /// test fails, which is the point — a safety guard nobody can read is not
    /// better than no guard.
    func testRhythmQuestionsAreRefusedInEveryShippedLocale() {
        let byLocale: [(locale: String, text: String)] = [
            ("ar", "هل لدي الرجفان الأذيني؟"),
            ("da", "har jeg atrieflimren?"),
            ("de", "habe ich Vorhofflimmern?"),
            ("es", "¿tengo fibrilación auricular?"),
            ("fi", "onko minulla eteisvärinä?"),
            ("fr", "est-ce que j'ai une fibrillation auriculaire ?"),
            ("is", "er ég með gáttatif?"),
            ("it", "ho una fibrillazione atriale?"),
            ("ja", "私は心房細動でしょうか？"),
            ("ko", "제가 심방세동인가요?"),
            ("nb", "har jeg atrieflimmer?"),
            ("nl", "heb ik boezemfibrilleren?"),
            ("pt-BR", "eu tenho fibrilação atrial?"),
            ("ru", "у меня фибрилляция предсердий?"),
            ("sv", "har jag förmaksflimmer?"),
            ("zh-Hans", "我有心房颤动吗？")
        ]
        for entry in byLocale {
            XCTAssertEqual(
                MedicalQueryGuard.classify(entry.text), .rhythm,
                "Rhythm question in \(entry.locale) must be refused before it reaches a provider: \(entry.text)"
            )
        }
    }

    /// Symptom triage, same treatment. Chest pain is the case where getting
    /// this wrong matters most.
    func testSymptomQuestionsAreRefusedInEveryShippedLocale() {
        let byLocale: [(locale: String, text: String)] = [
            ("ar", "أشعر بألم في الصدر"),
            ("da", "jeg har brystsmerter"),
            ("de", "ich habe Brustschmerzen"),
            ("es", "tengo dolor en el pecho"),
            ("fi", "minulla on rintakipu"),
            ("fr", "j'ai une douleur thoracique"),
            ("is", "ég er með brjóstverk"),
            ("it", "ho dolore al petto"),
            ("ja", "胸痛があります"),
            ("ko", "가슴 통증이 있어요"),
            ("nb", "jeg har brystsmerter"),
            ("nl", "ik heb pijn op de borst"),
            ("pt-BR", "estou com dor no peito"),
            ("ru", "у меня боль в груди"),
            ("sv", "jag har bröstsmärta"),
            ("zh-Hans", "我胸痛")
        ]
        for entry in byLocale {
            XCTAssertEqual(
                MedicalQueryGuard.classify(entry.text), .symptom,
                "Symptom question in \(entry.locale) must be refused: \(entry.text)"
            )
        }
    }

    /// Breathlessness and fainting round out the symptom set across a sample of
    /// scripts — Latin, Cyrillic, CJK and Arabic each exercise a different
    /// branch of the lexicon's word-boundary handling.
    func testOtherSymptomFamiliesAreRefusedAcrossScripts() {
        let cases = [
            "ich habe Atemnot", "j'ai un essoufflement", "tengo dificultad para respirar",
            "у меня одышка", "息切れがします", "호흡곤란이 있어요", "أعاني من ضيق التنفس",
            "jeg besvimte i morges", "he tenido un desmayo", "私は失神しました", "我晕倒了"
        ]
        for text in cases {
            XCTAssertEqual(MedicalQueryGuard.classify(text), .symptom, "Expected symptom refusal for: \(text)")
        }
    }

    /// Ordinary training questions in the same languages must still work — a
    /// guard that refuses everything is just as broken as one that refuses
    /// nothing, and the multilingual vocabulary is where over-matching would
    /// show up first.
    func testOrdinaryTrainingQuestionsStillProceedInEveryShippedLocale() {
        let cases = [
            "wie war mein Schlaf letzte Nacht?",
            "comment était ma récupération cette semaine ?",
            "¿cómo va mi carga de entrenamiento?",
            "qual foi meu VFC ontem?",
            "com'è andato il mio allenamento?",
            "hoe was mijn slaap?",
            "hvordan var min restitution?",
            "hvordan var treningen min?",
            "hur var min sömn?",
            "millainen unen laatuni oli?",
            "hvernig svaf ég?",
            "как прошла моя тренировка?",
            "昨夜の睡眠はどうでしたか？",
            "어젯밤 수면은 어땠나요?",
            "我昨晚的睡眠怎么样？",
            "كيف كان تدريبي اليوم؟"
        ]
        for text in cases {
            XCTAssertNil(
                MedicalQueryGuard.classify(text),
                "Ordinary training question must NOT be refused: \(text)"
            )
        }
    }

    /// `sinus arrhythmia` is normal physiology and appears in the app's own
    /// methodology copy. The lookbehind that preserves it is load-bearing.
    func testSinusArrhythmiaIsNotRefused() {
        XCTAssertNil(MedicalQueryGuard.classify("what is respiratory sinus arrhythmia?"))
    }

    /// The refusal copy is localized now. It was hardcoded English, which meant
    /// a non-English user who DID trip the guard got a safety message in a
    /// language they may not read.
    func testRefusalCopyResolvesToTheCatalogue() {
        XCTAssertFalse(MedicalQueryGuard.arrhythmiaReply.isEmpty)
        XCTAssertFalse(MedicalQueryGuard.symptomReplyTemplate.isEmpty)
        XCTAssertTrue(MedicalQueryGuard.arrhythmiaReply.contains("Apple Watch"))
        XCTAssertTrue(MedicalQueryGuard.arrhythmiaReply.contains("ECG"))
    }

    /// Known remaining evasion, asserted as a known state rather than left as a
    /// silent pass. Leetspeak is not covered and deliberately so: `4F1B` and
    /// friends have no bounded, low-false-positive spelling, and the system
    /// prompt's MEDICAL BOUNDARY block remains the second leg for it. If this
    /// ever starts being refused, this test fails and the coverage claim above
    /// gets updated — the previous version of this test passed either way.
    func testLeetSpeakRemainsUncovered() {
        XCTAssertNil(
            MedicalQueryGuard.classify("do I have 4F1B"),
            "Leetspeak is a documented, deliberate gap. If it is now covered, update the doc and this test."
        )
    }
    // MARK: - Group / guard agreement

    /// Every concept the lexicon declares refusable must actually be refused.
    ///
    /// `MedicalTermLexicon.refuseBeforeSending` existed, listed ten concepts,
    /// and had no consumer anywhere in the app: this guard hand-listed nine of
    /// them in two separate arrays. The tenth, `namedCardiacCondition`, was
    /// therefore declared refused-before-sending and was not refused at all —
    /// "am I having a heart attack?" went to a cloud provider. Three lists, one
    /// of them decorative.
    ///
    /// The probes are derived from the concepts themselves rather than
    /// hand-written, so a concept added tomorrow is covered tomorrow. Only
    /// alternatives that reduce to plain text are used; a concept whose every
    /// alternative carries regex syntax is reported rather than silently
    /// skipped.
    func testEveryDeclaredRefusalConceptIsActuallyRefused() {
        for concept in MedicalTermLexicon.refuseBeforeSending {
            var probed = 0
            for alternative in concept.latin {
                let plain = alternative.replacingOccurrences(of: "\\s+", with: " ")
                guard plain.rangeOfCharacter(from: CharacterSet(charactersIn: "\\[](){}?*+|^$.")) == nil
                else { continue }
                probed += 1
                XCTAssertNotNil(
                    MedicalQueryGuard.classify(plain),
                    "'\(plain)' is in concept '\(concept.id)', which MedicalTermLexicon " +
                    "declares refusable, but MedicalQueryGuard lets it through."
                )
            }
            for alternative in concept.unbounded where !alternative.isEmpty {
                probed += 1
                XCTAssertNotNil(
                    MedicalQueryGuard.classify(alternative),
                    "'\(alternative)' is in concept '\(concept.id)' and is not refused."
                )
            }
            XCTAssertGreaterThan(probed, 0, "No usable probe for concept '\(concept.id)'.")
        }
    }

    /// And the converse: the guard must not have grown broader than the
    /// declaration. Output-only concepts are things the model may not SAY;
    /// asking about them is an ordinary question and must still reach a
    /// provider.
    func testOutputOnlyConceptsAreNotRefusedOnInput() {
        let refusable = Set(MedicalTermLexicon.refuseBeforeSending.map(\.id))
        let outputOnly = MedicalTermLexicon.scrubFromOutput.filter { !refusable.contains($0.id) }
        XCTAssertFalse(outputOnly.isEmpty, "Precondition: the two groups must differ.")

        for phrase in ["Am I overtraining?", "What does my injury risk look like?",
                       "Is Emuqu FDA-approved?", "Tell me about pathology."] {
            XCTAssertNil(
                MedicalQueryGuard.classify(phrase),
                "'\(phrase)' names an output-only concept and must still reach the model."
            )
        }
    }

    /// The acute subset refuses; the chronic terms it was carved out of do not.
    /// An endurance athlete asking whether their resting heart rate counts as
    /// bradycardia is asking a training question.
    func testAcuteEventsRefuseWhileChronicDescriptorsProceed() {
        XCTAssertEqual(MedicalQueryGuard.classify("I think I am having a heart attack"), .symptom)
        XCTAssertEqual(MedicalQueryGuard.classify("could this be a pulmonary embolism"), .symptom)
        XCTAssertNil(MedicalQueryGuard.classify("is my resting heart rate low enough to be bradycardia"))
        XCTAssertNil(MedicalQueryGuard.classify("how does training affect hypertension in general"))
    }

    /// `stroke` in this app is a swimming metric. The input guard must not
    /// refuse a question about it.
    func testSwimStrokeQuestionsProceed() {
        XCTAssertNil(MedicalQueryGuard.classify("what was my stroke rate in that swim"))
        XCTAssertNil(MedicalQueryGuard.classify("how many total strokes did I take"))
        XCTAssertNil(MedicalQueryGuard.classify("that PB was a stroke of luck"))
        XCTAssertEqual(MedicalQueryGuard.classify("am I having a stroke"), .symptom)
        XCTAssertEqual(MedicalQueryGuard.classify("I had a stroke last year"), .symptom)
    }

    // MARK: - Precedence

    /// An acute symptom outranks a rhythm question.
    ///
    /// The two families answer differently: the rhythm reply recommends Apple
    /// Watch's ECG; the symptom reply says "contact a clinician (or your local
    /// emergency number for severe symptoms)". `classify` checked rhythm first
    /// and returned, so someone reporting chest pain alongside skipped beats was
    /// pointed at a watch feature. Swapping the order tripped no test, which
    /// is how it survived; this one pins it.
    func testAnAcuteSymptomOutranksARhythmQuestion() {
        let bothFamilies = [
            "skipped beats and chest tightness",
            "arrhythmia and I am having a heart attack",
            "I have palpitations and severe pain",
            "irregular heartbeat and I fainted"
        ]
        for text in bothFamilies {
            XCTAssertEqual(
                MedicalQueryGuard.classify(text), .symptom,
                """
                '\(text)' names an acute symptom. The reply must be the one that \
                mentions an emergency number, not the one that recommends an ECG watch.
                """
            )
        }
    }

    /// But a request for a RISK JUDGEMENT about a rhythm is still a rhythm
    /// question — "should I be worried about my AFib" is better served by the
    /// reply that points at a clinically validated ECG than by a generic
    /// redirect. `dangerJudgement` is deliberately checked last.
    func testARiskJudgementAboutRhythmStillGetsTheRhythmReply() {
        XCTAssertEqual(MedicalQueryGuard.classify("should I be worried about my atrial fibrillation"), .rhythm)
        XCTAssertEqual(MedicalQueryGuard.classify("is my arrhythmia dangerous"), .rhythm)
        // …and on its own it is still refused.
        XCTAssertEqual(MedicalQueryGuard.classify("is this dangerous"), .symptom)
    }

    /// Respiratory sinus arrhythmia is normal physiology. The English exclusion
    /// existed; the other sixteen locales did not have it, so those users could
    /// not ask about a term the app's own methodology page teaches them.
    func testSinusArrhythmiaIsNotRefusedInAnyLocale() {
        let benign = [
            "en": "what is respiratory sinus arrhythmia?",
            "es": "¿qué es la arritmia sinusal respiratoria?",
            "fr": "qu'est-ce que l'arythmie sinusale respiratoire ?",
            "it": "che cos'è l'aritmia sinusale respiratoria?",
            "pt-BR": "o que é a arritmia sinusal respiratória?",
            "de": "was ist die respiratorische Sinusarrhythmie?",
            "nl": "wat is respiratoire sinusaritmie?",
            "da": "hvad er respiratorisk sinusarytmi?",
            "fi": "mikä on hengitysperäinen sinusrytmihäiriö?",
            "ja": "呼吸性洞性不整脈とは何ですか。",
            "ko": "호흡성 동성 부정맥이 무엇인가요.",
            "zh-Hans": "什么是呼吸性窦性心律失常。",
            "ru": "что такое дыхательная синусовая аритмия.",
            "ar": "ما هو عدم انتظام ضربات القلب التنفسي."
        ]
        for (locale, question) in benign {
            XCTAssertNil(
                MedicalQueryGuard.classify(question),
                "[\(locale)] a question about normal physiology was refused: \(question)"
            )
        }
    }

}
