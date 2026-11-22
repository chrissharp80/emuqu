import AVFoundation
@testable import Emuqu
import os
import XCTest

/// Characterization tests for `VoiceConversationController`'s public
/// observable surface. Intentionally narrow — the controller's internals
/// couple tightly to AVAudioEngine / AVAudioSession / SFSpeechRecognizer /
/// AVSpeechSynthesizer which cannot be exercised in a unit-test process.
/// These tests pin the default observable values and the State enum so
/// future refactors of those subsystems are protected from breaking the
/// observable contract views depend on.
@MainActor
final class VoiceConversationControllerTests: XCTestCase {

    // MARK: - Shared singleton + initial state

    func testSharedSingletonIsPersistent() {
        let a = VoiceConversationController.shared
        let b = VoiceConversationController.shared
        XCTAssertTrue(a === b, "Shared instance must be a single object")
    }

    func testInitialStateIsIdle() {
        let c = VoiceConversationController.shared
        XCTAssertEqual(c.state, .idle)
    }

    // MARK: - State Equatable contract

    func testStateEquatableIdentity() {
        XCTAssertEqual(VoiceConversationController.State.idle, .idle)
        XCTAssertEqual(VoiceConversationController.State.listening, .listening)
        XCTAssertEqual(VoiceConversationController.State.speaking, .speaking)
        XCTAssertEqual(VoiceConversationController.State.triggerSpeaking, .triggerSpeaking)
        XCTAssertEqual(VoiceConversationController.State.starting, .starting)
    }

    func testStateEquatableDistinctness() {
        XCTAssertNotEqual(VoiceConversationController.State.idle, .listening)
        XCTAssertNotEqual(VoiceConversationController.State.listening, .speaking)
        XCTAssertNotEqual(VoiceConversationController.State.speaking, .triggerSpeaking)
    }

    // MARK: - Sentence chunking integration

    /// The chunker the controller feeds every streamed delta through
    /// (`ingestInterjectionDelta`, `finishInterjection`) must cut speech exactly
    /// like a standalone `SpokenTextChunker`: whole sentences, markdown
    /// stripped, the unterminated tail held until the turn finishes.
    func testTheControllersChunkerSplitsSentencesLikeAStandaloneOne() {
        let controllerChunker = VoiceConversationController.shared.textChunker
        controllerChunker.reset()
        defer { controllerChunker.reset() }
        let reference = SpokenTextChunker()
        let deltas = ["Run **hard** now. Then", " rest. Next up: walk", " home"]

        let spoken = deltas.map { controllerChunker.append(delta: $0) }
        XCTAssertEqual(spoken, deltas.map { reference.append(delta: $0) })
        XCTAssertEqual(spoken, ["Run hard now.", "Then rest.", nil])
        XCTAssertEqual(controllerChunker.finalize(), "Next up: walk home")
        XCTAssertNil(controllerChunker.finalize(), "finalize empties the buffer")
    }
}

/// The queue coach lines wait in behind the conversation.
final class VoiceTriggerQueueTests: XCTestCase {
    /// A newer route line replaces one still queued: both describe the same
    /// approach, and only the latest is still true.
    func testANewerRouteLineReplacesTheQueuedOne() {
        var queue = VoiceTriggerQueue()
        _ = queue.enqueue(.spokenLiteral("In 150 meters, turn left"), isRouteLine: true)
        _ = queue.enqueue(.spokenLiteral("Mile 3 in 8:45"))
        XCTAssertEqual(queue.enqueue(.spokenLiteral("Turn left"), isRouteLine: true), 1)
        XCTAssertEqual(lines(&queue), ["Mile 3 in 8:45", "Turn left"])
    }

    /// A route line that waited past its age is dropped, not played after the
    /// turn; other lines keep their place.
    func testAStaleRouteLineIsDropped() {
        var queue = VoiceTriggerQueue()
        let queuedAt = Date(timeIntervalSince1970: 1_000)
        _ = queue.enqueue(.spokenLiteral("Turn left"), isRouteLine: true, now: queuedAt)
        _ = queue.enqueue(.spokenLiteral("Mile 3 in 8:45"), now: queuedAt)
        let later = queuedAt.addingTimeInterval(VoiceTriggerQueue.routeLineMaxAge + 1)
        XCTAssertEqual(text(queue.popFirst(now: later)), "Mile 3 in 8:45")
        XCTAssertNil(queue.popFirst(now: later))
    }

    /// Over capacity, scripted lines go first; a queued AI prompt (an
    /// interval call) is the only copy of its call and stays.
    func testOverCapacityTheOldestScriptedLineGoesFirst() {
        var queue = VoiceTriggerQueue()
        _ = queue.enqueue(.aiPrompt("Announce the interval", fallback: "Interval 2 of 5"))
        for index in 0 ..< VoiceTriggerQueue.capacity {
            _ = queue.enqueue(.spokenLiteral("line \(index)"))
        }
        XCTAssertEqual(queue.count, VoiceTriggerQueue.capacity)
        guard case let .aiPrompt(prompt, fallback) = queue.popFirst() else { return XCTFail("the AI prompt was dropped") }
        XCTAssertEqual(prompt, "Announce the interval")
        XCTAssertEqual(fallback, "Interval 2 of 5")
        XCTAssertEqual(text(queue.popFirst()), "line 1")
    }

    func testMuteDropsScriptedLinesAndKeepsPrompts() {
        var queue = VoiceTriggerQueue()
        _ = queue.enqueue(.spokenLiteral("Mile 3 in 8:45"))
        _ = queue.enqueue(.aiPrompt("Summarise recovery", fallback: nil))
        queue.discardSpokenLines()
        XCTAssertEqual(queue.count, 1)
    }

    private func text(_ trigger: VoiceTriggerQueue.Trigger?) -> String? {
        guard case let .spokenLiteral(line) = trigger else { return nil }
        return line
    }

    private func lines(_ queue: inout VoiceTriggerQueue) -> [String] {
        var out: [String] = []
        while let next = queue.popFirst() { out.append(text(next) ?? "prompt") }
        return out
    }
}

/// `CoachCueSpeech` without the speech: what it does with a line's
/// audio-session hold and with an AI line's scripted fallback.
@MainActor
final class CoachCueSpeechTests: XCTestCase {
    /// The fallback is said once: taking it clears it.
    func testTheFallbackIsTakenOnce() {
        let manager = BackgroundAudioManager(session: CountingCueSession(), observesInterruptions: false)
        let cue = CoachCueSpeech(synthesizer: AVSpeechSynthesizer(), audio: { manager })
        cue.fallback = "Interval 2 of 5"
        XCTAssertEqual(cue.takeFallback(), "Interval 2 of 5")
        XCTAssertNil(cue.takeFallback())
    }

    /// A line stopped while its session claim came up is never spoken, and
    /// its hold is given back, so the session is deactivated again. Handing
    /// over the line also retires the fallback: something was said.
    ///
    /// The session's activation is held open until the line has been
    /// stopped, so `stopAll()` lands while the claim is in flight.
    func testALineStoppedWhileClaimingGivesItsHoldBack() async {
        let session = CountingCueSession(holdsActivation: true)
        defer { session.releaseActivation() }
        let manager = BackgroundAudioManager(session: session, observesInterruptions: false)
        let synthesizer = AVSpeechSynthesizer()
        let cue = CoachCueSpeech(synthesizer: synthesizer, audio: { manager })
        cue.fallback = "Interval 2 of 5"
        cue.speak(AVSpeechUtterance(string: "Coach alert")) {}
        XCTAssertNil(cue.fallback)
        XCTAssertTrue(cue.isBusy, "a line waiting for the session counts as speech")
        for _ in 0 ..< 500 where session.activations == 0 {
            await sleepQuietly(10_000_000, context: "CoachCueSpeechTests")
        }
        XCTAssertEqual(session.activations, 1, "the claim never reached the session")
        XCTAssertEqual(session.deactivations, 0)
        cue.stopAll()
        XCTAssertFalse(cue.isBusy)
        session.releaseActivation()
        for _ in 0 ..< 500 where session.deactivations == 0 {
            await sleepQuietly(10_000_000, context: "CoachCueSpeechTests")
            manager.waitForPendingTransitions()
        }
        XCTAssertEqual(session.activations, 1)
        XCTAssertEqual(session.deactivations, 1, "the dropped line's hold was not given back")
        XCTAssertFalse(synthesizer.isSpeaking)
    }
}

/// Counts activations and deactivations of a stand-in session. With
/// `holdsActivation`, `activate()` counts the activation and then blocks,
/// off the main actor, until `releaseActivation()`, so a test can act while
/// a cue's claim is still coming up.
private final class CountingCueSession: CueAudioSession {
    private struct State {
        var cueClaimed = false
        var activations = 0
        var deactivations = 0
        var activationReleased: Bool
    }

    private let state: OSAllocatedUnfairLock<State>
    private let activationGate = DispatchSemaphore(value: 0)

    init(holdsActivation: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(activationReleased: !holdsActivation))
    }

    var activations: Int { state.withLock { $0.activations } }
    var deactivations: Int { state.withLock { $0.deactivations } }

    func claimCuePlayback() { state.withLock { $0.cueClaimed = true } }
    func releaseCuePlayback() { state.withLock { $0.cueClaimed = false } }
    var hasActiveClaims: Bool { state.withLock { $0.cueClaimed } }

    func activate() throws {
        let blocks = state.withLock { (state: inout State) -> Bool in
            state.activations += 1
            return !state.activationReleased
        }
        if blocks { _ = activationGate.wait(timeout: .now() + 10) }
    }

    func deactivate() throws { state.withLock { $0.deactivations += 1 } }

    /// Lets a held `activate()` return, and every later one return at once.
    /// Calling it again does nothing.
    func releaseActivation() {
        let wasHeld = state.withLock { (state: inout State) -> Bool in
            defer { state.activationReleased = true }
            return !state.activationReleased
        }
        if wasHeld { activationGate.signal() }
    }
}
