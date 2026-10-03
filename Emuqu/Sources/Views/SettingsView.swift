import CoreBluetooth
import CoreLocation
import HealthKit
import SwiftUI
import UIKit
import UserNotifications

// MARK: - Settings View

/// Settings hub — each row drills into a sub-page, like iPhone Settings.
struct SettingsView: View {
    @Environment(\.dependencies) var dependencies
    @Environment(RRCollector.self) var collector
    @Environment(LanguageManager.self) private var languageManager
    @Environment(SettingsManager.self) private var settingsManager
    private var logger: DebugLogger { dependencies.app.debugLogger }
    var scrollToTopToken: UUID = .init()

    /// Settings search bar at the top. Type
    /// "HR zones" → jumps to the right sub-page. Driven by
    /// SettingsSearchIndex.
    @State private var searchQuery: String = ""
    @State private var navigatingTo: SearchResultRoute?
    /// Built once in `.onAppear` and reused. A computed property here
    /// rebuilds the whole catalogue on every `body` evaluation (i.e. every
    /// keystroke in the search field), re-running all the String(localized:)
    /// lookups and AnyView factories each time — per-keystroke work that
    /// shows up as search jank.
    @State private var cachedSearchEntries: [SettingsSearchEntry] = []
    /// What the last Restore Purchases tap found.
    @State private var restoreNotice: String?

    private struct SearchResultRoute: Identifiable {
        let id = UUID()
        let entry: SettingsSearchEntry
    }

    /// Settings renders eight groups, in the order of `settingsBody`:
    /// Identity & Profile, Data & Sources, Recovery & Training, Flo,
    /// Notifications, Appearance, Advanced, About & Help. Restore Purchases
    /// sits in its own one-line section per App Review 3.1.1.
    private var filteredSearchResults: [SettingsSearchEntry] {
        cachedSearchEntries.filter { $0.matches(searchQuery) }
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            settingsList(scrollProxy)
                .scrollContentBackground(.hidden)
                .onChange(of: scrollToTopToken) { scrollToTop(scrollProxy) }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle(String(localized: "Settings", bundle: LanguageManager.appBundle))
        .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: String(localized: "Search settings", bundle: LanguageManager.appBundle))
        .onAppear { buildSearchCatalogueIfNeeded() }
        // Titles and keywords are localized when built: rebuild on a live
        // language change so search matches the new language.
        .onChange(of: languageManager.revision) {
            cachedSearchEntries = []
            buildSearchCatalogueIfNeeded()
        }
        .sheet(item: $navigatingTo) { settingsSheet($0) }
    }

    private func scrollToTop(_ scrollProxy: ScrollViewProxy) {
        withAnimation { scrollProxy.scrollTo("settingsTop", anchor: .top) }
    }

    private func settingsList(_ scrollProxy: ScrollViewProxy) -> some View {
        List {
            // No row background: the zero-height anchor still got a list cell,
            // which drew as an empty white card above the first section.
            Color.clear.frame(height: 0).listRowSeparator(.hidden).listRowBackground(Color.clear).id("settingsTop")
            listContent(scrollProxy)
        }
    }

    /// Search results take over the list when the user has typed something;
    /// otherwise the standard grouped structure renders.
    @ViewBuilder
    private func listContent(_ scrollProxy: ScrollViewProxy) -> some View {
        if searchQuery.isEmpty {
            settingsBody(scrollProxy: scrollProxy)
        } else if filteredSearchResults.isEmpty {
            noSearchResultsSection
        } else {
            resultsSection
        }
    }

    private var noSearchResultsSection: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .scaledFont(size: 28)
                    .foregroundStyle(AppTheme.textTertiary)
                Text(String(localized: "No settings match \"\(searchQuery)\"", bundle: LanguageManager.appBundle))
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(AppTheme.textPrimary)
                Text(String(localized: "Try a different keyword.", bundle: LanguageManager.appBundle))
                    .scaledFont(size: 13)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    /// Build the search catalogue once (not per keystroke). Guard against
    /// re-building on every appear so navigating back to Settings doesn't
    /// needlessly re-run the factories.
    private func buildSearchCatalogueIfNeeded() {
        guard cachedSearchEntries.isEmpty else { return }
        cachedSearchEntries = SettingsSearchIndex.entries(scrollToTopToken: scrollToTopToken, settingsManager: settingsManager)
    }

    private func settingsSheet(_ route: SearchResultRoute) -> some View {
        NavigationStack {
            route.entry.destination()
                .toolbar { sheetDoneToolbarItem }
        }
    }

    @ToolbarContentBuilder
    private var sheetDoneToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) { navigatingTo = nil }
        }
    }

    private func searchResultRow(_ entry: SettingsSearchEntry) -> some View {
        Button {
            navigatingTo = SearchResultRoute(entry: entry)
        } label: {
            searchResultLabel(entry)
        }
        .buttonStyle(.plain)
    }

    private var resultsSection: some View {
        Section {
            ForEach(filteredSearchResults) { searchResultRow($0) }
        } header: {
            Text(String(localized: "Results", bundle: LanguageManager.appBundle))
        }
    }

    private func searchResultLabel(_ entry: SettingsSearchEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.systemImage)
                .foregroundStyle(AppTheme.primary)
                .frame(width: 24)
            searchResultText(entry)
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.caption)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private func searchResultText(_ entry: SettingsSearchEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: entry.title)
                .foregroundStyle(AppTheme.textPrimary)
            if !entry.subtitle.isEmpty {
                Text(verbatim: entry.subtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func settingsBody(scrollProxy: ScrollViewProxy) -> some View {
        Group {
            identitySection()
            dataSourcesSection()
            recoveryTrainingSection()
            floSection()
            notificationsSection()
            appearanceSection(scrollProxy: scrollProxy)
            advancedSection()
            aboutSection()
        }
    }

    /// Settings section: Identity & Profile.
    @ViewBuilder
    private func identitySection() -> some View {
        // 1. Identity & Profile
        Section {
            // Identifiers so UI tests need not match
            // rows with `label CONTAINS[c] "Sleep"`, which happily hits
            // the "Connect Apple Health, For sleep + vitals" banner
            // instead of the Sleep row and then fails on hittability.
            NavigationLink { ProfileSettingsPage() } label: {
                Label(String(localized: "Profile", bundle: LanguageManager.appBundle), systemImage: "person.circle")
            }
            .accessibilityIdentifier("settings.profile")
            NavigationLink { BiometricsSettingsPage() } label: {
                Label(String(localized: "Biometrics", bundle: LanguageManager.appBundle), systemImage: "heart.circle")
            }
            .accessibilityIdentifier("settings.biometrics")
        } header: {
            Text(String(localized: "Identity & Profile", bundle: LanguageManager.appBundle))
        }
    }

    /// Settings section: Data & Sources.
    @ViewBuilder
    private func dataSourcesSection() -> some View {
        // 2. Data & Sources
        Section {
            NavigationLink { WearablesSettingsPage() } label: {
                Label(String(localized: "Wearables", bundle: LanguageManager.appBundle), systemImage: "sensor.tag.radiowaves.forward")
            }
            .accessibilityIdentifier("settings.wearables")
            NavigationLink { DataSettingsPage() } label: {
                Label(String(localized: "iCloud & Data", bundle: LanguageManager.appBundle), systemImage: "icloud")
            }
            .accessibilityIdentifier("settings.data")
            NavigationLink { ReportsSettingsPage(settingsManager: settingsManager) } label: {
                Label(String(localized: "Reports", bundle: LanguageManager.appBundle), systemImage: "doc.text.image")
            }
            .accessibilityIdentifier("settings.reports")
        } header: {
            Text(String(localized: "Data & Sources", bundle: LanguageManager.appBundle))
        }
    }

    /// Settings section: Recovery & Training.
    @ViewBuilder
    private func recoveryTrainingSection() -> some View {
        Section {
            NavigationLink { SleepSettingsPage() } label: {
                Label(String(localized: "Sleep", bundle: LanguageManager.appBundle), systemImage: "moon.fill")
            }
            .accessibilityIdentifier("settings.sleep")
            NavigationLink { TrainingSettingsPage() } label: {
                Label(String(localized: "Training", bundle: LanguageManager.appBundle), systemImage: "figure.run")
            }
            .accessibilityIdentifier("settings.training")
            NavigationLink { ModesSettingsPage() } label: {
                Label(String(localized: "Modes", bundle: LanguageManager.appBundle), systemImage: "arrow.triangle.2.circlepath")
            }
            .accessibilityIdentifier("settings.modes")
            tagsAndRoutesLinks
        } header: {
            Text(String(localized: "Recovery & Training", bundle: LanguageManager.appBundle))
        }
    }

    /// The two library pages in the Recovery & Training section.
    @ViewBuilder
    private var tagsAndRoutesLinks: some View {
        NavigationLink { CustomTagsPage() } label: {
            Label(String(localized: "Tags", bundle: LanguageManager.appBundle), systemImage: "tag")
        }
        .accessibilityIdentifier("settings.tags")
        NavigationLink { SavedRoutesPage() } label: {
            Label(String(localized: "My Routes", bundle: LanguageManager.appBundle), systemImage: "map.fill")
        }
        .accessibilityIdentifier("settings.routes")
    }

    /// Settings section: Flo.
    @ViewBuilder
    private func floSection() -> some View {
        // 4. Flo (main AI) — the in-workout
        // trigger voice keeps the "Coach" name; this section is
        // for the conversational chat AI.
        Section {
            NavigationLink { AIAssistantSettingsPage() } label: {
                Label(String(localized: "Flo", bundle: LanguageManager.appBundle), systemImage: "sparkles")
            }
            // The row and its section header carry
            // the same word, so a label search would match the header
            // (untappable) about as often as the row.
            .accessibilityIdentifier("settings.flo")
        } header: {
            Text(String(localized: "Flo", bundle: LanguageManager.appBundle))
        }
    }

    /// Settings section: Notifications.
    @ViewBuilder
    private func notificationsSection() -> some View {
        // 5. Notifications
        Section {
            NavigationLink { NotificationsSettingsPage() } label: {
                Label(String(localized: "Notifications", bundle: LanguageManager.appBundle), systemImage: "bell.badge")
            }
            .accessibilityIdentifier("settings.notifications")
            NavigationLink { PermissionsSettingsPage() } label: {
                Label(String(localized: "Permissions", bundle: LanguageManager.appBundle), systemImage: "checkmark.shield")
            }
            .accessibilityIdentifier("settings.permissions")
        } header: {
            Text(String(localized: "Notifications", bundle: LanguageManager.appBundle))
        }
    }

    /// Settings section: Appearance, plus the purchase-status rows that sit
    /// directly beneath it.
    @ViewBuilder
    private func appearanceSection(scrollProxy: ScrollViewProxy) -> some View {
        Section {
            NavigationLink { AppearancePage() } label: {
                Label(String(localized: "Appearance", bundle: LanguageManager.appBundle), systemImage: "paintbrush")
            }
            .accessibilityIdentifier("settings.appearance")
            NavigationLink { PerformanceSettingsPage() } label: {
                Label(String(localized: "Performance & Battery", bundle: LanguageManager.appBundle), systemImage: "bolt.slash")
            }
            .accessibilityIdentifier("settings.performance")
            NavigationLink { LanguagePage() } label: { languageRowLabel }
                .accessibilityIdentifier("settings.language")
        } header: {
            Text(String(localized: "Appearance", bundle: LanguageManager.appBundle))
        }
        PurchaseStatusView()
        restorePurchasesSection
    }

    /// Language, with the current selection shown on the trailing edge.
    private var languageRowLabel: some View {
        HStack {
            Label(String(localized: "Language", bundle: LanguageManager.appBundle), systemImage: "globe")
            Spacer()
            Text(AppLanguage.current.displayName)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    /// Restore (App Review 3.1.1) — only shown when the paywall is live.
    @ViewBuilder
    private var restorePurchasesSection: some View {
        if StoreKitManager.paywallEnabled {
            Section {
                restorePurchasesButton
            } footer: {
                Text("If you previously purchased Emuqu and reinstalled, tap to restore your entitlement from your Apple ID.", bundle: LanguageManager.appBundle)
            }
        }
    }

    private var restorePurchasesButton: some View {
        Button {
            Task { restoreNotice = await dependencies.services.storeKitManager.restore() }
        } label: {
            restorePurchasesLabel
        }
        .disabled(dependencies.services.storeKitManager.isPurchasing)
        .alert(
            String(localized: "Restore Purchases", bundle: LanguageManager.appBundle),
            isPresented: Binding(
                get: { restoreNotice != nil },
                set: { if !$0 { restoreNotice = nil } }
            ),
            presenting: restoreNotice
        ) { _ in
            Button(String(localized: "OK", bundle: LanguageManager.appBundle)) { restoreNotice = nil }
        } message: { Text($0) }
    }

    /// A spinner while the App Store answers, so a slow restore does not read
    /// as a tap that did nothing.
    @ViewBuilder
    private var restorePurchasesLabel: some View {
        if dependencies.services.storeKitManager.isPurchasing {
            HStack {
                Label(String(localized: "Restore Purchases", bundle: LanguageManager.appBundle), systemImage: "arrow.clockwise")
                Spacer()
                ProgressView()
            }
        } else {
            Label(String(localized: "Restore Purchases", bundle: LanguageManager.appBundle), systemImage: "arrow.clockwise")
        }
    }

    /// Settings section: Advanced.
    @ViewBuilder
    private func advancedSection() -> some View {
        Section {
            NavigationLink { AdvancedDataControlsPage() } label: {
                Label(String(localized: "Advanced Data Controls", bundle: LanguageManager.appBundle), systemImage: "lock.shield")
            }
            .accessibilityIdentifier("settings.advancedDataControls")
            NavigationLink { TroubleshootingPage() } label: { troubleshootingRowLabel }
                .accessibilityIdentifier("settings.troubleshooting")
        } header: {
            Text(String(localized: "Advanced", bundle: LanguageManager.appBundle))
        } footer: {
            Text("Erasing all your data sits behind a confirmation step so a stray tap can't wipe your history.", bundle: LanguageManager.appBundle)
        }
    }

    /// Troubleshooting, badged with the number of logged errors when there are
    /// any.
    private var troubleshootingRowLabel: some View {
        HStack {
            Label(String(localized: "Troubleshooting", bundle: LanguageManager.appBundle), systemImage: "wrench.and.screwdriver")
            Spacer()
            if logger.errorCatalog.count > 0 {
                Text("\(logger.errorCatalog.count)")
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(AppTheme.alert)
                    .clipShape(Capsule())
            }
        }
    }

    /// Settings section: About & Help.
    @ViewBuilder
    private func aboutSection() -> some View {
        Section {
            NavigationLink { HelpCenterView() } label: {
                Label(String(localized: "Help Center", bundle: LanguageManager.appBundle), systemImage: "questionmark.circle")
            }
            .accessibilityIdentifier("settings.helpCenter")
            NavigationLink { MetricExplanationsView() } label: {
                Label(String(localized: "Metric Guide", bundle: LanguageManager.appBundle), systemImage: "waveform.path.ecg")
            }
            .accessibilityIdentifier("settings.metricGuide")
            NavigationLink { RecoveryMethodologyView() } label: {
                Text("How Emuqu scores recovery", bundle: LanguageManager.appBundle)
            }
            .accessibilityIdentifier("settings.methodology")
            supportLink
            legalLinks
            versionRow
        } header: {
            Text(String(localized: "About & Help", bundle: LanguageManager.appBundle))
        }
    }

    /// How to reach the developer with a question or a problem. Plain text
    /// when the `mailto:` does not parse, as on the privacy policy.
    @ViewBuilder
    private var supportLink: some View {
        if let mail = URL(string: "mailto:chrissharp80@gmail.com?subject=Emuqu%20Support") {
            Link(destination: mail) {
                Label(String(localized: "Contact Support", bundle: LanguageManager.appBundle), systemImage: "envelope")
            }
            .accessibilityIdentifier("settings.contactSupport")
        } else {
            Text(verbatim: "chrissharp80@gmail.com")
        }
    }

    /// Terms, privacy, health disclaimer, and open-source licenses.
    @ViewBuilder
    private var legalLinks: some View {
        NavigationLink { TermsOfUseView() } label: {
            Text("Terms of Use", bundle: LanguageManager.appBundle)
        }
        .accessibilityIdentifier("settings.termsOfUse")
        NavigationLink { PrivacyPolicyView() } label: {
            Text("Privacy Policy", bundle: LanguageManager.appBundle)
        }
        .accessibilityIdentifier("settings.privacyPolicy")
        NavigationLink { HealthDisclaimerView() } label: {
            Text("Health Disclaimer", bundle: LanguageManager.appBundle)
        }
        .accessibilityIdentifier("settings.healthDisclaimer")
        NavigationLink { AcknowledgementsView() } label: {
            Text("Open Source Licenses", bundle: LanguageManager.appBundle)
        }
        .accessibilityIdentifier("settings.acknowledgements")
    }

    private var versionRow: some View {
        HStack {
            Text("Version", bundle: LanguageManager.appBundle)
            Spacer()
            Text(Bundle.main.appVersionString)
                .foregroundColor(AppTheme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environment(AppDependencies.current.app.settingsManager)
    }
}

// NOTE — PermissionsSettingsPage lives HERE (not its own file) because
// the Views/ group uses explicit pbxproj membership, not a synchronized folder,
// so a new standalone .swift file isn't added to the target and fails to compile
// ("cannot find 'PermissionsSettingsPage' in scope"). Keeping it in this
// already-compiled file guarantees it builds. Move to its own file only after
// adding that file to the Emuqu target in Xcode.

/// Permissions status screen. Users hit silent failures when a
/// system permission wasn't granted — most painfully HealthKit **workout
/// write**, which made the app's workouts never reach Apple Health with no
/// visible reason (only a buried "Not authorized" log line). This surfaces the
/// status of every permission the app depends on, re-prompts the ones iOS still
/// allows to be re-prompted (`.notDetermined`), and deep-links to iOS Settings
/// for the ones the user already declined (iOS won't re-ask those).
///
/// Note on HealthKit **reads**: Apple deliberately withholds read-authorization
/// status for privacy, so a granted/denied read can't be shown here. Only writes
/// are reliably inspectable — which is exactly the gap that bit users.
struct PermissionsSettingsPage: View {
    @Environment(\.dependencies) var dependencies
    @Environment(\.openURL) private var openURL
    /// The system permission alert takes the app inactive; reload on return
    /// so a row reflects the user's answer straight away.
    @Environment(\.scenePhase) private var scenePhase

    @State private var healthWrites: [HealthKitManager.WritePermission] = []
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined
    @State private var locationStatus: CLAuthorizationStatus = .notDetermined
    @State private var bluetoothStatus: CBManagerAuthorization = .notDetermined
    @State private var locationManager = CLLocationManager()

    private var anyHealthDenied: Bool { healthWrites.contains { $0.status == .sharingDenied } }
    private var anyHealthUnset: Bool { healthWrites.contains { $0.status == .notDetermined } }

    var body: some View {
        Form {
            Section {
                Text(String(localized: "These are the system permissions Emuqu uses. Anything not allowed silently limits the app — grant what's missing here, or open iOS Settings if you already declined it.", bundle: LanguageManager.appBundle))
                    .scaledFont(size: 13)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            markAppleHealthWriteSection40
            markNotificationsSection
            markLocationSection
            markBluetoothSection
        }
        .navigationTitle(Text(String(localized: "Permissions", bundle: LanguageManager.appBundle)))
        .scrollContentBackground(.hidden)
        .background(AppTheme.background.ignoresSafeArea())
        .task { await reload() }
        .onChange(of: scenePhase) { _, phase in reloadOnReturn(phase) }
    }

    private func reloadOnReturn(_ phase: ScenePhase) {
        guard phase == .active else { return }
        Task { await reload() }
    }

    private var markAppleHealthWriteSection40: some View {
        // MARK: Apple Health (write)
        Section {
            ForEach(healthWrites) { perm in
                permRow(title: perm.label, state: state(for: perm.status))
            }
            reRequestHealthAccessButton
            if anyHealthDenied {
                openSettingsButton
            }
        } header: {
            Text(String(localized: "Apple Health", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: "The list above is WRITE access (does your Emuqu data reach Apple Health). READ access — sleep and vitals — is hidden by iOS, so it can't be shown here. If Apple Health has your sleep but Emuqu shows none (common after switching iPhones, where read permissions don't carry over), tap \"Re-request Health access\" — iOS will re-prompt for anything not yet granted, including Sleep. If it was hard-denied, enable it in iOS Settings → Health → Data Access & Devices → Emuqu.", bundle: LanguageManager.appBundle))
        }
    }

    private var reRequestHealthAccessButton: some View {
        Button {
            Task {
                await dependencies.collection.healthKitManager.forceReauthorize()
                await reload()
            }
        } label: {
            Label(String(localized: "Re-request Health access", bundle: LanguageManager.appBundle), systemImage: "arrow.clockwise")
        }
    }

    private var markNotificationsSection: some View {
        // MARK: Notifications
        Section {
            permRow(title: String(localized: "Notifications", bundle: LanguageManager.appBundle), state: state(for: notifStatus))
            switch notifStatus {
            case .notDetermined:
                allowNotificationsButton
            case .denied:
                openSettingsButton
            default:
                EmptyView()
            }
        } header: {
            Text(String(localized: "Notifications", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: "Needed for the morning recovery push.", bundle: LanguageManager.appBundle))
        }
    }

    private var allowNotificationsButton: some View {
        Button {
            Task {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
                await reload()
            }
        } label: {
            Label(String(localized: "Allow notifications", bundle: LanguageManager.appBundle), systemImage: "bell.badge")
        }
    }

    @ViewBuilder
    private var locationPermissionAction: some View {
        switch locationStatus {
        case .notDetermined: allowLocationButton
        case .denied, .restricted: openSettingsButton
        default: EmptyView()
        }
    }

    private var allowLocationButton: some View {
        Button {
            locationManager.requestWhenInUseAuthorization()
        } label: {
            Label(String(localized: "Allow location", bundle: LanguageManager.appBundle), systemImage: "location")
        }
    }

    private var markLocationSection: some View {
        // MARK: Location
        Section {
            permRow(title: String(localized: "Location", bundle: LanguageManager.appBundle), state: state(for: locationStatus))
            locationPermissionAction
        } header: {
            Text(String(localized: "Location", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: "Used to map outdoor workouts (GPS route + distance) and for road-aware coaching. Indoor sessions and the recovery score don't need it.", bundle: LanguageManager.appBundle))
        }
    }

    private var markBluetoothSection: some View {
        // MARK: Bluetooth
        Section {
            permRow(title: String(localized: "Bluetooth", bundle: LanguageManager.appBundle), state: state(for: bluetoothStatus))
            if bluetoothStatus == .denied || bluetoothStatus == .restricted {
                openSettingsButton
            }
        } header: {
            Text(String(localized: "Bluetooth", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: "Required to connect the Polar strap. iOS asks for this the first time you connect a sensor; if it's Denied here, the strap can't connect until you re-enable it in iOS Settings.", bundle: LanguageManager.appBundle))
        }
    }

    // MARK: - Rows

    fileprivate enum PermState { case allowed, denied, notSet, unavailable }

    @ViewBuilder
    private func permRow(title: String, state: PermState) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(state.label)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(state.color)
        }
    }

    private var openSettingsButton: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        } label: {
            Label(String(localized: "Open iOS Settings", bundle: LanguageManager.appBundle), systemImage: "gear")
        }
    }

    // MARK: - Status loading + mapping

    @MainActor
    private func reload() async {
        healthWrites = dependencies.collection.healthKitManager.writePermissionSummary()
        notifStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        locationStatus = locationManager.authorizationStatus
        bluetoothStatus = CBCentralManager.authorization
    }

    private func state(for s: HKAuthorizationStatus) -> PermState {
        switch s {
        case .sharingAuthorized: .allowed
        case .sharingDenied: .denied
        case .notDetermined: .notSet
        @unknown default: .unavailable
        }
    }

    private func state(for s: UNAuthorizationStatus) -> PermState {
        switch s {
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        case .notDetermined: .notSet
        @unknown default: .unavailable
        }
    }

    private func state(for s: CLAuthorizationStatus) -> PermState {
        switch s {
        case .authorizedAlways, .authorizedWhenInUse: .allowed
        case .denied, .restricted: .denied
        case .notDetermined: .notSet
        @unknown default: .unavailable
        }
    }

    private func state(for s: CBManagerAuthorization) -> PermState {
        switch s {
        case .allowedAlways: .allowed
        case .denied, .restricted: .denied
        case .notDetermined: .notSet
        @unknown default: .unavailable
        }
    }
}

private extension PermissionsSettingsPage.PermState {
    var label: String {
        switch self {
        case .allowed: String(localized: "Allowed", bundle: LanguageManager.appBundle)
        case .denied: String(localized: "Denied", bundle: LanguageManager.appBundle)
        case .notSet: String(localized: "Not set", bundle: LanguageManager.appBundle)
        case .unavailable: String(localized: "Unavailable", bundle: LanguageManager.appBundle)
        }
    }

    @MainActor var color: Color {
        switch self {
        case .allowed: AppTheme.sage
        case .denied: AppTheme.terracotta
        case .notSet: AppTheme.wongCaution
        case .unavailable: AppTheme.textTertiary
        }
    }
}
