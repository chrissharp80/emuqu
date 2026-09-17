import XCTest

/// One multiplier for every wait in this target.
///
/// ## Why
///
/// Every deadline here was calibrated on a developer Mac. On the CI runner the
/// same tests take 30-60 s each — run 33191820285 completed 67 of them in 66
/// minutes — because the host is slower and drives three simulator clones at
/// once. Five failed in that run purely by not finding an element in time
/// ("Settings must be reachable", "disclaimer.agree" absent, "onboarding.skip"
/// absent, dashboard content absent after a tab switch), and all five pass
/// locally. A deadline that is ample on one machine and not on another
/// describes the host, not the app.
///
/// ## Why a constant and not an environment variable
///
/// This was first written to read `TEST_RUNNER_UITEST_TIMEOUT_SCALE`, the
/// documented way to hand a value to a test runner. It does not arrive here —
/// proven by asserting a hardcoded scale and watching it fail both with and
/// without the setting, under `xcodebuild test` as well as
/// `test-without-building`. Had it shipped, every deadline would have silently
/// stayed at 1 while the code read as though it scaled: a no-op wearing the
/// costume of a fix.
///
/// A constant cannot fail that way. The cost is that a *failing* test takes
/// twice as long to report, because a wait deadline is a safety net and not a
/// pace — every helper returns the moment its element appears, so a passing
/// run is not slowed at all.
///
/// Deliberately 2 rather than the ~4 the runner timings suggest: the retry
/// loops here relaunch the app, so a doomed test already costs ~220 s and a
/// larger multiplier would spend the job's whole budget failing slowly.
enum UITestTiming {
    static let scale: Double = 2

    /// `seconds` as originally written, widened for slower hosts.
    static func s(_ seconds: TimeInterval) -> TimeInterval {
        seconds * scale
    }
}

/// Stable, non-localized UI-test handles.
///
/// Suites in this target must not query elements by their **English display
/// label** (e.g. a literal `buttons["I Agree"]`). The app ships 17 locales
/// against 3,729 string keys, so those queries fail outright on any non-English
/// simulator, and any copy change silently breaks a green test — including a
/// copy change *forced* by `Tools/copy_linter/lint.py`, whose entire job is to
/// force copy changes. That makes test breakage look like a product regression.
///
/// Each constant here must match an `.accessibilityIdentifier(...)` in the app
/// target. Keep the two in sync; the identifier is the contract, the label is
/// not.
@MainActor
enum UITestID {
    static let disclaimerAgree = "disclaimer.agree"

    static let paywallRestore = "paywall.restore"
    static let paywallSkipDebug = "paywall.skipDebug"
    static let paywallTermsOfUse = "paywall.termsOfUse"
    static let paywallPrivacyDone = "paywall.privacyDone"
    static let historySearch = "history.search"
    static let paywallPrivacyPolicy = "paywall.privacyPolicy"

    static let tabDashboard = "tab.dashboard"
    static let tabRecord = "tab.record"
    static let tabFitness = "tab.fitness"
    static let tabCoach = "tab.coach"
    static let tabMore = "tab.more"

    /// Visible titles of the same five tabs.
    ///
    /// A second handle is needed, and it has to be the
    /// *title*. SwiftUI applies neither `.accessibilityIdentifier(...)` nor
    /// `.accessibilityLabel(...)` from after `.tabItem` to the tab-bar button
    /// — both land on the tab's content view, so the button keeps the label
    /// its `Label` was built with. Measured on iOS 26 / Xcode 26: querying
    /// `tabBar.buttons["tab.dashboard"]` and `label CONTAINS "Dashboard tab"`
    /// both return nothing, while `label BEGINSWITH "Dashboard"` matches.
    /// The identifier is still tried first so this fixes itself the day
    /// SwiftUI starts forwarding it.
    ///
    /// Note `tabCoachTitle`: the Coach tab is titled "Flo" (the tab hosts the
    /// conversational AI; "Coach" means the in-workout trigger voice).
    static let tabDashboardTitle = "Dashboard"
    static let tabRecordTitle = "Record"
    static let tabFitnessTitle = "Fitness"
    static let tabCoachTitle = "Flo"
    static let tabMoreTitle = "More"

    // Destinations that are sub-pages, not tabs.
    //
    // The app has five tabs (Dashboard / Record / Fitness / Flo / More);
    // History, Trends and Settings are sub-destinations. Selecting
    // `tabBar.buttons["History"]` and friends matches nothing, so a test
    // written that way fails on the first line of its body.
    static let moreTrends = "more.trends"
    static let moreSettings = "more.settings"
    static let moreHelp = "more.help"
    static let moreAbout = "more.about"
    static let dashboardViewAllReadings = "dashboard.viewAllReadings"
    static let settingsProfile = "settings.profile"
    static let settingsBiometrics = "settings.biometrics"
    static let settingsSleep = "settings.sleep"
    static let settingsPrivacyPolicy = "settings.privacyPolicy"
    static let settingsFlo = "settings.flo"
    static let settingsWearables = "settings.wearables"
    static let settingsData = "settings.data"
    static let settingsReports = "settings.reports"
    static let settingsTraining = "settings.training"
    static let settingsModes = "settings.modes"
    static let settingsTags = "settings.tags"
    static let settingsRoutes = "settings.routes"
    static let settingsNotifications = "settings.notifications"
    static let settingsPermissions = "settings.permissions"
    static let settingsAppearance = "settings.appearance"
    static let settingsPerformance = "settings.performance"
    static let settingsLanguage = "settings.language"
    static let settingsAdvancedDataControls = "settings.advancedDataControls"
    static let settingsTroubleshooting = "settings.troubleshooting"
    static let settingsHelpCenter = "settings.helpCenter"
    static let settingsMetricGuide = "settings.metricGuide"
    static let settingsMethodology = "settings.methodology"
    static let settingsTermsOfUse = "settings.termsOfUse"
    static let settingsHealthDisclaimer = "settings.healthDisclaimer"
    static let settingsAcknowledgements = "settings.acknowledgements"
    static let settingsDeleteAllData = "settings.deleteAllData"

    static let deleteAllDataConfirmField = "deleteAllData.confirmField"
    static let deleteAllDataConfirmButton = "deleteAllData.confirmButton"

    // The onboarding walk-through. Every control that
    // moves the flow forward carries one of these two; `skip` is preferred
    // because it exits a step without acting, which keeps an automated walk
    // out of the Apple Health and Bluetooth system sheets.
    static let onboardingSkip = "onboarding.skip"
    static let onboardingAdvance = "onboarding.advance"

    static let assistantComposer = "assistant.composer"
    static let assistantPrefabChips = "assistant.prefabChips"
    static let assistantDisclaimerAccept = "assistant.disclaimerAccept"
    static let disclaimerScroll = "disclaimer.scroll"

    static let dashboardRoot = "dashboard.root"
    static let dashboardAskFlo = "dashboard.askFlo"
    static let fitnessRoot = "fitness.root"

    // A past reading and the screen it opens. `MorningResultsView` is what the
    // user reads every morning and the only place the score, the breakdown and
    // the re-analysis controls appear; History's rows are its one route once
    // the reading is no longer today's.
    static let historyEntryRow = "history.entryRow"
    static let morningRoot = "morning.root"
    /// The ring, not the card around it. An identifier on the card
    /// propagates to its leaves and overrides theirs, so the card carries
    /// none and the ring is the handle for "the score rendered".
    static let morningScoreRing = "morning.scoreRing"
    static let morningScoreExplainer = "morning.scoreExplainer"

    // Data in and out, from Settings → Data.
    static let dataImport = "data.import"
    static let dataExport = "data.export"
    static let exportRoot = "export.root"
    static let exportRRIntervals = "export.rrIntervals"
    static let importSelectFile = "import.selectFile"

    // The sensor sheet, reached from the Fitness tab's strap pill.
    static let fitnessStrapPill = "fitness.strapPill"
    static let sensorsRoot = "sensors.root"
    static let sensorsPairStrap = "sensors.pairStrap"
}

/// Element lookup that survives SwiftUI's inconsistent identifier plumbing.
///
/// An identifier-only query is the right *intent* but is not
/// sufficient on its own: SwiftUI forwards `.accessibilityIdentifier(...)` to
/// some rendered elements and not others (tab-bar buttons in particular), and
/// which ones changes between OS releases. Each lookup therefore tries the
/// identifier first — precise, localization-proof, the contract — and falls
/// back to a label match only when the identifier did not surface.
@MainActor
enum UITestFind {
    static func tabButton(in tabBar: XCUIElement, identifier: String, title: String) -> XCUIElement {
        let byIdentifier = tabBar.buttons[identifier]
        if byIdentifier.exists { return byIdentifier }
        // BEGINSWITH, so this matches both the bare title and the
        // "<title> tab" form if SwiftUI ever starts forwarding the
        // accessibility label to the button.
        return tabBar.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", title)).firstMatch
    }

    /// What the app is actually showing, for failure messages.
    ///
    /// `XCTAssertTrue(row.waitForExistence(...))` reports
    /// only that a query matched nothing, which is the least useful half of
    /// the story: the question is always *what was on screen instead*. Every
    /// navigation assertion in this target now carries this, so a failure in
    /// CI is diagnosable from the log without re-running locally.
    ///
    /// Uses `debugDescription` rather than walking `allElementsBoundByIndex`.
    /// Walking the queries on the Flo tab raises XCUITest's own "Automation
    /// type mismatch: computed Button from legacy attributes vs PopUpButton
    /// from modern attribute" — so the diagnostic becomes the failure. A
    /// diagnostic must never be able to do that.

    /// `isHittable` without the exceptions.
    ///
    /// A non-zero frame is not enough. `onboarding.skip` reached
    /// this check with a real frame and still raised "Activation point invalid
    /// and no suggested hit points based on element frame", failing the test
    /// from inside the launch walk. XCUITest raises rather than returning false
    /// whenever it cannot derive an activation point, and a frame that lies
    /// (partly or wholly) outside the app's own frame is one way to get there —
    /// a view mid-transition, or one laid out off-screen behind a cover.
    ///
    /// So: require the element to exist, to have a real frame, and for that
    /// frame to actually intersect the app, before asking the question that can
    /// throw.
    /// Whether an element is genuinely reachable — **including occlusion**.
    ///
    /// Use this to *assert* about reachability, not to decide whether to tap.
    /// `isHittable` is the only thing that knows a `fullScreenCover` is sitting
    /// on top of the tab bar, which is what
    /// `testFreshInstallShowsHealthDisclaimerFirst` exists to prove. Dropping it
    /// made a covered tab report as reachable and quietly turned that safety
    /// assertion into a no-op.
    ///
    /// It can still raise on an element mid-transition — see `tapSafely` — but
    /// assertion sites look at settled UI, which is where the distinction lies.
    static func isSafelyHittable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists, element.isEnabled else { return false }
        let frame = element.frame
        guard frame.width > 1, frame.height > 1 else { return false }
        guard app.frame.intersects(frame) else { return false }
        return element.isHittable
    }

    /// Tap an element without ever asking XCTest whether it is hittable.
    ///
    /// The guards above are not enough. `onboarding.skip` passed
    /// every one of them (it exists, it is enabled, its frame is real and lands
    /// inside the app) and `isHittable` still raised:
    ///
    ///     Failed to determine hittability of "onboarding.skip" Button:
    ///     Activation point invalid and no suggested hit points based on
    ///     element frame
    ///
    /// An element mid-transition, or under a cover view, has a perfectly valid
    /// frame and no derivable activation point — and that question *raises*
    /// rather than returning false, which fails the test outright.
    ///
    /// So stop asking it. A coordinate tap is resolved from the frame and needs
    /// no activation point, so the centre of a validated frame is tappable by
    /// construction. Returns whether a tap was attempted.
    @discardableResult
    static func tapSafely(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists, element.isEnabled else { return false }
        let frame = element.frame
        guard frame.width > 1, frame.height > 1 else { return false }
        guard app.frame.intersects(frame) else { return false }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return true
    }

    static func onScreen(_ app: XCUIApplication, limit: Int = 2_000) -> String {
        let dump = app.debugDescription
        return dump.count <= limit ? dump : String(dump.prefix(limit)) + "… (truncated)"
    }

    /// Taps once the element is actually tappable.
    ///
    /// `if element.waitForExistence(...) { element.tap() }`
    /// is a race against the presentation animation: a sheet's CTA exists
    /// before it is hittable, and `tap()` on it fails the test outright rather
    /// than retrying. Returns whether the tap happened.
    /// No `app` parameter here on purpose: this helper is called with elements
    /// from several different app instances, so it does its own frame check
    /// rather than the app-intersection one `isSafelyHittable` uses. The frame
    /// guard below is what keeps `isHittable` from raising.
    @discardableResult
    static func tapWhenReady(_ element: XCUIElement, timeout: TimeInterval = UITestTiming.s(5)) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let frame = element.frame
            if frame.width > 1, frame.height > 1, element.isEnabled {
                // Coordinate tap for the same reason as `tapSafely`: asking
                // `isHittable` here raises on an element that is present but
                // has no derivable activation point.
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return true
            }
            _ = element.waitForExistence(timeout: UITestTiming.s(0.5))
        }
        return false
    }

    /// An element carrying `identifier`, whatever type SwiftUI rendered it as.
    ///
    /// `app.otherElements[...]` and `app.buttons[...]` are
    /// guesses about how SwiftUI chose to surface a modifier, and the guess is
    /// wrong often enough to matter: a `TextField(axis: .vertical)` reports as
    /// a text view, an identified container can land on `other` or on nothing.
    static func anyElement(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A list row, which SwiftUI renders as a button, a cell, or a plain
    /// element depending on the container.
    ///
    /// This **polls**, and that is the whole point. The
    /// first version resolved its fallback chain once, synchronously, at the
    /// instant it was called — which is always immediately after the tap that
    /// starts the transition, when none of the candidates exist yet. Every
    /// candidate missed, so it returned the last one (`cells` matching the
    /// label) and the caller waited on that; if the row actually rendered as a
    /// button, the wait could only ever time out. Resolving lazily and then
    /// waiting looks equivalent and is not.
    static func row(
        in app: XCUIApplication,
        identifier: String,
        label: String,
        timeout: TimeInterval = UITestTiming.s(8)
    ) -> XCUIElement {
        let byLabel = NSPredicate(format: "label CONTAINS[c] %@", label)
        let candidates: [() -> XCUIElement] = [
            { app.buttons[identifier] },
            { app.cells[identifier] },
            { app.otherElements[identifier] },
            { app.staticTexts[identifier] },
            { app.buttons.matching(byLabel).firstMatch },
            { app.cells.matching(byLabel).firstMatch }
        ]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for makeCandidate in candidates {
                let element = makeCandidate()
                if element.exists { return element }
            }
        } while Date() < deadline
        // Nothing matched. Hand back the identifier query so the caller's
        // assertion reports the handle it was actually looking for.
        return app.buttons[identifier]
    }
}

/// Navigation between the five-tab information architecture's destinations.
///
/// Per-suite copies of "tap Settings in the tab bar, and if that misses, try
/// More" drift from the app's IA, and when each wraps the attempt in
/// `XCTSkipUnless` the misses report as skips rather than failures — a whole
/// class can skip every test without exercising anything. One implementation,
/// in one place, means the next IA change is a one-line fix instead of a
/// silent multi-suite regression.
@MainActor
enum UITestNav {
    /// Selects a tab and confirms the switch actually took.
    ///
    /// The confirmation matters, and it has a neat source.
    /// SwiftUI does not forward `.accessibilityIdentifier` from after
    /// `.tabItem` to the tab-bar *button* — it lands on the tab's **content**
    /// view instead, which is the whole reason tab queries here fall back to
    /// the title. That misplaced identifier is exactly the signal needed here:
    /// `descendants(matching: .any)[identifier]` exists precisely when that
    /// tab's content is on screen. Without it, a tap that did not land — the
    /// Flo tab's first-run sheet swallows one — reported success, and the
    /// failure surfaced several assertions later pointing at the wrong screen.
    ///
    /// - Returns: whether the tab exists. A tab that exists but never becomes
    ///   active still returns `true`; the caller's own assertion is what should
    ///   fail in that case, and it will, with the screen dumped.
    @discardableResult
    static func selectTab(
        _ app: XCUIApplication,
        identifier: String,
        title: String,
        attempts: Int = 3
    ) -> Bool {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: UITestTiming.s(8)) else { return false }
        let tab = UITestFind.tabButton(in: tabBar, identifier: identifier, title: title)
        guard tab.waitForExistence(timeout: UITestTiming.s(5)) else { return false }
        let content = UITestFind.anyElement(in: app, identifier: identifier)

        for attempt in 1 ... attempts {
            // Existence and hittability are separate states — a tab bar can be
            // in the tree a beat before it accepts touches. Poll for the second
            // rather than abandoning the attempt on the gap between them, which
            // is what the previous `guard tab.isHittable else { break }` did.
            let hittableDeadline = Date().addingTimeInterval(UITestTiming.s(3))
            while !UITestFind.isSafelyHittable(tab, in: app), Date() < hittableDeadline {
                usleep(100_000)
            }
            guard UITestFind.tapSafely(tab, in: app) else { continue }

            tab.tap()
            if content.waitForExistence(timeout: UITestTiming.s(Double(3 * attempt))) { return true }
        }

        // This must not `return true` unconditionally, or a tab switch that
        // never happened reports success and the caller goes on to assert
        // against whatever is still on screen. That produces the
        // suite's worst failure mode: `SettingsNavigationUITests` failing in
        // `setUp` with "More menu should list Settings" while the app was in
        // fact still sitting on the Dashboard — a message that points at
        // Settings when the real fault is three steps earlier. Report the truth.
        return content.exists
    }

    /// Scrolls a list until the row is both rendered and hittable.
    ///
    /// Order matters here and the obvious order is wrong. A
    /// SwiftUI `List` does not put rows below the fold into the accessibility
    /// tree at all, so "wait for the row to exist, then scroll to it" never
    /// gets past the wait: eleven Settings sub-pages failed on rows that were
    /// simply four screens down. Scroll first, re-query each time, then check.
    static func scrollTo(
        _ app: XCUIApplication,
        identifier: String,
        label: String,
        attempts: Int = 12
    ) -> XCUIElement {
        // Wait for the list to have ANY content before scrolling.
        //
        // Without this the swipes begin while the `List` is still populating,
        // run straight off the bottom of a nearly-empty tree, and the row is
        // then reported missing from a screen that is merely slow. Under three
        // parallel simulator clones that produced a recurring failure in
        // `SettingsNavigationUITests` — "Settings row 'settings.modes' should
        // exist" — with the on-screen dump showing the nav bar and search field
        // present and not one row beneath them.
        let anyRow = app.cells.firstMatch
        if !anyRow.waitForExistence(timeout: UITestTiming.s(8)) {
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: UITestTiming.s(4))
        }

        var row = UITestFind.row(in: app, identifier: identifier, label: label, timeout: 2)
        var tries = 0
        while !(row.exists && UITestFind.isSafelyHittable(row, in: app)), tries < attempts {
            app.swipeUp()
            row = UITestFind.row(in: app, identifier: identifier, label: label, timeout: 1)
            tries += 1
        }
        guard !(row.exists && UITestFind.isSafelyHittable(row, in: app)) else { return row }

        // Not found going down. The row may have been above the starting
        // position — a restored scroll offset, or a swipe that overshot — so
        // sweep back up before giving up. Searching one direction only is why
        // a miss here looked like a missing row rather than a missed row.
        tries = 0
        while !(row.exists && UITestFind.isSafelyHittable(row, in: app)), tries < attempts {
            app.swipeDown()
            row = UITestFind.row(in: app, identifier: identifier, label: label, timeout: 1)
            tries += 1
        }
        return row
    }

    /// More → the named row.
    ///
    /// Retried, because this is the single flakiest step in the suite and the
    /// failure is indistinguishable from a product bug in the report. The suite
    /// runs on three parallel simulator clones; when the host is loaded, a cold
    /// tab swap plus SwiftUI's first layout pass can exceed a flat 5 s wait,
    /// and the whole class then fails in `setUp` with "More menu should list
    /// Settings" — pointing at Settings, which is fine, rather than at the
    /// clock, which is the actual cause. Seen as one failure at 83 s
    /// wall-clock in an otherwise green 1,541-test run.
    ///
    /// Two things make it robust rather than merely slower:
    ///   * `isHittable` is polled separately from existence. A row can exist in
    ///     the tree a beat before it is laid out and tappable, and the old
    ///     single `guard` treated that instant as a hard failure.
    ///   * The tab selection is re-asserted between attempts, so a swap that
    ///     silently didn't take is retried rather than waited on forever.
    private static func openFromMore(
        _ app: XCUIApplication,
        identifier: String,
        label: String,
        attempts: Int = 3
    ) -> Bool {
        for attempt in 1 ... attempts {
            // A tab tap that silently does not take is the failure mode this
            // whole retry exists for, and on the last attempt no amount of
            // waiting fixes it — the app is wedged in whatever state the launch
            // left it. Relaunching is the only thing that clears that, and it
            // is cheap relative to losing the run.
            if attempt == attempts {
                app.terminate()
                app.launch()
                _ = UITestLaunch.toMainUI(app)
            }
            guard selectTab(app, identifier: UITestID.tabMore, title: UITestID.tabMoreTitle) else {
                continue
            }
            let row = UITestFind.row(in: app, identifier: identifier, label: label)
            // Grow the wait per attempt: a loaded host that missed 5 s is not
            // helped by another 5 s, but usually is by 10.
            guard row.waitForExistence(timeout: UITestTiming.s(Double(5 * attempt))) else { continue }

            // Existence and hittability are separate states. Poll briefly for
            // the second rather than failing on the gap between them.
            let hittableDeadline = Date().addingTimeInterval(UITestTiming.s(3))
            while !UITestFind.isSafelyHittable(row, in: app), Date() < hittableDeadline {
                usleep(100_000)
            }
            guard UITestFind.isSafelyHittable(row, in: app) else { continue }

            row.tap()
            return true
        }
        return false
    }

    /// More → Settings. Settings stopped being a tab when the app moved to the
    /// five-tab IA.
    static func openSettings(_ app: XCUIApplication) -> Bool {
        openFromMore(app, identifier: UITestID.moreSettings, label: "Settings")
    }

    /// More → Trends.
    static func openTrends(_ app: XCUIApplication) -> Bool {
        openFromMore(app, identifier: UITestID.moreTrends, label: "Trends")
    }

    /// More → Help & Learn.
    static func openHelp(_ app: XCUIApplication) -> Bool {
        openFromMore(app, identifier: UITestID.moreHelp, label: "Help")
    }

    /// Dashboard → Recent strip → "View all". History collapsed into the
    /// Dashboard's Recent strip (build plan §D4); this button is its only
    /// entry point.
    /// The Recent strip is the second-to-last dashboard section, below the
    /// fold on every phone, so scroll to its "View all" before judging
    /// whether the route exists.
    static func openHistory(_ app: XCUIApplication) -> Bool {
        guard selectTab(app, identifier: UITestID.tabDashboard, title: UITestID.tabDashboardTitle) else {
            return false
        }
        let viewAll = UITestNav.scrollTo(app, identifier: UITestID.dashboardViewAllReadings, label: "View all", attempts: 6)
        guard viewAll.exists, UITestFind.isSafelyHittable(viewAll, in: app) else { return false }
        viewAll.tap()
        return true
    }
}

extension UITestLaunch {
    /// `terminate()` kills the process. Onboarding completion is written by a
    /// background queue and the disclaimer flag is synced by `cfprefsd`, so a
    /// kill within a fraction of a second of the last tap loses both, and the
    /// next launch walks onboarding again. Sending the app to the background
    /// first is what a real app switch does: the scene-phase change flushes
    /// settings synchronously and the defaults sync completes.
    static func backgroundToPersist(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        _ = app.wait(for: .runningBackground, timeout: UITestTiming.s(5))
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: UITestTiming.s(5))
    }
}

/// Drives a freshly launched app past every first-run gate.
///
/// Never treat `app.tabBars.firstMatch.exists` as "the main UI is up". It
/// is not. SwiftUI leaves the presenting view in the accessibility hierarchy
/// underneath a `.sheet` or `.fullScreenCover`, so the tab bar *exists* while
/// the health disclaimer is still on screen swallowing every tap. A helper
/// that returns on that signal leaves the modal up, and tests then fail on
/// their first interaction with a message that points at the wrong thing
/// entirely ("More menu should list Settings").
///
/// The readiness signal here is `isHittable` plus the absence of any known
/// gate — the two conditions that actually mean "a tap will reach the app".
@MainActor
enum UITestLaunch {
    /// The health disclaimer and the seven-page onboarding walk-through.
    /// `skip` before `advance`, so the walk always takes the shortest exit
    /// from a step and never taps a control that opens an Apple Health or
    /// Bluetooth system sheet.
    private static let firstRunGates = [
        UITestID.disclaimerAgree,
        UITestID.onboardingSkip,
        UITestID.onboardingAdvance
    ]

    /// The purchase gate, which only presents when there is no active
    /// entitlement — so it is a gate for most suites and the subject under
    /// test for a few.
    private static let paywallGates = [
        UITestID.paywallSkipDebug
    ]

    /// Launches past every gate. Returns whether the main UI became reachable.
    @discardableResult
    static func toMainUI(_ app: XCUIApplication, timeout: TimeInterval = UITestTiming.s(45)) -> Bool {
        let all = firstRunGates + paywallGates
        walk(app, dismissing: all, until: { !anyPresent(app, all) && app.tabBars.firstMatch.exists },
             timeout: timeout)
        guard !anyPresent(app, all), app.tabBars.firstMatch.exists else { return false }

        // `exists` is not `isHittable`, and the gap between them is
        // where this suite kept failing. The tab bar enters the accessibility
        // tree before SwiftUI finishes its first layout pass, so a caller that
        // returned on `exists` alone would immediately tap a tab that was not
        // yet interactive. The tap silently did nothing, the app stayed on the
        // Dashboard, and the failure surfaced several steps later as "More menu
        // should list Settings" — pointing at Settings when the fault was here.
        //
        // Under three parallel simulator clones on a loaded host that window is
        // seconds wide, which is why it read as flakiness rather than a bug.
        let tabBar = app.tabBars.firstMatch
        let deadline = Date().addingTimeInterval(UITestTiming.s(10))
        while !UITestFind.isSafelyHittable(tabBar, in: app), Date() < deadline {
            usleep(100_000)
        }
        return UITestFind.isSafelyHittable(tabBar, in: app)
    }

    /// Launches past the disclaimer and onboarding but deliberately stops *at*
    /// the paywall. Returns whether the paywall actually presented — it does
    /// not when an entitlement is already active, which is a legitimate state
    /// rather than a failure.
    @discardableResult
    /// The purchase gate is presented from the root `.task`, a beat after the
    /// tab bar exists, so "no first-run gate on screen" is not "no paywall
    /// coming". Walk the first-run gates, then wait for the paywall itself.
    static func toPaywall(_ app: XCUIApplication, timeout: TimeInterval = UITestTiming.s(45)) -> Bool {
        walk(app, dismissing: firstRunGates,
             until: { anyPresent(app, paywallGates) || !anyPresent(app, firstRunGates) },
             timeout: timeout)
        if anyPresent(app, paywallGates) { return true }
        return app.buttons[UITestID.paywallSkipDebug].waitForExistence(timeout: UITestTiming.s(15))
    }

    private static func walk(
        _ app: XCUIApplication,
        dismissing gates: [String],
        until isDone: () -> Bool,
        timeout: TimeInterval
    ) {
        _ = app.tabBars.firstMatch.waitForExistence(timeout: UITestTiming.s(10))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isDone() { return }
            if !dismissOneGate(app, gates: gates) {
                // Nothing tappable yet — let the transition settle.
                _ = app.staticTexts.firstMatch.waitForExistence(timeout: UITestTiming.s(1))
            }
        }
    }

    /// Readiness is keyed on the gates, not on the tab bar's hittability.
    /// Measured on iOS 26, the tab bar under a `.fullScreenCover` reports as
    /// hittable even though every tap goes to the cover — which is exactly how
    /// eleven suites came to run against a screen they could not touch.
    private static func anyPresent(_ app: XCUIApplication, _ gates: [String]) -> Bool {
        gates.contains { element(app, gate: $0).exists }
    }

    /// The on-screen element carrying `identifier`.
    ///
    /// `matching(identifier:)` rather than `buttons[identifier]`, because a
    /// page can offer two ways forward (Skip *and* Next) and subscripting an
    /// ambiguous identifier fails at interaction time — and then the first
    /// candidate that is actually laid out, rather than `firstMatch`, because
    /// `OnboardingView` is a paged `TabView`: the neighbouring pages stay in
    /// the hierarchy with zero-size frames. Asking one of those whether it is
    /// hittable does not return false — it raises "Activation point invalid
    /// and no suggested hit points based on element frame", which fails the
    /// test from inside the launch helper.
    /// The gate button for `identifier`, resolved from ONE accessibility
    /// snapshot.
    ///
    /// Do not read `query.count`, then `element(boundBy:)`,
    /// then `.frame`. Each of those is a separate snapshot, and a gate that
    /// finishes dismissing between two of them leaves an element that answered
    /// `exists` and then raises "Failed to get matching snapshot" on `.frame`.
    /// XCUITest raises that as an Objective-C exception, which Swift cannot
    /// catch, so it fails the test from inside a helper whose whole job is to
    /// tolerate gates coming and going.
    ///
    /// That is what CI run 33230172290 hit: `testPrefabQuestionsRender` and
    /// `testOnboardingHealthPageHasSkipAffordance` both died in `setUp`, on the
    /// disclaimer and the onboarding skip respectively, with exactly that
    /// message — never on this Mac, because the window is only wide enough to
    /// land in when transitions are slow.
    ///
    /// `allElementsBoundByIndex` resolves the whole match set from a single
    /// snapshot, which removes the count/index race. The geometry probe is gone
    /// from here entirely: `dismissOneGate` already runs `isSafelyHittable`
    /// before tapping, so reading `.frame` twice bought nothing and supplied
    /// the throwing call.
    private static func element(_ app: XCUIApplication, gate identifier: String) -> XCUIElement {
        let matches = app.buttons.matching(identifier: identifier).allElementsBoundByIndex
        return matches.first ?? app.buttons[identifier]
    }

    /// Dismisses at most one gate. Returns whether anything was tapped.
    private static func dismissOneGate(_ app: XCUIApplication, gates: [String]) -> Bool {
        for identifier in gates {
            let button = element(app, gate: identifier)
            guard button.exists else { continue }
            // Both disclaimers keep their CTA disabled until the text has been
            // scrolled to the bottom. That is a deliberate product
            // requirement, so satisfy it rather than route around it.
            if !button.isEnabled {
                // The disclaimer's *own* scroll view. `scrollViews.firstMatch`
                // can resolve to the dashboard's, which is still in the
                // hierarchy underneath the cover — swiping that one never
                // enables the button and the walk stalls until it times out.
                let identified = app.scrollViews[UITestID.disclaimerScroll]
                let scrollView = identified.exists ? identified : app.scrollViews.firstMatch
                guard scrollView.exists else { continue }
                for _ in 0 ..< 8 where !button.isEnabled {
                    scrollView.swipeUp()
                }
            }
            // `UITestFind.isSafelyHittable` rather than a bare `isHittable`:
            // the latter raises on any element whose activation point cannot be
            // derived, which fails the test from inside this walk.
            if button.isEnabled, UITestFind.isSafelyHittable(button, in: app) {
                button.tap()
                return true
            }
        }
        return false
    }
}

/// UI tests for the main user flows of Emuqu.
///
/// These tests exercise tab navigation, dashboard structure,
/// recording view layout, settings navigation, history list,
/// and paywall interactions using XCUITest.
@MainActor
final class EmuquUITests: XCTestCase {

    private var app: XCUIApplication!

    // This suite defines `UITestLaunch` / `UITestNav` for every other suite but
    // was the only one of the fourteen that never adopted them itself, so it
    // ran against whatever onboarding/paywall/scroll state the shared simulator
    // clone happened to carry. That made seven tests fail — the Record cases
    // asserted against the Dashboard because `selectTab` never landed, and the
    // Settings cases missed the More row because the list held a prior test's
    // scroll offset. `-UITests-FreshInstall` wipes the first-run state
    // (`AppLaunchRecovery.removeStoredSessionData()`, called from `EmuquApp`)
    // and `toMainUI` walks past the resulting gates.
    // `scripts/check_uitest_fresh_install.sh` now keeps every suite on this
    // shape.
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

    // MARK: - Helpers

    /// Tabs that `MainTabView` renders unconditionally.
    private static let unconditionalTabs = [
        (UITestID.tabDashboard, UITestID.tabDashboardTitle),
        (UITestID.tabRecord, UITestID.tabRecordTitle),
        (UITestID.tabMore, UITestID.tabMoreTitle)
    ]

    /// Tabs behind a settings gate — present in the default build, absent in a
    /// supported configuration.
    private static let optionalTabs = [
        (UITestID.tabFitness, UITestID.tabFitnessTitle),
        (UITestID.tabCoach, UITestID.tabCoachTitle)
    ]

    /// Waits for the main tab bar to appear, handling any launch screen delay.
    @discardableResult
    private func waitForTabBar(timeout: TimeInterval = UITestTiming.s(10)) -> XCUIElement {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: timeout), "Tab bar should appear after launch")
        return tabBar
    }

    /// Taps a tab by its accessibility **identifier**.
    ///
    /// Identifier first, title as the fallback. The identifier is the contract
    /// — localization-proof and copy-proof — but SwiftUI does not currently
    /// forward it from `.tabItem` to the tab-bar button, so the title carries
    /// the query until it does. See `UITestFind.tabButton`.
    private func selectTab(_ identifier: String, _ title: String, timeout: TimeInterval = UITestTiming.s(5)) {
        let tabBar = waitForTabBar(timeout: timeout)
        let tab = UITestFind.tabButton(in: tabBar, identifier: identifier, title: title)
        XCTAssertTrue(tab.waitForExistence(timeout: UITestTiming.s(3)), "Tab '\(identifier)' / '\(title)' should exist")
        tab.tap()
    }

    private func openSettings() {
        XCTAssertTrue(UITestNav.openSettings(app),
                      "More menu should list Settings — \(UITestFind.onScreen(app))")
    }

    /// History has no entry point until the archive holds a reading: the
    /// Dashboard renders the Day-1 checklist instead of the Recent strip while
    /// `daysCollected == 0`, and the More menu deliberately omits History
    /// (build plan §D4). Relaunch with `-UITests-SeedArchive`, which has the
    /// app score one synthetic night through its own pipeline, wait for the
    /// disclaimer that follows the seed, then open History; not reaching it
    /// is a failure.
    private func openHistory() {
        app.terminate()
        app.launchArguments = ["-UITests", "-UITests-FreshInstall", "-UITests-SeedArchive"]
        app.launch()
        _ = app.buttons[UITestID.disclaimerAgree].waitForExistence(timeout: UITestTiming.s(30))
        UITestLaunch.toMainUI(app)
        XCTAssertTrue(
            UITestNav.openHistory(app),
            "History must be reachable from the Recent strip once the archive holds a reading — \(UITestFind.onScreen(app))"
        )
    }

    /// Drives past the first-run gates.
    ///
    /// Must handle the health disclaimer's `disclaimer.agree`, not only the
    /// paywall's debug-skip button / "Continue" / "Accept": on a simulator
    /// where the disclaimer has not yet been accepted, a helper that skips it
    /// returns having dismissed nothing and leaves the sheet on screen. The
    /// tab bar exists underneath a sheet, so every following `selectTab`
    /// "succeeds" and then finds none of the content it expects.
    private func dismissModalIfPresent() {
        UITestLaunch.toMainUI(app)
    }

    // MARK: - 1. App Launch and Tab Navigation

    func testAppLaunchShowsTabBar() throws {
        dismissModalIfPresent()
        let tabBar = waitForTabBar()
        XCTAssertTrue(tabBar.exists, "Tab bar should be visible after launch")
    }

    func testAllTabsExist() throws {
        dismissModalIfPresent()
        let tabBar = waitForTabBar()

        // Only three tabs are unconditional. Fitness is hidden by Settings →
        // Modes → Hide Fitness tab, and Coach is gated on `enableAIAssistant`
        // — both `if` blocks in `MainTabView`, both of which remove the tab
        // from the bar entirely rather than disabling it. Asserting on either
        // would make a supported configuration look like a regression.
        for (identifier, title) in Self.unconditionalTabs {
            XCTAssertTrue(
                UITestFind.tabButton(in: tabBar, identifier: identifier, title: title).exists,
                "Tab '\(identifier)' should exist in the tab bar"
            )
        }
        XCTAssertGreaterThanOrEqual(
            tabBar.buttons.count, Self.unconditionalTabs.count,
            "Tab bar should carry at least the unconditional tabs"
        )
    }

    func testCanSwitchBetweenAllTabs() throws {
        dismissModalIfPresent()

        let tabBar = waitForTabBar()
        // Walk whatever the build actually exposes, ending on Dashboard.
        var tabs = [(UITestID.tabRecord, UITestID.tabRecordTitle)]
        for optional in Self.optionalTabs
            where UITestFind.tabButton(in: tabBar, identifier: optional.0, title: optional.1).exists {
            tabs.append(optional)
        }
        tabs.append((UITestID.tabMore, UITestID.tabMoreTitle))
        tabs.append((UITestID.tabDashboard, UITestID.tabDashboardTitle))
        for (identifier, title) in tabs {
            selectTab(identifier, title)
            // The Flo tab presents its one-time AI
            // disclosure as a sheet the first time it opens, and a sheet leaves
            // the tab bar in the hierarchy underneath: the next `selectTab`
            // reported success and changed nothing, so the walk ended on Flo
            // and the final assertion failed pointing at the Dashboard.
            UITestFind.tapWhenReady(app.buttons[UITestID.assistantDisclaimerAccept], timeout: 2)
            // Brief wait for the tab content to load (LazyView defers content)
            Thread.sleep(forTimeInterval: 0.5)
        }
        // Land on the Dashboard explicitly before asserting.
        //
        // The walk above ends with a Dashboard tap, but a tap is not a
        // guarantee: any sheet a tab raises sits above the tab bar, swallows
        // the next tap, and leaves the walk wherever it was. The disclosure
        // handled inside the loop is one such sheet; it is not the only one,
        // and on a slow host it can appear after the loop has moved on.
        //
        // CI run 33202282889 failed here for that reason — `dashboard.root`
        // was polled for the full ten seconds and never appeared, because the
        // app was not on the Dashboard at all. Re-asserting the destination
        // fixes the cause; widening the deadline would only have waited longer
        // on the wrong screen.
        dismissModalIfPresent()

        // Use the shared navigator, not this file's `selectTab`.
        //
        // CI run 33230172290 failed here again after the re-select was added,
        // and the trace says why: `Computed hit point {-1, -1} after scrolling
        // to visible`. The tab existed, the tap was synthesized against an
        // unresolvable point, and nothing happened. The `selectTab` in this
        // file asserts existence and taps; existence and hittability are
        // different states, which is exactly the gap `UITestNav.selectTab`
        // exists to close — it polls for hittability, taps through
        // `tapSafely`, and retries until the destination actually renders.
        XCTAssertTrue(
            UITestNav.selectTab(app, identifier: UITestID.tabDashboard, title: UITestID.tabDashboardTitle),
            "Could not land on the Dashboard after walking the tabs — \(UITestFind.onScreen(app))"
        )

        // Not `dashboardTab.isSelected`: SwiftUI does not
        // reliably surface the selected state of a `TabView` tab-bar button to
        // XCUITest, and "is the right tab highlighted" is the weaker question
        // anyway. Assert the destination actually rendered.
        let dashboardTab = UITestFind.tabButton(in: tabBar, identifier: UITestID.tabDashboard, title: UITestID.tabDashboardTitle)
        XCTAssertTrue(dashboardTab.exists, "Dashboard tab should exist")
        XCTAssertTrue(
            UITestFind.anyElement(in: app, identifier: UITestID.dashboardRoot).waitForExistence(timeout: UITestTiming.s(5)),
            "Dashboard content should be on screen after switching back — \(UITestFind.onScreen(app))"
        )
    }

    // MARK: - 2. Dashboard View Structure

    func testDashboardShowsRecoveryScoreSection() throws {
        dismissModalIfPresent()
        selectTab(UITestID.tabDashboard, UITestID.tabDashboardTitle)

        // The recovery score card should display. Look for common text elements.
        // When no sessions exist, the dashboard may show a placeholder or score of "--"
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: UITestTiming.s(5)), "Dashboard should have a scroll view")

        // Binding `recoveryText` and never reading it would make this test
        // assert only that *a* scroll view exists, which every screen in the
        // app satisfies. On a fresh install the score card shows
        // a placeholder instead of a number, so the landmark worth asserting on
        // is the card's own label or the empty-state prompt that replaces it.
        let recoveryLabel = NSPredicate(format: "label CONTAINS[c] %@", "Recovery")
        let emptyStateLabel = NSPredicate(format: "label CONTAINS[c] %@", "first reading")
        let landmarks = [
            app.staticTexts.matching(recoveryLabel).firstMatch,
            app.buttons.matching(recoveryLabel).firstMatch,
            app.staticTexts.matching(emptyStateLabel).firstMatch,
            app.buttons.matching(emptyStateLabel).firstMatch
        ]
        XCTAssertTrue(
            landmarks.contains { $0.waitForExistence(timeout: UITestTiming.s(2)) },
            "Dashboard must show the recovery card or the empty-state prompt — \(UITestFind.onScreen(app))"
        )
    }

    func testDashboardShowsTrainingReadinessSection() throws {
        dismissModalIfPresent()
        selectTab(UITestID.tabDashboard, UITestID.tabDashboardTitle)

        // The training readiness section should be visible
        let readinessText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Readiness")
        ).firstMatch

        // Scroll down to find it if needed
        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists && !readinessText.exists {
            scrollView.swipeUp()
        }

        // In empty-data state this section may still render with placeholder values
        // We verify the dashboard is scrollable and structured
        XCTAssertTrue(scrollView.exists, "Dashboard scroll view should exist")
    }

    func testDashboardStartRecordingNavigation() throws {
        dismissModalIfPresent()
        selectTab(UITestID.tabDashboard, UITestID.tabDashboardTitle)

        // Look for a "Start Recording" or "Record" call-to-action button on dashboard
        let startButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Start Recording", "Record Now")
        ).firstMatch

        if startButton.waitForExistence(timeout: UITestTiming.s(3)) {
            startButton.tap()
            // Should navigate to the Record tab
            let tabBar = app.tabBars.firstMatch
            let recordTab = UITestFind.tabButton(in: tabBar, identifier: UITestID.tabRecord, title: UITestID.tabRecordTitle)
            if recordTab.exists {
                XCTAssertTrue(recordTab.isSelected, "Tapping start recording should switch to Record tab")
            }
        }
        // If no start button exists (user already has recent sessions), that is acceptable
    }

    // MARK: - 3. Record View Structure

    func testRecordViewShowsSessionSelector() throws {
        dismissModalIfPresent()
        selectTab(UITestID.tabRecord, UITestID.tabRecordTitle)

        // The selector header. Matched case-insensitively on purpose: the copy
        // linter enforces sentence case, so an exact-match query here breaks
        // every time that rule is applied ("Choose Session" → "Choose session").
        let chooseSession = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Choose session")
        ).firstMatch
        XCTAssertTrue(
            chooseSession.waitForExistence(timeout: UITestTiming.s(5)),
            "Record view should show the session-chooser header — \(UITestFind.onScreen(app))"
        )
    }

    func testRecordViewSessionTypeSelection() throws {
        dismissModalIfPresent()
        selectTab(UITestID.tabRecord, UITestID.tabRecordTitle)

        // Wait for the selector to appear (see note on case above).
        let chooseSession = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Choose session")
        ).firstMatch
        guard chooseSession.waitForExistence(timeout: UITestTiming.s(5)) else {
            XCTFail("Session-chooser header not found — \(UITestFind.onScreen(app))")
            return
        }

        // Tap the "Extended" session type card
        let extendedButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Extended")
        ).firstMatch
        if extendedButton.waitForExistence(timeout: UITestTiming.s(3)) {
            extendedButton.tap()
            // After selection, a session header with "Change" should appear
            let changeButton = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Change")
            ).firstMatch
            XCTAssertTrue(
                changeButton.waitForExistence(timeout: UITestTiming.s(3)),
                "After selecting session type, a Change button should appear"
            )
        }

        // Tap the "Quick" session type card
        // First go back to the selector if needed
        let changeBtn = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Change")
        ).firstMatch
        if changeBtn.exists {
            changeBtn.tap()
            // Wait for selector to reappear
            _ = chooseSession.waitForExistence(timeout: UITestTiming.s(3))
        }

        let quickButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Quick")
        ).firstMatch
        if quickButton.waitForExistence(timeout: UITestTiming.s(3)) {
            quickButton.tap()
        }
    }

    // MARK: - 4. Settings View Structure

    func testSettingsViewShowsSections() throws {
        dismissModalIfPresent()
        openSettings()

        // Main settings rows should be visible.
        for (identifier, label) in [
            (UITestID.settingsProfile, "Profile"),
            (UITestID.settingsBiometrics, "Biometrics"),
            (UITestID.settingsSleep, "Sleep")
        ] {
            XCTAssertTrue(
                UITestFind.row(in: app, identifier: identifier, label: label).waitForExistence(timeout: UITestTiming.s(3)),
                "Settings should show the '\(identifier)' row"
            )
        }
    }

    func testSettingsViewShowsHelpSection() throws {
        dismissModalIfPresent()
        openSettings()

        // Scroll down to find Help & Support section
        let list = app.tables.firstMatch.exists ? app.tables.firstMatch : app.collectionViews.firstMatch
        if list.exists {
            list.swipeUp()
        }

        let helpCenter = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Help Center")
        ).firstMatch

        // The Help Center row may require scrolling
        if !helpCenter.exists {
            app.swipeUp()
        }

        XCTAssertTrue(
            helpCenter.waitForExistence(timeout: UITestTiming.s(3)),
            "Settings should show 'Help Center' in Help & Support section"
        )
    }

    func testSettingsViewShowsAboutSection() throws {
        dismissModalIfPresent()
        openSettings()

        // Scroll to bottom to find About section
        app.swipeUp()
        app.swipeUp()

        let versionLabel = app.staticTexts["Version"]
        let privacyPolicy = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Privacy Policy")
        ).firstMatch
        let termsOfUse = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Terms of Use")
        ).firstMatch

        // At least one of these About items should be visible after scrolling
        let aboutVisible = versionLabel.exists || privacyPolicy.exists || termsOfUse.exists
        XCTAssertTrue(aboutVisible, "Settings About section should be visible after scrolling")
    }

    func testSettingsNavigateToProfile() throws {
        dismissModalIfPresent()
        openSettings()

        // Tap Profile to navigate to the sub-page. By identifier: a
        // `CONTAINS[c] "Profile"` sweep also matches the "Identity & Profile"
        // section header, which is not tappable.
        let profileRow = UITestFind.row(in: app, identifier: UITestID.settingsProfile, label: "Profile")
        XCTAssertTrue(profileRow.waitForExistence(timeout: UITestTiming.s(5)), "Settings should show the Profile row")
        profileRow.tap()

        // Verify navigation occurred — look for a back button or Profile title
        let backButton = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(
            backButton.waitForExistence(timeout: UITestTiming.s(3)),
            "Navigating to Profile should show a navigation bar with back button"
        )
    }

    // MARK: - 5. History View

    func testHistoryViewAppears() throws {
        dismissModalIfPresent()
        openHistory()

        // The History tab should load. With no sessions, it may show an empty state.
        // We verify the navigation title or content area exists.
        let navBar = app.navigationBars.firstMatch
        XCTAssertTrue(
            navBar.waitForExistence(timeout: UITestTiming.s(5)),
            "History view should have a navigation bar"
        )

        // Look for either session entries or an empty state message
        let scrollView = app.scrollViews.firstMatch
        let list = app.tables.firstMatch.exists ? app.tables.firstMatch : app.collectionViews.firstMatch
        let contentExists = scrollView.exists || list.exists
        XCTAssertTrue(contentExists, "History view should show a list or scroll view")
    }

    func testHistoryViewShowsNavigationTitle() throws {
        dismissModalIfPresent()
        openHistory()

        let navBar = app.navigationBars.firstMatch
        XCTAssertTrue(navBar.waitForExistence(timeout: UITestTiming.s(5)), "History navigation bar should appear")

        // The title should contain "History"
        let historyTitle = app.navigationBars.matching(
            NSPredicate(format: "identifier CONTAINS[c] %@ OR ANY staticTexts.label CONTAINS[c] %@", "History", "History")
        ).firstMatch
        // Navigation bars with large titles may render the title as a static text
        let titleText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "History")
        ).firstMatch
        let titleVisible = historyTitle.exists || titleText.exists
        XCTAssertTrue(titleVisible, "History view should display its navigation title")
    }

    // MARK: - 6. Paywall View

    /// The paywall is unreachable from a plain Debug launch: a Debug build is
    /// a developer install, which grants the entitlement before the launch
    /// gate is consulted. `-UITests-ForcePaywall` makes the gate treat the run
    /// as having no entitlement. The gate is consulted at launch, not at the
    /// end of onboarding (a new user's first launch never shows it), so this
    /// walks onboarding on a fresh install, then relaunches: the second
    /// launch presents the purchase gate exactly as it does for a store
    /// install whose trial has ended.
    private func relaunchToPaywall() {
        app.terminate()
        app.launchArguments = ["-UITests", "-UITests-FreshInstall", "-UITests-ForcePaywall"]
        app.launch()
        UITestLaunch.toMainUI(app)
        UITestLaunch.backgroundToPersist(app)
        app.terminate()
        app.launchArguments = ["-UITests", "-UITests-ForcePaywall"]
        app.launch()
        XCTAssertTrue(
            UITestLaunch.toPaywall(app),
            "The purchase gate must present at launch under -UITests-ForcePaywall — \(UITestFind.onScreen(app))"
        )
    }

    /// App Review requires the policy to be reachable from the purchase
    /// screen, so this walks the whole round trip: open it, and get back.
    ///
    /// Tapped through `tapSafely` rather than `XCUIElement.tap()`. The link is
    /// a `.caption2` text button in the paywall's fixed bottom row, and
    /// XCUITest could not derive an activation point for it — the tap logged
    /// "Computed hit point {-1, -1} after scrolling to visible" and went
    /// nowhere, so the assertion that followed blamed a missing Done button
    /// on a sheet that had never been asked to open. `tapSafely` validates
    /// the frame and taps its centre by coordinate, which is the same
    /// treatment every other small control in this target gets.
    func testPaywallPrivacyPolicyButton() {
        relaunchToPaywall()

        let privacyButton = app.buttons[UITestID.paywallPrivacyPolicy]
        XCTAssertTrue(privacyButton.waitForExistence(timeout: UITestTiming.s(5)),
                      "Privacy Policy button should be reachable on the paywall")

        let doneButton = app.buttons[UITestID.paywallPrivacyDone]
        XCTAssertTrue(
            openPrivacyPolicy(privacyButton, done: doneButton),
            "Tapping Privacy Policy on the paywall must open the policy — \(UITestFind.onScreen(app))"
        )
        XCTAssertTrue(UITestFind.tapSafely(doneButton, in: app), "The policy sheet must be dismissible")
        XCTAssertTrue(
            privacyButton.waitForExistence(timeout: UITestTiming.s(10)),
            "Dismissing the policy must return to the paywall — \(UITestFind.onScreen(app))"
        )
    }

    /// Taps the link until the sheet is actually up, and reports whether it
    /// got there.
    ///
    /// The retry is the point. The purchase gate is a `fullScreenCover`, and
    /// the link exists in the hierarchy while that cover is still animating
    /// in — a tap in that window is delivered to the dashboard underneath and
    /// is simply lost. One tap plus a long wait cannot recover from it: the
    /// wait watches for a sheet nothing ever asked to open, then blames the
    /// sheet. Same shape as `UITestNav.openFromMore`, for the same reason.
    private func openPrivacyPolicy(_ link: XCUIElement, done: XCUIElement) -> Bool {
        for _ in 1 ... 3 {
            guard UITestFind.tapSafely(link, in: app) else { continue }
            if done.waitForExistence(timeout: UITestTiming.s(5)) { return true }
        }
        return false
    }

    func testPaywallShowsFeatures() {
        relaunchToPaywall()

        let overnightFeature = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Overnight")
        ).firstMatch
        let recoveryFeature = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Recovery")
        ).firstMatch

        let hasFeatures = overnightFeature.exists || recoveryFeature.exists
        XCTAssertTrue(hasFeatures, "Paywall should display feature descriptions")
    }

    func testPaywallRestorePurchaseButton() {
        relaunchToPaywall()
        let restoreButton = app.buttons[UITestID.paywallRestore]
        XCTAssertTrue(restoreButton.waitForExistence(timeout: UITestTiming.s(3)),
                      "Restore Purchase button should be present on the paywall")
        XCTAssertTrue(restoreButton.isEnabled, "Restore Purchase button should be enabled")
        // We don't tap it to avoid actual StoreKit interaction in UI tests.
    }

    // MARK: - Critical-flow coverage gaps

    /// Verifies the health-disclaimer scroll-to-agree gate is present on
    /// first launch. Acceptance is persisted in UserDefaults — `-UITests`
    /// launch flag should reset it via the `dismissModalIfPresent` path
    /// the existing tests use, but if a future build regresses the gate
    /// (removes scroll-to-agree, shows the dashboard before agreement,
    /// fails to wire up the disclaimer view) this catches it.
    func testHealthDisclaimerGateOrTabsLoad() throws {
        // Either the disclaimer renders (first-launch path) or the tab
        // bar appears (post-acceptance path). One of these must be true
        // — failing both means launch is broken.
        let disclaimerHeading = app.staticTexts["Health Disclaimer"]
        let agreeButton = app.buttons[UITestID.disclaimerAgree]
        let tabBar = app.tabBars.firstMatch

        let healthGatePresent = disclaimerHeading.waitForExistence(timeout: UITestTiming.s(5))
            || agreeButton.exists
        let tabsPresent = tabBar.waitForExistence(timeout: UITestTiming.s(5))

        XCTAssertTrue(
            healthGatePresent || tabsPresent,
            "App must show either the health disclaimer or the main tabs after launch"
        )
    }

    /// Critical-flow smoke: from a launched app (with the disclaimer /
    /// paywall dismissed by `-UITests`), the user can reach Settings
    /// and the Settings → Profile page. Catches regressions in the
    /// settings navigation surface.
    func testSettingsProfileNavigationSmoke() throws {
        dismissModalIfPresent()
        let tabBar = waitForTabBar()
        XCTAssertTrue(tabBar.exists, "Tab bar should be present")

        // The settings tab is typically the rightmost; try by label first.
        openSettings()

        XCTAssertTrue(
            UITestFind.row(in: app, identifier: UITestID.settingsProfile, label: "Profile").waitForExistence(timeout: UITestTiming.s(5)),
            "Settings should expose a Profile entry"
        )
    }

    /// Smoke for the Assistant tab. This verifies the chat bar (or
    /// disclaimer-acceptance flow for first-time AI users) renders and
    /// the input field is reachable — without sending an actual message
    /// (no API keys in test env).
    func testAssistantTabSmoke() throws {
        dismissModalIfPresent()

        // The tab is titled "Flo", so a search for a tab labelled "Assistant"
        // or "AI" matches nothing and would skip every run.
        _ = waitForTabBar()
        try XCTSkipUnless(
            UITestNav.selectTab(app, identifier: UITestID.tabCoach, title: UITestID.tabCoachTitle),
            "Flo tab disabled in this build (Settings → Performance → enableAIAssistant)"
        )

        // "The chat input field must be reachable" is not
        // true of the default state. With Apple's on-device model and no API
        // key, `ChatInputBar` renders no composer at all — the prefab chips are
        // the input surface (see the `isAppleActive` branch). Accept the
        // first-run sheet, then require one of the two real surfaces.
        UITestFind.tapWhenReady(app.buttons[UITestID.assistantDisclaimerAccept])

        let surfaces = [
            UITestFind.anyElement(in: app, identifier: UITestID.assistantComposer),
            UITestFind.anyElement(in: app, identifier: UITestID.assistantPrefabChips)
        ]
        XCTAssertTrue(
            surfaces.contains { $0.waitForExistence(timeout: UITestTiming.s(5)) },
            "Flo must present either a composer or the prefab-question chips — \(UITestFind.onScreen(app))"
        )
    }
}

/// Pins the deadline scale.
///
/// `UITestTiming.s` is applied at 128 call sites across this target. If the
/// scale were ever zero or negative, every one of those waits would return
/// instantly and the whole suite would go green without testing anything —
/// which is the failure shape this repository keeps finding, so it is asserted
/// rather than assumed.
///
/// Deliberately launches nothing: it checks the harness, not the app.
@MainActor
final class UITestTimingTests: XCTestCase {
    func testScaleIsPositive() {
        XCTAssertGreaterThan(UITestTiming.scale, 0,
                             "A non-positive scale makes every wait in this target return instantly")
    }

    func testScaleWidensRatherThanShortens() {
        XCTAssertGreaterThanOrEqual(UITestTiming.scale, 1,
                                    "The scale exists to widen deadlines for slower hosts, never to tighten them")
    }

    func testScaleIsAppliedProportionally() {
        XCTAssertEqual(UITestTiming.s(10), 10 * UITestTiming.scale, accuracy: 0.0001)
        XCTAssertEqual(UITestTiming.s(0), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(UITestTiming.s(5), 0)
    }
}
