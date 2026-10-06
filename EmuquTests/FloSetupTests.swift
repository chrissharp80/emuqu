@testable import Emuqu
import XCTest

/// With no Apple Intelligence and no API key the Flo tab used to show disabled
/// suggestion chips under "Tap a suggestion above": a dead end. It now shows
/// the setup screen, which says what Flo needs and opens Settings → Flo.
@MainActor
final class FloSetupTests: XCTestCase {
    func testNoUsableModelShowsSetupWhicheverProviderIsSelected() {
        XCTAssertEqual(FloInputMode.resolve(activeProviderAvailable: false, appleSelected: true), .setup)
        XCTAssertEqual(FloInputMode.resolve(activeProviderAvailable: false, appleSelected: false), .setup)
    }

    func testAppleShowsSuggestionsAndACloudModelShowsTheComposer() {
        XCTAssertEqual(FloInputMode.resolve(activeProviderAvailable: true, appleSelected: true), .suggestions)
        XCTAssertEqual(FloInputMode.resolve(activeProviderAvailable: true, appleSelected: false), .composer)
    }

    /// Each Apple Intelligence state tells the user something different to do
    /// (turn it on, wait for the download, or add a key instead).
    func testEveryAppleIntelligenceStateHasItsOwnExplanation() {
        let states: [AppleIntelligenceStatus] = [.available, .notEnabled, .modelDownloading, .unsupported]
        let explanations = states.map(\.explanation)
        XCTAssertFalse(explanations.contains { $0.isEmpty })
        XCTAssertEqual(Set(explanations).count, states.count)
    }
}
