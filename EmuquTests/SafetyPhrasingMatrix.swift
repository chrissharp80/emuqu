@testable import Emuqu
import Foundation

/// Every safety guard that claims to cover the app's seventeen languages,
/// written out as a full grid instead of a sample: one row per language, one
/// column per form the guard exists to catch, and at least one natural
/// phrasing in every cell. `SafetyPhrasingMatrixTests` fails on an empty cell,
/// so a language or a form cannot be skipped quietly, and on any phrasing the
/// guard misses.
///
/// The self-harm columns are the forms the Columbia Suicide Severity Rating
/// Scale and safe-messaging guidance screen for. The input-guard columns are
/// the concepts `MedicalQueryGuard.classify` answers with a canned reply. The
/// static-copy columns are `MedicalTermLexicon.neverInStaticCopy`, the claims
/// the copy linter fails on in every locale.
///
/// Each row also carries training talk that borrows the same words ("this
/// hill is killing me", "das Training bringt mich um"), which must not get
/// the reply.
enum SafetyPhrasingMatrix {
    /// The app's languages, by catalogue code.
    static let languages = [
        "en", "ar", "da", "de", "es", "fi", "fr", "is", "it", "ja", "ko", "nb", "nl", "pt-BR", "ru", "sv", "zh-Hans"
    ]

    /// One language's row of the grid.
    struct Row<Column: Hashable & CaseIterable & Sendable>: Sendable {
        let language: String
        let cells: [Column: [String]]
        let negatives: [String]

        /// Every phrasing in the row, with the column it fills.
        var phrasings: [(column: Column, text: String)] {
            cells.flatMap { cell in cell.value.map { (column: cell.key, text: $0) } }
        }
    }

    /// What someone at risk says, by C-SSRS and safe-messaging form.
    enum SelfHarmForm: String, CaseIterable, Sendable {
        case passiveWish, activeWish, declaredIntent, planWithMethod, planWithTime
        case preparatoryAct, pastAttempt, hopelessness, notWantingToBeHere, selfInjury, methodQuestion
    }

    /// What the input guard answers with the symptom, injury or rhythm reply.
    enum InputForm: String, CaseIterable, Sendable {
        case chestPain, breathlessness, fainting, severeSymptom, heartAttack, stroke
        case injury, atrialFibrillation, irregularHeartbeat, dangerQuestion

        /// The reply family the guard must pick for this form.
        var trigger: MedicalQueryGuard.Trigger {
            switch self {
            case .injury: return .injury
            case .atrialFibrillation, .irregularHeartbeat: return .rhythm
            default: return .symptom
            }
        }
    }

    /// A claim the app's copy may never make, by `neverInStaticCopy` concept id.
    enum StaticClaim: String, CaseIterable, Sendable {
        case atrialFibrillation = "atrial-fibrillation", arrhythmia, namedCardiacCondition = "named-cardiac-condition"
        case acuteCardiacEvent = "acute-cardiac-event", neurovascularEvent = "neurovascular-event"
        case regulatoryClearance = "regulatory-clearance", cure, prescription, treatmentClaim = "treatment-claim"
        case speculativeDiagnosis = "speculative-diagnosis", pathology, clinicalPhysiologyLabels = "clinical-physiology-labels"
        case diagnosis, injuryRisk = "injury-risk", overtraining
    }

    static let selfHarmRows: [Row<SelfHarmForm>] = selfHarmWestern + selfHarmNordic + selfHarmOther
    static let inputRows: [Row<InputForm>] = inputWestern + inputNordic + inputOther
    static let staticClaimRows: [Row<StaticClaim>] = staticClaimWestern + staticClaimNordic + staticClaimOther
}
