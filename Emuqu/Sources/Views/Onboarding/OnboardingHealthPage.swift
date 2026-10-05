import SwiftUI

/// Connect Apple Health.
///
/// Dedicated page split from O3.
/// Critical because iOS only shows the system permission sheet ONCE
/// per scope; if the user denies in confusion, recovery requires
/// digging into Settings → Privacy & Security → Health. This page primes the
/// user for the system sheet, fires it on tap, then infers which scopes
/// were granted by checking for data (iOS hides read-denial state).
///
/// Layout:
///   • Apple Health icon at top (red-cross + heart)
///   • Headline "Connect to Apple Health"
///   • Body explaining what gets read and written
///   • One line on what Connect opens (see `nextStepNote`)
///   • Big "Connect" button — fires `requestAuthorization()`
///   • "Skip for now" tertiary
///
/// Post-return verification:
///   • Auth completed → confirmation card "You're connected" + scope
///     summary
///   • Partial grant → warning card listing what's missing and how to
///     fix in Settings
struct OnboardingHealthPage: View {
    @Environment(RRCollector.self) var collector
    let advance: () -> Void

    @State private var requesting: Bool = false
    @State private var didAttempt: Bool = false
    @State private var grantedScopes: Set<String> = []

    private var hk: HealthKitManager { collector.healthKit }

    /// The buttons are pinned above the page dots rather than scrolled with
    /// the content. At the end of the scroll view, "Skip for now" landed on
    /// the page indicator on a 390pt-wide iPhone, and a tap there went back a
    /// page instead of skipping.
    ///
    /// The status card arrives at the end of the content after the Health
    /// sheet closes, which is under the pinned buttons, so the page scrolls it
    /// into view rather than leaving it half covered.
    var body: some View {
        ScrollViewReader { proxy in
            healthPageScroll(proxy)
        }
    }

    private func healthPageScroll(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            healthPageContent
        }
        .scrollIndicatorsFlash(onAppear: true)
        .safeAreaInset(edge: .bottom) { pinnedButtons }
        .onChange(of: didAttempt) { _, attempted in
            guard attempted else { return }
            withAnimation { proxy.scrollTo(Self.statusCardID, anchor: .bottom) }
        }
    }

    private static let statusCardID = "onboarding.health.status"

    private var healthPageContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 20)
            healthPageHeader
            dataCategoriesCard
            nextStepNote
            authFailureNotice
                .id(Self.statusCardID)
        }
        .padding(.horizontal)
        .padding(.bottom, 16)
    }

    /// Once the Health sheet has been and gone, Connect cannot open it again
    /// and "Skip for now" would record a skip the user did not make, so both
    /// give way to Continue.
    private var pinnedButtons: some View {
        VStack(spacing: 8) {
            if didAttempt {
                continueButton
            } else {
                connectHealthButton
                healthNavigationButtons
                    .accessibilityIdentifier("onboarding.skip")
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 52)
        .background(AppTheme.background)
    }

    /// The accessibility identifier at the call site is deliberately only on
    /// "Skip for now". The Connect button above opens the Apple Health system
    /// sheet, which an automated walk-through must never be steered into.
    private var healthNavigationButtons: some View {
        skipForNowButton
            .buttonStyle(.plain)
    }

    private var healthPageHeader: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart.text.square.fill")
                .font(.system(.largeTitle))
                .fontWeight(.bold)
                .minimumScaleFactor(0.5)
                .foregroundStyle(AppTheme.sage)
                .accessibilityHidden(true)

            Text(String(localized: "Connect to Apple Health", bundle: LanguageManager.appBundle))
                .font(.title2.bold())
                .foregroundColor(AppTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Text(String(localized: "Emuqu uses Apple Health for sleep, vitals, and workout history. It is never sold or used for ads, and the Privacy Policy says exactly what leaves your device, and when.", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    /// What gets read / written. Spec line 478: "body
    /// explaining what gets read and written." We list the
    /// categories so the user has informed consent before
    /// the system sheet appears.
    private var dataCategoriesCard: some View {
        // Translated, and with HRV and activity, which the app reads too:
        // the list was English in every language and left them out.
        let bundle = LanguageManager.appBundle
        return VStack(alignment: .leading, spacing: 10) {
            scopeRow(glyph: "moon.zzz.fill", title: String(localized: "Sleep", bundle: bundle), subtitle: String(localized: "Stages, duration, in-bed time", bundle: bundle))
            scopeRow(glyph: "heart.fill", title: String(localized: "Heart rate and HRV", bundle: bundle), subtitle: String(localized: "Resting and workout heart rate, and Apple Watch HRV", bundle: bundle))
            scopeRow(glyph: "lungs.fill", title: String(localized: "Vitals", bundle: bundle), subtitle: String(localized: "Respiratory rate, SpO₂, wrist temp", bundle: bundle))
            scopeRow(glyph: "figure.walk", title: String(localized: "Activity", bundle: bundle), subtitle: String(localized: "Steps, distance, exercise time, VO₂ max", bundle: bundle))
            scopeRow(glyph: "figure.run", title: String(localized: "Workouts", bundle: bundle), subtitle: String(localized: "Read history + write new sessions", bundle: bundle))
        }
        .padding(14)
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
    }

    @ViewBuilder
    private var authFailureNotice: some View {
        if didAttempt {
            statusCard
        }
    }

    /// "big Connect button" + "Skip for now" tertiary.
    private var connectHealthButton: some View {
        Button {
            Task { await requestHealthAuthorization() }
        } label: {
            connectHealthLabel
        }
        .buttonStyle(.zen(AppTheme.sage))
        .disabled(requesting)
        .accessibilityHint(String(localized: "Open the Apple Health permission sheet", bundle: LanguageManager.appBundle))
    }

    private var connectHealthLabel: some View {
        HStack {
            if requesting {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "checkmark.shield.fill")
                Text(String(localized: "Connect", bundle: LanguageManager.appBundle))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 60)
    }

    private var continueButton: some View {
        Button(action: advance) {
            Text(String(localized: "Continue", bundle: LanguageManager.appBundle))
                .frame(maxWidth: .infinity)
                .frame(height: 60)
        }
        .buttonStyle(.zen(AppTheme.sage))
    }

    private var skipForNowButton: some View {
        Button {
            UserDefaults.standard.set(true, forKey: UserDefaultsKeys.healthAccessSkipped)
            advance()
        } label: {
            Text(String(localized: "Skip for now", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
    }

    private func scopeRow(glyph: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: glyph)
                .scaledFont(size: 18)
                .foregroundStyle(AppTheme.sage)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(AppTheme.textPrimary)
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }
            Spacer()
        }
    }

    /// What happens on Connect, in words. This used to be a drawn imitation
    /// of a system alert with "Allow" and "Don't Allow" buttons; Apple Health
    /// actually shows a full-screen sheet of per-type switches, so the drawing
    /// was wrong, and a mock system prompt with a primed "Allow" is the kind
    /// of pre-permission screen Guideline 5.1.1(iv) warns against.
    private var nextStepNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "iphone")
                .foregroundStyle(AppTheme.textSecondary)
                .accessibilityHidden(true)
            Text(String(localized: "Connect opens Apple Health, where you choose exactly which of these to share. You can change it any time in the Health app.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        if grantedScopes.count >= 4 {
            allScopesGrantedRow
        } else if grantedScopes.isEmpty {
            noDataVisibleRow
        } else {
            scopesPendingRow
        }
    }

    private var allScopesGrantedRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.wongOptimal)
            Text(String(localized: "You're connected. Sleep + vitals + workouts will start populating tonight.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(AppTheme.wongOptimal.opacity(0.1))
        .cornerRadius(10)
    }

    /// iOS hides read denials, so "nothing visible" is either no recent data
    /// or categories turned off, and the row says both. iOS asks for Health
    /// access once, so for the second case it says where the switches
    /// actually live and offers to open the Health app, the one place read
    /// access can be turned back on.
    private var noDataVisibleRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppTheme.wongCaution)
                Text(String(localized: "Emuqu can't see any Health data from the last 30 days. That's expected if you have none yet. If you turned categories off, iOS won't ask again.", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(String(localized: "Turn the categories back on in the Health app: tap your picture, then Privacy, then Apps and Services, then Emuqu. Settings → Privacy & Security → Health → Emuqu has the same switches.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            openHealthButton
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.wongCaution.opacity(0.1))
        .cornerRadius(10)
    }

    /// Opens this app's page in Settings, through the documented
    /// `openSettingsURLString`. iOS has no documented URL for the Health app,
    /// so the text above gives the path to the switches in both places.
    private var openHealthButton: some View {
        Button(action: openSettings) {
            Label(String(localized: "Open Settings", bundle: LanguageManager.appBundle), systemImage: "gear")
        }
        .buttonStyle(.bordered)
    }

    private func openSettings() {
        guard let settings = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settings)
    }

    private var scopesPendingRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(AppTheme.primary)
            Text(String(localized: "No recent data found for some categories. They may be switched off, or there may be nothing logged yet — you can check later in Settings → Privacy & Security → Health.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(AppTheme.primary.opacity(0.1))
        .cornerRadius(10)
    }

    @MainActor
    private func requestHealthAuthorization() async {
        requesting = true
        do {
            try await hk.requestAuthorization()
        } catch {
            debugLog("[OnboardingHealthPage] auth request failed: \(error)", level: .warning)
        }
        // Infer the granted scopes from data presence
        // (iOS hides read denial); the result drives the status card above.
        grantedScopes = await hk.grantedScopeSummary()
        requesting = false
        didAttempt = true
    }
}

#Preview {
    OnboardingHealthPage(advance: {})
        .environment(RRCollector())
}
