@testable import Emuqu
import os
import XCTest

/// Voice chat hands its tear-down deactivation to the cue manager's transition
/// queue (`BackgroundAudioManager.deactivateIfIdle`), so the decision and the
/// deactivation run in order with cue activations: a cue that begins at the
/// moment the voice chat ends is never cut off.
final class CueSessionIdleDeactivationTests: XCTestCase {
    func testIdleSessionIsDeactivated() {
        let session = IdleRecordingSession()
        let manager = BackgroundAudioManager(session: session, observesInterruptions: false)
        XCTAssertNil(deactivate(manager))
        XCTAssertEqual(session.deactivations, 1)
    }

    /// A cue speaking when the voice chat ends keeps the session; its own end
    /// deactivates it afterwards.
    func testSpeakingCueKeepsTheSession() {
        let session = IdleRecordingSession()
        let manager = BackgroundAudioManager(session: session, observesInterruptions: false)
        let token = manager.beginCue()
        XCTAssertNil(deactivate(manager))
        XCTAssertEqual(session.deactivations, 0, "a playing cue was cut off")
        manager.endCue(token)
        manager.waitForPendingTransitions()
        XCTAssertEqual(session.deactivations, 1)
    }

    /// Another claimant (dictation, the breathing guide) keeps the session.
    func testOtherClaimantKeepsTheSession() {
        let session = IdleRecordingSession()
        session.setOtherClaimant(true)
        let manager = BackgroundAudioManager(session: session, observesInterruptions: false)
        XCTAssertNil(deactivate(manager))
        XCTAssertEqual(session.deactivations, 0)
    }

    /// A failed deactivation reaches the caller, which retries and then tells
    /// the user.
    func testDeactivationFailureIsReported() {
        let session = IdleRecordingSession()
        session.setFailsDeactivation(true)
        let manager = BackgroundAudioManager(session: session, observesInterruptions: false)
        XCTAssertNotNil(deactivate(manager))
    }

    /// Runs `deactivateIfIdle` and returns the code of the error its
    /// completion received, or nil when it received none.
    private func deactivate(_ manager: BackgroundAudioManager) -> Int? {
        let received = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let done = expectation(description: "completion")
        manager.deactivateIfIdle { error in
            let code = error.map { ($0 as NSError).code }
            received.withLock { $0 = code }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        return received.withLock { $0 }
    }
}

/// Counts deactivations of a stand-in session.
private final class IdleRecordingSession: CueAudioSession {
    private struct State {
        var cueClaimed = false
        var otherClaimant = false
        var failsDeactivation = false
        var deactivations = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var deactivations: Int { state.withLock { $0.deactivations } }

    func setOtherClaimant(_ holds: Bool) {
        state.withLock { $0.otherClaimant = holds }
    }

    func setFailsDeactivation(_ fails: Bool) {
        state.withLock { $0.failsDeactivation = fails }
    }

    func claimCuePlayback() {
        state.withLock { $0.cueClaimed = true }
    }

    func releaseCuePlayback() {
        state.withLock { $0.cueClaimed = false }
    }

    var hasActiveClaims: Bool { state.withLock { $0.cueClaimed || $0.otherClaimant } }

    func activate() throws {}

    func deactivate() throws {
        let fails = state.withLock { (state: inout State) -> Bool in
            if !state.failsDeactivation { state.deactivations += 1 }
            return state.failsDeactivation
        }
        if fails { throw NSError(domain: NSOSStatusErrorDomain, code: 561_017_449) }
    }
}
