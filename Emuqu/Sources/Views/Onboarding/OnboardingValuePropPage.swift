import SwiftUI

/// Build plan §4.1 O2 — three-card value-prop carousel. Copy verbatim
/// from §6.2.
struct OnboardingValuePropPage: View {
    let advance: () -> Void
    @State private var index: Int = 0

    private struct Card: Identifiable {
        let id: Int
        let glyph: String
        let headline: String
        let body: String
    }

    // Localize the headline/body copy at definition so the
    // verbatim renders below show translated text. (Raw English
    // literals would opt the whole carousel out of localization.)
    private let cards: [Card] = [
        Card(id: 0, glyph: "circle.dotted",
             headline: String(localized: "One score. Every morning.", bundle: LanguageManager.appBundle),
             body: String(localized: "Tap your strap. Emuqu tells you what your body is ready for today.", bundle: LanguageManager.appBundle)),
        Card(id: 1, glyph: "iphone.gen3",
             headline: String(localized: "Your data. Your device.", bundle: LanguageManager.appBundle),
             body: String(localized: "Everything stays on your iPhone and in your private iCloud. Nothing on our servers.", bundle: LanguageManager.appBundle)),
        Card(id: 2, glyph: "sparkles",
             headline: String(localized: "A coach that remembers.", bundle: LanguageManager.appBundle),
             body: String(localized: "Ask anything about your training. The coach knows your data.", bundle: LanguageManager.appBundle))
    ]

    var body: some View {
        VStack(spacing: 0) {
            cardPager
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            continueButton
        }
    }

    private var cardPager: some View {
        TabView(selection: $index) {
            ForEach(cards) { card in
                cardView(card).tag(card.id)
            }
        }
    }

    private var continueButton: some View {
        Button(action: advance) {
            // Localizable label (not Text(verbatim:)).
            Text(String(localized: "Continue", bundle: LanguageManager.appBundle))
                .scaledFont(size: 17, weight: .semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(AppTheme.primary)
                )
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("onboarding.advance")
        .padding(.horizontal, 24)
        .padding(.bottom, 48)
    }

    private func cardView(_ card: Card) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: card.glyph)
                .scaledFont(size: 80)
                .foregroundStyle(AppTheme.primary)
                .accessibilityHidden(true)
            Text(verbatim: card.headline)
                .scaledFont(size: 28, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text(verbatim: card.body)
                .scaledFont(size: 16)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}
