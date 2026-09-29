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
        String(localized: "Some features do send data to services outside the app. Each one is described below: what it sends, where, and when.", bundle: LanguageManager.appBundle),
        String(localized: "In each case the data goes straight from your device to that service, never through the developer.", bundle: LanguageManager.appBundle)
    ]

    /// A heading and the sentences under it. Each sentence is its own
    /// localized string so no literal outgrows the line-length limit, and so
    /// correcting one claim re-translates one sentence rather than a page.
    struct PolicyBlock {
        let title: String
        let sentences: [String]
    }

    /// What the strap and Watch record.
    private static let heartRateBlock = PolicyBlock(
        title: String(localized: "Heart Rate & HRV Data", bundle: LanguageManager.appBundle),
        sentences: [
            String(localized: "Emuqu records heart rate and beat-to-beat (RR) intervals from the Polar H10 or Polar Verity Sense you connect over Bluetooth, and wrist heart rate from your Apple Watch during workouts.", bundle: LanguageManager.appBundle),
            String(localized: "These are used to calculate HRV metrics, recovery scores, training load and sleep analysis.", bundle: LanguageManager.appBundle)
        ]
    )

    /// Every HealthKit type read and written, as Guideline 5.1.3(i) asks. Keep
    /// this in step with `HealthKitManager.readTypes` / `writeTypes` and the
    /// Health purpose strings in Info.plist.
    private static let appleHealthBlock = PolicyBlock(
        title: String(localized: "Apple Health", bundle: LanguageManager.appBundle),
        sentences: [
            String(localized: "With your permission, Emuqu reads sleep, mindful minutes, heart rate, resting heart rate, HRV, respiratory rate, blood oxygen and sleeping wrist temperature from Apple Health.", bundle: LanguageManager.appBundle),
            String(localized: "It also reads VO2 max, workouts and routes, active energy, steps, distances, flights climbed, exercise minutes, walking and running speed, physical effort, body weight, date of birth and biological sex.", bundle: LanguageManager.appBundle),
            String(localized: "It saves the workouts you record, with their energy, distance and route.", bundle: LanguageManager.appBundle),
            String(localized: "If you turn on Apple Health export, it also writes HRV (SDNN), heart rate, resting heart rate, and sleep detected from heart rate on nights Health has none.", bundle: LanguageManager.appBundle),
            String(localized: "Apple Health data is used only to run the app's features. It is never used for advertising or sold.", bundle: LanguageManager.appBundle),
            String(localized: "It reaches a third party only when you use a cloud AI provider you have agreed to, as described below.", bundle: LanguageManager.appBundle)
        ]
    )

    /// The biometric profile.
    private static let profileBlock = PolicyBlock(
        title: String(localized: "Profile", bundle: LanguageManager.appBundle),
        sentences: [
            String(localized: "Your age, sex, weight and heart-rate settings, typed in or filled from Apple Health, personalise your scores and zones.", bundle: LanguageManager.appBundle)
        ]
    )

    /// Every location use; matches the location purpose string.
    private static let locationBlock = PolicyBlock(
        title: String(localized: "Location", bundle: LanguageManager.appBundle),
        sentences: [
            String(localized: "Location is used to map outdoor workouts, record your trail in Get Me Back, find nearby trails, look up the weather, and answer the AI assistant's questions about where you are.", bundle: LanguageManager.appBundle),
            String(localized: "It is used only while one of these features is running.", bundle: LanguageManager.appBundle)
        ]
    )

    /// Microphone, speech recognition and Face ID.
    private static let voiceBlock = PolicyBlock(
        title: String(localized: "Microphone & Speech", bundle: LanguageManager.appBundle),
        sentences: [
            String(localized: "Voice questions to the AI assistant are transcribed on your device when your device and language support it, and by Apple's speech recognition service when they do not.", bundle: LanguageManager.appBundle),
            String(localized: "Face ID, if you use it, only confirms it's you before data is deleted; Emuqu never sees your face data.", bundle: LanguageManager.appBundle)
        ]
    )

    /// Where data lives by default.
    private static let onDeviceBlock = PolicyBlock(
        title: String(localized: "On-Device Storage", bundle: LanguageManager.appBundle),
        sentences: [
            String(localized: "Your data is stored in the app's private container on your device, and leaves it only through the features this policy describes.", bundle: LanguageManager.appBundle),
            String(localized: "Emuqu runs no server of its own.", bundle: LanguageManager.appBundle)
        ]
    )

    /// What goes to iCloud. Keep in step with `CloudKitSyncManager+Push` and
    /// `CloudKitSyncSupport`: both payloads are encrypted by `CloudPayloadCodec`.
    private static let iCloudBlock = PolicyBlock(
        title: String(localized: "iCloud Sync", bundle: LanguageManager.appBundle),
        sentences: [
            String(localized: "iCloud Sync is on unless you skip it during setup, and you can turn it off at any time in Settings → iCloud & Data.", bundle: LanguageManager.appBundle),
            String(localized: "It copies your recordings, their analysis and your settings to Apple's CloudKit private database in your own iCloud account.", bundle: LanguageManager.appBundle),
            String(localized: "Each is encrypted on your device before upload, with a key kept in your iCloud Keychain, so neither Apple nor the developer can read it.", bundle: LanguageManager.appBundle),
            String(localized: "Only the date and type of each recording, and the beat count, time and strap ID of an in-progress backup, stay readable, so the app can find and sync them.", bundle: LanguageManager.appBundle)
        ]
    )

    /// The no-selling statement.
    private static let noSellingBlock = PolicyBlock(
        title: String(localized: "No Selling, No Tracking", bundle: LanguageManager.appBundle),
        sentences: [
            String(localized: "Emuqu never sells your data, and contains no analytics SDKs, advertising frameworks, or tracking services.", bundle: LanguageManager.appBundle)
        ]
    )

    /// The cloud AI flow. Keep the data list in step with `ProviderConsentSheet`.
    private static let aiBlock = PolicyBlock(
        title: String(localized: "AI Assistant", bundle: LanguageManager.appBundle),
        sentences: [
            String(localized: "Apple Intelligence, the default, runs on your device.", bundle: LanguageManager.appBundle),
            String(localized: "If you add your own API key for a cloud provider (Anthropic, OpenAI, Google, xAI or DeepSeek), your messages go directly to that provider, with the data needed to answer them.", bundle: LanguageManager.appBundle),
            String(localized: "That can include heart rate, HRV, sleep, overnight vitals such as blood oxygen, training load and workouts, your profile, and your location during workouts.", bundle: LanguageManager.appBundle),
            String(localized: "It can also include facts saved to the assistant's memory, which may mention health conditions.", bundle: LanguageManager.appBundle),
            String(localized: "When the assistant looks up a contact or writes an email for you, it also includes the names, email addresses and notes of your saved email contacts and your default email recipients.", bundle: LanguageManager.appBundle),
            String(localized: "Before anything is sent, Emuqu shows you exactly what that provider will receive and asks for your permission.", bundle: LanguageManager.appBundle),
            String(localized: "You can withdraw it at any time in Settings → Flo → the provider → Withdraw consent, and removing the provider's key withdraws it too.", bundle: LanguageManager.appBundle),
            String(localized: "Data already sent is kept under that provider's own retention policy.", bundle: LanguageManager.appBundle),
            String(localized: "DeepSeek processes and stores data in the People's Republic of China.", bundle: LanguageManager.appBundle)
        ]
    )

    /// The non-AI services.
    private static let otherServicesBlock = PolicyBlock(
        title: String(localized: "Other Services", bundle: LanguageManager.appBundle),
        sentences: [
            String(localized: "If you add a Tavily key for web search, the search queries the assistant writes go to Tavily.", bundle: LanguageManager.appBundle),
            String(localized: "If you turn on web search while using Claude, Anthropic runs the searches itself, with the queries the assistant writes.", bundle: LanguageManager.appBundle),
            String(localized: "Weather during outdoor workouts, and past weather if you turn on heat tracking, is looked up with your location rounded to about 1 km, sent to Open-Meteo.", bundle: LanguageManager.appBundle),
            String(localized: "Trail discovery, addresses and elevation send your coordinates to OpenStreetMap-based services: Nominatim, Overpass and OpenTopoData.", bundle: LanguageManager.appBundle),
            String(localized: "None of these services receive anything that identifies you.", bundle: LanguageManager.appBundle)
        ]
    )

    /// The Guideline 5.1.1(i) third-party statement. The providers act under
    /// the user's own account and key, not as the developer's partners, so the
    /// honest statement is that relationship, not a promise of equal terms the
    /// developer has no contract to enforce.
    private static let thirdPartyBlock = PolicyBlock(
        title: String(localized: "How These Services Treat Your Data", bundle: LanguageManager.appBundle),
        sentences: [
            String(localized: "The developer has no agreement with any of these services and shares nothing with them.", bundle: LanguageManager.appBundle),
            String(localized: "Each receives data directly from your device, under your own account where one is needed, and handles it under its own privacy policy, which the consent screen links to.", bundle: LanguageManager.appBundle),
            String(localized: "Read it before you agree: its protections can differ from this policy's.", bundle: LanguageManager.appBundle)
        ]
    )

    /// Export, deletion, and what survives deleting the app.
    private static let controlBlock = PolicyBlock(
        title: String(localized: "Data Export & Deletion", bundle: LanguageManager.appBundle),
        sentences: [
            String(localized: "Export all of your data at any time from Settings → iCloud & Data → Export Data.", bundle: LanguageManager.appBundle),
            String(localized: "Delete single recordings in the app, or everything with Settings → Advanced Data Controls → Delete All My Data, which erases your data on this device and in iCloud and removes your API keys.", bundle: LanguageManager.appBundle),
            String(localized: "Deleting the app removes its data from this device. API keys stay in the device keychain until you delete them or use Delete All My Data.", bundle: LanguageManager.appBundle),
            String(localized: "iCloud copies stay until you use Delete All My Data or remove them in your iCloud settings.", bundle: LanguageManager.appBundle),
            String(localized: "A diagnostic log you export from Troubleshooting contains health readings such as HRV values and sleep times. It is sent only if you choose to share it.", bundle: LanguageManager.appBundle)
        ]
    )

    private var dataCollectionSection: some View {
        Section("Data Collection") {
            policyBlock(Self.heartRateBlock)
            policyBlock(Self.appleHealthBlock)
            policyBlock(Self.profileBlock)
            policyBlock(Self.locationBlock)
            policyBlock(Self.voiceBlock)
        }
    }

    private var dataStorageSection: some View {
        Section("Data Storage") {
            policyBlock(Self.onDeviceBlock)
            policyBlock(Self.iCloudBlock)
        }
    }

    private var dataSharingSection: some View {
        Section("Data Sharing") {
            policyBlock(Self.noSellingBlock)
            policyBlock(Self.aiBlock)
            policyBlock(Self.otherServicesBlock)
            policyBlock(Self.thirdPartyBlock)
        }
    }

    /// The privacy contact. Plain text when the `mailto:` does not parse, so a
    /// screen about the user's rights cannot be the one that crashes.
    @ViewBuilder
    private var contactLink: some View {
        if let mail = URL(string: "mailto:chrissharp80@gmail.com?subject=Emuqu%20Privacy") {
            Link("chrissharp80@gmail.com", destination: mail)
                .font(.subheadline)
        } else {
            Text(verbatim: "chrissharp80@gmail.com")
                .font(.subheadline)
        }
    }

    private func policyBlock(_ block: PolicyBlock) -> some View {
        titledBlock(title: block.title, body: block.sentences.joined(separator: " "))
    }

    /// A heading and its paragraph — the shape every block on this screen uses.
    private func titledBlock(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.textPrimary)
            Text(body)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    private var yourControlSection: some View {
        Section("Your Control") {
            policyBlock(Self.controlBlock)
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
                Text(Self.childrenSentences.joined(separator: " "))
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
    }

    private static let childrenSentences: [String] = [
        String(localized: "Emuqu is for users aged 13 and over — you confirm this when you accept the health disclaimer at first launch.", bundle: LanguageManager.appBundle),
        String(localized: "The app is not directed at children, and the developer does not knowingly collect personal data from anyone under 13.", bundle: LanguageManager.appBundle),
        String(localized: "Emuqu has no accounts and no server of its own, so the developer holds nothing to delete.", bundle: LanguageManager.appBundle),
        String(localized: "If a child has used the app on your device, Settings → Advanced Data Controls → Delete All My Data erases everything on the device and in iCloud.", bundle: LanguageManager.appBundle)
    ]

    private var sensorPermissionsSection: some View {
        Section("Sensor Permissions") {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Permissions", bundle: LanguageManager.appBundle))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text(String(localized: "Emuqu asks for Bluetooth, Apple Health, location, motion, microphone, speech recognition, notification and Face ID permission only when a feature needs it.", bundle: LanguageManager.appBundle)
                    + " " + String(localized: "You can revoke any of them at any time in your device's Settings.", bundle: LanguageManager.appBundle))
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

        contactLink

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
            version: "8.3.0",
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
