@testable import Emuqu
import XCTest

// Injury reports. "I fell and hurt my ankle, get me to a hospital" used to
// pass the guard, and the model answered with a walking route and no word
// about the emergency number. These cases pin the reply that now comes first,
// in every shipped language, and the idioms that must still reach the model.

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
