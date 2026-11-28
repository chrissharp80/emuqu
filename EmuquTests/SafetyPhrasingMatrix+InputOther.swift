@testable import Emuqu
import Foundation

// The input-guard columns in Russian, Japanese, Korean, Simplified Chinese
// and Arabic.

extension SafetyPhrasingMatrix {
    static let inputOther: [Row<InputForm>] = [russian, japanese, korean, chinese, arabic]

    private static let russian = Row<InputForm>(language: "ru", cells: [
        .chestPain: ["у меня болит в груди", "у меня боль в груди"],
        .breathlessness: ["я не могу дышать", "мне не хватает воздуха"],
        .fainting: ["я потерял сознание", "у меня был обморок на пробежке"],
        .severeSymptom: ["у меня паническая атака", "у меня сильная боль"],
        .heartAttack: ["у меня инфаркт?", "кажется, у меня сердечный приступ"],
        .stroke: ["у меня инсульт?", "кажется, у меня был инсульт"],
        .injury: ["я упал и повредил лодыжку", "кажется, у меня сломано запястье", "у меня идёт кровь"],
        .atrialFibrillation: ["у меня фибрилляция предсердий?", "это мерцательная аритмия?"],
        .irregularHeartbeat: ["сердце бьётся неровно", "у меня перебои в сердце"],
        .dangerQuestion: ["мой пульс опасен?", "стоит ли беспокоиться?"]
    ], negatives: [
        "ноги мёртвые после пробежки", "я запыхался на подъёме", "я побил свой рекорд", "сердце колотилось на подъёме"
    ])

    private static let japanese = Row<InputForm>(language: "ja", cells: [
        .chestPain: ["胸が痛い", "胸が締め付けられる"],
        .breathlessness: ["息ができない", "息苦しい"],
        .fainting: ["気を失った", "ランニング中に倒れた"],
        .severeSymptom: ["パニック発作が起きている", "激しい痛みがある"],
        .heartAttack: ["心臓発作ですか？", "心筋梗塞かもしれない"],
        .stroke: ["脳卒中ですか？", "脳梗塞かもしれない"],
        .injury: ["転んで足首を痛めた", "手首が折れたと思う", "血が出ている"],
        .atrialFibrillation: ["心房細動ですか？", "私は心房細動がありますか？"],
        .irregularHeartbeat: ["脈が飛ぶ", "動悸がする"],
        .dangerQuestion: ["私の心拍数は危険ですか？", "心配すべきですか？"]
    ], negatives: [
        "走った後で脚が死んでいる", "坂で息が上がった", "自己ベストを更新した", "坂で心臓がドキドキした"
    ])

    private static let korean = Row<InputForm>(language: "ko", cells: [
        .chestPain: ["가슴이 아파요", "가슴 통증이 있어요"],
        .breathlessness: ["숨을 쉴 수가 없어요", "숨이 막혀요"],
        .fainting: ["기절했어요", "달리다가 쓰러졌어요"],
        .severeSymptom: ["공황 발작이 왔어요", "심한 통증이 있어요"],
        .heartAttack: ["심장마비인가요?", "심근경색인 것 같아요"],
        .stroke: ["뇌졸중인가요?", "뇌경색이 온 것 같아요"],
        .injury: ["넘어져서 발목을 다쳤어요", "손목이 부러진 것 같아요", "피가 나요"],
        .atrialFibrillation: ["심방세동인가요?", "저 심방세동이 있나요?"],
        .irregularHeartbeat: ["심장이 불규칙하게 뛰어요", "심계항진이 있어요"],
        .dangerQuestion: ["제 심박수가 위험한가요?", "걱정해야 하나요?"]
    ], negatives: [
        "달리고 나니 다리가 죽었어", "언덕에서 숨이 찼어", "개인 기록을 깼어", "언덕에서 심장이 쿵쾅거렸어"
    ])

    private static let chinese = Row<InputForm>(language: "zh-Hans", cells: [
        .chestPain: ["我胸口痛", "我胸闷"],
        .breathlessness: ["我喘不过气", "我无法呼吸"],
        .fainting: ["我晕倒了", "我跑步时昏过去了"],
        .severeSymptom: ["我惊恐发作了", "我剧痛"],
        .heartAttack: ["我是心脏病发作吗？", "我觉得我心肌梗死了"],
        .stroke: ["我是中风了吗？", "我觉得我脑卒中了"],
        .injury: ["我摔倒了，脚踝受伤了", "我觉得我手腕骨折了", "我在流血"],
        .atrialFibrillation: ["我有房颤吗？", "这是心房颤动吗？"],
        .irregularHeartbeat: ["我心跳不齐", "我心悸"],
        .dangerQuestion: ["我的心率危险吗？", "我该担心吗？"]
    ], negatives: [
        "跑完腿都废了", "爬坡时气喘吁吁", "我破了个人纪录", "爬坡时心跳得很快"
    ])

    private static let arabic = Row<InputForm>(language: "ar", cells: [
        .chestPain: ["صدري يؤلمني", "عندي ألم في الصدر"],
        .breathlessness: ["لا أستطيع التنفس", "عندي ضيق في التنفس"],
        .fainting: ["فقدت الوعي", "أغمي علي أثناء الجري"],
        .severeSymptom: ["عندي نوبة هلع", "عندي ألم شديد"],
        .heartAttack: ["هل أصابتني نوبة قلبية؟", "أعتقد أنني أصبت بنوبة قلبية"],
        .stroke: ["هل أصابتني سكتة دماغية؟", "أعتقد أنني أصبت بجلطة"],
        .injury: ["سقطت وأصبت كاحلي", "أعتقد أن معصمي مكسور", "أنا أنزف"],
        .atrialFibrillation: ["هل عندي رجفان أذيني؟", "هل هذا الرجفان الأذيني؟"],
        .irregularHeartbeat: ["قلبي ينبض بشكل غير منتظم", "عندي خفقان"],
        .dangerQuestion: ["هل معدل ضربات قلبي خطير؟", "هل يجب أن أقلق؟"]
    ], negatives: [
        "ساقاي ميتتان بعد الجري", "انقطع نفسي في الصعود", "حطمت رقمي القياسي", "كان قلبي يدق بقوة في الصعود"
    ])
}
