@testable import Emuqu
import XCTest

/// An auto-remember extraction runs in the background for up to 8 s after
/// a reply. What it finds is stored only if nothing since told the app to
/// forget: Clear conversation, Forget everything, or auto-remember switched
/// off. Driven on stores in a temporary directory.
@MainActor
final class AutoRememberTests: XCTestCase {
    private let fact = "Training for a marathon in April"
    private func make() throws -> (AssistantViewModel, UserFactsStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoRememberTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let facts = UserFactsStore(fileURL: dir.appendingPathComponent("user_facts.json"))
        let viewModel = AssistantViewModel(
            services: ChatServices(.current),
            store: ConversationStore(fileURL: dir.appendingPathComponent("conversation.json")),
            factsStore: facts
        )
        let hostSetting = UserDefaults.standard.object(forKey: "assistant.autoExtractFacts")
        facts.autoExtractEnabled = true
        addTeardownBlock {
            UserDefaults.standard.set(hostSetting, forKey: "assistant.autoExtractFacts")
            try? FileManager.default.removeItem(at: dir)
        }
        return (viewModel, facts)
    }

    func testAnExtractionWithNothingInTheWayIsStored() throws {
        let (viewModel, facts) = try make()
        viewModel.store(extractedFacts: [fact], startedIn: facts.extractionEpoch)
        XCTAssertEqual(facts.facts.map(\.text), [fact])
    }

    func testClearingTheConversationDropsAnExtractionStillRunning() throws {
        let (viewModel, facts) = try make()
        let epoch = facts.extractionEpoch
        viewModel.clearConversation()
        viewModel.store(extractedFacts: [fact], startedIn: epoch)
        XCTAssertTrue(facts.facts.isEmpty, "a fact from the cleared conversation was remembered")
    }

    func testForgetEverythingDropsAnExtractionStillRunning() throws {
        let (viewModel, facts) = try make()
        let epoch = facts.extractionEpoch
        XCTAssertTrue(facts.clear())
        viewModel.store(extractedFacts: [fact], startedIn: epoch)
        XCTAssertTrue(facts.facts.isEmpty, "a fact was remembered after Forget everything")
    }

    func testSwitchingAutoRememberOffDropsAnExtractionStillRunning() throws {
        let (viewModel, facts) = try make()
        let epoch = facts.extractionEpoch
        facts.autoExtractEnabled = false
        viewModel.store(extractedFacts: [fact], startedIn: epoch)
        XCTAssertTrue(facts.facts.isEmpty, "a fact was remembered after auto-remember was switched off")
    }
}
