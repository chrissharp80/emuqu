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
    /// system and no analytics, and `check_no_developer_endpoint.sh` fails the
    /// build if the app ever gains a developer endpoint. The developer gets
    /// only what the user emails: a support request (Settings), a reported AI
    /// reply (`ChatBubble`) or a diagnostic log the user shares.
    private var noCollectionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "The developer receives nothing unless you send it", bundle: LanguageManager.appBundle))
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

    /// The sentences of the no-collection statement, as data.
    ///
    /// Split at sentence boundaries rather than written as one paragraph so no
    /// single localized literal exceeds the line-length limit — the strings
    /// themselves are the localization keys, so wrapping them in source would
    /// change what Xcode extracts and orphan sixteen translations apiece.
    private static var noCollectionParagraphs: [String] {
        [
            String(localized: "Emuqu has no server, no account, and no login. The app never sends your data to the developer — not your heart rate, not your sleep, not your location, not your chats.", bundle: LanguageManager.appBundle),
            String(localized: "There is nowhere for it to go: the app contains no analytics, tracking, or crash-reporting service of any kind, and this is checked automatically before every release.", bundle: LanguageManager.appBundle),
            String(localized: "The developer receives only what you choose to email: a support request, an AI reply you report, or a diagnostic log you share.", bundle: LanguageManager.appBundle),
            String(localized: "Those emails are used only to answer you, and are deleted once your issue is resolved, and within 12 months at the latest.", bundle: LanguageManager.appBundle),
            String(localized: "Some features do send data to services outside the app. Each one is described below: what it sends, where, and when.", bundle: LanguageManager.appBundle),
            String(localized: "In each case the data goes straight from your device to that service, never through the developer.", bundle: LanguageManager.appBundle)
        ]
    }

    /// A heading and the sentences under it. Each sentence is its own
    /// localized string so no literal outgrows the line-length limit, and so
    /// correcting one claim re-translates one sentence rather than a page.
    struct PolicyBlock {
        let title: String
        let sentences: [String]
    }

    /// What the strap and Watch record.
    private static var heartRateBlock: PolicyBlock {
        PolicyBlock(
            title: String(localized: "Heart Rate & HRV Data", bundle: LanguageManager.appBundle),
            sentences: [
                String(localized: "Emuqu records heart rate and beat-to-beat (RR) intervals from the Polar H10 or Polar Verity Sense you connect over Bluetooth, and wrist heart rate from your Apple Watch during workouts.", bundle: LanguageManager.appBundle),
                String(localized: "These are used to calculate HRV metrics, recovery scores, training load and sleep analysis.", bundle: LanguageManager.appBundle)
            ]
        )
    }

    /// Every HealthKit type read and written, as Guideline 5.1.3(i) asks. Keep
    /// this in step with `HealthKitManager.readTypes` / `writeTypes` and the
    /// Health purpose strings in Info.plist.
    private static var appleHealthBlock: PolicyBlock {
        PolicyBlock(
            title: String(localized: "Apple Health", bundle: LanguageManager.appBundle),
            sentences: [
                String(localized: "With your permission, Emuqu reads sleep, heart rate, resting heart rate, HRV, respiratory rate, blood oxygen and sleeping wrist temperature from Apple Health.", bundle: LanguageManager.appBundle),
                String(localized: "It also reads VO2 max, heart rate recovery, workouts and routes, active energy, steps, flights climbed and exercise minutes.", bundle: LanguageManager.appBundle),
                String(localized: "It reads walking, running, cycling and rowing distance, walking and running speed, physical effort, body weight, date of birth and biological sex.", bundle: LanguageManager.appBundle),
                String(localized: "It saves the workouts you record, with their energy, distance and route.", bundle: LanguageManager.appBundle),
                String(localized: "If you turn on Apple Health export, it also writes HRV (SDNN), heart rate, resting heart rate, and sleep detected from heart rate on nights Health has none.", bundle: LanguageManager.appBundle),
                String(localized: "Apple Health data is used only to run the app's features. It is never used for advertising or sold.", bundle: LanguageManager.appBundle),
                String(localized: "It reaches a third party only through a feature described below: a cloud AI provider you have agreed to, or a lookup that sends a route.", bundle: LanguageManager.appBundle),
                String(localized: "Routes of workouts imported from Apple Health go to OpenTopoData when you look up their elevation, and to Overpass when the assistant loads one you saved.", bundle: LanguageManager.appBundle)
            ]
        )
    }

    /// The biometric profile.
    private static var profileBlock: PolicyBlock {
        PolicyBlock(
            title: String(localized: "Profile", bundle: LanguageManager.appBundle),
            sentences: [
                String(localized: "Your age, sex, weight and heart-rate settings, typed in or filled from Apple Health, personalise your scores and zones.", bundle: LanguageManager.appBundle),
                String(localized: "If you add them, a profile photo, the email contacts you save for the assistant and your default email recipients are kept with the rest of your data.", bundle: LanguageManager.appBundle)
            ]
        )
    }

    /// Every location use; matches the location purpose string.
    private static var locationBlock: PolicyBlock {
        PolicyBlock(
            title: String(localized: "Location", bundle: LanguageManager.appBundle),
            sentences: [
                String(
                    localized: "Location is used to map outdoor workouts, record your trail in Get Me Back, find nearby trails, look up the weather, keep nearby street names ready for workout updates, and answer the AI assistant's questions about where you are.",
                    bundle: LanguageManager.appBundle
                ),
                String(localized: "It is used only while the app is open or one of these features is running.", bundle: LanguageManager.appBundle)
            ]
        )
    }

    /// Microphone and speech recognition.
    private static var voiceBlock: PolicyBlock {
        PolicyBlock(
            title: String(localized: "Microphone & Speech", bundle: LanguageManager.appBundle),
            sentences: [
                String(localized: "Voice questions to the AI assistant are transcribed on your device when your device and language support it, and by Apple's speech recognition service when they do not.", bundle: LanguageManager.appBundle)
            ]
        )
    }

    /// Where data lives by default.
    private static var onDeviceBlock: PolicyBlock {
        PolicyBlock(
            title: String(localized: "On-Device Storage", bundle: LanguageManager.appBundle),
            sentences: [
                String(localized: "Your data is stored in the app's private container on your device, and leaves it only through the features this policy describes.", bundle: LanguageManager.appBundle),
                String(localized: "Emuqu runs no server of its own.", bundle: LanguageManager.appBundle),
                String(localized: "It stays on your device until you delete it in the app or delete the app.", bundle: LanguageManager.appBundle),
                String(localized: "A backup of your device made by iOS, such as iCloud Backup, can include it.", bundle: LanguageManager.appBundle)
            ]
        )
    }

    /// What goes to iCloud. Keep in step with `UserSettings.iCloudSyncEnabled`
    /// (off by default), `CloudKitSyncManager+Push` and `CloudKitSyncSupport`:
    /// both payloads are encrypted by `CloudPayloadCodec`, and every reading
    /// taken from Apple Health is left out of them (`CloudSessionPayload`);
    /// the scores computed from those readings travel.
    private static var iCloudBlock: PolicyBlock {
        PolicyBlock(
            title: String(localized: "iCloud Sync", bundle: LanguageManager.appBundle),
            sentences: [
                String(localized: "iCloud Sync is optional and off until you turn it on, during setup or in Settings → iCloud & Data, where you can also turn it off at any time.", bundle: LanguageManager.appBundle),
                String(localized: "It copies your recordings, their analysis and your settings to Apple's CloudKit private database in your own iCloud account.", bundle: LanguageManager.appBundle),
                String(localized: "Each is encrypted on your device before upload, with a key kept in your iCloud Keychain, so neither Apple nor the developer can read it.", bundle: LanguageManager.appBundle),
                String(localized: "Only the date of each recording, and the start time of a backup of a recording still in progress, stay readable, so the app can find and sync them.", bundle: LanguageManager.appBundle),
                String(localized: "Readings from Apple Health are never uploaded; scores Emuqu computes from them are, encrypted on your iPhone first.", bundle: LanguageManager.appBundle),
                String(localized: "Those readings are sleep, vitals, VO2 max, workouts from Apple Health, Apple Watch heart rate, and a birthday, sex or weight filled from Apple Health.", bundle: LanguageManager.appBundle),
                String(localized: "Each device reads them from Apple Health itself.", bundle: LanguageManager.appBundle)
            ]
        )
    }

    /// The no-selling statement.
    private static var noSellingBlock: PolicyBlock {
        PolicyBlock(
            title: String(localized: "No Selling, No Tracking", bundle: LanguageManager.appBundle),
            sentences: [
                String(localized: "Emuqu never sells your data, and contains no analytics SDKs, advertising frameworks, or tracking services.", bundle: LanguageManager.appBundle)
            ]
        )
    }

    /// The cloud AI flow. Keep the data list in step with `ProviderConsentSheet`.
    private static var aiBlock: PolicyBlock {
        PolicyBlock(
            title: String(localized: "AI Assistant", bundle: LanguageManager.appBundle),
            sentences: [
                String(localized: "Apple Intelligence, the default, runs on your device.", bundle: LanguageManager.appBundle),
                String(localized: "If you add your own API key for a cloud provider (Anthropic, OpenAI, Google, xAI or DeepSeek), your messages go directly to that provider, with the data needed to answer them.", bundle: LanguageManager.appBundle),
                String(localized: "That can include heart rate, HRV, sleep, overnight vitals such as blood oxygen, training load and workouts, today's steps and distance, your profile, your location during workouts, while a Get Me Back trail runs or when you ask for directions, the start points of your recent trails and GPS workouts, and your saved home address when you ask to be led home.", bundle: LanguageManager.appBundle),
                String(localized: "It can also include your notes, tags and morning check-ins, which may mention symptoms or mood, and the facts, notes and to-dos saved to the assistant's memory, which may mention health conditions.", bundle: LanguageManager.appBundle),
                String(localized: "When the assistant looks up a contact or writes an email for you, it also includes the names, email addresses and notes of your saved email contacts and your default email recipients.", bundle: LanguageManager.appBundle),
                String(localized: "Before anything is sent, Emuqu shows you exactly what that provider will receive and asks for your permission.", bundle: LanguageManager.appBundle),
                String(localized: "You can withdraw it at any time in Settings → Flo → the provider → Withdraw consent, and removing the provider's key withdraws it too.", bundle: LanguageManager.appBundle),
                String(localized: "Data already sent is kept under that provider's own retention policy.", bundle: LanguageManager.appBundle),
                String(localized: "Anthropic, OpenAI and xAI say they do not use what you send through their APIs to train their models, unless you have opted in to that in your account with them.", bundle: LanguageManager.appBundle),
                String(localized: "Google does not use what you send with a paid Gemini API key to improve its products. With a free key, Google may use it, including health data, to improve its products and AI, and people may review it.", bundle: LanguageManager.appBundle),
                String(localized: "DeepSeek says it may use what you send to train and improve its models; its privacy policy says you can opt out by emailing privacy@deepseek.com.", bundle: LanguageManager.appBundle),
                String(localized: "DeepSeek processes and stores data in the People's Republic of China.", bundle: LanguageManager.appBundle)
            ]
        )
    }

    /// The non-AI services.
    private static var otherServicesBlock: PolicyBlock {
        PolicyBlock(
            title: String(localized: "Other Services", bundle: LanguageManager.appBundle),
            sentences: [
                String(localized: "If you add a Tavily key for web search, the search queries the assistant writes go to Tavily.", bundle: LanguageManager.appBundle),
                String(localized: "Tavily may use parts of those queries to improve its search results.", bundle: LanguageManager.appBundle),
                String(localized: "If you turn on web search while using Claude, Anthropic runs the searches itself, with the queries the assistant writes.", bundle: LanguageManager.appBundle),
                String(localized: "Weather during outdoor workouts is looked up with your location rounded to about 1 km, sent to MET Norway (the Norwegian Meteorological Institute), whose weather data the app uses under the CC BY 4.0 licence.", bundle: LanguageManager.appBundle),
                String(localized: "Heat tracking uses only the weather saved with your workouts and sends nothing.", bundle: LanguageManager.appBundle),
                String(localized: "Overpass, an OpenStreetMap service, receives approximate coordinates: for trail discovery, the centre of the search, rounded to about 100 m.", bundle: LanguageManager.appBundle),
                String(localized: "For nearby roads it receives the centre of the 250 m square you are in during an outdoor workout, or of each turn of a saved route the assistant loads for you.", bundle: LanguageManager.appBundle),
                String(localized: "Overpass is asked at overpass.private.coffee, or at overpass-api.de when that one does not answer. Addresses are looked up with Apple's geocoder.", bundle: LanguageManager.appBundle),
                String(localized: "When you look up real elevation for a workout, including one imported from Apple Health, up to 100 of its route's points, rounded to about 11 m, are sent to OpenTopoData.", bundle: LanguageManager.appBundle),
                String(localized: "If you choose WhisperKit for voice input, its speech model is downloaded once from Hugging Face (huggingface.co). Your voice is still transcribed on your device.", bundle: LanguageManager.appBundle),
                String(localized: "Tavily and Anthropic searches run under your own key or account. The weather, map, elevation and model-download services get no account or name, though like any web request they see your device's IP address.", bundle: LanguageManager.appBundle)
            ]
        )
    }

    /// The Guideline 5.1.1(i) third-party statement. It names each service,
    /// says data reaches it only when the user uses its feature (and, for AI
    /// and search, only after the user adds a key and agrees), and that each
    /// handles it under its own terms, linked by `servicePolicies`. It says
    /// which services publish a privacy policy and which (overpass-api.de,
    /// OpenTopoData) publish none and so receive only approximate coordinates,
    /// without promising terms the developer does not set.
    private static var thirdPartyBlock: PolicyBlock {
        PolicyBlock(
            title: String(localized: "How These Services Treat Your Data", bundle: LanguageManager.appBundle),
            sentences: [
                String(localized: "These services are Anthropic, OpenAI, Google, xAI and DeepSeek for the AI assistant, Tavily for web search, and Apple for speech recognition and address lookup.", bundle: LanguageManager.appBundle),
                String(localized: "They also include MET Norway for weather, Overpass for trails and nearby roads, OpenTopoData for elevation, and Hugging Face for the speech model download.", bundle: LanguageManager.appBundle),
                String(localized: "Data reaches these services only when you use a feature that needs them.", bundle: LanguageManager.appBundle),
                String(localized: "A cloud AI provider receives nothing until you add your own key and agree to what it will receive, and Tavily nothing until you add your own Tavily key.", bundle: LanguageManager.appBundle),
                String(localized: "Each service receives the data directly from your device and handles it under its own privacy policy and terms, which you should review before you use it. They are linked below.", bundle: LanguageManager.appBundle),
                String(localized: "The AI and search services, Apple, MET Norway, Hugging Face and the Overpass server at overpass.private.coffee publish privacy policies. The developer does not set or enforce them.", bundle: LanguageManager.appBundle),
                String(localized: "The Overpass server at overpass-api.de and OpenTopoData publish no privacy policy, so their service pages are linked. They receive only approximate coordinates, with no account, name or identifier.", bundle: LanguageManager.appBundle),
                String(localized: "The developer shares no data with these services.", bundle: LanguageManager.appBundle)
            ]
        )
    }

    /// A service the app can send data to, and the page that says how it
    /// handles it. The Overpass server at overpass-api.de and OpenTopoData
    /// publish no privacy policy, so their service pages are linked.
    struct ServicePolicy: Identifiable {
        let name: String
        let url: URL
        var id: String { name }
    }

    /// Apple and the AI providers come from `ProviderID`, the same links the
    /// consent screen shows; the rest are the services in "Other Services".
    static var servicePolicies: [ServicePolicy] {
        let providers = ProviderID.allCases.compactMap { provider in
            provider.privacyPolicyURL.map { ServicePolicy(name: provider.vendorName, url: $0) }
        }
        let others = [
            ("Tavily", "https://tavily.com/privacy"),
            ("MET Norway", "https://www.met.no/en/About-us/privacy"),
            ("Overpass (overpass-api.de)", "https://overpass-api.de/"),
            ("Overpass (overpass.private.coffee)", "https://private.coffee/privacy"),
            ("OpenTopoData", "https://www.opentopodata.org/"),
            ("Hugging Face", "https://huggingface.co/privacy")
        ].compactMap { name, link in URL(string: link).map { ServicePolicy(name: name, url: $0) } }
        return providers + others
    }

    private var servicePolicyLinks: some View {
        ForEach(Self.servicePolicies) { service in
            Link(destination: service.url) {
                Text(verbatim: service.name)
                    .font(.subheadline)
                    .foregroundColor(AppTheme.sageText)
            }
        }
    }

    /// Export, deletion, and what survives deleting the app.
    private static var controlBlock: PolicyBlock {
        PolicyBlock(
            title: String(localized: "Data Export & Deletion", bundle: LanguageManager.appBundle),
            sentences: [
                String(localized: "Export all of your data at any time from Settings → iCloud & Data → Export Data.", bundle: LanguageManager.appBundle),
                String(localized: "Delete single recordings in the app, or everything with Settings → Advanced Data Controls → Delete All My Data, which erases your data on this device and in iCloud and removes your API keys.", bundle: LanguageManager.appBundle),
                String(localized: "Delete All My Data asks you to type a confirmation phrase and confirm once more before it erases anything.", bundle: LanguageManager.appBundle),
                String(localized: "Deleting the app removes its data from this device, but not what Emuqu keeps in the iOS keychain, which iOS keeps after an app is deleted.", bundle: LanguageManager.appBundle),
                String(localized: "That is your API keys, the keys that encrypt your recordings and your iCloud copies, and a record of your free trial and of any beta access.", bundle: LanguageManager.appBundle),
                String(localized: "To remove the API keys, use Delete All My Data before you delete the app. The other items hold none of your health data; the trial record stays so that reinstalling continues the same trial.", bundle: LanguageManager.appBundle),
                String(localized: "iCloud copies stay until you use Delete All My Data or remove them in your iCloud settings.", bundle: LanguageManager.appBundle),
                String(localized: "A diagnostic log you export from Troubleshooting has health values and GPS coordinates removed, but can contain parts of what you said to the assistant by voice and the names of nearby streets.", bundle: LanguageManager.appBundle),
                String(localized: "It is sent only if you choose to share it.", bundle: LanguageManager.appBundle)
            ]
        )
    }

    private var dataCollectionSection: some View {
        Section(String(localized: "Data Collection", bundle: LanguageManager.appBundle)) {
            policyBlock(Self.heartRateBlock)
            policyBlock(Self.appleHealthBlock)
            policyBlock(Self.profileBlock)
            policyBlock(Self.locationBlock)
            policyBlock(Self.voiceBlock)
        }
    }

    private var dataStorageSection: some View {
        Section(String(localized: "Data Storage", bundle: LanguageManager.appBundle)) {
            policyBlock(Self.onDeviceBlock)
            policyBlock(Self.iCloudBlock)
        }
    }

    private var dataSharingSection: some View {
        Section(String(localized: "Data Sharing", bundle: LanguageManager.appBundle)) {
            policyBlock(Self.noSellingBlock)
            policyBlock(Self.aiBlock)
            policyBlock(Self.otherServicesBlock)
            policyBlock(Self.thirdPartyBlock)
            servicePolicyLinks
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
        Section(String(localized: "Your Control", bundle: LanguageManager.appBundle)) {
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
        Section(String(localized: "Children's Privacy", bundle: LanguageManager.appBundle)) {
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

    private static var childrenSentences: [String] {
        [
            String(localized: "Emuqu is for users aged 13 and over — you confirm this when you accept the health disclaimer at first launch.", bundle: LanguageManager.appBundle),
            String(localized: "The app is not directed at children, and the developer does not knowingly collect personal data from anyone under 13.", bundle: LanguageManager.appBundle),
            String(localized: "Emuqu has no accounts and no server of its own, so the developer holds no app data, only any emails sent to them, which are deleted on request.", bundle: LanguageManager.appBundle),
            String(localized: "If a child has used the app on your device, Settings → Advanced Data Controls → Delete All My Data erases everything on the device and in iCloud.", bundle: LanguageManager.appBundle)
        ]
    }

    private var sensorPermissionsSection: some View {
        Section(String(localized: "Sensor Permissions", bundle: LanguageManager.appBundle)) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Permissions", bundle: LanguageManager.appBundle))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.textPrimary)
                Text(String(localized: "Emuqu asks for Bluetooth, Apple Health, location, motion, microphone, speech recognition, notification and add-only photo library permission only when a feature needs it.", bundle: LanguageManager.appBundle)
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

/// In-app open-source license screen: every resolved package, the full
/// license and NOTICE texts (`OpenSourceLicenseTexts`), and the data sources
/// and models the app uses. The package list is hand-maintained and
/// `check_sbom_drift.sh` compares it with `Package.resolved`.
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
    // includes the transitive pins (WhisperKit + the HuggingFace/Apple
    // libraries it pulls in), not just the direct deps. Versions match
    // `Package.resolved` — bump them when bumping the resolved file.
    private let packages: [Pkg] = [
        Pkg(
            name: "polar-ble-sdk",
            version: "8.3.0",
            license: "Polar SDK License · © Polar Electro Oy",
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
            licenseTextsSection
            dataSourcesSection
            sbomSection
        }
        .zenFormBackground()
        .navigationTitle(String(localized: "Open Source Licenses", bundle: LanguageManager.appBundle))
    }

    private var licenseIntroSection: some View {
        Section {
            Text("Emuqu uses the following open-source libraries. Their full license texts and notices are under License texts, and each link opens the project's source repository.", bundle: LanguageManager.appBundle)
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
            Text("Direct + transitive dependencies", bundle: LanguageManager.appBundle)
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
            Text("License: \(pkg.license)", bundle: LanguageManager.appBundle)
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
                    .foregroundColor(AppTheme.sageText)
            }
        }
    }

    private var licenseTextsSection: some View {
        Section {
            ForEach(OpenSourceLicenseTexts.documents) { document in
                licenseTextRow(document)
            }
        } header: {
            Text("License texts", bundle: LanguageManager.appBundle)
        }
    }

    private func licenseTextRow(_ document: OpenSourceLicenseTexts.Document) -> some View {
        NavigationLink {
            LicenseTextView(document: document)
        } label: {
            Text(verbatim: document.title)
        }
    }

    /// A credited data source or model: what it provides, and the page with
    /// its license or attribution terms.
    private struct DataSource: Identifiable {
        let credit: String
        let url: String
        var id: String { url }
    }

    /// OpenStreetMap's ODbL asks for "© OpenStreetMap contributors" with a
    /// link to its copyright page; MET Norway's CC BY 4.0 asks for a link to
    /// the license; the elevation datasets are public domain and credited as
    /// a courtesy; the Whisper model is MIT (text under License texts).
    private var dataSources: [DataSource] {
        let b = LanguageManager.appBundle
        return [
            DataSource(
                credit: String(localized: "Trail and road data © OpenStreetMap contributors, available under the Open Database License (ODbL).", bundle: b),
                url: "https://www.openstreetmap.org/copyright"
            ),
            DataSource(
                credit: String(localized: "Weather data: MET Norway (CC BY 4.0)", bundle: b),
                url: "https://creativecommons.org/licenses/by/4.0/"
            ),
            DataSource(
                credit: String(localized: "Elevation: OpenTopoData, using USGS NED and NASA SRTM elevation data (public domain).", bundle: b),
                url: "https://www.opentopodata.org/"
            ),
            DataSource(
                credit: String(localized: "Speech model, when you choose WhisperKit: OpenAI Whisper base.en (MIT License), converted to Core ML by Argmax.", bundle: b),
                url: "https://github.com/openai/whisper"
            )
        ]
    }

    private var dataSourcesSection: some View {
        Section {
            ForEach(dataSources) { source in
                dataSourceRow(source)
            }
        } header: {
            Text("Data sources", bundle: LanguageManager.appBundle)
        }
    }

    private func dataSourceRow(_ source: DataSource) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(source.credit)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
            dataSourceLink(source.url)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func dataSourceLink(_ link: String) -> some View {
        if let url = URL(string: link) {
            Link(destination: url) {
                Text(verbatim: link)
                    .font(.caption)
                    .foregroundColor(AppTheme.sageText)
            }
        }
    }

    private var sbomSection: some View {
        Section {
            Text("Apple frameworks (Apple Health, CoreBluetooth, AVFoundation, Speech, MapKit, Core Location, CoreMotion, CryptoKit, Combine, SwiftUI, WatchConnectivity, BackgroundTasks, StoreKit) are governed by their Apple SDK licenses included with Xcode.", bundle: LanguageManager.appBundle)
                .font(.footnote)
                .foregroundColor(AppTheme.textSecondary)
        } header: {
            Text("Apple system frameworks", bundle: LanguageManager.appBundle)
        }
    }
}

#Preview {
    NavigationStack {
        AcknowledgementsView()
    }
}
