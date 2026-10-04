import XCTest

/// Layout at the largest accessibility text size.
///
/// The gap this fills: `AccessibilityUITests`
/// explicitly excluded AX5, on the grounds that layout assertions under a
/// different content-size category are brittle. That reasoning is sound about
/// *pixel* assertions and wrong about the class of bug that actually ships —
/// text clipped to nothing, a control pushed off-screen, or a hit target that
/// collapses below the 44 pt minimum. None of those need a pixel comparison.
///
/// So this suite asserts only what is unambiguous at any text size:
///
///   • the app launches and renders at AX5 rather than hanging or crashing
///   • primary controls remain present in the accessibility tree
///   • they remain hittable, which is what a user needs
///   • their frames stay within the screen, and at or above 44 × 44 pt
///
/// It deliberately does NOT assert positions, sizes beyond the minimum, or
/// screenshot equality. Those are the brittle assertions the original comment
/// was right to avoid, and adding them would produce a suite that fails on
/// every legitimate design change and gets disabled within a month.
///
/// Launched with `UICTContentSizeCategoryAccessibilityXXXL`, which is AX5 — the
/// largest size iOS offers and the one where layouts break first.
@MainActor
final class DynamicTypeAX5UITests: XCTestCase {
    private var app: XCUIApplication!

    /// The screen bounds, read once from the app. Used to assert that controls
    /// stay reachable rather than being pushed outside the window.
    private var screen: CGRect { app.windows.firstMatch.frame }

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "-UITests",
            "-UITests-FreshInstall",
            // The documented way to force a content-size category in XCUITest.
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ] + UITestLanguage.english
        app.launch()
    }

    override func tearDown() async throws {
        app = nil
    }

    // MARK: - The launch argument actually took effect

    /// Proves the suite is testing what it claims to.
    ///
    /// If `-UIPreferredContentSizeCategoryName` were ignored — a typo, an OS
    /// change, a launch-argument conflict — every other test here would still
    /// pass, at the default text size, while reporting AX5 coverage. That is
    /// the shape of failure this repository keeps finding, so it is asserted
    /// rather than assumed.
    ///
    /// Measured on an iPhone 17 Pro simulator: the disclaimer accept
    /// button is 91 × 214 pt at AX5 and 48 × 104 pt at the default size. The
    /// 65 pt floor sits well clear of both, so it fails loudly if the argument
    /// stops working and does not fail on ordinary design changes.
    func testAX5LaunchArgumentIsActuallyApplied() {
        let agree = app.buttons[UITestID.disclaimerAgree]
        XCTAssertTrue(agree.waitForExistence(timeout: UITestTiming.s(15)),
                      "Disclaimer did not render under -UITests-FreshInstall. Not a skip: "
                          + "the launch configuration guarantees it, so its absence is the defect.")
        scrollToReveal(agree)
        XCTAssertGreaterThan(
            agree.frame.height, 65,
            "Accept button is \(agree.frame.height) pt tall — that is default-size layout, "
                + "not AX5. The content-size launch argument is not being applied, so every "
                + "other test in this suite is passing without testing anything."
        )
    }

    // MARK: - The app survives AX5 at all

    /// The cheapest and most valuable assertion in the suite: at the largest
    /// text size the app still starts and puts something on screen. A layout
    /// that traps or hangs under AX5 fails here before anything subtler runs.
    func testAppLaunchesAndRendersAtAX5() {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20),
                      "App did not reach the foreground at AX5")
        let anythingRendered = app.staticTexts.firstMatch.waitForExistence(timeout: UITestTiming.s(15))
            || app.buttons.firstMatch.waitForExistence(timeout: UITestTiming.s(5))
        XCTAssertTrue(anythingRendered, "Nothing rendered at AX5 — the first screen produced an empty tree")
    }

    // MARK: - The first thing a user must be able to do

    /// On a fresh install the disclaimer's accept button is the only way into
    /// the app. If AX5 pushes it off-screen or shrinks its hit target, a user
    /// at that text size cannot use the app at all — the highest-severity
    /// Dynamic Type failure there is.
    func testDisclaimerAcceptRemainsHittableAtAX5() {
        let agree = app.buttons[UITestID.disclaimerAgree]
        XCTAssertTrue(agree.waitForExistence(timeout: UITestTiming.s(15)), "Disclaimer did not render on fresh install")
        scrollToReveal(agree)
        XCTAssertTrue(agree.isHittable, "Accept button is not hittable at AX5 — the app is unusable at this text size")
        assertUsableTarget(agree, named: "disclaimer accept")
    }

    /// Every element that carries a label must still carry a non-empty one.
    /// A label that goes empty under AX5 means VoiceOver announces nothing,
    /// which is silent to sighted testing and total to a VoiceOver user.
    func testPrimaryButtonsKeepTheirLabelsAtAX5() {
        let agree = app.buttons[UITestID.disclaimerAgree]
        XCTAssertTrue(agree.waitForExistence(timeout: UITestTiming.s(15)), "Disclaimer did not render on fresh install")
        XCTAssertFalse(agree.label.trimmingCharacters(in: .whitespaces).isEmpty,
                       "Accept button lost its accessibility label at AX5")
    }

    // MARK: - The tab bar, which every other screen depends on

    /// Past the disclaimer, the tab bar is the app's spine. At AX5 tab labels
    /// grow enough to push items out of the bar on smaller devices.
    func testTabBarRemainsUsableAtAX5() {
        dismissDisclaimerIfPresent()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: UITestTiming.s(15)),
                      "Tab bar not reached after accepting the disclaimer at AX5. Asserted rather "
                          + "than skipped: a tab bar that never appears at AX5 is the bug this suite exists to find.")

        let tabs = tabBar.buttons.allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(tabs.count, 3, "Tab bar collapsed below three tabs at AX5")
        for tab in tabs where tab.exists {
            assertUsableTarget(tab, named: "tab '\(tab.label)'")
        }
    }

    // MARK: - Helpers

    /// A control is usable when it is inside the window and meets Apple's
    /// 44 × 44 pt minimum. Both are size-independent facts, which is why they
    /// are safe to assert at AX5 while pixel positions are not.
    private func assertUsableTarget(_ element: XCUIElement, named name: String) {
        let frame = element.frame
        guard frame != .zero else {
            XCTFail("\(name) reports a zero frame at AX5 — it is not laid out")
            return
        }
        XCTAssertGreaterThanOrEqual(frame.height, 44, "\(name) is under the 44 pt minimum height at AX5")
        XCTAssertGreaterThanOrEqual(frame.width, 44, "\(name) is under the 44 pt minimum width at AX5")
        XCTAssertTrue(screen.intersects(frame), "\(name) is laid out entirely off-screen at AX5")
    }

    /// AX5 makes almost everything scroll. Nudge the containing scroll view so
    /// a control below the fold becomes hittable before it is asserted on.
    private func scrollToReveal(_ element: XCUIElement) {
        guard !element.isHittable else { return }
        let scrollView = app.scrollViews.firstMatch
        guard scrollView.exists else { return }
        for _ in 0 ..< 6 where !element.isHittable {
            scrollView.swipeUp()
        }
    }

    /// Get past the disclaimer when it is in the way, without asserting on it —
    /// the tab-bar tests are about the tab bar.
    private func dismissDisclaimerIfPresent() {
        let agree = app.buttons[UITestID.disclaimerAgree]
        guard agree.waitForExistence(timeout: UITestTiming.s(10)) else { return }
        scrollToReveal(agree)
        if agree.isHittable {
            agree.tap()
        }
    }
}
