import SwiftUI

/// Privacy Policy accessible from Settings. Required for App Store review for health-related apps.
struct PrivacyPolicyView: View {
    var body: some View {
        List {
            introSection
            noCollectionSection
            dataCollectionSection
            dataStorageSection
            dataSharingSection
            yourControlSection
            childrensPrivacySection
            sensorPermissionsSection
            contactSection
        }
        .zenFormBackground()
        .navigationTitle(String(localized: "Privacy Policy", bundle: LanguageManager.appBundle))
    }

    private var introSection: some View {
        Section {
            Text(String(localized: "Emuqu is committed to protecting your privacy. This policy explains what data is collected, how it is stored, and how it is used.", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    /// The plainest statement in the policy, deliberately placed first.
    ///
    /// The rest of this policy describes where data goes; this section
    /// says outright where it does NOT go. Emuqu has no server, no account
    /// system and no analytics: the developer receives nothing, ever, and
    /// `check_no_developer_endpoint.sh` fails the build if that ever stops
    /// being true. Users reading a health app's privacy policy are looking for
    /// exactly this sentence, and they should not have to infer it from four
    /// paragraphs about storage.
    private var noCollectionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "The developer receives nothing", bundle: LanguageManager.appBundle))
                    .font(.subheadline.weight(.semibold))
                noCollectionBody
            }
        }
    }

    private var noCollectionBody: some View {
        ForEach(Self.noCollectionParagraphs, id: \.self) { paragraph in
            Text(paragraph)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    /// The four sentences of the no-collection statement, as data.
    ///
    /// Split at sentence boundaries rather than written as one paragraph so no
    /// single localized literal exceeds the line-length limit — the strings
    /// themselves are the localization keys, so wrapping them in source would
    /// change what Xcode extracts and orphan sixteen translations apiece.
    private static let noCollectionParagraphs: [String] = [
        String(localized: "Emuqu has no server, no account, and no login. Your data is never sent to the developer — not your heart rate, not your sleep, not your location, not your chats.", bundle: LanguageManager.appBundle),
        String(localized: "There is nowhere for it to go: the app contains no analytics, tracking, or crash-reporting service of any kind, and this is checked automatically before every release.", bundle: LanguageManager.appBundle),
        String(localized: "Two optional features do send data somewhere, and both are off until you turn them on.", bundle: LanguageManager.appBundle),
        String(localized: "iCloud Sync copies your sessions to your own private iCloud account. The AI assistant needs an API key you supply yourself.", bundle: LanguageManager.appBundle),
        String(localized: "In that case the data goes directly to that provider under your own account and their terms — the developer is not part of that exchange and cannot see it.", bundle: LanguageManager.appBundle)
    ]

    private var dataCollectionSection: some View {
        Section("Data Collection") {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Heart Rate & HRV Data", bundle: LanguageManager.appBundle))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text(String(localized: "Emuqu collects heart rate and RR interval data from connected Bluetooth sensors (Polar H10, Polar Verity Sense) and Apple Watch. This data is used to calculate HRV metrics, recovery scores, and sleep analysis.", bundle: LanguageManager.appBundle))
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
    }

    private var dataStorageSection: some View {
        Section("Data Storage") {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "On-Device Storage", bundle: LanguageManager.appBundle))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text(String(localized: "All health data is stored locally on your device in the app's private container. It stays on-device unless you turn on an optional feature that needs an outside service — the AI assistant, weather, or location-aware features (see \u{201C}AI Assistant & Optional Cloud Features\u{201D} below). Emuqu runs no server of its own.", bundle: LanguageManager.appBundle))
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "iCloud Backup", bundle: LanguageManager.appBundle))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text(String(localized: "If you enable iCloud Sync, your HRV session data is backed up to your personal iCloud account using Apple's CloudKit private database. This data is only accessible to you through your Apple ID. You can disable iCloud Sync at any time in Settings.", bundle: LanguageManager.appBundle))
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
    }

    private var dataSharingSection: some View {
        Section("Data Sharing") {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "No Selling, No Tracking", bundle: LanguageManager.appBundle))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text(String(localized: "Emuqu never sells your data, and contains no analytics SDKs, advertising frameworks, or tracking services. The only time data leaves your device is when you turn on an optional feature that needs an outside service, described next.", bundle: LanguageManager.appBundle))
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "AI Assistant & Optional Cloud Features", bundle: LanguageManager.appBundle))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text(String(localized: "If you enable the AI assistant with a cloud provider (e.g. Anthropic, OpenAI, DeepSeek), the questions you ask and the recovery context needed to answer them are sent over HTTPS directly to that provider's API using your own API key — there is no Emuqu server in between. Apple Intelligence, if you choose it, runs on-device. If web search is on, your search query goes to Tavily. Location-aware features (weather, heat tracking, nearby roads/trails, elevation) send your approximate coordinates to free OpenStreetMap-based services — Open-Meteo, Nominatim, Overpass, and OpenTopoData. Each of these is opt-in, disclosed again in-context before it runs, and subject to that provider's own privacy policy. DeepSeek in particular processes and stores data in the People's Republic of China.", bundle: LanguageManager.appBundle))
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
    }

    private var yourControlSection: some View {
        Section("Your Control") {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Data Export & Deletion", bundle: LanguageManager.appBundle))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text(String(localized: "You can export all of your data at any time from Settings > Export Data. You can delete individual sessions or all data from within the app. Deleting the app removes all locally stored data.", bundle: LanguageManager.appBundle))
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
    }

    /// The 13+ affirmation also lives in
    /// HealthDisclaimerView ("Age Requirement", shown at first launch),
    /// but the privacy policy itself must restate it. App Review and
    /// GDPR Art. 8 both look for the policy to carry it. The threshold
    /// here MUST stay in sync with HealthDisclaimerView's gate; that
    /// file documents the COPPA / GDPR 13–16 reasoning for choosing 13.
    private var childrensPrivacySection: some View {
        Section("Children's Privacy") {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Not Intended for Children", bundle: LanguageManager.appBundle))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text(String(localized: "Emuqu is for users aged 13 and over — you confirm this when you accept the health disclaimer at first launch. The app is not directed at children, and the developer does not knowingly collect personal data from anyone under 13. Emuqu has no accounts and no server of its own, so there is no stored profile held anywhere to request the deletion of; health data stays in your device's private container. If a child has used the app on your device, Settings > Delete All Data erases everything locally, and deleting the app does the same.", bundle: LanguageManager.appBundle))
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
    }

    private var sensorPermissionsSection: some View {
        Section("Sensor Permissions") {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Bluetooth & HealthKit", bundle: LanguageManager.appBundle))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text(String(localized: "Emuqu requests Bluetooth permission to connect to heart rate sensors and HealthKit permission to read workout and VO2max data. These permissions can be revoked at any time in your device's Settings.", bundle: LanguageManager.appBundle))
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
    }

    private var contactSection: some View {
        Section {
            contactDetails
        }
    }

    private var contactDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            dataControllerText
            contactText
        }
    }

    @ViewBuilder
    private var dataControllerText: some View {
        Text(String(localized: "Data Controller", bundle: LanguageManager.appBundle))
            .font(.subheadline.weight(.semibold))
            .foregroundColor(AppTheme.textPrimary)

        Text(String(localized: "Emuqu is operated as an independent project by Chris Sharp. The developer is the data controller for any personal data processed by this app.", bundle: LanguageManager.appBundle))
            .font(.subheadline)
            .foregroundColor(AppTheme.textSecondary)

    }

    @ViewBuilder
    private var contactText: some View {
        Text(String(localized: "Contact", bundle: LanguageManager.appBundle))
            .font(.subheadline.weight(.semibold))
            .foregroundColor(AppTheme.textPrimary)
            .padding(.top, 8)

        Text(String(localized: "Privacy questions, GDPR/CCPA data-subject requests (access, deletion, correction), and security reports:", bundle: LanguageManager.appBundle))
            .font(.subheadline)
            .foregroundColor(AppTheme.textSecondary)

        Link("chrissharp80@gmail.com", destination: URL(string: "mailto:chrissharp80@gmail.com?subject=Emuqu%20Privacy")!)
            .font(.subheadline)

        Text(String(localized: "You can also contact the developer through the App Store listing.", bundle: LanguageManager.appBundle))
            .font(.caption)
            .foregroundColor(AppTheme.textTertiary)
    }
}

#Preview {
    NavigationStack {
        PrivacyPolicyView()
    }
}

// MARK: - Acknowledgements

/// In-app open-source license screen. The list is hand-maintained; bump
/// when a new SPM dependency is added (also update Package.resolved
/// drift in `scripts/check_unchecked_sendable.sh`-style fashion if
/// future work adds a package-list lint).
struct AcknowledgementsView: View {
    private struct Pkg: Identifiable {
        let id = UUID()
        let name: String
        let version: String
        let license: String
        let url: String
    }

    // This list must mirror `Package.resolved` 1:1 — every resolved SPM pin
    // (direct or transitive) needs an attribution entry, since MIT/Apache/BSD
    // notices are required and reviewers occasionally flag missing ones. That
    // includes the eight transitive pins (WhisperKit + the
    // HuggingFace/Apple libraries it pulls in), not just the four SDK-direct
    // deps. Versions match `Package.resolved` — bump them when bumping the
    // resolved file.
    private let packages: [Pkg] = [
        Pkg(
            name: "polar-ble-sdk",
            version: "8.2.0",
            license: "BSD 3-Clause",
            url: "https://github.com/polarofficial/polar-ble-sdk"
        ),
        Pkg(
            name: "WhisperKit",
            version: "0.18.0",
            license: "MIT",
            url: "https://github.com/argmaxinc/WhisperKit"
        ),
        Pkg(
            name: "swift-transformers",
            version: "1.1.9",
            license: "Apache 2.0",
            url: "https://github.com/huggingface/swift-transformers"
        ),
        Pkg(
            name: "swift-jinja",
            version: "2.3.5",
            license: "Apache 2.0",
            url: "https://github.com/huggingface/swift-jinja"
        ),
        Pkg(
            name: "swift-protobuf",
            version: "1.33.3",
            license: "Apache 2.0",
            url: "https://github.com/apple/swift-protobuf"
        ),
        Pkg(
            name: "swift-crypto",
            version: "4.5.0",
            license: "Apache 2.0",
            url: "https://github.com/apple/swift-crypto"
        ),
        Pkg(
            name: "swift-asn1",
            version: "1.7.0",
            license: "Apache 2.0",
            url: "https://github.com/apple/swift-asn1"
        ),
        Pkg(
            name: "swift-collections",
            version: "1.4.1",
            license: "Apache 2.0",
            url: "https://github.com/apple/swift-collections"
        ),
        Pkg(
            name: "swift-argument-parser",
            version: "1.7.1",
            license: "Apache 2.0",
            url: "https://github.com/apple/swift-argument-parser"
        ),
        Pkg(
            name: "yyjson",
            version: "0.12.0",
            license: "MIT",
            url: "https://github.com/ibireme/yyjson"
        ),
        Pkg(
            name: "Zip",
            version: "2.1.2",
            license: "MIT",
            url: "https://github.com/marmelroy/Zip"
        )
    ]

    var body: some View {
        Form {
            licenseIntroSection
            acknowledgementsSection
            sbomSection
        }
        .zenFormBackground()
        .navigationTitle(String(localized: "Open Source Licenses", bundle: LanguageManager.appBundle))
    }

    private var licenseIntroSection: some View {
        Section {
            Text("Emuqu uses the following open-source libraries. Each link opens the project's source repository where the full license text lives.")
                .font(.footnote)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    private var acknowledgementsSection: some View {
        Section {
            ForEach(packages) { pkg in
                acknowledgementRow(pkg)
            }
        } header: {
            Text("Direct + transitive dependencies")
        }
    }

    private func acknowledgementRow(_ pkg: Pkg) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(pkg.name)
                    .font(.body.weight(.medium))
                Spacer()
                Text(pkg.version)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(AppTheme.textTertiary)
            }
            Text("License: \(pkg.license)")
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
            packageLink(pkg)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func packageLink(_ pkg: Pkg) -> some View {
        if let url = URL(string: pkg.url) {
            Link(destination: url) {
                Text(pkg.url)
                    .font(.caption)
                    .foregroundColor(AppTheme.sage)
            }
        }
    }

    private var sbomSection: some View {
        Section {
            Text("Apple system frameworks (HealthKit, CoreBluetooth, AVFoundation, Speech, MapKit, Core Location, CoreMotion, CryptoKit, Combine, SwiftUI, WatchConnectivity, BackgroundTasks, StoreKit) are governed by their respective Apple SDK licenses included with Xcode.")
                .font(.footnote)
                .foregroundColor(AppTheme.textSecondary)
        } header: {
            Text("Apple system frameworks")
        }
    }
}

#Preview {
    NavigationStack {
        AcknowledgementsView()
    }
}
