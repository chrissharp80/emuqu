import XCTest

/// Coverage for the eight-page onboarding flow.
///
/// The main `EmuquUITests` suite uses a launch arg
/// (`-UITests`) that doesn't actually reset persisted state — it just
/// dismisses whatever modal happens to be up. To exercise the real
/// new-install path, this suite uses
/// the `-UITests-FreshInstall` flag handled by
/// `EmuquApp.resetUITestStateIfRequested()`. That flag wipes:
///
///   • UserDefaults flags: `hasAcceptedHealthDisclaimer`,
///     `lastTrialReminderDate`, `assistant.disclaimerAccepted`
///   • `user_settings.json` from the App Group container (which
///     carries `hasCompletedOnboarding`, the score-architecture-change
///     ack, the trial start date, etc.)
///
/// On launch, the app should land on the HealthDisclaimerView — the
/// canonical first-launch gate — and the user should be able to walk
/// the eight onboarding pages from there.
///
/// Tests that interact with the system HealthKit prompt would be
/// flaky in CI, so the prompt-sensitive paths are gated with
/// `XCTSkipUnless` and rely on the user-tappable "Skip" affordances
/// that the onboarding pages expose.
@MainActor
final class OnboardingFlowUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Combine flags so this suite gets a clean state but is still
        // detectable as a UI-test run for any future code paths that
        // care.
        app.launchArguments += ["-UITests", "-UITests-FreshInstall"]
        app.launch()
    }

    override func tearDown() async throws {
        app = nil
    }

    // MARK: - Disclaimer gate

    /// The brand-new-install path must land on the HealthDisclaimerView
    /// before exposing any tabs. The "I Agree" button is gated on
    /// scroll-to-bottom, so we don't tap it here — we just assert the
    /// view rendered and the agree button exists in some state.
    func testFreshInstallShowsHealthDisclaimerFirst() throws {
        let disclaimerHeading = app.staticTexts["Health Disclaimer"]
        let agreeButton = app.buttons[UITestID.disclaimerAgree]

        let disclaimerVisible = disclaimerHeading.waitForExistence(timeout: UITestTiming.s(8))
            || agreeButton.waitForExistence(timeout: UITestTiming.s(2))

        XCTAssertTrue(
            disclaimerVisible,
            "Fresh install must present the Health Disclaimer before any tab is reachable. " +
            "If this fails, the disclaimer gate at EmuquApp.activeModal == .disclaimer " +
            "regressed."
        )

        // The tab bar must not be REACHABLE yet on a fresh install.
        //
        // Not `!tabBar.exists`, which the app's
        // launch architecture can never satisfy: `EmuquApp` deliberately always
        // renders `MainTabView` and presents the disclaimer as a
        // `fullScreenCover` on top of it (see the "splash CONDITIONAL REMOVED"
        // note in EmuquApp.swift — a conditional root broke launch on a real
        // user's device). The tab bar therefore still exists in the hierarchy;
        // what matters, and what the gate actually guarantees, is that it
        // cannot be touched while the cover is up.
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists {
            XCTAssertFalse(
                UITestFind.isSafelyHittable(tabBar.buttons.firstMatch, in: app),
                "Tabs must not be tappable until the disclaimer is accepted."
            )
        }
    }

    // MARK: - Walk the disclaimer + onboarding flow

    /// Accept the disclaimer (if presented), then verify the onboarding
    /// flow appears. We don't drive every page — that's brittle — but
    /// we do confirm the Welcome page renders and the user can advance.
    /// This catches regressions where the onboarding modal fails to
    /// present after disclaimer acceptance, which is the primary 2026
    /// support-ticket category.
    func testDisclaimerAcceptanceRevealsOnboarding() throws {
        // Try to scroll to the bottom of the disclaimer to enable the
        // "I Agree" button. The disclaimer view is a ScrollView with
        // the agree button conditionally enabled when the user reaches
        // the bottom.
        let agreeButton = app.buttons[UITestID.disclaimerAgree]
        let disclaimerVisible = agreeButton.waitForExistence(timeout: UITestTiming.s(8))
        // Asserted, not skipped. `-UITests-FreshInstall` wipes the acceptance
        // flag, so the disclaimer is guaranteed on this launch — the AX5 suite
        // asserts the same thing and passes. Skipping here meant a missing
        // disclaimer, the one screen legally required before any data is
        // shown, reported as a pass.
        XCTAssertTrue(disclaimerVisible,
                      "Disclaimer did not render under -UITests-FreshInstall")

        // Swipe up a few times to reveal "I Agree" — the button is
        // disabled until scroll reaches bottom. Use the first
        // ScrollView the app exposes; on a fresh install only the
        // disclaimer is on screen so this is unambiguous.
        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists {
            for _ in 0 ..< 6 where !agreeButton.isEnabled {
                scrollView.swipeUp()
            }
        }

        // Some builds keep the button visible-but-disabled until
        // scroll completes. If we got it enabled, tap; otherwise skip
        // gracefully — the prior test already covers the gate's
        // existence.
        try XCTSkipUnless(
            agreeButton.isEnabled,
            "Could not enable the I Agree button via swipe — the scroll surface may have changed."
        )
        agreeButton.tap()

        // After acceptance, the OnboardingView's Welcome page should
        // appear. Look for the canonical text or the page indicator.
        let welcomeMarker = app.staticTexts["Welcome to Emuqu"]
        let getStartedButton = app.buttons["Get started"]
        let nextButton = app.buttons["Next"]

        let onboardingPresent = welcomeMarker.waitForExistence(timeout: UITestTiming.s(5))
            || getStartedButton.waitForExistence(timeout: UITestTiming.s(2))
            || nextButton.waitForExistence(timeout: UITestTiming.s(2))
        XCTAssertTrue(
            onboardingPresent,
            "After the disclaimer is accepted, the OnboardingView should present " +
            "(Welcome page or Next/Get started button visible)."
        )
    }

    // MARK: - Permission denial path

    /// Denying HealthKit
    /// during onboarding must not leave the user stuck. The dedicated
    /// OnboardingHealthPage exposes a "Skip for now" / "Skip" button
    /// for this exact case. This test
    /// verifies the skip affordance is reachable from the onboarding
    /// flow without requiring the system HealthKit prompt to be
    /// dismissed (which is non-interactive in XCUITest).
    func testOnboardingHealthPageHasSkipAffordance() throws {
        // Pre-condition — a fresh-install state, so accept the disclaimer the
        // same way the other tests in this class do.
        let agreeButton = app.buttons[UITestID.disclaimerAgree]
        if agreeButton.waitForExistence(timeout: UITestTiming.s(5)) {
            let scrollView = app.scrollViews.firstMatch
            if scrollView.exists {
                for _ in 0 ..< 6 where !agreeButton.isEnabled {
                    scrollView.swipeUp()
                }
            }
            if agreeButton.isEnabled { agreeButton.tap() }
        }

        // Do not look for any button whose label contains "Skip" on whichever
        // page happens to be showing and skip the test when none is found: the
        // first onboarding page offers only "Get started", so that finds none
        // every run and the test never asserts anything.
        //
        // The question the test is named for is stronger: can a user who
        // declines every permission still get
        // through? Walk the flow using only its skip and advance controls and
        // require it to terminate at the tab bar. Neither control opens a
        // system prompt — the Apple Health and Bluetooth CTAs are deliberately
        // left without identifiers, so this walk cannot touch them.
        var sawSkipAffordance = false
        var reachedApp = false
        for _ in 0 ..< 12 {
            let skip = app.buttons.matching(identifier: UITestID.onboardingSkip).firstMatch
            let advance = app.buttons.matching(identifier: UITestID.onboardingAdvance).firstMatch
            if skip.exists, skip.isEnabled, UITestFind.isSafelyHittable(skip, in: app) {
                sawSkipAffordance = true
                skip.tap()
                continue
            }
            if advance.exists, advance.isEnabled, UITestFind.isSafelyHittable(advance, in: app) {
                advance.tap()
                continue
            }
            if !skip.exists, !advance.exists, app.tabBars.firstMatch.exists {
                reachedApp = true
                break
            }
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: UITestTiming.s(1))
        }

        XCTAssertTrue(
            sawSkipAffordance,
            "The onboarding flow must expose a usable Skip affordance for users who deny " +
                "HealthKit / decline to pair a strap. Without this, denied-permission users are stuck."
        )
        XCTAssertTrue(
            reachedApp,
            "Skipping every optional onboarding step must land the user in the app — " +
                UITestFind.onScreen(app)
        )
    }
}
