@testable import Emuqu
import Foundation

// The app's own disclaimer, and the model repeating it: a clearance, a
// diagnosis or a treatment named in order to deny it. Each cell must pass the
// output guard and the copy linter's patterns. The negatives are the opposite
// check: a real claim in the same sentence as a negation of something else,
// which must still be caught.

extension SafetyPhrasingMatrix {
    static let disclaimerRows: [Row<DisclaimedClaim>] = [
        row("en", ["Emuqu is not FDA-approved.", "It isn't FDA-cleared or certified by any regulator.", "Not approved by the FDA."],
            ["Emuqu does not diagnose any condition.", "Not medical advice, diagnosis, or treatment.", "I can't diagnose that."],
            ["It doesn't treat your condition."],
            ["Emuqu isn't a medical device, but it is FDA-cleared.", "This is not a workout plan and it diagnoses heart disease."]),
        row("de", ["Emuqu ist nicht von der FDA zugelassen.", "Es ist weder von der FDA zugelassen noch zertifiziert."],
            ["Emuqu diagnostiziert keine Erkrankungen.", "Emuqu stellt keine Diagnose."], ["Emuqu behandelt deine Erkrankung nicht."],
            ["Emuqu ist kein Medizinprodukt, aber von der FDA zugelassen."]),
        row("fr", ["Emuqu n'est pas approuvé par la FDA.", "Il n'est ni approuvé ni autorisé par la FDA."],
            ["Emuqu ne diagnostique aucune maladie."], ["Emuqu ne peut pas traiter votre maladie."],
            ["Emuqu n'est pas un dispositif médical, mais il est approuvé par la FDA."]),
        row("es", ["Emuqu no está aprobado por la FDA.", "No ha sido aprobado ni autorizado por la FDA."],
            ["Emuqu no diagnostica enfermedades cardíacas."], ["Emuqu no puede tratar tu enfermedad."],
            ["Emuqu no es un dispositivo médico, pero está aprobado por la FDA."]),
        row("pt-BR", ["O Emuqu não é aprovado pela FDA."], ["O Emuqu não diagnostica doenças."], ["O Emuqu não pode tratar sua doença."],
            ["O Emuqu não é um dispositivo médico, mas é aprovado pela FDA."]),
        row("it", ["Emuqu non è approvato dalla FDA."], ["Emuqu non diagnostica malattie."], ["Emuqu non può curare la tua malattia."],
            ["Emuqu non è un dispositivo medico, ma è approvato dalla FDA."]),
        row("nl", ["Emuqu is niet goedgekeurd door de FDA."], ["Emuqu stelt geen diagnose."], ["Emuqu behandelt je aandoening niet."],
            ["Emuqu is geen medisch hulpmiddel, maar wel goedgekeurd door de FDA."]),
        row("da", ["Emuqu er ikke godkendt af FDA."], ["Emuqu diagnosticerer ikke sygdomme."], ["Emuqu kan ikke behandle din sygdom."],
            ["Emuqu er ikke medicinsk udstyr, men er godkendt af FDA."]),
        row("nb", ["Emuqu er ikke godkjent av FDA."], ["Emuqu diagnostiserer ikke sykdom."], ["Emuqu kan ikke behandle sykdommen din."],
            ["Emuqu er ikke medisinsk utstyr, men er godkjent av FDA."]),
        row("sv", ["Emuqu är inte godkänd av FDA."], ["Emuqu diagnostiserar inte sjukdomar."], ["Emuqu kan inte behandla din sjukdom."],
            ["Emuqu är inte en medicinteknisk produkt, men är godkänd av FDA."]),
        row("fi", ["Emuqu ei ole FDA:n hyväksymä."], ["Emuqu ei diagnosoi sairauksia.", "Ei lääketieteellistä neuvontaa, diagnoosia tai hoitoa."],
            ["Emuqu ei voi hoitaa sairauttasi."], ["Emuqu ei ole lääkinnällinen laite, mutta se on FDA:n hyväksymä."]),
        row("is", ["Emuqu er ekki samþykkt af FDA."], ["Emuqu veitir ekki sjúkdómsgreiningu."], ["Emuqu getur ekki meðhöndlað sjúkdóminn þinn."],
            ["Emuqu er ekki lækningatæki, en er samþykkt af FDA."]),
        row("ru", ["Emuqu не одобрен FDA."], ["Emuqu не диагностирует болезни.", "Не является медицинской консультацией, диагнозом или лечением."],
            ["Emuqu не лечит ваше заболевание."], ["Emuqu не медицинское изделие, но одобрен FDA."]),
        row("ja", ["EmuquはFDAの承認を受けていません。", "FDAの承認・認可を受けておらず、認証もありません。"],
            ["Emuquは病気を診断しません。"], ["あなたの病気を治療するものではありません。"],
            ["Emuquは医療機器ではありませんが、FDA承認済みです。"]),
        row("ko", ["Emuqu는 FDA 승인을 받지 않았습니다."], ["Emuqu는 질환을 진단하지 않습니다."], ["질병을 치료하지 않습니다."],
            ["Emuqu는 의료기기가 아니지만 FDA 승인을 받았습니다."]),
        row("zh-Hans", ["Emuqu 未经 FDA 批准。"], ["Emuqu 不诊断任何疾病。"], ["Emuqu 不能治疗你的疾病。"],
            ["Emuqu 不是医疗设备，但获得FDA批准。"]),
        row("ar", ["Emuqu ليس معتمد من إدارة الغذاء والدواء."], ["Emuqu لا يشخص أمراض القلب."], ["Emuqu لا يقدم علاج مرضك."],
            ["Emuqu ليس جهازا طبيا لكن حاصل على موافقة FDA."])
    ]

    /// Arguments in `DisclaimedClaim` order; `stillClaims` are the negatives.
    private static func row(
        _ language: String, _ clearance: [String], _ diagnosis: [String], _ treatment: [String], _ stillClaims: [String]
    ) -> Row<DisclaimedClaim> {
        Row(language: language, cells: [.regulatoryClearance: clearance, .diagnosis: diagnosis, .treatmentClaim: treatment], negatives: stillClaims)
    }
}
