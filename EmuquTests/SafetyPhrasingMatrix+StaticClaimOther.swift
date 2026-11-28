@testable import Emuqu
import Foundation

// Claims the copy linter must fail in Russian, Japanese, Korean, Simplified
// Chinese and Arabic.

extension SafetyPhrasingMatrix {
    static let staticClaimOther: [Row<StaticClaim>] = [russian, japanese, korean, chinese, arabic]

    private static let russian = Row<StaticClaim>(language: "ru", cells: [
        .atrialFibrillation: ["Emuqu обнаруживает фибрилляцию предсердий."],
        .arrhythmia: ["Предупреждает об аритмии."],
        .namedCardiacCondition: ["Выявляет гипертонию по вашей ВСР.", "Выявляет брадикардию ночью."],
        .acuteCardiacEvent: ["Предупреждает об инфаркте."],
        .neurovascularEvent: ["Распознаёт первые признаки инсульта."],
        .regulatoryClearance: ["Одобрено FDA.", "Одобрен FDA."],
        .cure: ["Вылечит бессонницу.", "Излечение болезней."],
        .prescription: ["Выписывает лекарства, когда они нужны.", "Отпускается по рецепту."],
        .treatmentClaim: ["Лечит ваше заболевание."],
        .speculativeDiagnosis: ["У вас, возможно, апноэ сна."],
        .pathology: ["Выявляет патологию сердца."],
        .clinicalPhysiologyLabels: ["Показывает вегетативную ригидность."],
        .diagnosis: ["Диагностирует болезни сердца.", "Ставит диагноз."],
        .injuryRisk: ["Предсказывает риск травмы."],
        .overtraining: ["Выявляет перетренированность до того, как она наступит."]
    ], negatives: ["Рецепт овсяной каши.", "Ваш план предписывает лёгкую пробежку."])

    private static let japanese = Row<StaticClaim>(language: "ja", cells: [
        .atrialFibrillation: ["Emuquは心房細動を検出します。"],
        .arrhythmia: ["不整脈をお知らせします。"],
        .namedCardiacCondition: ["高血圧を検出します。", "夜間の徐脈を検出します。"],
        .acuteCardiacEvent: ["心筋梗塞の前に警告します。", "心臓発作を予測します。"],
        .neurovascularEvent: ["脳卒中の初期兆候を検出します。"],
        .regulatoryClearance: ["FDA承認済み。", "FDAの承認を取得しています。"],
        .cure: ["病気を治します。", "不眠症を治癒します。"],
        .prescription: ["必要なときに薬を処方します。"],
        .treatmentClaim: ["あなたの病気を治療します。"],
        .speculativeDiagnosis: ["睡眠時無呼吸症候群の可能性があります。", "病気の可能性があります。"],
        .pathology: ["心臓の病理を示します。"],
        .clinicalPhysiologyLabels: ["自律神経硬直を示します。"],
        .diagnosis: ["心臓病を診断します。"],
        .injuryRisk: ["怪我のリスクを予測します。"],
        .overtraining: ["オーバートレーニングを検出します。"]
    ], negatives: ["診断ログを書き出す", "回復に気を配りましょう。"])

    private static let korean = Row<StaticClaim>(language: "ko", cells: [
        .atrialFibrillation: ["Emuqu는 심방세동을 감지합니다."],
        .arrhythmia: ["부정맥을 알려 줍니다."],
        .namedCardiacCondition: ["고혈압을 감지합니다.", "밤사이 서맥을 감지합니다."],
        .acuteCardiacEvent: ["심근경색 전에 경고합니다.", "심장마비를 예측합니다."],
        .neurovascularEvent: ["뇌졸중의 초기 징후를 감지합니다."],
        .regulatoryClearance: ["FDA 승인을 받았습니다.", "FDA 승인 제품입니다."],
        .cure: ["질병을 완치합니다.", "병을 고쳐 줍니다."],
        .prescription: ["필요할 때 약을 처방합니다."],
        .treatmentClaim: ["질병을 치료합니다."],
        .speculativeDiagnosis: ["수면 무호흡 질환일 수 있습니다."],
        .pathology: ["심장 병리를 보여 줍니다."],
        .clinicalPhysiologyLabels: ["자율신경 경직을 보여 줍니다."],
        .diagnosis: ["심장 질환을 진단합니다."],
        .injuryRisk: ["부상 위험을 예측합니다."],
        .overtraining: ["과훈련을 감지합니다."]
    ], negatives: ["진단 로그 내보내기", "회복에 신경 쓰세요."])

    private static let chinese = Row<StaticClaim>(language: "zh-Hans", cells: [
        .atrialFibrillation: ["Emuqu 可检测心房颤动。"],
        .arrhythmia: ["提醒你心律失常。"],
        .namedCardiacCondition: ["检测高血压。", "夜间检测心动过缓。"],
        .acuteCardiacEvent: ["在心肌梗死前发出警告。", "预测心脏病发作。"],
        .neurovascularEvent: ["检测中风的早期迹象。"],
        .regulatoryClearance: ["获得FDA批准。", "经 FDA 批准。"],
        .cure: ["治愈疾病。", "治好失眠。"],
        .prescription: ["需要时为你开处方。"],
        .treatmentClaim: ["治疗你的疾病。"],
        .speculativeDiagnosis: ["你可能患有睡眠呼吸暂停。"],
        .pathology: ["显示心脏病理。"],
        .clinicalPhysiologyLabels: ["显示自主神经僵硬。"],
        .diagnosis: ["诊断心脏病。"],
        .injuryRisk: ["预测你的受伤风险。"],
        .overtraining: ["检测过度训练。"]
    ], negatives: ["导出诊断日志", "注意你的恢复。"])

    private static let arabic = Row<StaticClaim>(language: "ar", cells: [
        .atrialFibrillation: ["يكتشف Emuqu الرجفان الأذيني."],
        .arrhythmia: ["ينبهك إلى عدم انتظام ضربات القلب."],
        .namedCardiacCondition: ["يكتشف ارتفاع ضغط الدم.", "يكتشف بطء القلب أثناء الليل."],
        .acuteCardiacEvent: ["يحذرك قبل حدوث نوبة قلبية."],
        .neurovascularEvent: ["يكتشف العلامات المبكرة للسكتة الدماغية."],
        .regulatoryClearance: ["معتمد من إدارة الغذاء والدواء.", "حاصل على موافقة FDA."],
        .cure: ["يشفي من الأمراض.", "علاج نهائي للأرق."],
        .prescription: ["يصف لك الأدوية عند الحاجة.", "يتطلب وصفة طبية."],
        .treatmentClaim: ["علاج مرضك."],
        .speculativeDiagnosis: ["قد تكون مصابا بانقطاع النفس النومي."],
        .pathology: ["يظهر علم الأمراض القلبية."],
        .clinicalPhysiologyLabels: ["يظهر تصلب لاإرادي."],
        .diagnosis: ["يشخص أمراض القلب.", "تشخيص أمراض القلب."],
        .injuryRisk: ["يتنبأ بخطر الإصابة."],
        .overtraining: ["يكتشف الإفراط في التدريب."]
    ], negatives: ["تصدير سجل التشخيص", "اهتم بتعافيك."])
}
