import SwiftUI

/// First-run disclosure presented when the user opens the Assistant tab.
///
/// Three points: (1) Apple model is on-device, (2) third-party providers
/// receive your data and Emuqu does not police what they do with
/// it or what they tell you, (3) this is not medical advice.
///
/// Once accepted, never shown again unless the user clears app data.
struct DisclaimerSheet: View {
    @Binding var isPresented: Bool
    let onAccept: () -> Void

    var body: some View {
        NavigationStack {
            disclaimerScroll
        }
    }

    private var disclaimerScroll: some View {
        ScrollView {
            disclaimerStack
        }
        .navigationTitle(String(localized: "AI Assistant", bundle: LanguageManager.appBundle))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var disclaimerStack: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            disclaimerPoints
            Spacer(minLength: 12)
            iUnderstandContinueButton
                .accessibilityIdentifier("assistant.disclaimerAccept")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
    }

    /// The accept button carries an accessibility identifier
    /// because this sheet is the first thing the Flo tab presents: a test that
    /// cannot dismiss it cannot reach the tab at all, and because the sheet
    /// leaves the tab bar in the hierarchy underneath, it also cannot switch
    /// away.
    @ViewBuilder
    private var disclaimerPoints: some View {
        privacyPoints
        responsibilityPoints
    }

    @ViewBuilder
    private var privacyPoints: some View {
        point(
            symbol: "apple.logo",
            title: String(localized: "Apple Intelligence is on-device", bundle: LanguageManager.appBundle),
            body: String(localized: "When you use Apple Intelligence, your recovery data and questions never leave this iPhone. No network involved.", bundle: LanguageManager.appBundle)
        )

        point(
            symbol: "network",
            title: String(localized: "Connected models send your data to that vendor", bundle: LanguageManager.appBundle),
            body: String(localized: "If you add a Claude, ChatGPT, Gemini, Grok, or DeepSeek API key, your session data and questions are sent to Anthropic, OpenAI, Google, xAI, or DeepSeek, under that company's privacy policy.", bundle: LanguageManager.appBundle)
                + " " + String(localized: "Emuqu screens questions and replies on this device for medical red flags and points you to a clinician, but it cannot control what those services do with your data or everything they say. Long-press any reply to report it.", bundle: LanguageManager.appBundle)
        )

    }

    @ViewBuilder
    private var responsibilityPoints: some View {
        point(
            symbol: "stethoscope",
            title: String(localized: "Coaching, not medical advice", bundle: LanguageManager.appBundle),
            body: String(localized: "AI responses are informational coaching from the data this app collected. They are not medical diagnosis or treatment. For health decisions, talk to a qualified clinician.", bundle: LanguageManager.appBundle)
        )

        point(
            symbol: "key.fill",
            title: String(localized: "Your keys stay on this device", bundle: LanguageManager.appBundle),
            body: String(localized: "API keys are stored in the iOS Keychain, encrypted, never synced to iCloud, and used only to call the provider you added them for.", bundle: LanguageManager.appBundle)
        )
    }

    /// Not `Color.accentColor`: the asset is unset, so it resolves to system
    /// blue (#007AFF), and white on that is 4.02:1 — under the 4.5:1 AA floor
    /// for this button's body-sized label. `primary` is tuned to read as an
    /// accent against the background, not underneath white text — it lands at
    /// 3.69:1. `primaryFilled` is the same hue darkened until white clears AA.
    private var acceptButtonBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(AppTheme.primaryFilled)
    }

    private var iUnderstandContinueButton: some View {
        Button {
            onAccept()
            isPresented = false
        } label: {
            Text(String(localized: "I understand — continue", bundle: LanguageManager.appBundle))
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(acceptButtonBackground)
                .foregroundStyle(.white)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                Text(String(localized: "Before you start", bundle: LanguageManager.appBundle))
                    .font(.title2.weight(.bold))
            }
            Text(String(localized: "A few things to know about how this feature handles your data.", bundle: LanguageManager.appBundle))
                .font(.callout)
                // System `.secondary` resolves to ~4.4:1 on a sheet
                // background — just under WCAG AA. AppTheme.textSecondary is
                // contrast-checked against every surface in every theme.
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private func point(symbol: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(Color.accentColor)
                // Decorative. The adjacent `title` states the point in words,
                // so exposing the glyph makes VoiceOver announce the raw SF
                // Symbol name ("apple.logo") before the sentence that explains
                // it — which the accessibility audit flagged as a
                // not-human-readable label.
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(body)
                    .font(.callout)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }
}
