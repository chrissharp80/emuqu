@testable import Emuqu
import XCTest

/// The conversation voice is looked up off the main actor, because the first
/// enumeration of installed voices can block for seconds while the speech
/// service starts, and each language is enumerated once per launch.
final class ConversationVoicePickerTests: XCTestCase {
    func testLookupRunsOffTheMainActorAndIsCached() async {
        let first = await Task.detached { ConversationVoicePicker.bestVoice(for: "en-US") }.value
        let second = await Task.detached { ConversationVoicePicker.bestVoice(for: "en-US") }.value
        XCTAssertNotNil(first, "an English voice ships with every simulator and device")
        XCTAssertTrue(first === second, "the second lookup enumerated again instead of reading the cache")
    }
}
