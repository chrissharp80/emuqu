@testable import Emuqu
import XCTest

// An injury told by its cause, in every shipped language: a trip or slip
// that ended in a fall, a car, a blow to the head, a torn or pulled muscle,
// being knocked off the bike. Each went to the model, which could answer
// with a route and no word about the emergency number. The same words in
// training talk still reach the model.

extension MedicalQueryGuardTests {
    func testAnInjuryToldByItsCauseGetsTheInjuryReplyInEveryLocale() {
        for row in Self.injuryByCauseRows {
            XCTAssertEqual(MedicalQueryGuard.classify(row.text), .injury, "[\(row.locale)] expected the injury reply: \(row.text)")
        }
    }

    func testTheSameWordsInTrainingTalkReachTheModel() {
        for row in Self.injuryByCauseLookalikeRows {
            XCTAssertNil(MedicalQueryGuard.classify(row.text), "[\(row.locale)] refused as an injury: \(row.text)")
        }
    }

    static let injuryByCauseRows: [Row] = [
        ("fr", "j'ai trébuché et je suis tombé"), ("fr", "j'ai glissé sur le verglas"), ("fr", "une voiture m'a renversé"),
        ("fr", "je me suis cogné la tête"), ("fr", "je me suis fait un claquage"), ("fr", "j'ai été renversé à vélo"),
        ("es", "tropecé y me caí"), ("es", "resbalé en el hielo"), ("es", "un coche me atropelló"),
        ("es", "me golpeé la cabeza"), ("es", "me desgarré el gemelo"), ("es", "un coche me tiró de la bici"),
        ("pt-BR", "tropecei e caí"), ("pt-BR", "escorreguei no gelo"), ("pt-BR", "fui atropelado"),
        ("pt-BR", "bati a cabeça"), ("pt-BR", "distendi a panturrilha"), ("pt-BR", "fui derrubado da bike"),
        ("it", "sono inciampato e caduto"), ("it", "sono scivolato sul ghiaccio"), ("it", "sono stato investito da un'auto"),
        ("it", "ho battuto la testa"), ("it", "mi sono strappato il polpaccio"), ("it", "sono caduto dalla bici"),
        ("de", "ich bin gestolpert und hingefallen"), ("de", "ich bin auf dem Eis ausgerutscht"), ("de", "ein Auto hat mich angefahren"),
        ("de", "ich habe mir den Kopf angeschlagen"), ("de", "ich habe mir eine Zerrung geholt"), ("de", "ich bin vom Rad gestürzt"),
        ("nl", "ik ben gestruikeld en gevallen"), ("nl", "ik ben uitgegleden op het ijs"), ("nl", "ik ben aangereden door een auto"),
        ("nl", "ik heb mijn hoofd gestoten"), ("nl", "ik heb een zweepslag"), ("nl", "ik ben van mijn fiets gevallen"),
        ("da", "jeg snublede og faldt"), ("da", "jeg gled på isen"), ("da", "jeg blev ramt af en bil"),
        ("da", "jeg slog hovedet"), ("da", "jeg fik en fibersprængning"), ("da", "jeg faldt af cyklen"),
        ("nb", "jeg snublet og falt"), ("nb", "jeg skled på isen"), ("nb", "jeg ble påkjørt av en bil"),
        ("nb", "jeg slo hodet"), ("nb", "jeg fikk en muskelstrekk"), ("nb", "jeg veltet på sykkelen"),
        ("sv", "jag snubblade och föll"), ("sv", "jag halkade på isen"), ("sv", "jag blev påkörd av en bil"),
        ("sv", "jag slog i huvudet"), ("sv", "jag fick en muskelbristning"), ("sv", "jag ramlade av cykeln"),
        ("fi", "liukastuin jäällä"), ("fi", "jäin auton alle"), ("fi", "löin pääni"),
        ("fi", "revähdytin pohkeeni"), ("fi", "putosin pyörän selstä"),
        ("is", "ég hrasaði og datt"), ("is", "ég rann á svelli"), ("is", "ég varð fyrir bíl"),
        ("is", "ég rak höfuðið í"), ("is", "ég reif vöðva"), ("is", "ég datt af hjóli"),
        ("ru", "я споткнулся и упал"), ("ru", "я поскользнулся на льду"), ("ru", "меня сбила машина"),
        ("ru", "я ударился головой"), ("ru", "я порвал икру"),
        ("ja", "氷で滑って転んだ"), ("ja", "車にはねられた"), ("ja", "頭を打った"), ("ja", "肉離れした"), ("ja", "自転車から落ちた"),
        ("zh-Hans", "我在冰上滑倒了"), ("zh-Hans", "我被车撞了"), ("zh-Hans", "我撞到头了"), ("zh-Hans", "我拉伤了大腿"),
        ("zh-Hans", "我从自行车上摔下来了"),
        ("ko", "빙판에서 미끄러졌어요"), ("ko", "차에 치였어요"), ("ko", "머리를 부딪혔어요"), ("ko", "종아리 근육이 찢어졌어요"),
        ("ko", "자전거에서 떨어졌어요"),
        ("ar", "انزلقت على الجليد"), ("ar", "صدمتني سيارة"), ("ar", "ضربت رأسي"), ("ar", "عندي تمزق في العضلة"), ("ar", "سقطت عن الدراجة")
    ]

    static let injuryByCauseLookalikeRows: [Row] = [
        ("fr", "j'ai trébuché sur une étude sur la VFC"), ("fr", "j'ai glissé au classement"), ("fr", "j'ai fait une chute de forme"),
        ("es", "tropecé con un artículo interesante"), ("es", "me arrolló el cansancio"), ("es", "¿cómo evito un desgarro?"),
        ("pt-BR", "tropecei numa ideia boa"), ("pt-BR", "bati a meta de hoje"),
        ("it", "sono scivolato in classifica"), ("it", "ho uno strappo alla regola oggi"), ("it", "ho battuto il record"),
        ("de", "ich bin über eine Studie gestolpert"), ("de", "wie vermeide ich eine Zerrung?"),
        ("nl", "ik ben over die studie gestruikeld"),
        ("da", "jeg gled igennem intervallerne"), ("nb", "hvordan unngå muskelstrekk?"), ("sv", "jag halkade efter i schemat"),
        ("fi", "kompastuin virheeseen sovelluksessa"), ("is", "ég rann í gegnum æfinguna"),
        ("ru", "как избежать растяжения?"),
        ("ja", "肉離れの予防は？"), ("zh-Hans", "怎么预防拉伤？"), ("zh-Hans", "被车撞的风险高吗？"),
        ("ko", "근육이 찢어질 것 같아"), ("ko", "순위가 미끄러졌어"),
        ("ar", "انزلق ترتيبي هذا الأسبوع"), ("ar", "ما علاج الشد العضلي؟")
    ]
}
