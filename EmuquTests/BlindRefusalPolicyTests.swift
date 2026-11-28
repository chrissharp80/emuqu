@testable import Emuqu
import XCTest

/// "I don't have that data" is allowed only after a lookup came back empty.
/// A refusal with no tool call this turn is taken off the screen and the
/// model is re-asked with what the app's own search found, once.
@MainActor
final class BlindRefusalPolicyTests: XCTestCase {
    // MARK: - Recognising a refusal

    /// The replies from a real conversation, and what a reply that answers looks like.
    func testTheRefusalsUsersSawAreRecognised() {
        for text in [
            "I don't have that data right now — no lowest heart rate readings for the last week.",
            "I don\u{2019}t have that data right now — no overnight heart rate nadirs for every night this week.",
            "Sorry, I do not have that information.",
            "No tengo esos datos ahora mismo."
        ] {
            XCTAssertTrue(BlindRefusalPolicy.isRefusal(text), text)
        }
        XCTAssertFalse(BlindRefusalPolicy.isRefusal("Recovery 22/100 last night, down from 40 the night before."))
    }

    func testTheQuestionIsSentAsEscapedJSON() {
        XCTAssertEqual(BlindRefusalPolicy.queryJSON(#"my "lowest" HR"#), #"{"query":"my \"lowest\" HR"}"#)
    }

    func testOnlyABlindRefusalIsReasked() async {
        let refusal = "I don't have that data right now."
        let afterLookup = await BlindRefusalPolicy.reask(roundText: refusal, question: "lowest heart rate", lookedUp: true, registry: nil)
        XCTAssertNil(afterLookup, "a refusal after a lookup stands")
        let answer = await BlindRefusalPolicy.reask(roundText: "Your nadir was low.", question: "lowest heart rate", lookedUp: false, registry: nil)
        XCTAssertNil(answer, "an answer is not re-asked")
        let blind = await BlindRefusalPolicy.reask(roundText: refusal, question: "lowest heart rate", lookedUp: false, registry: nil)
        XCTAssertEqual(blind?.role, .user)
    }

    // MARK: - The tool loop

    private func makeViewModel() -> AssistantViewModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlindRefusalPolicyTests-\(UUID().uuidString)", isDirectory: true)
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

    private func enableOpenAI() {
        let flags = FeatureFlags.shared
        let wasOn = flags.value(for: .providerOpenAIEnabled)
        flags.set(true, for: .providerOpenAIEnabled)
        ProviderConsentTracker.shared.acknowledge(.openai)
        addTeardownBlock { flags.set(wasOn, for: .providerOpenAIEnabled) }
    }

    private static let refusal = "I don't have that data right now — no lowest heart rate readings for the last week."

    /// Runs the loop on `rounds`, one per request, and returns the reply and
    /// what each request was sent.
    private func run(_ rounds: [[AIStreamEvent]]) async throws -> (reply: String, sent: SentMessages) {
        enableOpenAI()
        let viewModel = makeViewModel()
        let question = ChatTurn(role: .user, text: "What's my lowest heart rate of the last week?")
        let reply = ChatTurn(role: .assistant, text: "", providerID: .openai)
        viewModel.turns = [question, reply]
        let sent = SentMessages()
        let registry = FactResolverRegistry()
        registry.register(NightlyHeartRateNamespace())
        try await viewModel.tools.runToolUseLoop(
            provider: SequencedRoundsProvider(rounds: rounds, sent: sent), model: AppleFoundationProvider.model,
            outbound: [question], systemPrompt: "", tools: [], factRegistry: registry, turnID: reply.id
        )
        return (viewModel.turns.last?.text ?? "", sent)
    }

    func testABlindRefusalIsReplacedByTheAnswerAfterALookup() async throws {
        let (reply, sent) = try await run([
            [.textDelta(Self.refusal), .done],
            [.toolUse(id: "1", name: "lookup_fact", inputJSON: #"{"key":"nightly.heart_rate"}"#), .done],
            [.textDelta("Your lowest heart rate this week came on Tuesday night."), .done]
        ])
        XCTAssertEqual(reply, "Your lowest heart rate this week came on Tuesday night.", "the refusal must leave the screen")
        XCTAssertEqual(sent.requests.count, 3)
        let reask = sent.requests[1].last { $0.role == .user }?.text ?? ""
        XCTAssertTrue(reask.contains("find_data for the user's question returned"), "the re-ask carries the search: \(reask)")
        XCTAssertTrue(reask.contains("nightly.heart_rate"), "the search found the lookup that answers: \(reask)")
    }

    func testARefusalAfterALookupStands() async throws {
        let (reply, sent) = try await run([
            [.toolUse(id: "1", name: "lookup_fact", inputJSON: #"{"key":"nightly.heart_rate"}"#), .done],
            [.textDelta(Self.refusal), .done]
        ])
        XCTAssertEqual(reply, Self.refusal)
        XCTAssertEqual(sent.requests.count, 2)
    }

    func testATurnIsReaskedOnlyOnce() async throws {
        let (reply, sent) = try await run([[.textDelta(Self.refusal), .done], [.textDelta(Self.refusal), .done]])
        XCTAssertEqual(reply, Self.refusal)
        XCTAssertEqual(sent.requests.count, 2)
    }
}

// MARK: - Fixtures

/// What each request to a sequenced provider carried.
@MainActor
final class SentMessages {
    var requests: [[ChatTurn]] = []
}

/// A provider that plays its rounds in request order, one per request.
struct SequencedRoundsProvider: AIProvider {
    let rounds: [[AIStreamEvent]]
    let sent: SentMessages
    var id: ProviderID { .openai }
    var availableModels: [ModelOption] { [AppleFoundationProvider.model] }
    var requiresKey: Bool { false }
    var isAvailable: Bool { true }

    func send(
        messages: [ChatTurn], model _: ModelOption, contextRendered _: String, systemPrompt _: String,
        tools _: [ToolSpec], toolRounds _: [[ToolExchange]]
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let (rounds, sent) = (rounds, sent)
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                let index = sent.requests.count
                sent.requests.append(messages)
                for event in index < rounds.count ? rounds[index] : [.done] { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}

/// One fact the search can find for a nightly heart-rate question.
struct NightlyHeartRateNamespace: FactNamespaceResolver {
    var namespace: String { "nightly" }

    var entries: [FactEntry] {
        [.fixed(
            key: "nightly.heart_rate", description: "Lowest heart rate each night this week.", valueType: "List",
            availability: { .alwaysAvailable }, resolve: { .list([.record(["overnight_nadir_hr_bpm": .double(47)])]) }
        )]
    }
}
