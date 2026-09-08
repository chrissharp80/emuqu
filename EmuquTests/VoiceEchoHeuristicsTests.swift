@testable import Emuqu
import XCTest

/// Tests for the token-overlap heuristics that keep the voice assistant from
/// hearing itself.
///
/// Both failure directions are user-visible: too eager and a real question is
/// swallowed as echo, too lax and the assistant answers its own last sentence
/// or refuses to be interrupted.
final class VoiceEchoHeuristicsTests: XCTestCase {
    // MARK: - Tokeniser

    func testTokensAreLowercasedAndPunctuationStripped() {
        XCTAssertEqual(
            VoiceEchoHeuristics.tokens("Your HRV, today, is HIGH!"),
            ["your", "hrv", "today", "is", "high"]
        )
    }

    /// The two-character floor drops "a" and "I" but must keep the words a
    /// barge-in actually starts with.
    func testShortFillerWordsAreDroppedButBargeInWordsSurvive() {
        XCTAssertEqual(VoiceEchoHeuristics.tokens("a I"), [])
        XCTAssertEqual(VoiceEchoHeuristics.tokens("hey stop no"), ["hey", "stop", "no"])
    }

    func testDigitsAreKept() {
        XCTAssertEqual(VoiceEchoHeuristics.tokens("rmssd 42 ms"), ["rmssd", "42", "ms"])
    }

    func testTokensOfEmptyTextIsEmpty() {
        XCTAssertTrue(VoiceEchoHeuristics.tokens("").isEmpty)
        XCTAssertTrue(VoiceEchoHeuristics.tokens("   ").isEmpty)
    }

    // MARK: - wordCount

    /// Barge-in counts new words with `wordCount` and then tests them for echo
    /// with `tokens`. If the two disagreed on what a word is, the count could
    /// clear the barge-in gate on words the echo check never sees.
    func testWordCountAgreesWithTheTokeniserOnTheTwoCharacterFloor() {
        for text in ["a I", "hey stop no", "ok", "x y z", "Your HRV is high today"] {
            let counted = VoiceEchoHeuristics.wordCount(text)
            let tokenised = text.split(whereSeparator: { $0.isWhitespace }).filter { $0.count >= 2 }.count
            XCTAssertEqual(counted, tokenised, "disagreement on: \(text)")
        }
    }

    func testWordCountIgnoresSubTwoCharacterWords() {
        XCTAssertEqual(VoiceEchoHeuristics.wordCount("I am a runner"), 2)
    }

    func testWordCountOfEmptyTextIsZero() {
        XCTAssertEqual(VoiceEchoHeuristics.wordCount(""), 0)
    }

    // MARK: - overlapRatio

    func testOverlapRatioIsTheFractionOfTranscriptTokensFound() {
        XCTAssertEqual(
            VoiceEchoHeuristics.overlapRatio(of: "your hrv is high", against: "your hrv is low"),
            0.75, accuracy: 0.0001
        )
    }

    func testOverlapRatioIsOneForAnExactRepeat() {
        let text = "your recovery score is seventy two"
        XCTAssertEqual(VoiceEchoHeuristics.overlapRatio(of: text, against: text), 1.0, accuracy: 0.0001)
    }

    func testOverlapRatioIsZeroWhenNothingMatches() {
        XCTAssertEqual(
            VoiceEchoHeuristics.overlapRatio(of: "start a workout", against: "your hrv is high"),
            0, accuracy: 0.0001
        )
    }

    /// Nothing overlaps nothing — and the ratio must not divide by zero.
    func testOverlapRatioOfAnEmptyTranscriptIsZero() {
        XCTAssertEqual(VoiceEchoHeuristics.overlapRatio(of: "", against: "anything at all"), 0)
        XCTAssertEqual(VoiceEchoHeuristics.overlapRatio(of: "I a", against: "I a"), 0)
    }

    /// The ratio is directional: it asks how much of the transcript is
    /// accounted for, not how similar the two strings are. A short echo of a
    /// long reply is still an echo.
    func testOverlapRatioIsDirectional() {
        let reply = "your resting heart rate this morning was fifty two beats per minute"
        XCTAssertEqual(
            VoiceEchoHeuristics.overlapRatio(of: "beats per minute", against: reply),
            1.0, accuracy: 0.0001
        )
        XCTAssertLessThan(
            VoiceEchoHeuristics.overlapRatio(of: reply, against: "beats per minute"),
            0.4
        )
    }

    // MARK: - In-flight echo (barge-in guard)

    /// The mic hearing the sentence currently being spoken must not count as
    /// the user interrupting.
    func testTheMicHearingTheInFlightResponseIsEcho() {
        XCTAssertTrue(VoiceEchoHeuristics.isEchoOfInFlightResponse(
            candidate: "recovery looks strong this morning",
            streamedSoFar: "Your recovery looks strong this morning, so a hard session is fine."
        ))
    }

    /// A genuine interruption uses different words and must get through.
    func testAGenuineInterruptionIsNotEcho() {
        XCTAssertFalse(VoiceEchoHeuristics.isEchoOfInFlightResponse(
            candidate: "stop, start a bike ride instead",
            streamedSoFar: "Your recovery looks strong this morning, so a hard session is fine."
        ))
    }

    /// Before the AI has streamed anything there is nothing to echo, so a
    /// barge-in this early is always real.
    func testNothingStreamedYetMeansNothingCanBeEcho() {
        XCTAssertFalse(VoiceEchoHeuristics.isEchoOfInFlightResponse(
            candidate: "stop", streamedSoFar: ""
        ))
    }

    func testACandidateWithNoUsableTokensIsNotEcho() {
        XCTAssertFalse(VoiceEchoHeuristics.isEchoOfInFlightResponse(
            candidate: "a I", streamedSoFar: "a I am talking"
        ))
    }

    /// The in-flight guard is deliberately more permissive than the post-turn
    /// one: missing a barge-in is better than yanking the AI mid-sentence.
    func testTheInFlightThresholdIsLooserThanThePostTurnOne() {
        XCTAssertGreaterThan(
            VoiceEchoHeuristics.inFlightEchoThreshold,
            VoiceEchoHeuristics.longTranscriptEchoThreshold
        )
        XCTAssertLessThan(
            VoiceEchoHeuristics.inFlightEchoThreshold,
            VoiceEchoHeuristics.shortTranscriptEchoThreshold
        )
    }

    func testInFlightEchoFiresAtItsThreshold() {
        // 13 of 20 tokens = 0.65, exactly the threshold.
        let reference = (1 ... 13).map { "w\($0)" }.joined(separator: " ")
        let candidate = ((1 ... 13).map { "w\($0)" } + (90 ... 96).map { "w\($0)" })
            .joined(separator: " ")
        XCTAssertEqual(
            VoiceEchoHeuristics.overlapRatio(of: candidate, against: reference),
            0.65, accuracy: 0.0001
        )
        XCTAssertTrue(VoiceEchoHeuristics.isEchoOfInFlightResponse(
            candidate: candidate, streamedSoFar: reference
        ))
    }

    // MARK: - Post-turn echo

    func testTheAssistantsOwnLastTurnComingBackIsEcho() {
        let reply = "Your sleep last night was six hours and twelve minutes"
        XCTAssertTrue(VoiceEchoHeuristics.looksLikeEcho(transcript: reply, ofLastAssistantTurn: reply))
    }

    func testARealFollowUpQuestionIsNotEcho() {
        XCTAssertFalse(VoiceEchoHeuristics.looksLikeEcho(
            transcript: "what about my training load for tomorrow",
            ofLastAssistantTurn: "Your sleep last night was six hours and twelve minutes"
        ))
    }

    /// A short reply whose words are NOT in the answer is a real turn. This is
    /// the common case the short threshold has to leave alone.
    func testAShortReplyWithItsOwnWordsIsNotEcho() {
        XCTAssertFalse(VoiceEchoHeuristics.looksLikeEcho(
            transcript: "start a run",
            ofLastAssistantTurn: "No problem — thanks for checking in, your numbers look fine."
        ))
    }

    /// Documented consequence of the short-transcript rule: a one-word
    /// transcript whose word appears anywhere in the reply scores 1.0 and is
    /// treated as echo. That is deliberate — right after TTS, a bare "thanks"
    /// the assistant just said itself is far more often speaker bleed than a
    /// user turn, and the cost of dropping it is one lost pleasantry.
    func testAOneWordTranscriptTakenFromTheReplyCountsAsEcho() {
        XCTAssertTrue(VoiceEchoHeuristics.looksLikeEcho(
            transcript: "thanks",
            ofLastAssistantTurn: "No problem — thanks for checking in, your numbers look fine."
        ))
    }

    /// Two words, one of them absent from the reply, is under the 0.85 bar and
    /// gets through — so the rule above does not generalise to short phrases.
    func testATwoWordReplyWithOneNewWordIsNotEcho() {
        XCTAssertFalse(VoiceEchoHeuristics.looksLikeEcho(
            transcript: "thanks Emuqu",
            ofLastAssistantTurn: "No problem — thanks for checking in, your numbers look fine."
        ))
    }

    /// But a short transcript that IS the reply, near-verbatim, still counts.
    func testAShortNearVerbatimEchoIsStillCaught() {
        XCTAssertTrue(VoiceEchoHeuristics.looksLikeEcho(
            transcript: "recovery score seventy two",
            ofLastAssistantTurn: "Recovery score: seventy two."
        ))
    }

    func testEmptyInputsAreNeverEcho() {
        XCTAssertFalse(VoiceEchoHeuristics.looksLikeEcho(transcript: "", ofLastAssistantTurn: "hello there"))
        XCTAssertFalse(VoiceEchoHeuristics.looksLikeEcho(transcript: "hello there", ofLastAssistantTurn: ""))
        XCTAssertFalse(VoiceEchoHeuristics.looksLikeEcho(transcript: "I a", ofLastAssistantTurn: "I a"))
    }

    // MARK: - Threshold selection

    func testFourTokensOrFewerUsesTheShortThreshold() {
        for count in 1 ... 4 {
            XCTAssertEqual(
                VoiceEchoHeuristics.threshold(forTokenCount: count),
                VoiceEchoHeuristics.shortTranscriptEchoThreshold
            )
        }
    }

    func testFiveTokensOrMoreUsesTheLongThreshold() {
        for count in 5 ... 12 {
            XCTAssertEqual(
                VoiceEchoHeuristics.threshold(forTokenCount: count),
                VoiceEchoHeuristics.longTranscriptEchoThreshold
            )
        }
    }

    /// Chance overlap is likelier at short lengths, so the short bar must be
    /// the stricter one. Inverting these would swallow every "yes" and "okay".
    func testTheShortThresholdIsStricter() {
        XCTAssertGreaterThan(
            VoiceEchoHeuristics.shortTranscriptEchoThreshold,
            VoiceEchoHeuristics.longTranscriptEchoThreshold
        )
    }
}
