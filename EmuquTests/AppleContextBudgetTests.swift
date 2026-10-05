//
//  AppleContextBudgetTests.swift
//  EmuquTests
//
//  Apple Intelligence has a 4,096-token window that holds the instructions,
//  the tool descriptions, the transcript, every tool result the model reads
//  back mid-generation, and the reply. Tool results used to be uncapped, and
//  both built-in suggestion chips failed with `exceededContextWindowSize`.
//  These tests pin the budget that stops that, and the error policy that
//  decides what happens when Apple still fails.
//

@testable import Emuqu
import XCTest

final class AppleContextBudgetTests: XCTestCase {
    private typealias Compactor = AppleContextCompactor

    // MARK: - Truncation

    func testTextThatFitsIsReturnedUnchanged() {
        let text = #"{"value":42,"confidence":"high"}"#
        XCTAssertEqual(Compactor.truncate(text, toTokens: 100, note: Compactor.toolOutputCutNote), text)
    }

    /// A cut result never exceeds the limit, note included, and says it was cut.
    func testCutTextStaysWithinTheLimitAndCarriesTheNote() {
        let long = String(repeating: #"{"date":"2026-10-01","rmssd":41.2},"#, count: 400)
        for limit in [60, 250, 600] {
            let cut = Compactor.truncate(long, toTokens: limit, note: Compactor.toolOutputCutNote)
            XCTAssertLessThanOrEqual(Compactor.estimateTokens(cut), limit, "limit \(limit)")
            XCTAssertTrue(cut.hasSuffix(Compactor.toolOutputCutNote))
            XCTAssertTrue(long.hasPrefix(String(cut.dropLast(Compactor.toolOutputCutNote.count))))
        }
    }

    /// Non-ASCII text counts a token per character, so the cut has to honour
    /// that too.
    func testCutHonoursNonASCIICost() {
        let japanese = String(repeating: "睡眠の質は良好です。", count: 200)
        let cut = Compactor.truncate(japanese, toTokens: 120, note: Compactor.toolOutputCutNote)
        XCTAssertLessThanOrEqual(Compactor.estimateTokens(cut), 120)
    }

    // MARK: - Turn budget

    /// Tool results get what the window has left after the fixed prefix, the
    /// transcript, the reply's reserve and the estimate margin.
    func testToolOutputBudgetIsWhatTheWindowHasLeft() {
        let budget = Compactor.toolOutputBudget(fixedTokens: 1500, transcriptTokens: 400)
        let expected = Compactor.contextWindow - 1500 - 400 - Compactor.responseReserve - Compactor.estimateMargin
        XCTAssertEqual(budget, expected)
        XCTAssertLessThanOrEqual(
            1500 + 400 + budget + Compactor.responseReserve, Compactor.contextWindow,
            "Prefix, transcript, tool results and the reply must fit the window together"
        )
    }

    /// An overfull prefix still leaves a floor, so a tool call returns
    /// something readable rather than nothing.
    func testToolOutputBudgetNeverDropsBelowTheFloor() {
        XCTAssertEqual(
            Compactor.toolOutputBudget(fixedTokens: 4000, transcriptTokens: 900),
            Compactor.minToolOutputTokens
        )
    }

    /// The compactor's transcript allowance plus the tool-result budget plus
    /// the reply reserve fit the window for any fixed prefix the compactor
    /// accepts.
    func testCompactedTranscriptLeavesRoomForToolResultsAndTheReply() {
        let turns = (0 ..< 60).map { index in
            ChatTurn(role: index.isMultiple(of: 2) ? .user : .assistant,
                     text: String(repeating: "Recovery was steady and sleep was long. ", count: 8))
        }
        for fixed in [800, 1400, 2000] {
            let kept = Compactor.compactedPromptInput(messages: turns, systemPromptTokens: fixed)
            let transcript = Compactor.transcriptTokens(kept)
            let tools = Compactor.toolOutputBudget(fixedTokens: fixed, transcriptTokens: transcript)
            XCTAssertLessThanOrEqual(fixed + transcript + tools + Compactor.responseReserve, Compactor.contextWindow,
                                     "fixed \(fixed)")
        }
    }

    // MARK: - Allowance

    /// Each result is capped per call and charged; once the allowance is
    /// spent the model is told to answer with what it has.
    func testAllowanceCapsEachResultAndRunsOut() {
        var allowance = Compactor.ToolOutputAllowance(remaining: 700, perCallCap: 400)
        let big = String(repeating: "x", count: 10000)

        let first = allowance.admit(big)
        XCTAssertLessThanOrEqual(Compactor.estimateTokens(first), 400)
        let second = allowance.admit(big)
        XCTAssertLessThanOrEqual(Compactor.estimateTokens(first) + Compactor.estimateTokens(second), 700)
        XCTAssertLessThan(allowance.remaining, Compactor.minToolOutputTokens)
        XCTAssertEqual(allowance.admit(big), Compactor.ToolOutputAllowance.spentNote)
    }

    /// A small result passes through whole and costs only what it is.
    func testSmallResultPassesThroughWhole() {
        var allowance = Compactor.ToolOutputAllowance(remaining: 500, perCallCap: 300)
        let small = #"{"value":63,"confidence":"high"}"#
        XCTAssertEqual(allowance.admit(small), small)
        XCTAssertEqual(allowance.remaining, 500 - Compactor.estimateTokens(small))
    }

    // MARK: - Retry plan

    /// One trimmed retry after an overflow, and no third attempt.
    func testOverflowIsRetriedOnceTrimmed() {
        XCTAssertEqual(Compactor.Attempt.full.afterOverflow, .trimmed)
        XCTAssertNil(Compactor.Attempt.trimmed.afterOverflow)
    }

    /// The retry asks for strictly less of the window on every axis.
    func testTrimmedAttemptAsksForLessOfTheWindow() {
        let full = Compactor.Attempt.full
        let trimmed = Compactor.Attempt.trimmed
        XCTAssertLessThan(trimmed.toolTokenBudget, full.toolTokenBudget)
        XCTAssertLessThan(trimmed.toolOutputCap, full.toolOutputCap)
        XCTAssertLessThan(trimmed.instructionTokenCap, full.instructionTokenCap)
        XCTAssertTrue(full.keepsHistory)
        XCTAssertFalse(trimmed.keepsHistory)
        XCTAssertLessThan(
            trimmed.instructionTokenCap + trimmed.toolTokenBudget + Compactor.responseReserve + Compactor.estimateMargin,
            Compactor.contextWindow,
            "The trimmed attempt's fixed prefix must leave room for a question, a tool result and the reply"
        )
    }

    // MARK: - Error policy

    /// An Apple safety refusal is never routed to another provider: the
    /// Foundation Models acceptable-use terms forbid circumventing its
    /// guardrails.
    func testSafetyRefusalIsNotHandedToAnotherProvider() {
        XCTAssertTrue(AIProviderError.guardrailViolation.isAppleGuardrail)
        XCTAssertFalse(AIProviderError.guardrailViolation.isFallbackable)
    }

    /// Failures that say nothing about the content, including Apple's
    /// context overflow (reported as `.unknown`) and an unavailable model,
    /// may move on to another provider.
    func testNonSafetyFailuresMayMoveOn() {
        let failures: [AIProviderError] = [
            .unknown("Apple Intelligence couldn't answer that."),
            .modelUnavailable("Apple Intelligence isn't ready on this device yet."),
            .rateLimited, .network("offline"), .authFailed
        ]
        for failure in failures {
            XCTAssertTrue(failure.isFallbackable, "\(failure)")
            XCTAssertFalse(failure.isAppleGuardrail, "\(failure)")
        }
    }
}
