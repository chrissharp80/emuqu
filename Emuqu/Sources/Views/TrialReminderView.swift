import SwiftUI

/// A friendly daily reminder shown during the free trial period.
/// Must be dismissed by tapping "Continue" — not swipe-dismissible.
struct TrialReminderView: View {
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            freeTrialSection

            Spacer()

            // Bottom buttons
            bottomButtonsSection
        }
        .background(AppTheme.background.ignoresSafeArea())
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var freeTrialSection: some View {
        VStack(spacing: 24) {
            // Icon
            iconSection2
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                .fill(AppTheme.cardBackground)
                .shadow(color: AppTheme.cardShadow, radius: AppTheme.cardShadowRadius, x: 0, y: 4)
        )
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var iconSection2: some View {
        iconSection

        // Title
        titleSection

        // Message
        Text(String(localized: "You have full access to Emuqu during your trial. After that, a one-time purchase unlocks the app forever.", bundle: LanguageManager.appBundle))
    }

    private var iconSection: some View {
        ZStack {
            Circle()
                .fill(AppTheme.primary.opacity(0.12))
                .frame(width: 80, height: 80)

            Image(systemName: "clock.fill")
                .scaledFont(size: 36, weight: .medium)
                .foregroundColor(AppTheme.primary)
        }
    }

    private var titleSection: some View {
        VStack(spacing: 8) {
            Text(String(localized: "Free Trial", bundle: LanguageManager.appBundle))
                .font(.title2.bold())
                .foregroundColor(AppTheme.textPrimary)

            Text(daysRemainingText)
                .font(.headline)
                .foregroundColor(AppTheme.primary)
        }
    }

    private var bottomButtonsSection: some View {
        VStack(spacing: 12) {
            Button(String(localized: "Continue", bundle: LanguageManager.appBundle)) {
                settingsManager.recordTrialReminderShown()
                dismiss()
            }
            .buttonStyle(.zen(AppTheme.primary))

            Button(String(localized: "Unlock Now", bundle: LanguageManager.appBundle)) {
                settingsManager.recordTrialReminderShown()
                dismiss()
                // The app will present the paywall after dismissal
                // via the showPaywallAfterReminder flag
                NotificationCenter.default.post(name: .showPaywallFromTrial, object: nil)
            }
            .font(.subheadline)
            .foregroundColor(AppTheme.textSecondary)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 40)
    }

    private var daysRemainingText: String {
        let days = settingsManager.trialDaysRemaining
        return String(localized: "\(days) days remaining", bundle: LanguageManager.appBundle)
    }
}

extension Notification.Name {
    static let showPaywallFromTrial = Notification.Name("showPaywallFromTrial")
}

#Preview {
    TrialReminderView()
        .environment(AppDependencies.current.app.settingsManager)
}
