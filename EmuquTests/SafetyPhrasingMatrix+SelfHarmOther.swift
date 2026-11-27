@testable import Emuqu
import Foundation

// Russian, Japanese, Korean, Simplified Chinese and Arabic. The CJK and
// Arabic patterns are substrings, so the idioms that share a verb ("死にそう",
// "累死了", "죽겠다", "يقتلني") are the negatives that keep them honest.

extension SafetyPhrasingMatrix {
    static let selfHarmOther: [Row<SelfHarmForm>] = [russian, japanese, korean, chinese, arabic]

    private static let russian = Row<SelfHarmForm>(language: "ru", cells: [
        .passiveWish: ["лучше бы я умер", "хочу уснуть и не проснуться", "лучше бы меня не было"],
        .activeWish: ["хочу убить себя", "хочу умереть", "хочу покончить с собой"],
        .declaredIntent: ["я убью себя", "я покончу с собой", "я собираюсь убить себя", "я себя убью"],
        .planWithMethod: ["я повешусь", "я спрыгну с моста", "я выпью все свои таблетки сразу"],
        .planWithTime: ["сегодня ночью я убью себя", "завтра я покончу с собой"],
        .preparatoryAct: ["я написал прощальную записку", "я коплю таблетки", "я собрала таблетки, чтобы умереть"],
        .pastAttempt: ["я пытался покончить с собой", "я наглотался таблеток", "я пыталась убить себя"],
        .hopelessness: ["всем будет лучше без меня", "я обуза для всех", "в моей жизни нет смысла"],
        .notWantingToBeHere: ["я больше не хочу здесь быть", "не хочу больше существовать"],
        .selfInjury: ["я режу себя", "я хочу причинить себе боль", "я наношу себе порезы"],
        .methodQuestion: ["какая смертельная доза парацетамола", "сколько снотворного нужно, чтобы умереть", "сколько таблеток нужно выпить, чтобы умереть"]
    ], negatives: [
        "этот подъём меня убивает", "я умираю после тренировки", "я убился на тренировке", "я пью таблетки каждое утро", "я ушибся на пробежке"
    ])

    private static let japanese = Row<SelfHarmForm>(language: "ja", cells: [
        .passiveWish: ["死んでしまいたい", "目が覚めなければいいのに", "死んだほうがましだ"],
        .activeWish: ["死にたい", "自殺したい", "消えたい"],
        .declaredIntent: ["自殺します", "死ぬつもりです", "死ぬことにした", "命を絶つつもりです"],
        .planWithMethod: ["首を吊るつもり", "橋から飛び降りる", "薬を全部まとめて飲むつもり"],
        .planWithTime: ["今夜死ぬつもり", "明日自殺する"],
        .preparatoryAct: ["遺書を書いた", "薬を貯めている", "睡眠薬を集めている"],
        .pastAttempt: ["自殺未遂をした", "薬を大量に飲んだ", "死のうとした"],
        .hopelessness: ["私なんていないほうがいい", "私がいなければみんな幸せになる", "生きている意味がない"],
        .notWantingToBeHere: ["もうこの世にいたくない", "この世から消えたい"],
        .selfInjury: ["リストカットしてる", "自分を傷つけたい", "腕を切っている"],
        .methodQuestion: ["致死量はどれくらい", "睡眠薬を何錠飲めば死ねる", "アセトアミノフェンの致死量"]
    ], negatives: [
        "死にそう", "死ぬほど疲れた", "この坂は殺人的", "毎朝薬を飲んでいる", "足を怪我した"
    ])

    private static let korean = Row<SelfHarmForm>(language: "ko", cells: [
        .passiveWish: ["차라리 죽었으면 좋겠어", "자고 일어나지 않았으면 좋겠어", "그냥 죽어버렸으면"],
        .activeWish: ["죽고 싶어", "자살하고 싶어", "내 목숨을 끊고 싶어"],
        .declaredIntent: ["자살할 거야", "스스로 목숨을 끊을 거야", "자살하기로 했어"],
        .planWithMethod: ["목을 매달 거야", "다리에서 뛰어내릴 거야", "약을 한꺼번에 다 먹을 거야"],
        .planWithTime: ["오늘 밤 자살할 거야", "내일 목숨을 끊을 거야"],
        .preparatoryAct: ["유서를 썼어", "수면제를 모으고 있어", "약을 모아두고 있어"],
        .pastAttempt: ["자살 시도를 했어", "약을 너무 많이 먹었어", "죽으려고 했어"],
        .hopelessness: ["내가 없으면 다들 더 나을 거야", "나는 모두에게 짐이야", "사는 게 의미가 없어"],
        .notWantingToBeHere: ["이 세상에 더 이상 있고 싶지 않아", "사라지고 싶어"],
        .selfInjury: ["자해하고 있어", "나를 해치고 싶어", "칼로 팔을 긋고 있어"],
        .methodQuestion: ["타이레놀 치사량이 얼마야", "수면제를 몇 알 먹으면 죽어", "약을 얼마나 먹어야 죽어"]
    ], negatives: [
        "죽겠다", "죽을 것 같아", "이 언덕 때문에 죽겠어", "매일 아침 약을 먹어", "발목을 다쳤어"
    ])

    private static let chinese = Row<SelfHarmForm>(language: "zh-Hans", cells: [
        .passiveWish: ["我宁愿死了", "希望睡着了就再也不醒来", "真希望自己死了"],
        .activeWish: ["我想死", "我想自杀", "我想结束自己的生命"],
        .declaredIntent: ["我要自杀", "我会杀了自己", "我要去死", "我打算自杀"],
        .planWithMethod: ["我要上吊", "我要从桥上跳下去", "我要把所有的药一次吃完"],
        .planWithTime: ["今晚我就自杀", "明天我就去死"],
        .preparatoryAct: ["我写好了遗书", "我一直在攒安眠药", "我在存药"],
        .pastAttempt: ["我自杀过", "我吃了太多药", "我试过自杀"],
        .hopelessness: ["没有我大家会更好", "我是大家的负担", "活着没有意义"],
        .notWantingToBeHere: ["我不想再待在这个世界上了", "我不想活在这个世界上"],
        .selfInjury: ["我在割自己", "我想伤害自己", "我故意伤害自己"],
        .methodQuestion: ["扑热息痛的致死量是多少", "吃多少安眠药会死", "吃多少片药能死"]
    ], negatives: [
        "累死了", "这个坡要了我的命", "我每天早上吃药", "笑死我了", "我不想活动", "我扭伤了脚踝"
    ])

    private static let arabic = Row<SelfHarmForm>(language: "ar", cells: [
        .passiveWish: ["أتمنى لو كنت ميتا", "أتمنى أن أنام ولا أستيقظ", "ليتني مت"],
        .activeWish: ["أريد أن أموت", "أريد أن أقتل نفسي", "أريد الانتحار"],
        .declaredIntent: ["سأقتل نفسي", "سوف أنتحر", "سأنهي حياتي"],
        .planWithMethod: ["سأشنق نفسي", "سأقفز من الجسر", "سآخذ كل حبوبي مرة واحدة"],
        .planWithTime: ["الليلة سأقتل نفسي", "غدا سأنتحر"],
        .preparatoryAct: ["كتبت رسالة وداع", "أجمع الحبوب لأنتحر", "أخزن الحبوب"],
        .pastAttempt: ["حاولت الانتحار", "حاولت قتل نفسي", "أخذت جرعة زائدة"],
        .hopelessness: ["الجميع سيكونون أفضل بدوني", "أنا عبء على الجميع", "لا معنى لحياتي"],
        .notWantingToBeHere: ["لا أريد أن أكون هنا بعد الآن", "لم أعد أريد أن أكون موجودا"],
        .selfInjury: ["أجرح نفسي", "أريد أن أؤذي نفسي", "أؤذي نفسي عمدا"],
        .methodQuestion: ["ما هي الجرعة القاتلة من الباراسيتامول", "كم حبة منومة تقتل", "كم حبة أحتاج لأموت"]
    ], negatives: [
        "هذا التمرين يقتلني", "أنا ميت من التعب", "آخذ دوائي كل صباح", "أصبت كاحلي"
    ])
}
