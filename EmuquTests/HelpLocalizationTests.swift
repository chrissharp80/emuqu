@testable import Emuqu
import XCTest

/// Holds `Help.xcstrings` to the Help Center's content.
///
/// The articles are English in `HelpContent*.swift` and are translated at
/// display time by exact English text (`HelpLocalization`). Nothing else ties
/// the two together, so an edited sentence would silently fall back to English
/// in every other language. These tests make that loud in both directions:
/// every string the Help Center shows has a translation in every shipped
/// language, and the table holds nothing the Help Center no longer shows.
@MainActor
final class HelpLocalizationTests: XCTestCase {
    /// One age per RMSSD band, plus no age, so every personalised variant of
    /// the HRV articles is looked up at least once.
    private static let ages: [Int?] = [nil, 15, 25, 35, 45, 55, 65, 75]

    private func everyHelpKey() -> Set<String> {
        HelpLocalization.startRecording()
        for age in Self.ages {
            _ = HelpContent.categories(forAge: age)
        }
        return HelpLocalization.stopRecording()
    }

    /// Writes the key list when `HELP_KEYS_OUT` is set (pass it as
    /// `TEST_RUNNER_HELP_KEYS_OUT`), which is how the table is regenerated.
    private func exportKeysIfRequested(_ keys: Set<String>) throws {
        guard let path = ProcessInfo.processInfo.environment["HELP_KEYS_OUT"], !path.isEmpty else { return }
        let data = try JSONSerialization.data(withJSONObject: keys.sorted(), options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func compiledTable(for language: String) throws -> [String: String] {
        let path = try XCTUnwrap(
            Bundle.main.path(forResource: HelpLocalization.table, ofType: "strings", inDirectory: nil, forLocalization: language),
            "no compiled Help table for \(language)"
        )
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String], "unreadable Help table for \(language)")
    }

    private var shippedLanguages: [String] {
        Bundle.main.localizations.filter { $0 != "en" && $0 != "Base" }.sorted()
    }

    func testTheContentLooksUpAKnownNumberOfStrings() throws {
        let keys = everyHelpKey()
        try exportKeysIfRequested(keys)
        XCTAssertGreaterThan(keys.count, 300, "the recorder saw too few strings to be the Help Center")
        XCTAssertFalse(keys.contains { $0.contains("\u{2060}") }, "a formatted string was looked up as a key")
    }

    func testEveryHelpStringIsTranslatedInEveryLanguage() throws {
        let keys = everyHelpKey()
        XCTAssertGreaterThanOrEqual(shippedLanguages.count, 16)
        for language in shippedLanguages {
            let table = try compiledTable(for: language)
            let missing = keys.subtracting(table.keys).sorted()
            XCTAssertTrue(missing.isEmpty, "\(language): \(missing.count) Help strings untranslated, e.g. \(missing.prefix(3))")
        }
    }

    func testTheHelpTableHoldsNothingTheHelpCenterNoLongerShows() throws {
        let keys = everyHelpKey()
        for language in shippedLanguages {
            let stale = Set(try compiledTable(for: language).keys).subtracting(keys).sorted()
            XCTAssertTrue(stale.isEmpty, "\(language): \(stale.count) stale Help entries, e.g. \(stale.prefix(3))")
        }
    }

    /// Tokens survive translation, or a reader's age would print as "{age}".
    func testTranslationsKeepEveryPlaceholderToken() throws {
        let token = try NSRegularExpression(pattern: "\\{[a-z]+\\}")
        for language in shippedLanguages {
            for (key, value) in try compiledTable(for: language) {
                let wanted = Set(token.matches(in: key, range: NSRange(key.startIndex..., in: key)).map { (key as NSString).substring(with: $0.range) })
                let found = Set(token.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { (value as NSString).substring(with: $0.range) })
                XCTAssertEqual(wanted, found, "\(language) changed the placeholders in: \(key.prefix(60))")
            }
        }
    }
}
