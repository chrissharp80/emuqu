@testable import Emuqu
import Foundation

// Claims the copy linter must fail in Danish, Norwegian Bokmål, Swedish,
// Finnish and Icelandic.

extension SafetyPhrasingMatrix {
    static let staticClaimNordic: [Row<StaticClaim>] = [danish, norwegian, swedish, finnish, icelandic]

    private static let danish = Row<StaticClaim>(language: "da", cells: [
        .atrialFibrillation: ["Emuqu registrerer atrieflimren."],
        .arrhythmia: ["Advarer dig om hjerterytmeforstyrrelser."],
        .namedCardiacCondition: ["Registrerer forhøjet blodtryk ud fra din HRV.", "Opdager bradykardi om natten."],
        .acuteCardiacEvent: ["Advarer dig før et hjerteanfald."],
        .neurovascularEvent: ["Opdager de første tegn på en blodprop."],
        .regulatoryClearance: ["Godkendt af FDA.", "FDA-godkendt."],
        .cure: ["Helbreder sygdomme."],
        .prescription: ["Udskriver medicin, når du har brug for det.", "Kun på recept."],
        .treatmentClaim: ["Behandler din sygdom."],
        .speculativeDiagnosis: ["Du har måske søvnapnø."],
        .pathology: ["Viser hjertepatologi."],
        .clinicalPhysiologyLabels: ["Viser autonom rigiditet."],
        .diagnosis: ["Diagnosticerer hjertesygdomme."],
        .injuryRisk: ["Forudsiger din skadesrisiko."],
        .overtraining: ["Opdager overtræning, før den sker."]
    ], negatives: ["Din plan foreskriver en rolig tur i dag.", "En opskrift på havregrød.", "Avanceret diagnosticering"])

    private static let norwegian = Row<StaticClaim>(language: "nb", cells: [
        .atrialFibrillation: ["Emuqu oppdager atrieflimmer."],
        .arrhythmia: ["Varsler deg om hjerterytmeforstyrrelser."],
        .namedCardiacCondition: ["Oppdager høyt blodtrykk fra HRV-en din.", "Oppdager bradykardi om natten."],
        .acuteCardiacEvent: ["Varsler deg før et hjerteinfarkt."],
        .neurovascularEvent: ["Oppdager de første tegnene på hjerneslag."],
        .regulatoryClearance: ["Godkjent av FDA.", "FDA-godkjent."],
        .cure: ["Helbreder sykdom."],
        .prescription: ["Skriver ut medisiner når du trenger det.", "Kun på resept."],
        .treatmentClaim: ["Behandler sykdommen din."],
        .speculativeDiagnosis: ["Du har kanskje søvnapné."],
        .pathology: ["Viser hjertepatologi."],
        .clinicalPhysiologyLabels: ["Viser autonom rigiditet."],
        .diagnosis: ["Diagnostiserer hjertesykdom."],
        .injuryRisk: ["Forutsier skaderisikoen din."],
        .overtraining: ["Oppdager overtrening før det skjer."]
    ], negatives: ["Planen din foreskriver en rolig tur i dag.", "En oppskrift på havregrøt."])

    private static let swedish = Row<StaticClaim>(language: "sv", cells: [
        .atrialFibrillation: ["Emuqu upptäcker förmaksflimmer."],
        .arrhythmia: ["Varnar dig för hjärtrytmrubbningar."],
        .namedCardiacCondition: ["Upptäcker högt blodtryck utifrån din HRV.", "Upptäcker bradykardi under natten."],
        .acuteCardiacEvent: ["Varnar dig före en hjärtinfarkt."],
        .neurovascularEvent: ["Upptäcker de första tecknen på slaganfall."],
        .regulatoryClearance: ["Godkänd av FDA.", "FDA-godkänd."],
        .cure: ["Botar sjukdomar."],
        .prescription: ["Skriver ut läkemedel när du behöver det.", "Receptbelagd."],
        .treatmentClaim: ["Behandlar din sjukdom."],
        .speculativeDiagnosis: ["Du har kanske sömnapné."],
        .pathology: ["Visar hjärtpatologi."],
        .clinicalPhysiologyLabels: ["Visar autonom rigiditet."],
        .diagnosis: ["Diagnostiserar hjärtsjukdomar."],
        .injuryRisk: ["Förutsäger din skaderisk."],
        .overtraining: ["Upptäcker överträning innan den inträffar."]
    ], negatives: ["Din plan föreskriver ett lugnt pass i dag.", "Ett recept på havregrynsgröt."])

    private static let finnish = Row<StaticClaim>(language: "fi", cells: [
        .atrialFibrillation: ["Emuqu tunnistaa eteisvärinän."],
        .arrhythmia: ["Varoittaa rytmihäiriöistä."],
        .namedCardiacCondition: ["Tunnistaa korkean verenpaineen HRV:stäsi.", "Havaitsee bradykardian yöllä."],
        .acuteCardiacEvent: ["Varoittaa ennen sydäninfarktia."],
        .neurovascularEvent: ["Tunnistaa aivohalvauksen ensimmäiset merkit."],
        .regulatoryClearance: ["FDA:n hyväksymä.", "FDA-hyväksytty."],
        .cure: ["Parantaa sairauksia."],
        .prescription: ["Määrää lääkkeitä, kun tarvitset niitä.", "Reseptilääke."],
        .treatmentClaim: ["Hoitaa sairauttasi."],
        .speculativeDiagnosis: ["Sinulla saattaa olla uniapnea."],
        .pathology: ["Näyttää sydämen patologian."],
        .clinicalPhysiologyLabels: ["Näyttää autonomisen jäykkyyden.", "Autonominen jäykkyys."],
        .diagnosis: ["Diagnosoi sydänsairaudet.", "Antaa diagnoosin."],
        .injuryRisk: ["Ennustaa loukkaantumisriskisi."],
        .overtraining: ["Tunnistaa ylikunnon ennen kuin se iskee."]
    ], negatives: ["Parantaa unesi laatua.", "Resepti kaurapuuroon."])

    private static let icelandic = Row<StaticClaim>(language: "is", cells: [
        .atrialFibrillation: ["Emuqu greinir gáttatif."],
        .arrhythmia: ["Varar þig við hjartsláttartruflunum."],
        .namedCardiacCondition: ["Greinir háþrýsting út frá HRV.", "Greinir hægslátt á nóttunni."],
        .acuteCardiacEvent: ["Varar þig við hjartaáfalli."],
        .neurovascularEvent: ["Greinir fyrstu merki heilablóðfalls."],
        .regulatoryClearance: ["Samþykkt af FDA.", "FDA-samþykkt."],
        .cure: ["Læknar sjúkdóma."],
        .prescription: ["Ávísar lyfjum þegar þú þarft á þeim að halda.", "Lyfseðilsskylt."],
        .treatmentClaim: ["Meðhöndlar sjúkdóminn þinn."],
        .speculativeDiagnosis: ["Þú gætir verið með kæfisvefn."],
        .pathology: ["Sýnir meinafræði hjartans."],
        .clinicalPhysiologyLabels: ["Sýnir ósjálfráða stífni."],
        .diagnosis: ["Veitir sjúkdómsgreiningu."],
        .injuryRisk: ["Spáir fyrir um meiðslahættu."],
        .overtraining: ["Greinir ofþjálfun áður en hún verður."]
    ], negatives: ["Greining lokið.", "Uppskrift að hafragraut.", "Hratt — þú gætir verið með svefnskuld"])
}
