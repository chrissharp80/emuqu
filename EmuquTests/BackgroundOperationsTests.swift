@testable import Emuqu
import XCTest

/// Tests for the workout cue audio session.
///
/// These tests verify:
/// - A cue holds the audio session only between `beginCue` and `endCue`
/// - Unmatched or repeated ends and stops are safe
@MainActor
final class BackgroundOperationsTests: XCTestCase {
    // MARK: - Cue audio session

    func testCueHoldsTheSessionOnlyWhileSpeaking() {
        let audioManager = BackgroundAudioManager.shared
        XCTAssertFalse(audioManager.isRunning, "No cue is held initially")

        audioManager.beginCue()
        XCTAssertTrue(audioManager.isRunning, "A cue holds the session while it speaks")

        audioManager.endCue()
        XCTAssertFalse(audioManager.isRunning, "The session is released when the cue ends")
    }

    /// Two overlapping cues: the session stays held until the second ends.
    func testOverlappingCuesReleaseOnTheLastEnd() {
        let audioManager = BackgroundAudioManager.shared

        audioManager.beginCue()
        audioManager.beginCue()
        audioManager.endCue()
        XCTAssertTrue(audioManager.isRunning, "One cue is still speaking")

        audioManager.endCue()
        XCTAssertFalse(audioManager.isRunning)
    }

    /// A finish callback for an utterance that never began a cue (the launch
    /// warm-up) must not drive the count below zero.
    func testUnmatchedEndIsSafe() {
        let audioManager = BackgroundAudioManager.shared

        audioManager.endCue()
        audioManager.beginCue()
        XCTAssertTrue(audioManager.isRunning, "An earlier unmatched end must not cancel a later cue")

        audioManager.endCue()
        XCTAssertFalse(audioManager.isRunning)
    }

    func testStopEndsEveryCueAndIsIdempotent() {
        let audioManager = BackgroundAudioManager.shared

        audioManager.beginCue()
        audioManager.beginCue()
        audioManager.stopBackgroundAudio()
        XCTAssertFalse(audioManager.isRunning, "Workout end releases every cue")

        audioManager.stopBackgroundAudio()
        XCTAssertFalse(audioManager.isRunning, "Should still be stopped after double stop")
        XCTAssertFalse(audioManager.wasInterrupted)
    }

    func testFreshCueIsNotMarkedInterrupted() {
        let audioManager = BackgroundAudioManager.shared

        audioManager.beginCue()
        XCTAssertFalse(audioManager.wasInterrupted, "Should not be interrupted after a fresh cue")

        audioManager.endCue()
    }
}
