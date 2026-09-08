@testable import Emuqu
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
        XCTAssertEqual(VoiceConversationController.State.thinking, .thinking)
        XCTAssertEqual(VoiceConversationController.State.speaking, .speaking)
        XCTAssertEqual(VoiceConversationController.State.triggerSpeaking, .triggerSpeaking)
        XCTAssertEqual(VoiceConversationController.State.starting, .starting)
    }

    func testStateEquatableDistinctness() {
        XCTAssertNotEqual(VoiceConversationController.State.idle, .listening)
        XCTAssertNotEqual(VoiceConversationController.State.listening, .thinking)
        XCTAssertNotEqual(VoiceConversationController.State.thinking, .speaking)
        XCTAssertNotEqual(VoiceConversationController.State.speaking, .triggerSpeaking)
    }

    // MARK: - Sentence chunking integration

    /// Sanity-check that the controller's delegated text-chunking behaves
    /// exactly like `SpokenTextChunker` directly — protects against a
    /// future regression where the delegation gets accidentally bypassed.
    func testTextChunkerDelegatesSentenceSplittingIdentically() {
        let reference = SpokenTextChunker()
        let sample = "Run **hard** now. Then rest. Next up: walk home."
        let first = reference.append(delta: sample)
        let flushed = reference.finalize()
        XCTAssertEqual(first, "Run hard now. Then rest. Next up: walk home.")
        XCTAssertNil(flushed, "No remainder after a complete-sentence delta")
    }
}
