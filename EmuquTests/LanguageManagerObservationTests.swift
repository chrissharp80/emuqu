@testable import Emuqu
import XCTest

/// The app root re-renders on a language change only if something it reads is
/// observed. `locale` is lock-backed for its nonisolated readers and therefore
/// invisible to Observation; `currentLocale` is the root's tracked view of it.
@MainActor
final class LanguageManagerObservationTests: XCTestCase {
    /// The defect this pins: after the Observation migration the root injected
    /// the untracked `locale`, so picking another language in Settings moved
    /// the picker's checkmark and nothing else until relaunch.
    func testTheRootLocaleIsObservedAcrossALanguageChange() {
        let manager = LanguageManager.shared
        let original = AppLanguage.current
        defer { manager.setLanguage(original) }

        let fired = expectation(description: "currentLocale change observed")
        withObservationTracking {
            _ = manager.currentLocale
        } onChange: {
            fired.fulfill()
        }

        manager.setLanguage(original == .de ? .en : .de)
        wait(for: [fired], timeout: 1)
        XCTAssertEqual(manager.currentLocale, manager.locale)
    }
}
