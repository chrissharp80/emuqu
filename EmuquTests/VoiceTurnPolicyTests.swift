@testable import Emuqu
import XCTest

/// Tests for whose turn it is in a spoken conversation.
///
/// Both decisions encode reported bugs and both were unreachable — the audio
/// pipeline sat at 0–3% coverage because testing it meant driving
/// `AVAudioEngine` and the speech recogniser.
final class VoiceTurnPolicyTests: XCTestCase {
    private typealias State = VoiceConversationController.State

    // MARK: - Restarting recognition

    /// The two errors that mean "the recognition task died but the session is
    /// fine" — the only ones a restart can fix.
    func testTheKnownRecoverableErrorsRestartWhileListening() {
        XCTAssertTrue(VoiceTurnPolicy.shouldRestartRecognition(
            errorDomain: "kAFAssistantErrorDomain", errorCode: 1110, state: .listening))
        XCTAssertTrue(VoiceTurnPolicy.shouldRestartRecognition(
            errorDomain: "kLSRErrorDomain", errorCode: 301, state: .listening))
    }

    /// The defect this pins: restarting while TTS is playing re-arms the mic
    /// against the synthesiser and can cut the assistant off mid-sentence. The
    /// natural `.speaking` → `.listening` transition re-arms it cleanly instead.
    func testARecoverableErrorDoesNotRestartWhileSpeaking() {
        XCTAssertFalse(VoiceTurnPolicy.shouldRestartRecognition(
            errorDomain: "kAFAssistantErrorDomain", errorCode: 1110, state: .speaking))
        XCTAssertFalse(VoiceTurnPolicy.shouldRestartRecognition(
            errorDomain: "kAFAssistantErrorDomain", errorCode: 1110, state: .triggerSpeaking))
    }

    /// Only `.listening` restarts — every other state either has no mic loop to
    /// re-arm or is about to create one anyway.
    func testOnlyListeningRestarts() {
        for state in [State.idle, .starting, .thinking, .speaking, .triggerSpeaking] {
            XCTAssertFalse(
                VoiceTurnPolicy.shouldRestartRecognition(
                    errorDomain: "kLSRErrorDomain", errorCode: 301, state: state),
                "\(state) must not restart recognition"
            )
        }
    }

    /// An unrecognised failure is left to the watchdogs, which can tell a dead
    /// task from a healthy-but-quiet one. Retrying blindly loops.
    func testUnknownErrorsAreNotRestarted() {
        XCTAssertFalse(VoiceTurnPolicy.shouldRestartRecognition(
            errorDomain: "kAFAssistantErrorDomain", errorCode: 1101, state: .listening))
        XCTAssertFalse(VoiceTurnPolicy.shouldRestartRecognition(
            errorDomain: "NSURLErrorDomain", errorCode: 1110, state: .listening))
        XCTAssertFalse(VoiceTurnPolicy.shouldRestartRecognition(
            errorDomain: "", errorCode: 0, state: .listening))
    }

    /// The domain and code must match together — a right code under the wrong
    /// domain is a different failure entirely.
    func testTheDomainAndCodeMustMatchAsAPair() {
        XCTAssertFalse(VoiceTurnPolicy.shouldRestartRecognition(
            errorDomain: "kLSRErrorDomain", errorCode: 1110, state: .listening))
        XCTAssertFalse(VoiceTurnPolicy.shouldRestartRecognition(
            errorDomain: "kAFAssistantErrorDomain", errorCode: 301, state: .listening))
    }

    // MARK: - Interrupting the user

    private func busy(
        _ state: State,
        llm: Bool = false,
        streaming: Bool = false,
        speaking: Bool = false,
        partial: Bool = false
    ) -> Bool {
        VoiceTurnPolicy.isBusyWithUserResponse(
            state: state, hasInFlightLLMTask: llm, isStreamingResponse: streaming,
            synthesizerIsSpeaking: speaking, hasPartialTranscript: partial
        )
    }

    /// The reported bug — "alerts wipe out my message". A trigger speaking over
    /// a sentence in progress clears the partial transcript and the user's words
    /// are gone.
    func testAUserMidSentenceIsBusy() {
        XCTAssertTrue(busy(.listening, partial: true))
    }

    /// Listening with nothing said yet is free — that is the moment a trigger
    /// is least intrusive.
    func testListeningWithNothingSaidYetIsFree() {
        XCTAssertFalse(busy(.listening, partial: false))
    }

    func testAnInFlightResponseIsBusy() {
        XCTAssertTrue(busy(.thinking, llm: true))
        XCTAssertTrue(busy(.listening, llm: true))
        XCTAssertTrue(busy(.listening, streaming: true))
    }

    func testThinkingIsBusyEvenWithNoTaskHandle() {
        XCTAssertTrue(busy(.thinking))
    }

    /// The synthesiser check is paired with `.speaking` on purpose: audio can
    /// still be draining after the state has moved on, and that tail must not
    /// block the next trigger forever.
    func testASpeakingSynthesiserOnlyBlocksWhileTheStateAgrees() {
        XCTAssertTrue(busy(.speaking, speaking: true))
        XCTAssertFalse(busy(.idle, speaking: true))
        XCTAssertFalse(busy(.listening, speaking: true))
    }

    /// A trigger already speaking chains into the next one rather than queueing
    /// behind itself forever.
    func testATriggerAlreadySpeakingIsNotBusy() {
        XCTAssertFalse(busy(.triggerSpeaking, speaking: true, partial: true))
        XCTAssertFalse(busy(.triggerSpeaking, llm: true, streaming: true))
    }

    /// Idle and starting are always free — nothing to interrupt.
    func testIdleAndStartingAreFree() {
        XCTAssertFalse(busy(.idle))
        XCTAssertFalse(busy(.starting))
    }

    // MARK: - Whole-space property

    /// Across every combination, `.triggerSpeaking` is the only state that is
    /// free while work is in flight. If any other state leaked through, a
    /// trigger could fire over a response being generated.
    func testOnlyTriggerSpeakingIsFreeWhileWorkIsInFlight() {
        for state in [State.idle, .starting, .listening, .thinking, .speaking, .triggerSpeaking] {
            let result = busy(state, llm: true, streaming: true)
            if state == .triggerSpeaking {
                XCTAssertFalse(result)
            } else {
                XCTAssertTrue(result, "\(state) must be busy while a response is in flight")
            }
        }
    }

    // MARK: - Telling one stream from the next

    private typealias Edge = VoiceTurnPolicy.StreamEdge

    /// The defect this pins: the view model finishes the in-flight stream and
    /// drains the queued send in one run, so the observation loop delivers a
    /// single `isStreaming == true`. Read as a Bool that is "no change" and
    /// the queued reply arrived as silent text. The generation moved, so the
    /// queued turn is visible.
    func testAQueuedTurnIsVisibleWhenFinishAndRedispatchCollapseIntoOneDelivery() {
        let wired = Edge(isStreaming: true, generation: 4)
        XCTAssertTrue(VoiceTurnPolicy.queuedTurnStarted(
            wiredTo: wired, now: Edge(isStreaming: true, generation: 5)))
    }

    /// The stream the loop queued behind is not the queued turn, however many
    /// times its value is re-delivered.
    func testTheInFlightStreamDoesNotCountAsTheQueuedTurn() {
        let wired = Edge(isStreaming: true, generation: 4)
        XCTAssertFalse(VoiceTurnPolicy.queuedTurnStarted(wiredTo: wired, now: wired))
        XCTAssertFalse(VoiceTurnPolicy.queuedTurnStarted(
            wiredTo: wired, now: Edge(isStreaming: false, generation: 4)))
    }

    /// Cancelling bumps the generation without starting a stream; nothing to
    /// speak.
    func testACancelledStreamDoesNotStartSpeaking() {
        XCTAssertFalse(VoiceTurnPolicy.queuedTurnStarted(
            wiredTo: Edge(isStreaming: true, generation: 4),
            now: Edge(isStreaming: false, generation: 5)))
    }

    /// The spoken response is over when its stream stops, and equally when a
    /// follow-up queued during the reply has already replaced it in the same
    /// delivery; both must drain the remainder and reopen the mic.
    func testASpokenResponseFinishesOnStopOrOnReplacement() {
        let wired = Edge(isStreaming: true, generation: 4)
        XCTAssertTrue(VoiceTurnPolicy.spokenResponseFinished(
            wiredTo: wired, now: Edge(isStreaming: false, generation: 4)))
        XCTAssertTrue(VoiceTurnPolicy.spokenResponseFinished(
            wiredTo: wired, now: Edge(isStreaming: true, generation: 5)))
        XCTAssertFalse(VoiceTurnPolicy.spokenResponseFinished(wiredTo: wired, now: wired))
    }
}
