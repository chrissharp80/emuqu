import SwiftUI

/// Flat index of every searchable Settings row and
/// the destination it pushes to. Drives the `.searchable` field at the
/// top of `SettingsView`. Type "HR zones" → jumps to the Biometrics
/// sub-page.
///
/// Each entry carries its own destination View (type-erased) so search
/// results can render NavigationLinks directly without re-implementing
/// the routing logic that lives in SettingsView's body.
struct SettingsSearchEntry: Identifiable {
    /// Stable identity derived from the (English) title. Was `UUID()`,
    /// which minted a fresh id every time the index was rebuilt — and
    /// the index was rebuilt in `SettingsView.body` on every keystroke,
    /// so `ForEach` treated every result as brand-new each frame (no
    /// view reuse → jank). Deriving `id` from the title keeps rows
    /// stable across rebuilds. Titles are unique in the catalogue.
    var id: String { title }
    /// Primary label shown in the search row.
    let title: String
    /// Subtitle used both as a hint and as an additional fuzzy-match
    /// substring.
    let subtitle: String
    /// Synonyms folded into the match string but not shown in the row.
    let aliases: [String]
    /// SF Symbol for the row.
    let systemImage: String
    /// Destination factory — invoked when the user taps the search row.
    let destination: () -> AnyView

    /// One lowercased haystack used by `matches(_:)` for substring
    /// matching. Pre-computed at construction so search is O(N) over
    /// entries with no per-keystroke string work besides the contains.
    let haystack: String

    init(title: String, subtitle: String = "", aliases: [String] = [], systemImage: String, destination: @escaping () -> AnyView) {
        self.title = title
        self.subtitle = subtitle
        self.aliases = aliases
        self.systemImage = systemImage
        self.destination = destination
        self.haystack = ([title, subtitle] + aliases).joined(separator: " ").lowercased()
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return false }
        // All space-separated tokens must appear somewhere in the
        // haystack — closer to a real "search" than a single-substring
        // match (so "hr zones" finds the row even though the haystack
        // says "Biometrics — heart rate zones").
        return q.split(separator: " ").allSatisfy { token in
            haystack.contains(token)
        }
    }
}

/// Full searchable catalogue. Hand-curated so the
/// best terms (synonyms, common questions) match the right destinations.
@MainActor
enum SettingsSearchIndex {
    static func entries(scrollToTopToken: UUID, settingsManager: SettingsManager) -> [SettingsSearchEntry] {
        identityProfileEntries(scrollToTopToken: scrollToTopToken, settingsManager: settingsManager)
            + dataSourcesEntries(scrollToTopToken: scrollToTopToken, settingsManager: settingsManager)
            + recoveryTrainingEntries(scrollToTopToken: scrollToTopToken, settingsManager: settingsManager)
            + floMainAiEntries(scrollToTopToken: scrollToTopToken, settingsManager: settingsManager)
            + notificationsEntries(scrollToTopToken: scrollToTopToken, settingsManager: settingsManager)
            + appearanceEntries(scrollToTopToken: scrollToTopToken, settingsManager: settingsManager)
            + advancedEntries(scrollToTopToken: scrollToTopToken, settingsManager: settingsManager)
            + helpAboutEntries(scrollToTopToken: scrollToTopToken, settingsManager: settingsManager)
    }

    /// Search entries for the Identity & Profile section of Settings.
    private static func identityProfileEntries(
        scrollToTopToken: UUID,
        settingsManager: SettingsManager
    ) -> [SettingsSearchEntry] {
        [

            SettingsSearchEntry(
                title: String(localized: "Profile", bundle: LanguageManager.appBundle),
                subtitle: String(localized: "Name, birthday, sex, weight, units", bundle: LanguageManager.appBundle),
                aliases: ["age", "imperial", "metric", "lb", "kg", "biological"],
                systemImage: "person.circle"
            ) { AnyView(ProfileSettingsPage()) },
            SettingsSearchEntry(
                title: String(localized: "Biometrics", bundle: LanguageManager.appBundle),
                subtitle: String(localized: "HR zones, max HR, RHR, LTHR, FTP", bundle: LanguageManager.appBundle),
                aliases: ["heart rate", "lthr", "ftp", "zones", "hr zones", "field test"],
                systemImage: "heart.circle"
            ) { AnyView(BiometricsSettingsPage()) }
        ]
    }

    /// Search entries for the Data & Sources section of Settings.
    private static func dataSourcesEntries(
        scrollToTopToken: UUID,
        settingsManager: SettingsManager
    ) -> [SettingsSearchEntry] {
        [
            wearablesSettingsPageEntry(),
            dataSettingsPageEntry(),
            reportsSettingsPageEntry(settingsManager: settingsManager)
        ]
    }

    private static func wearablesSettingsPageEntry() -> SettingsSearchEntry {
        SettingsSearchEntry(
            title: String(localized: "Wearables", bundle: LanguageManager.appBundle),
            subtitle: String(localized: "Polar H10, Verity Sense, Apple Health, broadcast", bundle: LanguageManager.appBundle),
            aliases: ["polar", "h10", "strap", "verity", "broadcast", "ble", "bluetooth", "apple health", "healthkit"],
            systemImage: "sensor.tag.radiowaves.forward"
        ) { AnyView(WearablesSettingsPage()) }
    }

    private static func dataSettingsPageEntry() -> SettingsSearchEntry {
        SettingsSearchEntry(
            title: String(localized: "iCloud & Data", bundle: LanguageManager.appBundle),
            subtitle: String(localized: "Sync, import, export, recover RR, storage", bundle: LanguageManager.appBundle),
            aliases: ["icloud", "sync", "backup", "export", "import", "csv", "rr", "trash", "storage"],
            systemImage: "icloud"
        ) { AnyView(DataSettingsPage()) }
    }

    private static func reportsSettingsPageEntry(settingsManager: SettingsManager) -> SettingsSearchEntry {
        SettingsSearchEntry(
            title: String(localized: "Reports", bundle: LanguageManager.appBundle),
            subtitle: String(localized: "Daily, workout, recovery PDFs, auto-email", bundle: LanguageManager.appBundle),
            aliases: ["pdf", "report", "email", "coach"],
            systemImage: "doc.text.image"
        ) { AnyView(ReportsSettingsPage(settingsManager: settingsManager)) }
    }

    /// Search entries for the Recovery & Training section of Settings.
    private static func recoveryTrainingEntries(
        scrollToTopToken: UUID,
        settingsManager: SettingsManager
    ) -> [SettingsSearchEntry] {
        [
            sleepSettingsPageEntry(),
            trainingSettingsPageEntry(),
            modesSettingsPageEntry(),
            customTagsPageEntry(),
            savedRoutesPageEntry()
        ]
    }

    private static func sleepSettingsPageEntry() -> SettingsSearchEntry {
        SettingsSearchEntry(
            title: String(localized: "Sleep", bundle: LanguageManager.appBundle),
            subtitle: String(localized: "Schedule, target, Apple Health sleep, split-night", bundle: LanguageManager.appBundle),
            aliases: ["sleep schedule", "wake", "bedtime", "target hours"],
            systemImage: "moon.fill"
        ) { AnyView(SleepSettingsPage()) }
    }

    private static func trainingSettingsPageEntry() -> SettingsSearchEntry {
        SettingsSearchEntry(
            title: String(localized: "Training", bundle: LanguageManager.appBundle),
            subtitle: String(localized: "Goal, training-load integration, training break", bundle: LanguageManager.appBundle),
            aliases: ["trimp", "ctl", "atl", "tsb", "load", "training break", "vacation", "goal", "maintain", "build", "peak"],
            systemImage: "figure.run"
        ) { AnyView(TrainingSettingsPage()) }
    }

    private static func modesSettingsPageEntry() -> SettingsSearchEntry {
        SettingsSearchEntry(
            title: String(localized: "Modes", bundle: LanguageManager.appBundle),
            subtitle: String(localized: "Comeback, peaking, intentional overreach", bundle: LanguageManager.appBundle),
            aliases: ["comeback", "peaking", "taper", "overreach", "race"],
            systemImage: "arrow.triangle.2.circlepath"
        ) { AnyView(ModesSettingsPage()) }
    }

    private static func customTagsPageEntry() -> SettingsSearchEntry {
        SettingsSearchEntry(
            title: String(localized: "Tags", bundle: LanguageManager.appBundle),
            subtitle: String(localized: "Custom tags for HRV sessions", bundle: LanguageManager.appBundle),
            aliases: ["tag", "custom"],
            systemImage: "tag"
        ) { AnyView(CustomTagsPage()) }
    }

    private static func savedRoutesPageEntry() -> SettingsSearchEntry {
        SettingsSearchEntry(
            title: String(localized: "My Routes", bundle: LanguageManager.appBundle),
            subtitle: String(localized: "Saved running / cycling routes", bundle: LanguageManager.appBundle),
            aliases: ["route", "gpx", "trail"],
            systemImage: "map.fill"
        ) { AnyView(SavedRoutesPage()) }
    }

    /// Search entries for the Flo (main AI) section of Settings.
    private static func floMainAiEntries(
        scrollToTopToken: UUID,
        settingsManager: SettingsManager
    ) -> [SettingsSearchEntry] {
        // Aliases keep "coach" / "assistant" so search still lands here
        // regardless of which name the user types.
        [
            SettingsSearchEntry(
                title: String(localized: "Flo", bundle: LanguageManager.appBundle),
                subtitle: String(localized: "Provider, BYOK, memory, web search", bundle: LanguageManager.appBundle),
                aliases: ["ai", "assistant", "coach", "claude", "chatgpt", "gemini", "grok", "deepseek", "memory", "tavily", "byok", "api key"],
                systemImage: "sparkles"
            ) { AnyView(AIAssistantSettingsPage()) }
        ]
    }

    /// Search entries for the Notifications section of Settings.
    private static func notificationsEntries(
        scrollToTopToken: UUID,
        settingsManager: SettingsManager
    ) -> [SettingsSearchEntry] {
        [

            SettingsSearchEntry(
                title: String(localized: "Notifications", bundle: LanguageManager.appBundle),
                subtitle: String(localized: "Daily report, alerts", bundle: LanguageManager.appBundle),
                aliases: ["push", "notification", "morning report", "alerts", "battery", "anomaly"],
                systemImage: "bell.badge"
            ) { AnyView(NotificationsSettingsPage()) },
            SettingsSearchEntry(
                title: String(localized: "Permissions", bundle: LanguageManager.appBundle),
                subtitle: String(localized: "Apple Health, notifications, location, Bluetooth", bundle: LanguageManager.appBundle),
                aliases: ["permission", "access", "privacy", "location", "gps", "bluetooth", "health", "allow"],
                systemImage: "checkmark.shield"
            ) { AnyView(PermissionsSettingsPage()) }
        ]
    }

    /// Search entries for the Appearance section of Settings.
    private static func appearanceEntries(
        scrollToTopToken: UUID,
        settingsManager: SettingsManager
    ) -> [SettingsSearchEntry] {
        [
            appearancePageEntry(),
            performanceSettingsPageEntry(),
            languagePageEntry()
        ]
    }

    private static func appearancePageEntry() -> SettingsSearchEntry {
        SettingsSearchEntry(
            title: String(localized: "Appearance", bundle: LanguageManager.appBundle),
            subtitle: String(localized: "Theme, color, dashboard layout", bundle: LanguageManager.appBundle),
            aliases: ["dark", "light", "dim", "color theme", "v2 dashboard"],
            systemImage: "paintbrush"
        ) { AnyView(AppearancePage()) }
    }

    private static func performanceSettingsPageEntry() -> SettingsSearchEntry {
        SettingsSearchEntry(
            title: String(localized: "Performance & Battery", bundle: LanguageManager.appBundle),
            subtitle: String(localized: "Master switches for older devices", bundle: LanguageManager.appBundle),
            aliases: ["performance", "battery", "low power"],
            systemImage: "bolt.slash"
        ) { AnyView(PerformanceSettingsPage()) }
    }

    private static func languagePageEntry() -> SettingsSearchEntry {
        SettingsSearchEntry(
            title: String(localized: "Language", bundle: LanguageManager.appBundle),
            subtitle: String(localized: "App language", bundle: LanguageManager.appBundle),
            aliases: ["language", "translate", "locale"],
            systemImage: "globe"
        ) { AnyView(LanguagePage()) }
    }

    /// Search entries for the Advanced section of Settings.
    private static func advancedEntries(
        scrollToTopToken: UUID,
        settingsManager: SettingsManager
    ) -> [SettingsSearchEntry] {
        [

            SettingsSearchEntry(
                title: String(localized: "Advanced Data Controls", bundle: LanguageManager.appBundle),
                subtitle: String(localized: "Erase all data", bundle: LanguageManager.appBundle),
                aliases: ["erase", "delete", "danger", "destructive"],
                systemImage: "lock.shield"
            ) { AnyView(AdvancedDataControlsPage()) },
            SettingsSearchEntry(
                title: String(localized: "Troubleshooting", bundle: LanguageManager.appBundle),
                subtitle: String(localized: "Diagnostics, repair, telemetry", bundle: LanguageManager.appBundle),
                aliases: ["diagnostics", "repair", "logs", "debug", "telemetry"],
                systemImage: "wrench.and.screwdriver"
            ) { AnyView(TroubleshootingPage()) },
            sampleDataEntry()
        ]
    }

    /// Reviewers and new users without a strap search for "demo" or "sample".
    private static func sampleDataEntry() -> SettingsSearchEntry {
        SettingsSearchEntry(
            title: String(localized: "Sample data", bundle: LanguageManager.appBundle),
            subtitle: String(localized: "Explore the app without a strap", bundle: LanguageManager.appBundle),
            aliases: ["demo", "sample", "example", "try", "no strap", "without strap", "review", "synthetic"],
            systemImage: "wand.and.stars"
        ) { AnyView(SampleDataPage()) }
    }

    /// Search entries for the Help & About section of Settings.
    private static func helpAboutEntries(
        scrollToTopToken: UUID,
        settingsManager: SettingsManager
    ) -> [SettingsSearchEntry] {
        helpEntries() + legalEntries()
    }

    private static func helpEntries() -> [SettingsSearchEntry] {
        [
            helpCenterViewEntry(),
            metricExplanationsViewEntry(),
            recoveryMethodologyViewEntry()
        ]
    }

    private static func helpCenterViewEntry() -> SettingsSearchEntry {
        SettingsSearchEntry(
            title: String(localized: "Help Center", bundle: LanguageManager.appBundle),
            subtitle: String(localized: "Articles, glossary", bundle: LanguageManager.appBundle),
            aliases: ["help", "docs", "guide"],
            systemImage: "questionmark.circle"
        ) { AnyView(HelpCenterView()) }
    }

    private static func metricExplanationsViewEntry() -> SettingsSearchEntry {
        SettingsSearchEntry(
            title: String(localized: "Metric Guide", bundle: LanguageManager.appBundle),
            subtitle: String(localized: "What every metric means", bundle: LanguageManager.appBundle),
            aliases: ["metric", "rmssd", "sdnn", "lf", "hf", "dfa"],
            systemImage: "waveform.path.ecg"
        ) { AnyView(MetricExplanationsView()) }
    }

    private static func recoveryMethodologyViewEntry() -> SettingsSearchEntry {
        SettingsSearchEntry(
            title: String(localized: "How Emuqu scores recovery", bundle: LanguageManager.appBundle),
            subtitle: String(localized: "Methodology + literature", bundle: LanguageManager.appBundle),
            aliases: ["methodology", "score", "60 25 15", "acwr"],
            systemImage: "doc.text"
        ) { AnyView(RecoveryMethodologyView()) }
    }

    private static func legalEntries() -> [SettingsSearchEntry] {
        [
            healthDisclaimerViewEntry(),
            privacyPolicyViewEntry(),
            termsOfUseViewEntry(),
            acknowledgementsViewEntry()
        ]
    }

    private static func healthDisclaimerViewEntry() -> SettingsSearchEntry {
        SettingsSearchEntry(
            title: String(localized: "Health Disclaimer", bundle: LanguageManager.appBundle),
            subtitle: String(localized: "Not a medical device, not medical advice", bundle: LanguageManager.appBundle),
            aliases: ["disclaimer", "medical", "fda"],
            systemImage: "heart.text.square"
        ) { AnyView(HealthDisclaimerView()) }
    }

    private static func privacyPolicyViewEntry() -> SettingsSearchEntry {
        SettingsSearchEntry(
            title: String(localized: "Privacy Policy", bundle: LanguageManager.appBundle),
            subtitle: String(localized: "How your data is handled", bundle: LanguageManager.appBundle),
            aliases: ["privacy", "policy", "data", "gdpr"],
            systemImage: "hand.raised"
        ) { AnyView(PrivacyPolicyView()) }
    }

    private static func termsOfUseViewEntry() -> SettingsSearchEntry {
        SettingsSearchEntry(
            title: String(localized: "Terms of Use", bundle: LanguageManager.appBundle),
            subtitle: String(localized: "Legal terms and conditions", bundle: LanguageManager.appBundle),
            aliases: ["terms", "eula", "legal", "conditions"],
            systemImage: "doc.plaintext"
        ) { AnyView(TermsOfUseView()) }
    }

    private static func acknowledgementsViewEntry() -> SettingsSearchEntry {
        SettingsSearchEntry(
            title: String(localized: "Open Source Licenses", bundle: LanguageManager.appBundle),
            subtitle: String(localized: "Acknowledgements", bundle: LanguageManager.appBundle),
            aliases: ["licenses", "acknowledgements", "open source", "credits"],
            systemImage: "text.badge.checkmark"
        ) { AnyView(AcknowledgementsView()) }
    }

}
