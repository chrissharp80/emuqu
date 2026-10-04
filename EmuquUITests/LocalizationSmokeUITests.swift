import XCTest

/// Localization smoke coverage.
///
/// Source strings are catalogued across 17 languages, but a catalogue
/// does not prove the app actually renders in the language it is launched
/// in.
///
/// This suite launches the app under different `AppleLanguages`
/// arguments (the standard XCUITest pattern for forcing a locale) and, for
/// each, finds the disclaimer's agree button by its locale-independent
/// identifier and asserts its label is that language's translation of
/// "I Agree" from Localizable.xcstrings. A UI that stayed in English, or a
/// missing translation, fails here.
///
/// A sample of four languages (en / ja / de / ar, the last right-to-left)
/// rather than all 17. Adding one is a one-line call with the catalogue's
/// translation.
@MainActor
final class LocalizationSmokeUITests: XCTestCase {

    private func makeApp(language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-UITests",
            "-UITests-FreshInstall",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", language
        ]
        return app
    }

    /// Launches in `language` and asserts the disclaimer's agree button
    /// reads `expectedLabel`.
    private func assertAgreeButton(
        language: String,
        reads expectedLabel: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let app = makeApp(language: language)
        app.launch()
        defer { app.terminate() }
        let agreeButton = app.buttons[UITestID.disclaimerAgree]
        XCTAssertTrue(
            agreeButton.waitForExistence(timeout: UITestTiming.s(10)),
            "\(language) launch must reach the disclaimer gate",
            file: file, line: line
        )
        XCTAssertEqual(agreeButton.label, expectedLabel, "\(language) launch is not in \(language)", file: file, line: line)
    }

    func testEnglishLaunchRendersDisclaimer() {
        assertAgreeButton(language: "en", reads: "I Agree")
    }

    func testJapaneseLaunchRendersInJapanese() {
        assertAgreeButton(language: "ja", reads: "同意する")
    }

    func testGermanLaunchRendersInGerman() {
        assertAgreeButton(language: "de", reads: "Ich stimme zu")
    }

    /// Right-to-left: the layout flips and must still reach the gate.
    func testArabicRTLLaunchRendersInArabic() {
        assertAgreeButton(language: "ar", reads: "أوافق")
    }
}
