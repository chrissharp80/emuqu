@testable import Emuqu
import XCTest

/// A scrubbed sentence must never come back as its own opposite.
///
/// The guard matches a term and replaces the whole sentence, so it cannot
/// tell "There's no sign of overtraining" from "You're overtrained". Several
/// replacement sentences used to assert a finding — accumulated stress,
/// heavier training than usual, numbers outside the usual range, a notable
/// pattern, a reason to see a professional — so a reassuring answer reached
/// the user, in every language, as an alarming one. Every deflection now
/// asserts nothing about the user's state, which is true whichever way the
/// original sentence pointed.
final class CoachVoiceGuardNegationTests: XCTestCase {
    /// Fragments of the old replacement sentences, each a claim about the
    /// user that the model had not made.
    private static let assertedFindings = [
        "accumulated stress", "heavier than usual", "outside your usual range",
        "notable pattern", "Worth checking", "not symptoms of any condition",
        "often associated with that pattern"
    ]

    /// Sentences that deny the regulated term, in several shipped languages,
    /// each with an affirmative sentence that trips the same rule.
    private static let negatedAndAffirmed: [(negated: String, affirmed: String)] = [
        ("There's no sign of overtraining.", "You are overtrained."),
        ("You're not overtrained — your HRV is stable.", "This is overtraining."),
        ("There's no injury risk from this week's load.", "Your injury risk is elevated."),
        ("You're not in a danger zone.", "You are in the danger zone."),
        ("You don't need to see a doctor about this.", "You should see a doctor about this."),
        ("You are definitely not sick.", "You are definitely sick."),
        ("This doesn't look like a diagnosis of anything.", "My diagnosis is that you are run down."),
        ("These are not symptoms of a disease.", "These are symptoms of a disease."),
        ("Es gibt keine Anzeichen von Übertraining.", "Das ist Übertraining."),
        ("Il n'y a aucun signe de surentraînement.", "C'est du surentraînement."),
        ("No hay señales de sobreentrenamiento.", "Esto es sobreentrenamiento."),
        ("Det finns inga tecken på överträning.", "Det här är överträning."),
        ("Это не перетренированность.", "У вас перетренированность."),
        ("オーバートレーニングの兆候はありません。", "オーバートレーニングです。"),
        ("没有过度训练的迹象。", "这是过度训练。"),
        ("과훈련의 징후는 없습니다.", "과훈련입니다."),
        ("Du behöver inte kontakta läkare.", "Kontakta läkare."),
        ("Sie müssen keinen Arzt aufsuchen.", "Bitte einen Arzt aufsuchen.")
    ]

    func testNegatedSentencesAreNotTurnedIntoTheirOpposite() {
        for pair in Self.negatedAndAffirmed {
            let negated = CoachVoiceGuard.scrub(pair.negated)
            XCTAssertTrue(negated.didIntercept, "the term is still out of scope when denied: \(pair.negated)")
            for finding in Self.assertedFindings {
                XCTAssertFalse(
                    negated.scrubbed.localizedCaseInsensitiveContains(finding),
                    "'\(pair.negated)' was turned into a finding: \(negated.scrubbed)"
                )
            }
        }
    }

    /// The replacement does not depend on which way the sentence pointed, so
    /// a denial and an assertion of the same term read the same.
    func testADenialAndAnAssertionGetTheSameNeutralLine() {
        for pair in Self.negatedAndAffirmed {
            XCTAssertEqual(
                CoachVoiceGuard.scrub(pair.negated).scrubbed,
                CoachVoiceGuard.scrub(pair.affirmed).scrubbed,
                "\(pair.negated) / \(pair.affirmed)"
            )
        }
    }

    func testNoDeflectionAssertsAFinding() {
        for (concept, deflection) in CoachVoiceGuard.deflections {
            for finding in Self.assertedFindings {
                XCTAssertFalse(
                    deflection.localizedCaseInsensitiveContains(finding),
                    "Deflection for \(concept) asserts a finding: \(deflection)"
                )
            }
        }
    }

    /// The scrubbed reply is shown and spoken in the user's language, so every
    /// shipped translation of every deflection must exist and must itself pass
    /// the guard.
    func testEveryTranslatedDeflectionIsPresentAndClean() {
        var tablesRead = 0
        for language in Bundle.main.localizations where language != "Base" && language != "en" {
            guard let path = Bundle.main.path(
                forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language
            ), let strings = NSDictionary(contentsOfFile: path) as? [String: String] else { continue }
            tablesRead += 1
            for english in Set(CoachVoiceGuard.deflections.values) {
                guard let translated = strings[english] else {
                    XCTFail("\(language): no translation for deflection '\(english)'")
                    continue
                }
                XCTAssertFalse(
                    CoachVoiceGuard.containsProhibitedLanguage(translated),
                    "\(language): deflection trips the guard: \(translated)"
                )
            }
        }
        XCTAssertGreaterThanOrEqual(tablesRead, 16, "the compiled string tables were not found")
    }
}
