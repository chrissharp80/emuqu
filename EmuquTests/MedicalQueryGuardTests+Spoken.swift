@testable import Emuqu
import XCTest

// The everyday first-person ways people report an emergency symptom or
// self-harm, in every shipped language. The clinical nouns alone ("dolor en
// el pecho", "Brustschmerz") left "me duele el pecho" and "ich bekomme keine
// Luft" to a cloud model instead of the fixed reply. Each row below is a
// phrasing the noun-only lexicon did not match. The second half pins the
// exercise talk that borrows the same words and must still reach the model.

extension MedicalQueryGuardTests {
    typealias Row = (locale: String, text: String)

    /// Chest pain, breathlessness, fainting and collapsing: the symptom reply,
    /// which tells an exercising user to stop and names the emergency number.
    func testSpokenEmergencySymptomsGetTheSymptomReplyInEveryLocale() {
        assertRows(Self.spokenEmergencyRows, classifyAs: .symptom)
        for row in Self.spokenEmergencyRows {
            guard case let .refuse(reply) = MedicalQueryGuard.evaluate(row.text) else { continue }
            XCTAssertEqual(reply, MedicalQueryGuard.symptomReplyTemplate, "[\(row.locale)] \(row.text)")
        }
    }

    /// An irregular heartbeat said in the first person gets the rhythm reply.
    func testSpokenIrregularHeartbeatGetsTheRhythmReplyInEveryLocale() {
        assertRows(Self.spokenRhythmRows, classifyAs: .rhythm)
    }

    /// Thinking about it, ongoing forms and contractions get the crisis reply.
    func testOngoingSelfHarmPhrasingGetsTheCrisisReplyInEveryLocale() {
        assertRows(Self.spokenSelfHarmRows, classifyAs: .selfHarm)
        for row in Self.spokenSelfHarmRows {
            guard case let .refuse(reply) = MedicalQueryGuard.evaluate(row.text) else { continue }
            XCTAssertEqual(reply, MedicalQueryGuard.selfHarmReply, "[\(row.locale)] \(row.text)")
        }
    }

    /// Past or hedged exertion, a pace or metric that collapses, a racing
    /// heart on a climb and training idioms reach the model in every locale.
    func testExerciseTalkAboutBreathAndEffortStillReachesTheModel() {
        for row in Self.exerciseTalkRows {
            XCTAssertNil(MedicalQueryGuard.classify(row.text), "[\(row.locale)] exercise talk was refused: \(row.text)")
        }
    }

    private func assertRows(_ rows: [Row], classifyAs trigger: MedicalQueryGuard.Trigger) {
        for row in rows {
            XCTAssertEqual(MedicalQueryGuard.classify(row.text), trigger, "[\(row.locale)] expected \(trigger): \(row.text)")
        }
    }
}

// MARK: - Tables

extension MedicalQueryGuardTests {
    static let spokenEmergencyRows: [Row] = [
        ("en", "I cannot breathe"), ("en", "I can not breathe right now"), ("en", "I can't catch my breath"),
        ("en", "I can't get any air"), ("en", "it's hard to breathe"), ("en", "I'm short of breath"),
        ("en", "there's pressure on my chest"), ("en", "my chest really hurts"), ("en", "my chest is so tight"),
        ("en", "I collapsed during my run"), ("en", "I just collapsed"), ("en", "I think I'm going to collapse"),
        ("en", "I lost consciousness on the bike"),
        ("es", "me duele el pecho"), ("es", "me duele mucho el pecho"), ("es", "siento presion en el pecho"),
        ("es", "no puedo respirar"), ("es", "me falta el aire"), ("es", "me cuesta respirar"),
        ("es", "me desmaye en la carrera"), ("es", "me voy a desmayar"), ("es", "perdí el conocimiento"),
        ("fr", "j'ai mal à la poitrine"), ("fr", "j'ai mal a la poitrine"), ("fr", "ma poitrine me fait mal"),
        ("fr", "je ne peux pas respirer"), ("fr", "j'arrive pas à respirer"), ("fr", "j'ai du mal a respirer"),
        ("fr", "je me suis évanoui"), ("fr", "je vais m'evanouir"), ("fr", "j'ai perdu connaissance"),
        ("fr", "je me suis effondré pendant la course"),
        ("de", "mir tut die Brust weh"), ("de", "die Brust tut mir weh"), ("de", "ich habe Druck auf der Brust"),
        ("de", "ich bekomme keine Luft"), ("de", "ich krieg keine Luft mehr"), ("de", "ich kann nicht atmen"),
        ("de", "ich bin ohnmächtig geworden"), ("de", "ich bin beim Laufen zusammengebrochen"),
        ("it", "mi fa male il petto"), ("it", "ho male al petto"), ("it", "sento un peso sul petto"),
        ("it", "non riesco a respirare"), ("it", "mi manca il respiro"), ("it", "sono svenuto"),
        ("it", "sto per svenire"), ("it", "ho perso i sensi"),
        ("pt-BR", "meu peito está doendo"), ("pt-BR", "meu peito esta doendo"), ("pt-BR", "dói o peito"),
        ("pt-BR", "não consigo respirar"), ("pt-BR", "nao consigo respirar"), ("pt-BR", "tô sem ar"),
        ("pt-BR", "vou desmaiar"), ("pt-BR", "perdi a consciência"),
        ("nl", "mijn borst doet pijn"), ("nl", "ik heb druk op de borst"), ("nl", "ik kan niet ademen"),
        ("nl", "ik krijg geen lucht"), ("nl", "ik viel flauw"), ("nl", "ik val bijna flauw"),
        ("da", "jeg har ondt i brystet"), ("da", "brystet gør ondt"), ("da", "jeg kan ikke få vejret"),
        ("da", "jeg er ved at besvime"), ("da", "jeg mistede bevidstheden"),
        ("nb", "jeg har vondt i brystet"), ("nb", "jeg får ikke puste"), ("nb", "jeg kan ikke puste"),
        ("nb", "jeg holder på å besvime"), ("nb", "jeg mistet bevisstheten"),
        ("sv", "jag har ont i bröstet"), ("sv", "jag har tryck över bröstet"), ("sv", "jag kan inte andas"),
        ("sv", "jag får ingen luft"), ("sv", "jag svimmade"), ("sv", "jag håller på att svimma"),
        ("fi", "rintaan sattuu"), ("fi", "minulla on rintakipua"), ("fi", "rintaa puristaa"),
        ("fi", "en saa henkeä"), ("fi", "en pysty hengittämään"), ("fi", "pyörryin lenkillä"), ("fi", "menetin tajuntani"),
        ("is", "ég er með verk í brjóstinu"), ("is", "ég get ekki andað"), ("is", "ég næ ekki andanum"),
        ("is", "það leið yfir mig"), ("is", "ég missti meðvitund"),
        ("ru", "у меня болит грудь"), ("ru", "болит в груди"), ("ru", "давит в груди"), ("ru", "не могу дышать"),
        ("ru", "мне не хватает воздуха"), ("ru", "я задыхаюсь"), ("ru", "я потерял сознание"), ("ru", "я теряю сознание"),
        ("ja", "胸が痛い"), ("ja", "胸が苦しいです"), ("ja", "胸が締め付けられる"), ("ja", "息ができない"),
        ("ja", "息が苦しい"), ("ja", "気を失いました"), ("ja", "ランの途中で倒れました"),
        ("zh-Hans", "我胸口痛"), ("zh-Hans", "胸口很疼"), ("zh-Hans", "我胸闷"), ("zh-Hans", "我喘不过气"),
        ("zh-Hans", "我无法呼吸"), ("zh-Hans", "我晕过去了"), ("zh-Hans", "我失去了意识"),
        ("ko", "가슴이 아파요"), ("ko", "가슴이 너무 아파"), ("ko", "숨을 못 쉬겠어요"), ("ko", "숨을 쉴 수가 없어요"),
        ("ko", "숨쉬기가 힘들어요"), ("ko", "기절했어요"), ("ko", "달리다가 쓰러졌어요"),
        ("ar", "صدري يؤلمني"), ("ar", "عندي الم في صدري"), ("ar", "لا أستطيع التنفس"), ("ar", "لا استطيع التنفس"),
        ("ar", "أغمي علي أثناء الجري"), ("ar", "فقدت الوعي")
    ]

    static let spokenRhythmRows: [Row] = [
        ("en", "my heart is racing irregularly"), ("en", "my heart keeps skipping"),
        ("es", "mi corazón late de forma irregular"), ("fr", "mon cœur bat de façon irrégulière"),
        ("de", "mein Herz schlägt unregelmäßig"), ("de", "mein Herz stolpert"),
        ("it", "il cuore mi batte in modo irregolare"), ("pt-BR", "meu coração está batendo irregular"),
        ("nl", "mijn hart slaat onregelmatig"), ("da", "mit hjerte slår uregelmæssigt"),
        ("nb", "hjertet slår uregelmessig"), ("sv", "hjärtat slår oregelbundet"),
        ("fi", "sydän lyö epäsäännöllisesti"), ("is", "hjartað slær óreglulega"), ("ru", "сердце бьётся неровно"),
        ("ja", "脈が乱れています"), ("zh-Hans", "我心跳不齐"), ("ko", "심장이 불규칙하게 뛰어요"),
        ("ar", "قلبي ينبض بشكل غير منتظم")
    ]

    static let spokenSelfHarmRows: [Row] = [
        ("en", "I keep thinking about killing myself"), ("en", "I've been thinking of killing myself"),
        ("en", "I feel like killing myself"), ("en", "I keep thinking about hurting myself"),
        ("en", "I keep thinking about ending it all"), ("en", "I dont wanna live anymore"), ("en", "I'd be better off dead"),
        ("es", "he pensado en matarme"), ("es", "no dejo de pensar en morirme"), ("es", "no quiero seguir viviendo"),
        ("fr", "je pense à me tuer"), ("fr", "je n'arrête pas de penser à mourir"), ("fr", "je veux en finir"),
        ("fr", "j'ai plus envie de vivre"),
        ("de", "ich habe keine Lust mehr zu leben"), ("de", "ich will nicht mehr am Leben sein"),
        ("it", "continuo a pensare di uccidermi"),
        ("pt-BR", "não paro de pensar em me matar"), ("pt-BR", "fico pensando em morrer"),
        ("nl", "ik denk erover om mezelf van kant te maken"),
        ("da", "jeg tænker på at slå mig selv ihjel"), ("da", "jeg vil tage livet af mig"),
        ("nb", "jeg tenker på å ta livet av meg"),
        ("sv", "jag tänker på att ta livet av mig"), ("sv", "jag vill inte leva langre"),
        ("fi", "mietin itseni tappamista"), ("is", "ég hugsa um að drepa mig"),
        ("ru", "я всё время думаю убить себя"), ("ru", "жить не хочется"),
        ("ja", "死のうと思っている"), ("ja", "消えてしまいたい"),
        ("zh-Hans", "活着没意思"), ("zh-Hans", "我想要伤害自己"),
        ("ko", "죽어버리고 싶어"), ("ko", "살기 싫어"),
        ("ar", "أفكر في قتل نفسي"), ("ar", "لا أريد العيش")
    ]

    static let exerciseTalkRows: [Row] = [
        ("en", "this hill is killing me"), ("en", "my lungs are burning on this climb"),
        ("en", "I could barely breathe on that last interval"), ("en", "I couldn't breathe on that hill"),
        ("en", "I was out of breath after the sprint"), ("en", "how should I breathe when I run"),
        ("en", "I'm killing myself on these intervals"), ("en", "I've been killing myself in training"),
        ("en", "thinking about cutting myself some slack this week"), ("en", "worried about hurting myself on the descent"),
        ("en", "my pace collapsed in the last mile"), ("en", "my HRV collapsed this week"),
        ("en", "my chest is sore after bench press"), ("en", "breathing hard on the climb"),
        ("en", "my heart was racing on that climb"), ("en", "I want to end it early today"),
        ("es", "esta cuesta me está matando"), ("es", "me quedé sin aliento en la subida"),
        ("es", "casi no podía respirar en el último intervalo"), ("es", "mi ritmo se desplomó"),
        ("es", "mi corazón late muy rápido en la subida"),
        ("fr", "cette côte me tue"), ("fr", "j'étais essoufflé après le sprint"), ("fr", "mon allure s'est effondrée"),
        ("fr", "je veux en finir avec cette séance"), ("fr", "mon cœur bat vite dans la côte"),
        ("de", "ich war völlig außer Atem"), ("de", "mein Tempo ist zusammengebrochen"),
        ("de", "ich will heute nicht mehr laufen"), ("de", "mein Herz rast am Berg"),
        ("it", "ero senza fiato dopo la salita"), ("it", "voglio farla finita con questo allenamento"),
        ("pt-BR", "fiquei sem ar na subida"), ("nl", "ik was buiten adem na de sprint"),
        ("da", "jeg var forpustet efter løbet"), ("nb", "jeg var andpusten etter intervallene"),
        ("nb", "snøen falt om natten"), ("sv", "jag var andfådd efter backen"),
        ("fi", "olin hengästynyt mäen jälkeen"), ("is", "ég var móður eftir hlaupið"),
        ("ru", "я запыхался после пробежки"), ("ru", "этот подъём меня убивает"),
        ("ja", "走った後で息が上がった"), ("ja", "疲れて倒れそう"),
        ("zh-Hans", "跑完累死了"), ("zh-Hans", "跑完气喘吁吁"), ("zh-Hans", "什么是呼吸性窦性心律不齐"),
        ("ko", "달리고 나서 숨이 찼어"), ("ko", "이 언덕 때문에 죽을 것 같아"),
        ("ar", "كنت ألهث بعد الجري"), ("ar", "هذا التل يقتلني")
    ]
}
