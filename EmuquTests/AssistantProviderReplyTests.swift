//
//  AssistantProviderReplyTests.swift
//  EmuquTests
//
//  What reaches the user from a provider: the error shown when a key's
//  account has no credit (never a pointer to an outside purchase, App Store
//  3.1.1), the tools Apple Intelligence's small window keeps for a question,
//  and how an Apple reply that reaches its token cap ends.
//

@testable import Emuqu
import XCTest

// MARK: - Credit and billing replies

final class ProviderAccountReplyTests: XCTestCase {
    /// Each vendor's out-of-credit reply is recognised.
    func testEveryVendorsCreditFailureIsRecognised() {
        let bodies: [(Int, String)] = [
            (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API."}}"#),
            (429, #"{"error":{"message":"You exceeded your current quota.","type":"insufficient_quota","code":"insufficient_quota"}}"#),
            (402, #"{"error":{"message":"Insufficient Balance","type":"unknown_error"}}"#),
            (403, #"{"error":"Your newly created team doesn't have any credits yet."}"#)
        ]
        for (status, body) in bodies {
            XCTAssertTrue(ProviderAccountReply.isCreditExhausted(status: status, body: body), body)
        }
    }

    /// An ordinary rate limit or bad request is not a credit failure.
    func testOtherFailuresAreNotCreditFailures() {
        XCTAssertFalse(ProviderAccountReply.isCreditExhausted(status: 429, body: #"{"error":{"message":"Rate limit reached for requests"}}"#))
        XCTAssertFalse(ProviderAccountReply.isCreditExhausted(status: 400, body: #"{"error":{"message":"max_tokens is too large"}}"#))
    }

    /// The out-of-credit message names the vendor and points nowhere: no
    /// address, no billing page, no "add funds".
    func testOutOfCreditMessageHasNoPurchaseCallToAction() {
        for provider in ProviderID.allCases where provider != .apple {
            let message = AIProviderError.outOfCredit(provider).errorDescription ?? ""
            XCTAssertTrue(message.contains(provider.vendorName), message)
            XCTAssertFalse(message.contains(".com"), message)
            XCTAssertFalse(ProviderAccountReply.carriesPurchasePrompt(message), message)
        }
    }

    /// Vendor text that sends the user to pay is never shown verbatim.
    func testVendorPurchasePromptIsReplaced() {
        let vendorText = "Please enable billing on your project in Google AI Studio: https://aistudio.google.com/plan_information"
        for error in [AIProviderError.invalidResponse(vendorText), .modelUnavailable(vendorText), .unknown(vendorText)] {
            let shown = error.errorDescription ?? ""
            XCTAssertFalse(shown.contains("aistudio"), shown)
            XCTAssertFalse(shown.isEmpty)
        }
        XCTAssertEqual(AIProviderError.modelUnavailable("Model gpt-x not found").errorDescription, "Model gpt-x not found")
    }

    /// A credit failure may still be answered by another model where the
    /// routing mode allows it.
    func testOutOfCreditIsFallbackable() {
        XCTAssertTrue(AIProviderError.outOfCredit(.openai).isFallbackable)
    }
}

// MARK: - Apple tool ranking

final class AppleToolRankingTests: XCTestCase {
    /// Apple's window holds about a thousand tokens of tool descriptions.
    private let budget = 1024

    /// The cost Apple charges a tool, as `AppleFoundationProvider` counts it.
    private func appleCost(_ spec: ToolSpec) -> Int {
        #if canImport(FoundationModels)
            if #available(iOS 26, *) { return AppleToolCatalog.estimatedTokens(for: spec) }
        #endif
        return AppleContextCompactor.estimateTokens(spec.name + spec.description) + 10
    }

    /// The schema arrives in name order, and the window holds only its first
    /// few tools. A sleep question must lead with the sleep tool and keep it
    /// inside the budget, ahead of tools that merely sort first or whose
    /// examples share the question's wording ("how", "did").
    @MainActor
    func testSleepQuestionKeepsTheSleepToolWithinBudget() {
        let schema = CompactToolRouter.readTools().sorted { $0.name < $1.name }
        let ranked = ToolRetriever.ranked(for: "How did I sleep last night?", tools: schema)
        let kept = ToolRetriever.fitting(ranked, budget: budget, cost: appleCost)
        XCTAssertEqual(kept.tools.first?.name, "get_sleep")
        XCTAssertLessThanOrEqual(kept.tokens, budget)
        XCTAssertEqual(kept.tokens, kept.tools.map(appleCost).reduce(0, +))
        XCTAssertNotEqual(schema.first?.name, "get_sleep", "name order alone would not lead with it")
    }

    /// Ranking reorders and never drops: matches first, then the essentials,
    /// then the rest in the order given.
    @MainActor
    func testRankingKeepsEveryToolAndPutsEssentialsBeforeTheRest() {
        let schema = CompactToolRouter.readTools().sorted { $0.name < $1.name }
        let ranked = ToolRetriever.ranked(for: "ok thanks", tools: schema)
        XCTAssertEqual(Set(ranked.map(\.name)), Set(schema.map(\.name)))
        XCTAssertEqual(ranked.count, schema.count)
        XCTAssertEqual(ranked.first?.name, "get_session", "with no match, the essentials lead in schema order")
    }

    /// A tool too large for the room left is skipped, and smaller ones after
    /// it still fit.
    func testFittingSkipsWhatDoesNotFit() {
        let tools = ["a", "b", "c"].map {
            ToolSpec(name: $0, description: "", inputSchema: ToolSpec.InputSchema(properties: [:], required: []))
        }
        let cost: (ToolSpec) -> Int = { $0.name == "b" ? 80 : 30 }
        let kept = ToolRetriever.fitting(tools, budget: 70, cost: cost)
        XCTAssertEqual(kept.tools.map(\.name), ["a", "c"])
        XCTAssertEqual(kept.tokens, 60)
    }
}

// MARK: - Apple reply length

final class AppleReplyTrimmerTests: XCTestCase {
    /// Long enough that the cap may have stopped it.
    private let longBody = String(repeating: "Your recovery looks steady today. ", count: 60)

    func testCompletePrefixEndsAtTheLastSentenceOrLine() {
        XCTAssertEqual(AppleReplyTrimmer.completePrefix(of: "Good night. You slept we"), "Good night.")
        XCTAssertEqual(AppleReplyTrimmer.completePrefix(of: "- Sleep 6h 55m\n- HRV 4"), "- Sleep 6h 55m\n")
        XCTAssertEqual(AppleReplyTrimmer.completePrefix(of: "今日は良い。明日も"), "今日は良い。")
        XCTAssertEqual(AppleReplyTrimmer.completePrefix(of: "He said \"rest.\" Then"), "He said \"rest.\"")
    }

    /// A decimal point is not a sentence end while the number is streaming.
    func testDecimalIsNotASentenceEnd() {
        XCTAssertEqual(AppleReplyTrimmer.completePrefix(of: "Your TSB is 3.5 and"), "")
        XCTAssertEqual(AppleReplyTrimmer.completePrefix(of: "Your TSB is 3."), "")
    }

    func testShortReplyIsShownWhole() {
        XCTAssertEqual(AppleReplyTrimmer.finalText("Rest today"), "Rest today")
    }

    func testCappedReplyEndsAtItsLastCompleteSentence() {
        let cut = longBody + "Tomorrow you could try an eas"
        XCTAssertTrue(AppleReplyTrimmer.mayHaveReachedCap(cut))
        XCTAssertEqual(AppleReplyTrimmer.finalText(cut), longBody.trimmingCharacters(in: .whitespaces))
    }

    func testLongReplyThatEndsCleanlyIsKept() {
        let whole = longBody + "Rest well."
        XCTAssertEqual(AppleReplyTrimmer.finalText(whole), whole)
    }

    /// The relay shows complete sentences as they stream, holds the
    /// unfinished one, and shows it at the end of a reply that was not cut.
    func testRelayHoldsTheUnfinishedSentenceUntilTheEnd() {
        var emitted: [String] = []
        var relay = AppleReplyRelay { emitted.append($0) }
        relay.receive("Nice run. Your HR")
        XCTAssertEqual(emitted.joined(), "Nice run.")
        relay.receive("Nice run. Your HR stayed low")
        relay.finish()
        XCTAssertEqual(emitted.joined(), "Nice run. Your HR stayed low")
        XCTAssertEqual(relay.shown, "Nice run. Your HR stayed low")
    }

    func testRelayDropsTheTailOfACappedReply() {
        var emitted: [String] = []
        var relay = AppleReplyRelay { emitted.append($0) }
        let cut = longBody + "Tomorrow you could try an eas"
        relay.receive(cut)
        relay.finish()
        XCTAssertEqual(emitted.joined(), longBody.trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(relay.generated, cut)
    }

    /// The instructions ask for less than the cap holds.
    func testLengthRuleAsksForShortAnswers() {
        XCTAssertTrue(AppleReplyTrimmer.lengthRule.contains("150 words"))
        XCTAssertLessThan(AppleContextCompactor.estimateTokens(AppleReplyTrimmer.lengthRule), 60)
    }
}
