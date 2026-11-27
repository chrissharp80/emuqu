@testable import Emuqu
import Foundation

// What the output guard rewrites when the model says it, for the concepts
// only the output side scrubs: risk-zone framing, a medical referral, a
// symptom tied to a disease, a categorical autonomic state, certainty about
// the user's body, and a verdict a metric cannot support. The negatives are
// coaching the model may say in the same words.

extension SafetyPhrasingMatrix {
    static let outputClaimRows: [Row<OutputClaim>] = [
        row("en", ["This puts you in the danger zone.", "You're at high risk tonight."], ["You should see a doctor about this."],
            ["These are symptoms of a disease."], ["You're in clear parasympathetic dominance."], ["You are clearly exhausted."],
            ["HRV is the gold standard for recovery.", "Your HRV is an early warning system for illness."],
            negatives: ["Your load is within your usual range.", "Make tomorrow a true recovery day."]),
        row("de", ["Du bist in der Gefahrenzone.", "Das ist ein hohes Risiko."], ["Du solltest einen Arzt aufsuchen."],
            ["Das sind Symptome einer Krankheit."], ["Du zeigst eine klare parasympathische Dominanz."], ["Du bist eindeutig erschöpft."],
            ["HRV ist der Goldstandard für die Erholung."], negatives: ["Plane echte Erholung ein.", "Deine Belastung liegt im üblichen Bereich."]),
        row("fr", ["Vous êtes dans la zone dangereuse."], ["Vous devriez consulter un médecin."], ["Ce sont des symptômes d'une maladie."],
            ["Vous montrez une dominance parasympathique nette."], ["Vous êtes clairement épuisé.", "Tu es clairement épuisé."],
            ["La VFC est l'étalon-or de la récupération."], negatives: ["Ta charge reste dans ta plage habituelle.", "Une journée facile aide."]),
        row("es", ["Estás en la zona de peligro."], ["Deberías consultar a un médico."], ["Son síntomas de una enfermedad."],
            ["Muestras una dominancia parasimpática clara."], ["Estás claramente agotado."], ["La VFC es el estándar de oro."],
            negatives: ["Tu carga está en tu rango habitual.", "Mañana toca un día suave."]),
        row("pt-BR", ["Você está na zona de perigo."], ["Você deveria procurar um médico."], ["Esses são sintomas de uma doença."],
            ["Você mostra uma dominância parassimpática clara."], ["Você está claramente exausto."], ["A VFC é o padrão-ouro da recuperação."],
            negatives: ["Sua carga está na faixa habitual.", "Amanhã é dia de treino leve."]),
        row("it", ["Sei nella zona di pericolo."], ["Dovresti consultare un medico."], ["Sono sintomi di una malattia."],
            ["Mostri una dominanza parasimpatica netta."], ["Sei chiaramente esausto."], ["L'HRV è lo standard aureo del recupero."],
            negatives: ["Il carico è nel tuo intervallo abituale.", "Domani una giornata facile."]),
        row("nl", ["Je zit in de gevarenzone."], ["Je moet een arts raadplegen."], ["Dit zijn symptomen van een ziekte."],
            ["Je vertoont een duidelijke parasympathische dominantie."], ["Je bent duidelijk uitgeput."], ["HRV is de gouden standaard voor herstel."],
            negatives: ["Plan echt herstel in.", "Je belasting ligt binnen je gebruikelijke bereik."]),
        row("da", ["Du er i farezonen."], ["Du bør søge læge."], ["Det er symptomer på sygdom."], ["Du viser tydelig parasympatisk dominans."],
            ["Du er tydeligvis udmattet."], ["HRV er guldstandarden for restitution."], negatives: ["Din belastning er inden for dit normale område.", "Tag en rolig dag."]),
        row("nb", ["Du er i faresonen."], ["Du bør kontakte lege."], ["Dette er symptomer på sykdom."], ["Du viser tydelig parasympatisk dominans."],
            ["Du er helt klart utslitt."], ["HRV er gullstandarden for restitusjon."], negatives: ["Belastningen din er innenfor det vanlige.", "Ta en rolig dag."]),
        row("sv", ["Du är i riskzonen."], ["Du bör kontakta läkare."], ["Det är symtom på sjukdom."], ["Du visar tydlig parasympatisk dominans."],
            ["Du är tydligt utmattad."], ["HRV är guldstandarden för återhämtning."], negatives: ["Din belastning ligger inom ditt vanliga intervall.", "Ta en lugn dag."]),
        row("fi", ["Olet vaaravyöhykkeellä."], ["Ota yhteyttä lääkäriin."], ["Nämä ovat sairauden oireita."],
            ["Sinulla on selvä parasympaattinen hallitsevuus."], ["Olet selvästi uupunut."], ["HRV on palautumisen kultainen standardi."],
            negatives: ["Olet selvästi oman normaalisi yläpuolella.", "Kuormasi on tavallisella alueella."]),
        row("is", ["Þú ert á hættusvæði."], ["Leitaðu til læknis."], ["Þetta eru einkenni sjúkdóms."], ["Þú sýnir skýr parasympatísk yfirráð."],
            ["Þú ert greinilega úrvinda."], ["HRV er gullstaðallinn fyrir endurheimt."], negatives: ["Álagið er innan venjulegs bils.", "Taktu rólegan dag."]),
        row("ru", ["Вы в опасной зоне."], ["Обратитесь к врачу."], ["Это симптомы болезни."], ["У вас явное парасимпатическое преобладание."],
            ["Вы явно истощены."], ["ВСР — золотой стандарт восстановления."], negatives: ["Вы явно сохранили темп.", "Нагрузка в вашем обычном диапазоне."]),
        row("ja", ["危険ゾーンに入っています。"], ["医師に相談してください。"], ["これは病気の症状です。"], ["明らかな副交感神経優位です。"],
            ["あなたは明らかに疲れ切っています。"], ["HRVは回復のゴールドスタンダードです。"], negatives: ["負荷はいつもの範囲内です。", "明日は軽めにしましょう。"]),
        row("ko", ["위험 구간에 있습니다."], ["의사와 상담하세요."], ["이것은 질병의 증상입니다."], ["명확한 부교감 우세 상태입니다."],
            ["당신은 분명히 지쳐 있습니다."], ["HRV는 회복의 골드 스탠다드입니다."], negatives: ["부하는 평소 범위 안에 있습니다.", "내일은 가볍게 하세요."]),
        row("zh-Hans", ["你处于危险区。"], ["请咨询医生。"], ["这些是疾病症状。"], ["你表现出明显的副交感优势。"], ["你显然已经筋疲力尽。"],
            ["HRV是恢复的金标准。"], negatives: ["你的负荷在平常范围内。", "明天轻松一点。"]),
        row("ar", ["أنت في منطقة الخطر."], ["استشر الطبيب."], ["هذه أعراض مرض."], ["لديك هيمنة واضحة للجهاز اللاودي."], ["أنت بالتأكيد مرهق."],
            ["تقلب معدل ضربات القلب هو المعيار الذهبي للتعافي."], negatives: ["حملك ضمن نطاقك المعتاد.", "خذ يوما سهلا غدا."])
    ]

    /// One phrasing list per `OutputClaim` case, in order, so each row reads as one line per language.
    private static func row(_ language: String, _ columns: [String]..., negatives: [String]) -> Row<OutputClaim> {
        Row(language: language, cells: Dictionary(uniqueKeysWithValues: zip(OutputClaim.allCases, columns)), negatives: negatives)
    }
}
