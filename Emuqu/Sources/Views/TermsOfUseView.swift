import SwiftUI

/// Read-only Terms of Use / Health Disclaimer accessible from Settings at any time.
struct TermsOfUseView: View {
    /// Last substantive revision to the terms. Shown to users so they know
    /// what version they last agreed to; bump when the text materially changes.
    static let lastRevisedDate = DateComponents(year: 2026, month: 4, day: 24)

    /// The revision date in the app language ("24. April 2026", "2026年4月24日").
    static var lastRevised: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = LanguageManager.appLocale
        guard let date = calendar.date(from: lastRevisedDate) else { return "" }
        return date.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: LanguageManager.appLocale, calendar: calendar))
    }

    var body: some View {
        List {
            lastRevisedSection
            disclaimerSections
            contactSection
        }
        .zenFormBackground()
        .navigationTitle(String(localized: "Terms of Use", bundle: LanguageManager.appBundle))
    }

    private var lastRevisedSection: some View {
        Section {
            Text(String(localized: "By using Emuqu you agree to the following terms.", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
            Text("Last revised: \(Self.lastRevised)", bundle: LanguageManager.appBundle)
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    private var disclaimerSections: some View {
        ForEach(Array(HealthDisclaimer.sections.enumerated()), id: \.offset) { _, section in
            Section {
                DisclaimerSectionView(section: section)
            }
        }
    }

    private var contactSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Contact", bundle: LanguageManager.appBundle))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.textPrimary)

                Text(String(localized: "If you have questions about these terms, contact the developer through the App Store listing.", bundle: LanguageManager.appBundle))
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
    }
}

#Preview {
    NavigationStack {
        TermsOfUseView()
    }
}
