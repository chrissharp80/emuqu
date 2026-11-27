@testable import Emuqu
import XCTest

// An act already taken (an overdose), a method, and a plan with a time: the
// Columbia scale's questions beyond the wish to die. Each went to a cloud
// model while only the wish phrasings matched. Training talk that shares the
// words ("end it here", "took all my meds", "shoot myself in the foot") must
// still reach the model.

extension MedicalQueryGuardTests {
    func testActsMethodsAndPlansGetTheCrisisReplyInEveryLocale() {
        let byLocale: [(locale: String, text: String)] = [
            ("en", "I took too many pills"), ("en", "I overdosed on my pills"), ("en", "I'm going to end it tonight"),
            ("en", "I just overdosed."), ("en", "I've swallowed a whole bottle of sleeping pills"),
            ("en", "I'm going to hang myself"), ("en", "I wish I could go to sleep and never wake up"),
            ("ar", "أخذت جرعة زائدة"), ("da", "jeg har taget for mange piller"), ("de", "ich habe zu viele Tabletten genommen"),
            ("de", "heute Nacht mache ich Schluss mit meinem Leben"), ("es", "me tomé demasiadas pastillas"),
            ("es", "voy a acabar con todo esta noche"), ("fi", "otin liikaa lääkkeitä"), ("fr", "j'ai pris trop de médicaments"),
            ("fr", "je vais en finir ce soir"), ("is", "ég tók of margar töflur"), ("it", "ho preso troppe pillole"),
            ("it", "stasera la faccio finita"), ("ja", "薬を飲みすぎた"), ("ko", "약을 너무 많이 먹었어"),
            ("nb", "jeg har tatt for mange tabletter"), ("nb", "jeg vil gjøre slutt på livet"), ("nl", "ik heb te veel pillen genomen"),
            ("pt-BR", "tomei remédios demais"), ("ru", "я выпил слишком много таблеток"), ("ru", "я покончу с этим сегодня"),
            ("sv", "jag har tagit för många tabletter"), ("zh-Hans", "我吃了太多药")
        ]
        for (locale, text) in byLocale {
            XCTAssertEqual(MedicalQueryGuard.classify(text), .selfHarm, "[\(locale)] Expected self-harm for: \(text)")
            guard case .refuse(let reply) = MedicalQueryGuard.evaluate(text) else {
                XCTFail("[\(locale)] Expected a refusal for: \(text)")
                continue
            }
            XCTAssertEqual(reply, MedicalQueryGuard.selfHarmReply, "[\(locale)] Expected the crisis reply for: \(text)")
        }
    }

    func testTrainingTalkSharingTheWordsIsNotSelfHarm() {
        let byLocale: [(locale: String, text: String)] = [
            ("en", "I'm going to end it here, my legs are gone"), ("en", "I took all my meds this morning"),
            ("en", "I overdosed on intervals this week"), ("en", "I'd shoot myself in the foot going out that fast"),
            ("en", "I want to take my life back from the couch"), ("en", "should I end it early if my HR drifts?"),
            ("ar", "أتناول الكثير من الحبوب الكاملة"), ("de", "ich nehme meine Tabletten jeden Morgen"),
            ("es", "quiero colgarme la medalla"), ("fr", "je vais en finir avec cette séance"),
            ("it", "la faccio finita con le ripetute"), ("ja", "今夜死ぬほど疲れた"), ("ko", "기록에 목을 매고 있어"),
            ("nb", "kan jeg henge meg på økta i morgen?"), ("sv", "jag vill hänga med på passet"), ("zh-Hans", "今晚就结束训练")
        ]
        for (locale, text) in byLocale {
            XCTAssertNotEqual(MedicalQueryGuard.classify(text), .selfHarm, "[\(locale)] Training talk misread as self-harm: \(text)")
        }
    }
}
