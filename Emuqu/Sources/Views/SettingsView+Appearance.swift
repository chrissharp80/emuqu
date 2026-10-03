import SwiftUI

// The Appearance and Language pages.

// MARK: - Appearance Page

struct AppearancePage: View {
    @Environment(SettingsManager.self) var settingsManager
    @Environment(LanguageManager.self) private var languageManager

    /// Notes on two settings that are deliberately NOT on this page:
    ///
    /// No "Try the new design" feature flag:
    /// the classic dashboard is gone; v2 is the design.
    /// The original plan was a toggle for a v2.0 opt-in rollout
    /// with 8-week classic-mode fallback — irrelevant at the
    /// current scale (handful of beta users on old builds).
    ///
    /// "Hide Fitness tab" lives in Settings → Training,
    /// alongside the Training Load toggle. It's a workout-related
    /// preference, not an Appearance one — and having it in two
    /// places (here AND a top-level Tabs section)
    /// confused users who toggled one and saw the other still on.
    var body: some View {
        Form {
            livePreviewSection
            backgroundThemeSection
            colorThemeSection
            paletteSwatchSection
        }
        .zenFormBackground()
        .navigationTitle(String(localized: "Appearance", bundle: LanguageManager.appBundle))
    }

    /// Live preview area showing hero ring +
    /// sample card + sample text in the currently-selected theme +
    /// colour. Reactively updates the moment a swatch is tapped.
    private var livePreviewSection: some View {
        Section {
            VStack(spacing: 14) {
                ScoreRing(state: .default(score: 84, verdict: .good), size: .card)
                    .frame(width: 110, height: 110)
                NarrativeCard(
                    text: String(localized: "Sample preview — your dashboard's narrative card looks like this in the current theme.", bundle: LanguageManager.appBundle),
                    accent: AppTheme.primary
                )
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        } header: {
            Text(String(localized: "Preview", bundle: LanguageManager.appBundle))
        }
    }

    private var backgroundThemeSection: some View {
        Section {
            ForEach(AppearanceTheme.allCases) { theme in
                backgroundThemeRow(theme)
            }
        } header: {
            Text("Background Theme", bundle: LanguageManager.appBundle)
        } footer: {
            Text("Choose a background style that's comfortable for your eyes. The Dim and Dark themes are easier to read for some users.", bundle: LanguageManager.appBundle)
        }
    }

    private func backgroundThemeRow(_ theme: AppearanceTheme) -> some View {
        Button {
            settingsManager.settings.appearanceTheme = theme
        } label: {
            backgroundThemeLabel(theme)
        }
        .accessibilityLabel(Text("\(theme.displayName): \(theme.description)", bundle: LanguageManager.appBundle))
        .accessibilityAddTraits(settingsManager.settings.appearanceTheme == theme ? [.isSelected] : [])
    }

    private func backgroundThemeLabel(_ theme: AppearanceTheme) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(theme.displayName)
                    .foregroundColor(AppTheme.textPrimary)
                Text(theme.description)
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
            Spacer()
            selectedCheckmark(for: theme)
        }
    }

    @ViewBuilder
    private func selectedCheckmark(for theme: AppearanceTheme) -> some View {
        if settingsManager.settings.appearanceTheme == theme {
            Image(systemName: "checkmark")
                .foregroundColor(AppTheme.primary)
                .accessibilityHidden(true)
        }
    }

    private var colorThemeSection: some View {
        Section {
            colorThemeGrid
        } header: {
            Text("Color Theme", bundle: LanguageManager.appBundle)
        }
    }

    private var colorThemeGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 12)], spacing: 12) {
            ForEach(ColorTheme.allCases) { theme in
                colorThemeSwatch(theme)
            }
        }
        .padding(.vertical, 8)
    }

    private func colorThemeSwatch(_ theme: ColorTheme) -> some View {
        Button {
            settingsManager.settings.colorTheme = theme
        } label: {
            colorThemeSwatchLabel(theme)
        }
    .buttonStyle(.plain)
    .accessibilityLabel(Text("Color theme: \(theme.displayName)", bundle: LanguageManager.appBundle))
    .accessibilityAddTraits(settingsManager.settings.colorTheme == theme ? [.isSelected] : [])
    }

    private func colorThemeSwatchLabel(_ theme: ColorTheme) -> some View {
        VStack(spacing: 6) {
            Circle()
                .fill(colorSwatch(for: theme))
                .frame(width: 36, height: 36)
                .overlay(colorSwatchCheckmark(theme))
            Text(theme.displayName)
                .font(.caption)
                .foregroundColor(AppTheme.textPrimary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func colorSwatchCheckmark(_ theme: ColorTheme) -> some View {
        if settingsManager.settings.colorTheme == theme {
            Image(systemName: "checkmark")
                .font(.caption.bold())
                .foregroundColor(.white)
        }
    }

    private var paletteSwatchSection: some View {
        Section {
            VStack(spacing: 12) {
                surfaceSwatches
                accentSwatches
                textSwatches
            }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Preview of current theme", bundle: LanguageManager.appBundle))
        } header: {
            Text("Preview", bundle: LanguageManager.appBundle)
        }
    }

    private var surfaceSwatches: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.background)
                .frame(height: 40)
                .overlay(
                    Text("Background", bundle: LanguageManager.appBundle)
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                )
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.cardBackground)
                .frame(height: 40)
                .overlay(
                    Text("Card", bundle: LanguageManager.appBundle)
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                )
        }
    }

    private var accentSwatches: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(AppTheme.primary)
                .frame(width: 20, height: 20)
            Circle()
                .fill(AppTheme.primaryDark)
                .frame(width: 20, height: 20)
            Circle()
                .fill(AppTheme.primaryLight)
                .frame(width: 20, height: 20)
        }
        .accessibilityHidden(true)
    }

    private var textSwatches: some View {
        HStack(spacing: 16) {
            Text("Primary", bundle: LanguageManager.appBundle)
                .font(.subheadline)
                .foregroundColor(AppTheme.textPrimary)
            Text("Secondary", bundle: LanguageManager.appBundle)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
            Text("Tertiary", bundle: LanguageManager.appBundle)
                .font(.subheadline)
                .foregroundColor(AppTheme.textTertiary)
        }
    }

    /// Static swatch color for the color theme picker (not affected by current selection)
    func colorSwatch(for theme: ColorTheme) -> Color {
        switch theme {
        case .blue: Color(red: 0.23, green: 0.51, blue: 0.96)
        case .teal: Color(red: 0.10, green: 0.59, blue: 0.56)
        case .indigo: Color(red: 0.35, green: 0.34, blue: 0.84)
        case .purple: Color(red: 0.58, green: 0.30, blue: 0.82)
        case .rose: Color(red: 0.82, green: 0.28, blue: 0.48)
        case .orange: Color(red: 0.82, green: 0.44, blue: 0.10)
        }
    }
}

// MARK: - Language Page

/// Supported app languages — maps to the translations in Localizable.xcstrings.
/// Uses the iOS AppleLanguages override so the user can pick a language
/// different from their device setting. `LanguageManager.setLanguage` applies
/// it live; the override persists for the next launch.
@MainActor
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case da
    case de
    case es
    case fi
    case fr
    case icelandic = "is"
    case it
    case ja
    case ko
    case nb
    case nl
    case ptBR = "pt-BR"
    case ru
    case sv
    case zhHans = "zh-Hans"
    case ar

    nonisolated var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .system: String(localized: "System Default", bundle: LanguageManager.appBundle)
        case .en: "English"
        case .da: "Dansk"
        case .de: "Deutsch"
        case .es: "Español"
        case .fi: "Suomi"
        case .fr: "Français"
        case .icelandic: "Íslenska"
        case .it: "Italiano"
        case .ja: "日本語"
        case .ko: "한국어"
        case .nb: "Norsk Bokmål"
        case .nl: "Nederlands"
        case .ptBR: "Português (Brasil)"
        case .ru: "Русский"
        case .sv: "Svenska"
        case .zhHans: "简体中文"
        case .ar: "العربية"
        }
    }

    /// The current app language based on the app's own AppleLanguages
    /// override. Read from the app's persistent domain only: the plain
    /// `UserDefaults` lookup falls through to the global domain, where the
    /// phone's language list would read as a choice made in the app.
    /// `nonisolated` (reads only UserDefaults) so `LanguageManager`'s
    /// nonisolated init can read it under default-MainActor isolation.
    nonisolated static var current: AppLanguage {
        let appDomain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        guard let overrides = appDomain?["AppleLanguages"] as? [String],
              let first = overrides.first
        else {
            return .system
        }
        return AppLanguage.allCases.first { $0.rawValue == first } ?? .system
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

struct LanguagePage: View {
    @Environment(LanguageManager.self) private var languageManager
    @State private var selectedLanguage = AppLanguage.current

    var body: some View {
        Form {
            languageSection
        }
        .zenFormBackground()
        .navigationTitle(String(localized: "Language", bundle: LanguageManager.appBundle))
    }

    private func languageRow(_ language: AppLanguage) -> some View {
        Button {
            selectLanguage(language)
        } label: {
            languageRowLabel(language)
        }
        .accessibilityLabel(language.displayName)
        .accessibilityAddTraits(selectedLanguage == language ? [.isSelected] : [])
    }

    private func selectLanguage(_ language: AppLanguage) {
        guard language != selectedLanguage else { return }
        selectedLanguage = language
        languageManager.setLanguage(language)
    }

    private func languageRowLabel(_ language: AppLanguage) -> some View {
        HStack {
            Text(language.displayName)
                .foregroundColor(AppTheme.textPrimary)
            Spacer()
            selectedLanguageCheckmark(language)
        }
    }

    @ViewBuilder
    private func selectedLanguageCheckmark(_ language: AppLanguage) -> some View {
        if selectedLanguage == language {
            Image(systemName: "checkmark")
                .foregroundColor(AppTheme.primary)
                .accessibilityHidden(true)
        }
    }

    private var languageSection: some View {
        Section {
            ForEach(AppLanguage.allCases) { language in
                languageRow(language)
            }
        } footer: {
            Text("The app switches language right away. Choose System to follow your iPhone's language.", bundle: LanguageManager.appBundle)
        }
    }
}
