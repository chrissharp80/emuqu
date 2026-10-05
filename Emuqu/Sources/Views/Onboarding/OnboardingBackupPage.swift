import SwiftUI

/// Sixth onboarding page, before the closing page: the optional iCloud sync
/// toggle. Off until the user turns it on (Guideline 5.1.3(ii)): the default
/// install stores nothing in iCloud.
struct OnboardingBackupPage: View {
    @Environment(SettingsManager.self) var settingsManager
    /// Two-way access to the settings for controls. An `@Environment` value has
    /// no projected `$` binding, so this stands in for `$settingsManager.settings`.
    private var settingsBinding: Binding<UserSettings> {
        Binding(get: { settingsManager.settings }, set: { settingsManager.settings = $0 })
    }
    let advance: () -> Void

    /// Scrolls when the content outgrows the screen (the largest
    /// accessibility text sizes), so the description and the buttons are never
    /// clipped; at ordinary sizes it fills the screen and doesn't scroll.
    var body: some View {
        OnboardingFillingScroll {
            VStack(spacing: 24) {
                Spacer()

                backupHeadline
                iCloudSyncToggle

                Spacer()

                backupNavigationButtons
            }
            .padding()
        }
    }

    private var backupHeadline: some View {
        VStack(spacing: 24) {
            backupPageHeader
                .font(.system(.largeTitle))
                .fontWeight(.bold)
                .minimumScaleFactor(0.5)
                .foregroundStyle(AppTheme.mist)
                .accessibilityHidden(true)

            Text(String(localized: "iCloud Sync", bundle: LanguageManager.appBundle))
                .font(.title2.bold())
                .foregroundColor(AppTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)

            backupDescription
        }
    }

    private var backupDescription: some View {
        Text(String(
            localized: """
            Optional. Turn this on to sync your recordings and settings between your own devices through your private \
            iCloud account. Everything is encrypted on your iPhone before upload. Readings from Apple Health are never \
            uploaded; scores Emuqu computes from them are. Uses your Apple ID; no sign-up needed.
            """,
            bundle: LanguageManager.appBundle
        ))
        .font(.subheadline)
        .foregroundColor(AppTheme.textSecondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
    }

    private var iCloudSyncToggle: some View {
        VStack(spacing: 24) {
            Toggle(String(localized: "iCloud Sync", bundle: LanguageManager.appBundle), isOn: settingsBinding.iCloudSyncEnabled)
                .tint(AppTheme.sage)
                .padding(.horizontal, 40)
                .accessibilityLabel(String(localized: "iCloud Sync", bundle: LanguageManager.appBundle))
                .accessibilityHint(String(localized: "Back up your recordings and settings, encrypted, to your private iCloud account.", bundle: LanguageManager.appBundle))

            Text(String(localized: "You can change this anytime in Settings.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    private var backupPageHeader: some View {
        Image(systemName: "icloud.fill")
    }

    private var backupNavigationButtons: some View {
        VStack(spacing: 12) {
            Button(String(localized: "Next", bundle: LanguageManager.appBundle)) { advance() }
                .buttonStyle(.zen(AppTheme.sage))
                .accessibilityLabel(String(localized: "Next", bundle: LanguageManager.appBundle))
                .accessibilityHint(settingsManager.settings.iCloudSyncEnabled
                    ? String(localized: "Continue with iCloud sync enabled", bundle: LanguageManager.appBundle)
                    : String(localized: "Continue with iCloud sync off", bundle: LanguageManager.appBundle))
                .accessibilityIdentifier("onboarding.advance")

            Button(String(localized: "Skip", bundle: LanguageManager.appBundle)) {
                settingsManager.settings.iCloudSyncEnabled = false
                advance()
            }
            .font(.subheadline)
            .foregroundColor(AppTheme.textSecondary)
            .accessibilityLabel(String(localized: "Skip", bundle: LanguageManager.appBundle))
            .accessibilityIdentifier("onboarding.skip")
            .accessibilityHint(String(localized: "Disable iCloud sync and continue", bundle: LanguageManager.appBundle))
        }
        .padding(.bottom, 48)
    }
}

#Preview {
    OnboardingBackupPage(advance: {})
        .environment(AppDependencies.current.app.settingsManager)
}
