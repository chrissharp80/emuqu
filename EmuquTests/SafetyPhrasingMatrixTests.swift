@testable import Emuqu
import XCTest

/// Runs `SafetyPhrasingMatrix`: every cell of every guard's grid, in every
/// app language, and the training talk that must not trip it. Also pins the
/// two paths that could drop a crisis message before the guard answers it:
/// the voice echo checks and Flo being switched off.
@MainActor
final class SafetyPhrasingMatrixTests: XCTestCase {
    typealias Matrix = SafetyPhrasingMatrix

    override func setUp() async throws {
        try await super.setUp()
        pinEnglishLanguage()
    }

    // MARK: - The grid is complete

    func testEveryLanguageFillsEveryColumnOfEveryMatrix() {
        assertComplete(Matrix.selfHarmRows, name: "self-harm")
        assertComplete(Matrix.inputRows, name: "input guard")
        assertComplete(Matrix.staticClaimRows, name: "static copy")
    }

    /// The static-copy columns are exactly the concepts the copy linter runs.
    func testStaticClaimColumnsAreTheLintedConcepts() {
        XCTAssertEqual(
            Set(Matrix.StaticClaim.allCases.map(\.rawValue)),
            Set(MedicalTermLexicon.neverInStaticCopy.map(\.id))
        )
    }

    private func assertComplete<Column>(_ rows: [Matrix.Row<Column>], name: String) {
        XCTAssertEqual(rows.map(\.language).sorted(), Matrix.languages.sorted(), "\(name): one row per app language")
        for row in rows {
            for column in Column.allCases where row.cells[column]?.isEmpty ?? true {
                XCTFail("\(name) [\(row.language)] has no phrasing for \(column)")
            }
            XCTAssertFalse(row.negatives.isEmpty, "\(name) [\(row.language)] has no lookalike negative")
        }
    }

    // MARK: - Each guard catches its cells and leaves the idioms

    func testEverySelfHarmFormGetsTheCrisisReplyInEveryLanguage() {
        for row in Matrix.selfHarmRows {
            for (form, text) in row.phrasings {
                XCTAssertEqual(MedicalQueryGuard.evaluate(text), .refuse(reply: MedicalQueryGuard.selfHarmReply), "[\(row.language)] \(form): \(text)")
            }
            for text in row.negatives {
                XCTAssertNotEqual(MedicalQueryGuard.classify(text), .selfHarm, "[\(row.language)] training talk read as self-harm: \(text)")
            }
        }
    }

    func testEveryInputFormGetsItsReplyInEveryLanguage() {
        for row in Matrix.inputRows {
            for (form, text) in row.phrasings {
                XCTAssertEqual(MedicalQueryGuard.classify(text), form.trigger, "[\(row.language)] \(form): \(text)")
            }
            for text in row.negatives {
                XCTAssertNil(MedicalQueryGuard.classify(text), "[\(row.language)] effort talk refused: \(text)")
            }
        }
    }

    func testEveryStaticClaimIsCaughtByItsConceptInEveryLanguage() throws {
        let concepts = try Dictionary(uniqueKeysWithValues: MedicalTermLexicon.neverInStaticCopy.map {
            ($0.id, try XCTUnwrap(MedicalTermLexicon.regex(for: $0)))
        })
        for row in Matrix.staticClaimRows {
            for (claim, text) in row.phrasings {
                let regex = try XCTUnwrap(concepts[claim.rawValue])
                XCTAssertTrue(Self.matches(regex, text), "[\(row.language)] \(claim.rawValue) passes the linter: \(text)")
            }
            for text in row.negatives {
                let hits = concepts.filter { Self.matches($0.value, text) }.map(\.key)
                XCTAssertTrue(hits.isEmpty, "[\(row.language)] coaching copy fails \(hits): \(text)")
            }
        }
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - Voice never drops one as echo

    /// After the crisis reply is spoken, "I'm really sorry, I want to end my
    /// life" shares most of its words with it. Every self-harm and emergency
    /// cell must still reach the guard after every canned reply.
    func testACrisisOrEmergencyUtteranceIsNeverEcho() {
        let replies = MedicalQueryGuard.cannedReplies
        let texts = Matrix.selfHarmRows.flatMap { $0.phrasings.map(\.text) }
            + Matrix.inputRows.flatMap { $0.phrasings.filter { $0.column.trigger.namesEmergencyNumber }.map(\.text) }
        for text in texts {
            for reply in replies {
                // The one exception: the reply itself classifies the same way, so this could be its echo.
                let couldBeItsEcho = MedicalQueryGuard.classify(reply) == MedicalQueryGuard.classify(text)
                XCTAssertTrue(couldBeItsEcho || VoiceEchoHeuristics.mustReachGuard(text, lastAssistantTurn: reply), "dropped as echo: \(text)")
            }
        }
        let afterCrisisReply = "I'm really sorry, I want to end my life"
        XCTAssertTrue(VoiceEchoHeuristics.mustReachGuard(afterCrisisReply, lastAssistantTurn: MedicalQueryGuard.selfHarmReply))
    }

    /// A crisis message is exempt after every reply only while no reply
    /// itself reads as self-harm. A translation that said "suicide hotline"
    /// would make the next "I want to kill myself" droppable as its echo.
    func testNoCannedReplyInAnyLanguageReadsAsSelfHarm() throws {
        let keys = NarrativeLanguage.english { MedicalQueryGuard.cannedReplies }
        for language in Matrix.languages {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), language)
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                let reply = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(MedicalQueryGuard.classify(reply), .selfHarm, "[\(language)] \(reply)")
            }
        }
    }

    // MARK: - Flo switched off

    /// "Flo is off" is no answer to someone in crisis: the crisis reply is
    /// the app's own and never reaches a model, so it is given anyway.
    func testTheCrisisReplyIsGivenWhileFloIsOff() {
        let viewModel = makeViewModel()
        let accepted = viewModel.hasAcceptedDisclaimer
        viewModel.hasAcceptedDisclaimer = false
        addTeardownBlock { @MainActor in viewModel.hasAcceptedDisclaimer = accepted }

        guard case .dispatched = viewModel.send(text: "I will kill myself") else { return XCTFail("the crisis message was refused") }
        XCTAssertEqual(viewModel.turns.last?.text, MedicalQueryGuard.selfHarmReply)
        guard case .rejectedNoProvider = viewModel.send(text: "how did I sleep?") else { return XCTFail("an ordinary message was sent with Flo off") }
    }

    private func makeViewModel() -> AssistantViewModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SafetyPhrasingMatrixTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                // swallow-ok: the folder is temporary and may never have been created.
            }
        }
        return AssistantViewModel(
            services: ChatServices(.current),
            store: ConversationStore(fileURL: directory.appendingPathComponent("conversation.json")),
            factsStore: UserFactsStore(fileURL: directory.appendingPathComponent("user_facts.json"))
        )
    }
}
