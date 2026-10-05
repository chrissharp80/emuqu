import AVFoundation
@testable import Emuqu
import os
import XCTest

/// Tests for the workout cue audio session.
///
/// These tests verify:
/// - The session is claimed and activated when a cue begins, and released and
///   deactivated when the last cue ends, unless another claimant holds it
/// - Only a cue's own token ends its hold: stale, repeated and post-interruption
///   ends are ignored
/// - Workout stop deactivates an idle session and lets a speaking cue finish
/// - Concurrent cues never leave a held cue on a deactivated session
@MainActor
final class BackgroundOperationsTests: XCTestCase {
    /// XCTest builds a fresh instance per test, so each test gets its own
    /// session and manager.
    private let session = RecordingCueSession()
    private lazy var manager = BackgroundAudioManager(session: session, observesInterruptions: false)

    // MARK: - One cue

    func testCueHoldsTheSessionOnlyWhileSpeaking() {
        XCTAssertFalse(manager.isRunning, "No cue is held initially")

        let token = manager.beginCue()
        XCTAssertTrue(manager.isRunning, "A cue holds the session while it speaks")
        XCTAssertEqual(session.events, [.claim, .activate], "The session is up before the utterance is queued")

        manager.endCue(token)
        manager.waitForPendingTransitions()
        XCTAssertFalse(manager.isRunning, "The session is released when the cue ends")
        XCTAssertEqual(session.events, [.claim, .activate, .release, .deactivate])
    }

    func testOverlappingCuesActivateOnceAndReleaseOnTheLastEnd() {
        let first = manager.beginCue()
        let second = manager.beginCue()
        manager.endCue(first)
        manager.waitForPendingTransitions()
        XCTAssertTrue(manager.isRunning, "One cue is still speaking")
        XCTAssertEqual(session.events, [.claim, .activate], "A second cue doesn't reactivate, and the first end doesn't release")

        manager.endCue(second)
        manager.waitForPendingTransitions()
        XCTAssertFalse(manager.isRunning)
        XCTAssertEqual(session.events, [.claim, .activate, .release, .deactivate])
    }

    func testRepeatedEndOfOneTokenCannotEndAnotherCue() {
        let first = manager.beginCue()
        let second = manager.beginCue()
        manager.endCue(first)
        manager.endCue(first)
        manager.waitForPendingTransitions()
        XCTAssertTrue(manager.isRunning, "A second end of the first cue must not release the second")
        XCTAssertFalse(session.events.contains(.deactivate))

        manager.endCue(second)
        manager.waitForPendingTransitions()
        XCTAssertFalse(manager.isRunning)
    }

    func testAnotherClaimantKeepsTheSessionActive() {
        session.setOtherClaimant(true)
        let token = manager.beginCue()
        manager.endCue(token)
        manager.waitForPendingTransitions()
        XCTAssertFalse(manager.isRunning)
        XCTAssertEqual(
            session.events, [.claim, .activate, .release],
            "With a voice chat or the breathing guide holding the session, the cue drops only its claim"
        )
    }

    // MARK: - Interruptions

    func testInterruptionEndsEveryHoldAndIsRecorded() {
        _ = manager.beginCue()
        _ = manager.beginCue()
        manager.interruptionBegan()
        manager.waitForPendingTransitions()
        XCTAssertFalse(manager.isRunning, "An interruption ends every cue's hold")
        XCTAssertTrue(manager.wasInterrupted)
        XCTAssertEqual(session.events, [.claim, .activate, .release, .deactivate], "The same release path as a finished cue")
    }

    func testLateCancelAfterInterruptionDoesNotReleaseTheNextCue() {
        let interrupted = manager.beginCue()
        manager.interruptionBegan()
        let next = manager.beginCue()
        XCTAssertFalse(manager.wasInterrupted, "A new cue clears the interrupted flag")

        manager.endCue(interrupted)
        manager.waitForPendingTransitions()
        XCTAssertTrue(manager.isRunning, "The cut utterance's late cancel must not end the next cue")
        XCTAssertEqual(session.events.last, .activate, "The next cue's session stays active")

        manager.endCue(next)
        manager.waitForPendingTransitions()
        XCTAssertFalse(manager.isRunning)
        XCTAssertEqual(session.events.last, .deactivate)
    }

    // MARK: - Workout stop

    func testStopWithNoCueDeactivatesTheSession() {
        manager.stopBackgroundAudio()
        manager.waitForPendingTransitions()
        XCTAssertEqual(session.events, [.release, .deactivate], "Nothing keeps the session active after the workout")
        XCTAssertFalse(manager.wasInterrupted)
    }

    func testStopLeavesASpeakingCueToFinish() {
        let token = manager.beginCue()
        manager.stopBackgroundAudio()
        manager.waitForPendingTransitions()
        XCTAssertTrue(manager.isRunning, "A cue mid-sentence isn't cut off")
        XCTAssertFalse(session.events.contains(.deactivate))

        manager.endCue(token)
        manager.waitForPendingTransitions()
        XCTAssertEqual(session.events.last, .deactivate, "The cue deactivates the session when it finishes")
    }

    func testStopWithAnotherClaimantLeavesTheSessionActive() {
        session.setOtherClaimant(true)
        manager.stopBackgroundAudio()
        manager.stopBackgroundAudio()
        manager.waitForPendingTransitions()
        XCTAssertFalse(session.events.contains(.deactivate), "A voice chat outlives the workout")
    }

    // MARK: - Concurrency

    /// Cues begin and end on many threads at once. Every cue must find the
    /// session active from its `beginCue()` until its own `endCue(_:)`, and
    /// the session must be inactive once all have ended.
    func testConcurrentCuesNeverRunOnADeactivatedSession() {
        let manager = manager
        let session = session
        let violations = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 400) { @Sendable _ in
            let token = manager.beginCue()
            if !session.isActive { violations.withLock { $0 += 1 } }
            manager.endCue(token)
        }
        manager.waitForPendingTransitions()
        XCTAssertEqual(violations.withLock { $0 }, 0, "A held cue found the session deactivated")
        XCTAssertFalse(manager.isRunning)
        XCTAssertFalse(session.isActive, "The last end deactivates the session")
        XCTAssertTrue(session.transitionsAlternate, "Claim/activate and release/deactivate never interleave")
    }

    // MARK: - Releaser

    func testReleaserEndsOnlyTheTrackedUtterancesCue() {
        let releaser = CueAudioSessionReleaser(manager: manager)
        let synthesizer = AVSpeechSynthesizer()
        let tracked = AVSpeechUtterance(string: "Run started")
        releaser.track(tracked, token: manager.beginCue())

        releaser.speechSynthesizer(synthesizer, didFinish: AVSpeechUtterance(string: "Other"))
        manager.waitForPendingTransitions()
        XCTAssertTrue(manager.isRunning, "A callback for an untracked utterance does nothing")

        releaser.speechSynthesizer(synthesizer, didCancel: tracked)
        releaser.speechSynthesizer(synthesizer, didFinish: tracked)
        manager.waitForPendingTransitions()
        XCTAssertFalse(manager.isRunning)
        XCTAssertEqual(session.events.filter { $0 == .deactivate }.count, 1, "A repeated callback ends nothing more")
    }
}

/// Records what `BackgroundAudioManager` does to the session.
private final class RecordingCueSession: CueAudioSession {
    enum Event: Equatable, Sendable {
        case claim, activate, release, deactivate
    }

    private struct State {
        var events: [Event] = []
        var cueClaimed = false
        var otherClaimant = false
        var active = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var events: [Event] { state.withLock { $0.events } }
    var isActive: Bool { state.withLock { $0.active } }

    /// True when the events are whole claim-activate / release-deactivate
    /// pairs in turn, as one serial queue produces them.
    var transitionsAlternate: Bool {
        let events = events
        let up: [Event] = [.claim, .activate]
        let down: [Event] = [.release, .deactivate]
        return stride(from: 0, to: events.count, by: 2).allSatisfy { index in
            let pair = Array(events[index..<min(index + 2, events.count)])
            return pair == (index % 4 == 0 ? up : down)
        }
    }

    func setOtherClaimant(_ holds: Bool) {
        state.withLock { $0.otherClaimant = holds }
    }

    func claimCuePlayback() {
        state.withLock { $0.cueClaimed = true; $0.events.append(.claim) }
    }

    func releaseCuePlayback() {
        state.withLock { $0.cueClaimed = false; $0.events.append(.release) }
    }

    var hasActiveClaims: Bool { state.withLock { $0.cueClaimed || $0.otherClaimant } }

    func activate() throws {
        state.withLock { $0.active = true; $0.events.append(.activate) }
    }

    func deactivate() throws {
        state.withLock { $0.active = false; $0.events.append(.deactivate) }
    }
}
