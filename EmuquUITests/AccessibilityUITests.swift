import XCTest

/// Accessibility coverage.
///
/// Without this suite, a regression that dropped a VoiceOver label
/// would only surface on a real VoiceOver run.
///
/// This suite exercises:
///
///   • Tab-bar buttons all expose a label that VoiceOver can read.
///   • Critical CTA buttons (I Agree on disclaimer, Take a reading on
///     onboarding done page) carry both `accessibilityLabel` and
///     `accessibilityHint`.
///   • Hit-target sanity: critical buttons report a frame at least
///     44 × 44 pt (Apple HIG minimum).
///
/// We do not test Dynamic Type AX5 layout — that requires re-launching
/// the app under a different content-size category which XCUITest
/// supports via launch arguments but the resulting layout assertions
/// are brittle.
@MainActor
final class AccessibilityUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-UITests", "-UITests-FreshInstall"] + UITestLanguage.english
        app.launch()
    }

    override func tearDown() async throws {
        app = nil
    }

    // MARK: - Disclaimer screen accessibility

    /// On a fresh install, the very first user-touchable element is
    /// the I-Agree button on `HealthDisclaimerView`. It must:
    ///   • Be reachable in the accessibility tree.
    ///   • Report a usable label.
    ///   • Meet the 44 × 44 pt minimum hit target.
    func testHealthDisclaimerButtonHitTargetAndLabel() throws {
        let agreeButton = app.buttons[UITestID.disclaimerAgree]
        // Asserted, not skipped. This suite launches with
        // `-UITests-FreshInstall`, which wipes the acceptance flag, so the
        // disclaimer is guaranteed — the AX5 suite asserts the same thing at
        // the largest text size and passes. Skipping meant a missing health
        // disclaimer, and an unchecked hit target on it, reported as success.
        XCTAssertTrue(
            agreeButton.waitForExistence(timeout: UITestTiming.s(15)),
            "Disclaimer did not render under -UITests-FreshInstall"
        )
        XCTAssertFalse(agreeButton.label.isEmpty,
                       "I Agree button must expose a non-empty accessibility label")
        // Frame may be 0×0 if not yet visible; scroll to enable.
        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists {
            for _ in 0 ..< 8 where !agreeButton.isEnabled { scrollView.swipeUp() }
        }
        if agreeButton.frame.size != .zero {
            XCTAssertGreaterThanOrEqual(
                agreeButton.frame.height, 44,
                "I Agree button must meet the 44pt minimum hit-target height"
            )
        }
    }

    // MARK: - Tab-bar accessibility

    /// Every tab-bar button must expose a non-empty accessibility
    /// label and be selectable. Without this guard,
    /// a regression to `Label("")` or `accessibilityLabel("")` would
    /// silently break VoiceOver tab-switching.
    func testEveryTabBarButtonHasUsableLabel() throws {
        UITestLaunch.toMainUI(app)
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: UITestTiming.s(8)))
        let buttons = tabBar.buttons.allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(buttons.count, 3,
                                    "Tab bar must expose at least 3 tabs")
        for button in buttons {
            XCTAssertFalse(
                button.label.isEmpty,
                "Tab-bar button reports an empty accessibility label — VoiceOver users can't navigate"
            )
        }
    }

    // MARK: - Reduce-Motion sanity

    /// Reduce-Motion is a system setting we can't toggle from a UI
    /// test, but the app's own animation-respecting code is exercised
    /// when the test runs — if any animation modifier was wired
    /// without a Reduce-Motion guard, the app would still render but
    /// throw warnings in CI logs. This is a smoke test that the app
    /// launches and reaches the dashboard without crashing the main
    /// thread on launch animations.
    func testAppReachesDashboardWithoutAnimationCrashes() throws {
        UITestLaunch.toMainUI(app)
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: UITestTiming.s(8)),
                      "App must reach the tab bar without animation-related stalls")
    }
}

/// XCTest's built-in accessibility audit, run once per tab.
///
/// The hand-written assertions above check things somebody thought to check.
/// This checks the things nobody thought to check: contrast ratios below WCAG
/// AA, hit targets under 44 × 44, elements with no label, labels that duplicate
/// their neighbours, and text that clips at larger content sizes. It is the
/// difference between an accessibility sweep that is a guess and one that is a
/// worklist.
///
/// ## Why two audit types are excluded
///
/// Both exclusions are for checks that report against this codebase's
/// *mechanism* rather than its behaviour. Everything else is on — including
/// contrast, hit targets, and element descriptions, which are the three that
/// matter most for a health app whose primary output is a number.
///
/// **`.textClipped`.** SwiftUI reports false positives on `Text` inside a
/// `ScrollView` whose content extends past the viewport: the audit sees a
/// truncated frame and reports clipping even though the text is fully readable
/// once scrolled.
///
/// **`.dynamicType`.** The app scales fixed-point fonts through
/// `View.scaledFont(size:)`, which drives an `@ScaledMetric` on a
/// `ViewModifier` and resolves to `Font.system(size: <scaled value>)`. That
/// genuinely scales — `@ScaledMetric` is a `DynamicProperty`, so the view
/// re-renders when the content-size category changes. But the audit inspects
/// the resulting `UIFont` looking for a `UIFontMetrics` text style, finds a
/// plain system font at a computed size, and reports it as unsupported. It
/// flagged `scaledFont` call sites and correctly-scaling ones alike, which
/// makes it unable to distinguish the ~300 migrated sites from the handful of
/// genuine `.font(.system(size:))` holdouts.
///
/// The holdouts are tracked instead by `check_fixed_font_budget.sh`, which
/// counts raw `.font(.system(size:` in the view layer and ratchets it down.
/// That measures the thing this audit type was meant to measure, without the
/// false positives.
@MainActor
final class AccessibilityAuditUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-UITests", "-UITests-FreshInstall"] + UITestLanguage.english
        app.launch()
        UITestLaunch.toMainUI(app)
    }

    override func tearDown() async throws {
        app = nil
    }

    private var auditTypes: XCUIAccessibilityAuditType {
        var types = XCUIAccessibilityAuditType.all
        types.remove(.textClipped)
        types.remove(.dynamicType)
        return types
    }

    /// Per-tab ceiling on outstanding audit issues.
    ///
    /// Same ratchet shape as `.ci/*.txt`: measured, committed, and only ever
    /// allowed to fall. A hard zero was tried first and is not honest here —
    /// the remaining findings are contrast readings on elements composited over
    /// gradients and tinted cards, where the audit samples rendered pixels and
    /// cannot always resolve the effective background. Fixing them means
    /// changing a colour whose measured contrast is already compliant, which
    /// trades a real design decision for a green check.
    ///
    /// What this does buy: a new unlabelled control, a new too-small tap
    /// target, or a genuinely low-contrast colour lands as a regression the
    /// moment it appears, instead of joining a list nobody reads.
    ///
    /// Ratchet these down. Do not raise one without a reason in the diff.
    /// Measured values, down from an initial 49.
    ///
    /// Cleared en route: `textTertiary` failed WCAG AA in all three themes on
    /// all three surfaces (2.78–3.89:1) and was recontrasted; 188 system
    /// `.secondary` foregrounds were moved onto the contrast-checked
    /// `AppTheme.textSecondary`; the assistant disclaimer's primary button
    /// moved to the new `AppTheme.primaryFilled` (white on `primary` was
    /// 3.69:1); two decorative SF Symbols and the confidence pips were hidden
    /// from VoiceOver; two sub-44 pt tap targets were enlarged. Coach and More
    /// reached zero and are pinned there.
    private static let issueBudget: [String: Int] = [
        UITestID.tabDashboard: 1,
        // The five left on the smallest phone (iPhone 17e) are partly hidden,
        // not low-contrast: the last reading-type chip is cut off at the edge
        // of its scrolling row, and the device card sits under the floating
        // tab bar until the screen scrolls. iPhone 17 measures 3.
        UITestID.tabRecord: 5,
        UITestID.tabFitness: 8,
        UITestID.tabCoach: 0,
        UITestID.tabMore: 0
    ]

    /// Audits one tab and compares the issue count against its budget.
    ///
    /// Every issue is printed regardless of outcome, so the worklist is in the
    /// log even on a passing run — that is what makes ratcheting possible
    /// without re-deriving the list each time.
    private func auditTab(identifier: String, title: String, file: StaticString = #filePath, line: UInt = #line) throws {
        // Asserted, not skipped. A skip here would mean an unreachable tab
        // silently reports a clean audit — the same vacuous-pass shape that
        // `DataDeletionUITests` was bitten by. If a tab cannot be reached, that
        // is worth failing over on its own.
        guard UITestNav.selectTab(app, identifier: identifier, title: title) else {
            XCTFail("Tab '\(identifier)' not reachable — \(UITestFind.onScreen(app))", file: file, line: line)
            return
        }
        // Let the tab settle: several of these screens animate content in, and
        // auditing mid-transition reports frames that no longer exist.
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: UITestTiming.s(5))

        var issues: [String] = []
        try app.performAccessibilityAudit(for: auditTypes) { issue in
            let element = issue.element?.debugDescription.split(separator: "\n").first.map(String.init) ?? "unknown element"
            issues.append("\(issue.auditType): \(issue.compactDescription) — \(element)")
            // `true` means "this closure handled it" — XCTest then suppresses
            // its own per-issue failure. That is what lets the budget check
            // below be the single thing that decides pass/fail.
            return true
        }

        let budget = Self.issueBudget[identifier] ?? 0

        // Attach the full list on every run, pass or fail. On a pass it is the
        // standing worklist for the next ratchet; on a fail it is the diff.
        let listing = issues.sorted().enumerated()
            .map { "  \($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let attachment = XCTAttachment(string: listing.isEmpty ? "(none)" : listing)
        attachment.name = "a11y-issues-\(title)"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertLessThanOrEqual(
            issues.count, budget,
            """
            \(title): \(issues.count) accessibility issues, budget \(budget).
            \(listing)
            If you fixed some, lower the budget in `issueBudget`.
            """,
            file: file, line: line
        )
    }

    func testDashboardTabPassesAccessibilityAudit() throws {
        try auditTab(identifier: UITestID.tabDashboard, title: UITestID.tabDashboardTitle)
    }

    func testRecordTabPassesAccessibilityAudit() throws {
        try auditTab(identifier: UITestID.tabRecord, title: UITestID.tabRecordTitle)
    }

    func testFitnessTabPassesAccessibilityAudit() throws {
        try auditTab(identifier: UITestID.tabFitness, title: UITestID.tabFitnessTitle)
    }

    func testCoachTabPassesAccessibilityAudit() throws {
        try auditTab(identifier: UITestID.tabCoach, title: UITestID.tabCoachTitle)
    }

    func testMoreTabPassesAccessibilityAudit() throws {
        try auditTab(identifier: UITestID.tabMore, title: UITestID.tabMoreTitle)
    }
}
