@testable import Emuqu
import Foundation

// Claims the copy linter must fail in English, German, French, Spanish,
// Brazilian Portuguese, Italian and Dutch, written the way a translated
// marketing line or onboarding string would put them. The negatives are
// coaching copy that shares a word ("cura il recupero" is "look after your
// recovery", a "prescribed pace" is a plan).

extension SafetyPhrasingMatrix {
    static let staticClaimWestern: [Row<StaticClaim>] = [english, german, french, spanish, portuguese, italian, dutch]

    private static let english = Row<StaticClaim>(language: "en", cells: [
        .atrialFibrillation: ["Emuqu detects atrial fibrillation."],
        .arrhythmia: ["Alerts you to arrhythmias."],
        .namedCardiacCondition: ["Detects hypertension from your HRV.", "Spots bradycardia overnight."],
        .acuteCardiacEvent: ["Warns you before a heart attack."],
        .neurovascularEvent: ["Spots the early signs of a stroke.", "Detects blood clots."],
        .regulatoryClearance: ["FDA-cleared heart monitoring.", "Approved by the FDA."],
        .cure: ["Cures insomnia."],
        .prescription: ["Prescribes medication when you need it."],
        .treatmentClaim: ["Treats your condition."],
        .speculativeDiagnosis: ["You may have sleep apnea."],
        .pathology: ["Flags cardiac pathology."],
        .clinicalPhysiologyLabels: ["Shows autonomic rigidity."],
        .diagnosis: ["Diagnoses heart disease."],
        .injuryRisk: ["Predicts your injury risk."],
        .overtraining: ["Detects overtraining before it happens."]
    ], negatives: ["Your plan prescribes an easy run today.", "Stroke rate 32 per minute.", "Take care of your recovery."])

    private static let german = Row<StaticClaim>(language: "de", cells: [
        .atrialFibrillation: ["Emuqu erkennt Vorhofflimmern."],
        .arrhythmia: ["Warnt dich vor Herzrhythmusstörungen."],
        .namedCardiacCondition: ["Erkennt Bluthochdruck anhand deiner HRV.", "Erkennt eine Bradykardie über Nacht."],
        .acuteCardiacEvent: ["Warnt dich vor einem Herzinfarkt."],
        .neurovascularEvent: ["Erkennt frühe Anzeichen eines Schlaganfalls."],
        .regulatoryClearance: ["Von der FDA zugelassen.", "FDA-zugelassene Herzüberwachung.", "Von der FDA freigegeben."],
        .cure: ["Heilt deine Krankheit."],
        .prescription: ["Verschreibt Medikamente, wenn du sie brauchst."],
        .treatmentClaim: ["Behandelt deine Erkrankung."],
        .speculativeDiagnosis: ["Du hast möglicherweise eine Schlafapnoe."],
        .pathology: ["Zeigt kardiale Pathologie an."],
        .clinicalPhysiologyLabels: ["Zeigt autonome Starrheit."],
        .diagnosis: ["Diagnostiziert Herzkrankheiten."],
        .injuryRisk: ["Sagt dein Verletzungsrisiko voraus."],
        .overtraining: ["Erkennt Übertraining, bevor es passiert."]
    ], negatives: ["Dein Plan sieht heute einen lockeren Lauf vor.", "Achte auf deine Erholung."])

    private static let french = Row<StaticClaim>(language: "fr", cells: [
        .atrialFibrillation: ["Emuqu détecte la fibrillation auriculaire."],
        .arrhythmia: ["Vous alerte en cas d'arythmie."],
        .namedCardiacCondition: ["Détecte l'hypertension grâce à votre VFC.", "Repère la bradycardie pendant la nuit."],
        .acuteCardiacEvent: ["Vous prévient avant une crise cardiaque."],
        .neurovascularEvent: ["Repère les premiers signes d'un AVC.", "Détecte un accident vasculaire cérébral."],
        .regulatoryClearance: ["Approuvé par la FDA.", "Autorisé par la FDA."],
        .cure: ["Guérit l'insomnie.", "Guérit les maladies."],
        .prescription: ["Prescrit des médicaments quand vous en avez besoin.", "Délivre une ordonnance."],
        .treatmentClaim: ["Traite votre maladie."],
        .speculativeDiagnosis: ["Vous avez peut-être une apnée du sommeil."],
        .pathology: ["Signale une pathologie cardiaque."],
        .clinicalPhysiologyLabels: ["Montre une rigidité autonome."],
        .diagnosis: ["Diagnostique les maladies cardiaques."],
        .injuryRisk: ["Prédit votre risque de blessure."],
        .overtraining: ["Détecte le surentraînement avant qu'il n'arrive."]
    ], negatives: [
        "Votre plan prévoit une sortie facile.", "Prenez soin de votre récupération.",
        "L’app supprime les phrases contenant des affirmations diagnostiques."
    ])

    private static let spanish = Row<StaticClaim>(language: "es", cells: [
        .atrialFibrillation: ["Emuqu detecta la fibrilación auricular."],
        .arrhythmia: ["Te avisa de arritmias."],
        .namedCardiacCondition: ["Detecta la hipertensión a partir de tu VFC.", "Detecta la bradicardia por la noche."],
        .acuteCardiacEvent: ["Te avisa antes de un infarto."],
        .neurovascularEvent: ["Detecta los primeros signos de un ictus."],
        .regulatoryClearance: ["Aprobado por la FDA.", "Autorizado por la FDA."],
        .cure: ["Cura el insomnio.", "Cura enfermedades."],
        .prescription: ["Receta medicamentos cuando los necesitas.", "Emite una receta médica."],
        .treatmentClaim: ["Trata tu enfermedad."],
        .speculativeDiagnosis: ["Puede que tengas apnea del sueño."],
        .pathology: ["Señala una patología cardíaca."],
        .clinicalPhysiologyLabels: ["Muestra rigidez autónoma."],
        .diagnosis: ["Diagnostica enfermedades cardíacas."],
        .injuryRisk: ["Predice tu riesgo de lesión."],
        .overtraining: ["Detecta el sobreentrenamiento antes de que ocurra."]
    ], negatives: ["Tu plan prescribe un rodaje suave hoy.", "Una receta de batido de proteínas.", "Cuida tu recuperación."])

    private static let portuguese = Row<StaticClaim>(language: "pt-BR", cells: [
        .atrialFibrillation: ["O Emuqu detecta fibrilação atrial."],
        .arrhythmia: ["Avisa você sobre arritmias."],
        .namedCardiacCondition: ["Detecta hipertensão a partir da sua VFC.", "Detecta bradicardia durante a noite."],
        .acuteCardiacEvent: ["Avisa antes de um infarto."],
        .neurovascularEvent: ["Detecta os primeiros sinais de um AVC."],
        .regulatoryClearance: ["Aprovado pela FDA.", "Autorizado pela FDA."],
        .cure: ["Cura a insônia.", "Cura doenças."],
        .prescription: ["Receita medicamentos quando você precisa.", "Emite receita médica."],
        .treatmentClaim: ["Trata sua doença."],
        .speculativeDiagnosis: ["Você pode estar com apneia do sono."],
        .pathology: ["Aponta uma patologia cardíaca."],
        .clinicalPhysiologyLabels: ["Mostra rigidez autonômica."],
        .diagnosis: ["Diagnostica doenças cardíacas."],
        .injuryRisk: ["Prevê seu risco de lesão."],
        .overtraining: ["Detecta o sobretreinamento antes que aconteça."]
    ], negatives: ["Uma receita de vitamina de banana.", "Cuide da sua recuperação."])

    private static let italian = Row<StaticClaim>(language: "it", cells: [
        .atrialFibrillation: ["Emuqu rileva la fibrillazione atriale."],
        .arrhythmia: ["Ti avvisa in caso di aritmie."],
        .namedCardiacCondition: ["Rileva l'ipertensione dalla tua HRV.", "Rileva la bradicardia durante la notte."],
        .acuteCardiacEvent: ["Ti avvisa prima di un infarto."],
        .neurovascularEvent: ["Rileva i primi segni di un ictus."],
        .regulatoryClearance: ["Approvato dalla FDA.", "Autorizzato dalla FDA."],
        .cure: ["Cura l'insonnia.", "Cura le malattie."],
        .prescription: ["Prescrive farmaci quando ne hai bisogno.", "Rilascia prescrizioni mediche."],
        .treatmentClaim: ["Cura la tua malattia."],
        .speculativeDiagnosis: ["Potresti avere un'apnea notturna."],
        .pathology: ["Segnala una patologia cardiaca."],
        .clinicalPhysiologyLabels: ["Mostra rigidità autonomica."],
        .diagnosis: ["Diagnostica le malattie cardiache."],
        .injuryRisk: ["Prevede il tuo rischio di infortunio."],
        .overtraining: ["Rileva il sovrallenamento prima che accada."]
    ], negatives: ["Cura il tuo recupero.", "Prenditi cura di te.", "Il piano prescrive una corsa facile."])

    private static let dutch = Row<StaticClaim>(language: "nl", cells: [
        .atrialFibrillation: ["Emuqu detecteert boezemfibrilleren."],
        .arrhythmia: ["Waarschuwt je bij hartritmestoornissen."],
        .namedCardiacCondition: ["Detecteert hoge bloeddruk via je HRV.", "Herkent bradycardie 's nachts."],
        .acuteCardiacEvent: ["Waarschuwt je voor een hartaanval."],
        .neurovascularEvent: ["Herkent de eerste tekenen van een beroerte."],
        .regulatoryClearance: ["Goedgekeurd door de FDA.", "FDA-goedgekeurd."],
        .cure: ["Geneest je ziekte."],
        .prescription: ["Schrijft medicijnen voor wanneer je ze nodig hebt.", "Alleen op recept."],
        .treatmentClaim: ["Behandelt je aandoening."],
        .speculativeDiagnosis: ["Je hebt mogelijk slaapapneu."],
        .pathology: ["Signaleert cardiale pathologie."],
        .clinicalPhysiologyLabels: ["Toont autonome rigiditeit."],
        .diagnosis: ["Stelt een diagnose van hartziekten."],
        .injuryRisk: ["Voorspelt je blessurerisico."],
        .overtraining: ["Detecteert overtraining voordat het gebeurt."]
    ], negatives: ["Je schema schrijft vandaag een rustige duurloop voor.", "Een recept voor havermout."])
}
