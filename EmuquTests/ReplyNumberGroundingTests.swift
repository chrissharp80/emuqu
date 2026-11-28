@testable import Emuqu
import XCTest

/// Every number a reply states must come from the data the model was given
/// that turn. A number that doesn't is sent back once, then cut.
@MainActor
final class ReplyNumberGroundingTests: XCTestCase {
    private let lastNight = #"{"value":{"score":22,"previous_score":40,"rmssd_ms":32.04,"overnight_mean_hr_bpm":67.2,"overnight_nadir_hr_bpm":53,"total_sleep_minutes":252,"efficiency_percent":92.1}}"#

    private func ungrounded(_ reply: String, _ sources: [String]) -> [String] {
        ReplyNumberGrounding.ungrounded(in: reply, sources: sources).map(\.text)
    }

    /// The reply from a real conversation, every number in it from the night's record.
    func testAReplyBuiltFromTheDataPasses() {
        let reply = "Recovery 22/100 last night, down from 40 the night before. HRV RMSSD was 32.0 ms with mean overnight heart rate 67 bpm (nadir 53 bpm), while sleep was 4h12m at 92% efficiency."
        XCTAssertEqual(ungrounded(reply, [lastNight]), [])
    }

    func testAnInventedNumberIsCaught() {
        XCTAssertEqual(ungrounded("Your nadir was 49 bpm and your RMSSD 32.0 ms.", [lastNight]), ["49"])
        XCTAssertEqual(ungrounded("You slept 5h40m.", [lastNight]), ["5h40m"])
    }

    /// Unit changes into the unit written, rounding, and differences of grounded numbers.
    func testConversionsAndDifferencesPass() {
        let week = #"{"value":[{"overnight_nadir_hr_bpm":47,"distance_m":6373},{"overnight_nadir_hr_bpm":55}]}"#
        let reply = "Your walk was 3.96 mi. Your nadir was lowest at 47 bpm and highest at 55 bpm, a spread of 8 bpm, about 17% above the low."
        XCTAssertEqual(ungrounded(reply, [week]), [])
    }

    /// A conversion applies only into the unit the reply wrote: 3600 seconds
    /// is 60 minutes, not 60 ms of RMSSD.
    func testAConversionDoesNotGroundAnotherUnit() {
        let night = #"{"value":{"duration_sec":3600}}"#
        XCTAssertEqual(ungrounded("You recorded for 60 minutes.", [night]), [])
        XCTAssertEqual(ungrounded("Your RMSSD was 60 ms.", [night]), ["60"])
    }

    /// An average the model computed itself is not a value it was given: it
    /// has to come from analyze_data.
    func testAnAverageTheModelComputedIsNotGrounded() {
        let week = #"{"value":[{"overnight_nadir_hr_bpm":47},{"overnight_nadir_hr_bpm":52},{"overnight_nadir_hr_bpm":55}]}"#
        XCTAssertEqual(ungrounded("Your nadir averaged 51.3 bpm.", [week]), ["51.3"])
    }

    func testDatesTimesYearsAndCountsAreNotChecked() {
        XCTAssertEqual(ungrounded("On February 20, 2026 at 3:14 am you did 2 workouts; on the 3rd you rested.", []), [])
        XCTAssertEqual(ungrounded("Compare with Feb 20 and 2026-02-20.", []), [])
    }

    /// Clock times and dates in the turn's data are not values: the minutes
    /// of "12:44" do not ground a nadir of 44.
    func testClockTimesAndDatesInTheDataGroundNothing() {
        XCTAssertEqual(ungrounded("Your nadir was 44 bpm.", ["Current time 12:44 on 2026-02-20"]), ["44"])
        XCTAssertEqual(ungrounded("Your TSB is -17.2.", [#"{"tsb":-17.2}"#]), [])
    }

    /// General guidance is not a claim about the user's data.
    func testGeneralNormsAreNotChecked() {
        XCTAssertEqual(ungrounded("Adults typically need 7 to 9 hours of sleep. Your nadir was 53 bpm.", [lastNight]), [])
    }

    func testOnlyTheSentencesStatingInventedNumbersAreCut() {
        let numbers = ReplyNumberGrounding.ungrounded(in: "Your nadir was 49 bpm. You slept well.", sources: [lastNight])
        XCTAssertEqual(ReplyGroundingCheck.removingSentences(stating: numbers, from: "Your nadir was 49 bpm. You slept well."), "You slept well.")
        XCTAssertEqual(ReplyNumberGrounding.replySentences("RMSSD 32.0 ms. Good."), ["RMSSD 32.0 ms.", " Good."])
    }

    // MARK: - Voice

    /// Voice speaks a sentence once it is published, unless it states a
    /// number: that waits for the end-of-round check against the turn's data.
    func testVoiceHoldsASentenceWithANumberUntilTheCheck() {
        let viewModel = makeViewModel()
        let reply = ChatTurn(role: .assistant, text: "", providerID: .openai)
        viewModel.turns = [ChatTurn(role: .user, text: "How was my night?"), reply]
        let buffer = StreamTextBuffer(owner: viewModel, turnID: reply.id)
        buffer.append(chunk: "You slept well.", thisRoundIsEmpty: true)
        buffer.flush(force: true, thisRoundIsEmpty: true)
        XCTAssertEqual(viewModel.speakableTextCursor[reply.id], viewModel.turns.last?.text.count, "a sentence with no number is spoken at once")
        let released = viewModel.speakableTextCursor[reply.id]
        buffer.append(chunk: " Your nadir was 41.3 bpm.", thisRoundIsEmpty: true)
        buffer.flush(force: true, thisRoundIsEmpty: true)
        XCTAssertEqual(viewModel.speakableTextCursor[reply.id], released, "a sentence stating a number is not spoken before the check")
    }

    // MARK: - The tool loop

    private func makeViewModel() -> AssistantViewModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplyNumberGroundingTests-\(UUID().uuidString)", isDirectory: true)
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

    private func run(_ rounds: [[AIStreamEvent]]) async throws -> (reply: String, sent: SentMessages) {
        let flags = FeatureFlags.shared
        let wasOn = flags.value(for: .providerOpenAIEnabled)
        flags.set(true, for: .providerOpenAIEnabled)
        ProviderConsentTracker.shared.acknowledge(.openai)
        addTeardownBlock { flags.set(wasOn, for: .providerOpenAIEnabled) }
        let viewModel = makeViewModel()
        let question = ChatTurn(role: .user, text: "What was my lowest heart rate this week?")
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

    private let lookup: [AIStreamEvent] = [.toolUse(id: "1", name: "lookup_fact", inputJSON: #"{"key":"nightly.heart_rate"}"#), .done]

    func testAnInventedNumberIsReaskedAndTheGroundedAnswerShown() async throws {
        let (reply, sent) = try await run([lookup, [.textDelta("Your lowest was 41.3 bpm."), .done], [.textDelta("Your lowest was 47 bpm."), .done]])
        XCTAssertEqual(reply, "Your lowest was 47 bpm.")
        XCTAssertEqual(sent.requests.count, 3)
        let reask = sent.requests.dropFirst(2).first?.last { $0.role == .user }?.text ?? ""
        XCTAssertTrue(reask.contains("41.3"), "the re-ask names the number: \(reask)")
    }

    func testANumberStillInventedAfterTheReaskIsCut() async throws {
        let invented: [AIStreamEvent] = [.textDelta("Your lowest was 41.3 bpm. Sleep looked steady."), .done]
        let (reply, sent) = try await run([lookup, invented, invented])
        XCTAssertEqual(reply, "Sleep looked steady.")
        XCTAssertEqual(sent.requests.count, 3)
    }
}
