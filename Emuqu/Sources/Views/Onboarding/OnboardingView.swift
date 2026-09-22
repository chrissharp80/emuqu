import SwiftUI

/// Root onboarding container with paged navigation
struct OnboardingView: View {
    @Environment(SettingsManager.self) var settingsManager
    @Environment(RRCollector.self) var collector
    @State private var currentPage = 0
    // No `healthKitAuthInFlight` / `healthKitAuthRequested` state here:
    // the dedicated OnboardingHealthPage owns the auth
    // request and its own progress UI, so the parent does not need to
    // gate page-swiping during the system sheet (the user can't swipe
    // away from it during iOS's modal anyway).

    /// Build plan §4.1 — eight onboarding pages (O1-O7 + dedicated
    /// Apple Health page per BP §O4 lines 476-481).
    ///   0. Welcome (brand moment + Get started)
    ///   1. What Emuqu does (3-card carousel)
    ///   2. Quick profile
    ///   3. Pair your strap (Polar H10 / Verity Sense, "I'll do this later")
    ///   4. Connect Apple Health (dedicated page; system-sheet preview;
    ///      post-return scope verification)
    ///   5. Backup
    ///   6. Disclaimer (six-section legal disclaimer with I Agree gate)
    ///   7. You're in (donePage)
    private let pageCount = 8

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            TabView(selection: $currentPage) { pages }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                .animation(.easeInOut, value: currentPage)
        }
    }

    /// Tags are the page order; `advanceToNext` walks them one at a time, except
    /// the Health page which decides for itself where to go next.
    @ViewBuilder
    private var pages: some View {
        OnboardingWelcomePage(advance: advanceToNext)
            .tag(0)
        OnboardingValuePropPage(advance: advanceToNext)
            .tag(1)
        OnboardingProfilePage(advance: advanceToNext)
            .tag(2)
        OnboardingSensorPage(advance: advanceToNext)
            .tag(3)
        OnboardingHealthPage(advance: { advanceFromHealthPage() })
            .tag(4)
        OnboardingBackupPage(advance: advanceToNext)
            .tag(5)
        OnboardingDisclaimerPage(advance: advanceToNext)
            .tag(6)
        donePage
            .tag(7)
    }

    /// Apple Health auth is NOT fired as a side
    /// effect of advancing past the Sensor page.
    /// With the dedicated O4 OnboardingHealthPage in the flow, the
    /// page's own "Connect" button drives the authorization request
    /// directly — much clearer to the user. This advance handler only
    /// runs after the user taps "Skip for now" or has already attempted.
    private func advanceFromHealthPage() {
        // The HealthKitManager has already been asked (or skipped); no
        // further work needed before moving on. Kept as a named handler
        // in case future logic needs to gate the advance.
        advanceToNext()
    }

    private func advanceToNext() {
        withAnimation {
            currentPage = min(currentPage + 1, pageCount - 1)
        }
    }

    private func completeOnboarding() {
        settingsManager.settings.hasCompletedOnboarding = true
        // A fresh-install user never sees the score-
        // architecture change disclosure — their first reading is already
        // under the new algorithm (HRV/Sleep/Vitals 60/25/15). The
        // disclosure modal AND the one-shot history recompute are both
        // only for upgrading users whose stored settings predate this
        // build; mark them done so the new user skips both.
        settingsManager.settings.hasAcknowledgedScoreArchitectureChange = true
        settingsManager.settings.hasRunScoreHistoryRecompute = true
        // The free trial is not started here: it starts from the paywall that
        // follows, once the user has read its terms (Guideline 3.1.1).
    }

    // MARK: - O7 You're in
    //
    // Plan §4.1 O7 + §5.2 — copy locked. "You're in." headline,
    // 14-day calibration mention so the user expects calibration
    // before they get a verdict, primary CTA "Take a reading"
    // (drops them straight to Record), secondary "Skip — show me
    // around" lands them on Dashboard's day-1 checklist.

    private var donePage: some View {
        VStack(spacing: 24) {
            Spacer()
            doneGlyph
                .font(.system(.largeTitle))
                .fontWeight(.bold)
                .minimumScaleFactor(0.5)
                .foregroundStyle(AppTheme.wongOptimal)
                .accessibilityHidden(true)
            donePageCopy
            Spacer()
            donePageButtons
        }
        .padding(.horizontal)
    }

    /// These strings must not be `verbatim`: that renders them in
    /// English regardless of locale, so a Japanese / Korean / German user
    /// finishing onboarding hits an English wall on the very last page. The
    /// catalog has 17 languages; route through `LanguageManager.appBundle` for
    /// parity with the sibling onboarding pages.
    private var donePageCopy: some View {
        VStack(spacing: 24) {
            Text("You're in.", bundle: LanguageManager.appBundle)
                .scaledFont(size: 32, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Text(
                "Take your first reading when you're ready. You'll get a simple readiness score from day one; the full recovery score on the Dashboard arrives after 14 nights, once your own baseline is built.",
                bundle: LanguageManager.appBundle
            )
            .scaledFont(size: 15)
            .foregroundStyle(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
        }
    }

    /// The accessibility identifier sits on "Skip and show me around", not on
    /// "Take a reading": that one opens the recording flow, which is not where a
    /// test walking past onboarding wants to land.
    private var donePageButtons: some View {
        VStack(spacing: 12) {
            takeReadingButton
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Take a reading", bundle: LanguageManager.appBundle))
                .accessibilityHint(Text("Finish onboarding and open the recording flow", bundle: LanguageManager.appBundle))

            skipShowMeAroundButton
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Skip and show me around", bundle: LanguageManager.appBundle))
                .accessibilityHint(Text("Finish onboarding and open the dashboard", bundle: LanguageManager.appBundle))
                .accessibilityIdentifier("onboarding.skip")
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 48)
    }

    private var doneGlyph: some View {
        Image(systemName: "checkmark.circle.fill")
    }

    private var skipShowMeAroundButton: some View {
        Button {
            completeOnboarding()
        } label: {
            Text("Skip — show me around", bundle: LanguageManager.appBundle)
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var takeReadingButton: some View {
        Button {
            completeOnboarding()
            // The Record tab is the default landing target
            // for "Take a reading" — drops the user one tap
            // away from R3 (daily reading) and lets them
            // pair their strap if they skipped O3.
        } label: {
            Text("Take a reading", bundle: LanguageManager.appBundle)
                .scaledFont(size: 17, weight: .semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(AppTheme.primary)
                )
                .foregroundStyle(.white)
        }
    }
}

#Preview {
    OnboardingView()
        .environment(AppDependencies.current.app.settingsManager)
        .environment(RRCollector())
}
