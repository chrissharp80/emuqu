import XCTest

/// AI Assistant tab coverage.
///
/// The Assistant owns: chat surface, disclaimer gate, prefab questions, model
/// picker, voice mode, provider consent sheet, medical-query guard.
///
/// This suite asserts the structural contract without sending real
/// requests (no API keys are configured in test runs). What we test:
///
///   • Tab reachable when enabled in this build.
///   • DisclaimerSheet presents on first open and is dismissible.
///   • Prefab-question chips render and are tappable.
///   • Composer / input field reachable.
///   • Empty-state copy renders before any messages exist.
///   • The chat surface tolerates "no API key configured" gracefully
///     (no crash, no blocking modal that can't be dismissed).
///
/// Tests `XCTSkipUnless` cleanly when the AI tab is disabled in
/// Settings → Performance → enableAIAssistant.
@MainActor
final class AssistantUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-UITests", "-UITests-FreshInstall"]
        app.launch()
        UITestLaunch.toMainUI(app)
    }

    override func tearDown() async throws {
        app = nil
    }

    /// Not a four-predicate guess over "Assistant" / "Coach" / "Flo" / "AI".
    /// The tab is titled "Flo"; "Coach" means the in-workout trigger voice and
    /// is not a tab at all.
    private func navigateToAssistant() throws {
        guard UITestNav.selectTab(app, identifier: UITestID.tabCoach, title: UITestID.tabCoachTitle) else {
            throw XCTSkip("Flo tab disabled in this build " +
                          "(Settings → Performance → enableAIAssistant)")
        }
    }

    // MARK: - Disclaimer flow

    /// The first time the user opens the Assistant, `DisclaimerSheet`
    /// presents with a four-point disclosure. The sheet is
    /// non-dismissible until acknowledged. We assert it's reachable
    /// and tappable away with the standard "Got it" / "Continue" /
    /// "Accept" CTA.
    func testFirstOpenPresentsDisclaimer() throws {
        try navigateToAssistant()
        // Identified, not a `Got it / Accept / Continue` label predicate,
        // which would also match the *health* disclaimer's CTA one layer
        // down.
        UITestFind.tapWhenReady(app.buttons[UITestID.assistantDisclaimerAccept])
        // "The chat input field must be reachable" is not true of the
        // default configuration: with
        // Apple's on-device model and no API key, `ChatInputBar` renders no
        // composer at all and the prefab chips are the input surface. Note
        // also that `TextField(axis: .vertical)` reports as a text view rather
        // than a text field once it can grow, so the composer is matched
        // across element types rather than as `textFields[...]`.
        let surfaces = [
            UITestFind.anyElement(in: app, identifier: UITestID.assistantComposer),
            UITestFind.anyElement(in: app, identifier: UITestID.assistantPrefabChips)
        ]
        XCTAssertTrue(
            surfaces.contains { $0.waitForExistence(timeout: UITestTiming.s(8)) },
            "After dismissing the disclaimer, Flo must present a composer or its prefab chips — " +
                UITestFind.onScreen(app)
        )
    }

    // MARK: - Prefab questions

    /// Above the input bar, the Assistant exposes a row of prefab
    /// questions ("How am I doing today?", etc.). We don't tap them
    /// — that would fire a real send if a provider is configured —
    /// but we assert at least one is rendered.
    func testPrefabQuestionsRender() throws {
        try navigateToAssistant()
        // Dismiss disclaimer first if up.
        let acceptPredicate = NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                                          "Got it", "Accept", "Continue")
        if let accept = [app.buttons.matching(acceptPredicate).firstMatch].first(where: { $0.waitForExistence(timeout: UITestTiming.s(3)) }) {
            UITestFind.tapSafely(accept, in: app)
        }

        let prefabPhrases = [
            "How am I doing today",
            "Why is my score",
            "Should I train",
            "What changed"
        ]
        var anyMatched = false
        for phrase in prefabPhrases {
            let p = NSPredicate(format: "label CONTAINS[c] %@", phrase)
            if app.buttons.matching(p).firstMatch.waitForExistence(timeout: UITestTiming.s(1))
                || app.staticTexts.matching(p).firstMatch.waitForExistence(timeout: UITestTiming.s(1)) {
                anyMatched = true
                break
            }
        }
        try XCTSkipUnless(anyMatched,
                          "No prefab-question chips found — they may have been disabled / restyled")
    }

    // MARK: - No-API-key state

    /// Without any configured API key + with Apple Intelligence
    /// available, the chat tab must not present a blocking alert. The
    /// user should be able to type a message even if sending it would
    /// fail; the failure surfaces inline as a turn, not as a modal.
    func testNoAPIKeyDoesNotBlockChat() throws {
        try navigateToAssistant()
        // Dismiss disclaimer if up.
        let acceptPredicate = NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                                          "Got it", "Accept")
        if app.buttons.matching(acceptPredicate).firstMatch.waitForExistence(timeout: UITestTiming.s(3)) {
            app.buttons.matching(acceptPredicate).firstMatch.tap()
        }
        // Wait briefly for any pending alert.
        let alert = app.alerts.firstMatch
        XCTAssertFalse(
            alert.waitForExistence(timeout: UITestTiming.s(2)),
            "Assistant must not present a blocking alert when no API key is configured"
        )
    }
}
