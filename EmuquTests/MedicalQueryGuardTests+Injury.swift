@testable import Emuqu
import XCTest

// Injury reports. "I fell and hurt my ankle, get me to a hospital" must not
// pass the guard to the model, which could answer with a walking route and no
// word about the emergency number. These cases pin the reply that comes
// first, in every shipped language, and the idioms that must still reach the
// model.

extension MedicalQueryGuardTests {
    func testInjuryReportsGetTheEmergencyNumberReply() {
        let reports = [
            "I fell and hurt my ankle, get me to a hospital",
            "I'm hurt, I need help",
            "im injured",
            "I just fell on the trail",
            "I've fallen and I can't get up",
            "I think my ankle is broken",
            "I twisted my knee on the descent",
            "I sprained my wrist",
            "I'm bleeding",
            "I can't walk",
            "I can’t put weight on my foot",
            "I came off my bike",
            "call an ambulance",
            "I got hurt on my run"
        ]
        for text in reports {
            XCTAssertEqual(MedicalQueryGuard.classify(text), .injury, "Expected the injury reply for: \(text)")
            guard case let .refuse(reply) = MedicalQueryGuard.evaluate(text) else {
                XCTFail("Injury report must be answered locally: \(text)")
                continue
            }
            XCTAssertEqual(reply, MedicalQueryGuard.injuryReply)
        }
    }

    func testInjuryReportsAreCaughtInEveryShippedLocale() {
        let cases: [(String, String)] = [
            ("fr", "je suis tombée et je me suis tordu la cheville"),
            ("es", "me caí y me he torcido el tobillo"),
            ("pt-BR", "eu caí e torci o tornozelo"),
            ("it", "sono caduto, mi sono fatto male"),
            ("de", "ich bin gestürzt und habe mich verletzt"),
            ("nl", "ik ben gevallen"),
            ("da", "jeg er faldet og kan ikke gå"),
            ("nb", "jeg har falt og vrikket ankelen"),
            ("sv", "jag ramlade och har stukat foten"),
            ("fi", "kaaduin ja nilkka nyrjähti"),
            ("is", "ég datt og meiddi mig"),
            ("ru", "я упал и подвернул ногу"),
            ("ja", "転んで足をひねった"),
            ("zh-Hans", "我摔倒了，脚崴了"),
            ("ko", "넘어져서 발목을 다쳤어요"),
            ("ar", "سقطت ولا أستطيع المشي")
        ]
        for (locale, text) in cases {
            XCTAssertEqual(MedicalQueryGuard.classify(text), .injury, "[\(locale)] Expected the injury reply for: \(text)")
        }
    }

    /// The everyday senses of the same words are training talk.
    func testInjuryIdiomsStillReachTheModel() {
        let idioms = [
            "I fell asleep before my reading",
            "I fell behind on my training plan",
            "I fell in love with trail running",
            "I broke my PR today",
            "my legs hurt after the long run",
            "I should cut myself some slack this week",
            "bleeding edge running shoes",
            "me he roto el récord",
            "je me suis cassé la tête sur ce plan",
            "mi sono rotto le scatole della pioggia",
            "quebrei o recorde",
            "jeg falt i søvn tidlig",
            "jag föll i sömn direkt"
        ]
        for text in idioms {
            XCTAssertNil(MedicalQueryGuard.classify(text), "Idiom misread as an injury: \(text)")
        }
    }

    /// Chest pain with a fall still gets the symptom reply, which also names
    /// the emergency number and tells an exercising user to stop.
    func testAnAcuteSymptomOutranksAnInjury() {
        XCTAssertEqual(MedicalQueryGuard.classify("I fell and now I have chest pain"), .symptom)
    }

    /// Talk that shares an injury report's words: a verb that also means "go",
    /// "run" or "ride", a fall that is a pace or a plan, a score that "fell"
    /// (Arabic سقطت), an illness ("أنا مصاب بالزكام"), a triathlon transition,
    /// a barbell, a noun in a general question, and soreness after a session.
    func testInjuryLookalikesStillReachTheModel() {
        for row in Self.injuryLookalikeRows {
            XCTAssertNil(MedicalQueryGuard.classify(row.text), "[\(row.locale)] refused as an injury: \(row.text)")
        }
    }

    /// The same words in the injury shape still get the injury reply, and so
    /// does a joint that hurts now or gave way.
    func testNarrowedInjuryReportsStillGetTheInjuryReply() {
        for row in Self.narrowedInjuryReportRows {
            XCTAssertEqual(MedicalQueryGuard.classify(row.text), .injury, "[\(row.locale)] expected the injury reply: \(row.text)")
        }
    }

    static let injuryLookalikeRows: [Row] = [
        ("en", "I fell off pace in the last mile"), ("en", "I fell off the plan this week"),
        ("en", "I fell out of shape over the holidays"), ("en", "I fell into a rut"), ("en", "I fell down the rankings"),
        ("en", "I had a fall in fitness after my vacation"), ("en", "When I came off the bike my legs were dead"),
        ("en", "I can't put weight on the bar"), ("en", "I crashed my bike computer"),
        ("en", "my legs hurt after intervals yesterday"), ("en", "my knee hurts after long runs"),
        ("en", "my knee hurts when I run downhill"), ("en", "my calves are killing me"),
        ("da", "jeg kan ikke gå til træning i dag"), ("nb", "jeg kan ikke gå på trening i dag"),
        ("sv", "jag kan inte gå på passet ikväll"), ("nl", "ik kan niet lopen vandaag, ik moet werken"),
        ("ru", "не могу идти на тренировку сегодня"), ("es", "no puedo andar en bici hoy"),
        ("pt-BR", "não consigo andar de bike hoje"), ("fr", "je suis tombé sur une étude sur la VFC"),
        ("fr", "je suis tombé malade la semaine dernière"), ("pt-BR", "eu caí no sono cedo"),
        ("ar", "سقطت درجة التعافي اليوم"), ("ar", "نتيجتي سقطت بعد السباق"), ("ar", "أنا مصاب بالزكام هل أتمرن؟"),
        ("ja", "疲労骨折がある"), ("ja", "疲労骨折の予防は？"), ("zh-Hans", "我有应力性骨折"), ("ko", "피로 골절이 있어요"),
        ("es", "me duele la rodilla después de correr"), ("fr", "j'ai mal au genou après la course"),
        ("de", "mein Knie tut nach dem Lauf weh"), ("it", "mi fa male il ginocchio dopo la corsa"),
        ("pt-BR", "meu joelho está doendo depois do treino"), ("nl", "mijn knie doet pijn na het hardlopen"),
        ("da", "jeg har ondt i knæet efter løbet"), ("sv", "jag har ont i knät efter passet"),
        ("ru", "у меня болит колено после пробежки"), ("ja", "走った後に膝が痛い"),
        ("zh-Hans", "跑完步后膝盖疼"), ("ko", "달리기 후에 무릎이 아파요"), ("ar", "ركبتي تؤلمني بعد الجري")
    ]

    static let narrowedInjuryReportRows: [Row] = [
        ("en", "I fell down the stairs"), ("en", "I fell off my bike"), ("en", "I crashed my bike"),
        ("en", "My knee hurts, should I push through it?"), ("en", "my ankle is killing me"),
        ("en", "my knee gave way on the descent"),
        ("da", "jeg kan ikke gå"), ("sv", "jag kan inte gå"), ("nl", "ik kan niet lopen"), ("nl", "ik kan niet meer lopen"),
        ("ru", "не могу идти"), ("es", "no puedo caminar"), ("pt-BR", "não consigo andar"),
        ("fr", "je suis tombé"), ("pt-BR", "eu caí"), ("ar", "سقطت"), ("ar", "سقطت من الدراجة"), ("ar", "أنا مصاب"),
        ("ja", "足を骨折したかもしれない"), ("ja", "足首を捻挫した"), ("zh-Hans", "我的脚骨折了"), ("zh-Hans", "我扭伤了脚"),
        ("ko", "다리가 골절된 것 같아요"),
        ("es", "me duele la rodilla"), ("fr", "j'ai mal au genou"), ("de", "mein Knie tut weh"),
        ("it", "mi fa male il ginocchio"), ("pt-BR", "meu joelho está doendo"), ("nl", "mijn knie doet pijn"),
        ("da", "jeg har ondt i knæet"), ("nb", "jeg har vondt i kneet"), ("sv", "jag har ont i knät"),
        ("fi", "polveen sattuu"), ("ru", "у меня болит колено"), ("ja", "膝が痛い"), ("zh-Hans", "膝盖很疼"),
        ("ko", "무릎이 아파요"), ("ar", "ركبتي تؤلمني")
    ]

    /// Non-diagnostic, and it names the emergency number before anything else
    /// a reader could act on.
    func testInjuryReplyPointsAtTheEmergencyNumberWithoutDiagnosing() {
        let reply = MedicalQueryGuard.injuryReply
        XCTAssertTrue(reply.contains("call your local emergency number"))
        XCTAssertTrue(reply.contains("I can't assess injuries"))
        XCTAssertNil(MedicalQueryGuard.classify(reply), "the reply must not re-trigger the guard when echoed by voice")
    }

    /// Rule B in both system prompts quotes the injury reply word for word.
    func testRuleBQuotesTheInjuryReplyVerbatim() {
        let collapse = { (text: String) in text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let reply = collapse(MedicalQueryGuard.injuryReply)
        XCTAssertTrue(collapse(AssistantSystemPrompt.base).contains(reply))
        XCTAssertTrue(collapse(AssistantSystemPrompt.appleBase).contains(reply))
    }
}
