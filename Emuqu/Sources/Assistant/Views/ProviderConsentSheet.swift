//
//  ProviderConsentSheet.swift
//  Emuqu
//
//  Per-provider data-sharing consent. Shown the first time the user
//  sends a message to a particular hosted AI provider (Claude, ChatGPT,
//  Gemini, Grok, DeepSeek). Apple Intelligence is on-device and never
//  presents this sheet.
//
//  Distinct from the generic first-
//  launch HealthDisclaimer because the user can add or change providers
//  weeks after onboarding; the disclosure must follow the act of sending
//  data, not the act of installing the app.
//

import SwiftUI

struct ProviderConsentSheet: View {
    /// Materials go opaque when the user asks for reduced transparency —
    /// iOS does not substitute for you. See `AdaptiveMaterial`.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let provider: ProviderID
    let onAccept: () -> Void
    let onDecline: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// One-line data-residency note for
    /// providers whose API + storage sit under a jurisdiction the user
    /// should be told about up front. nil for providers with no special
    /// note (the default US/EU vendors covered by their linked policy).
    private var residencyNote: String? {
        switch provider {
        case .deepseek:
            return String(localized: "DeepSeek's API and stored data are hosted in the People's Republic of China. Your messages — including any health and location data — may be processed and retained under PRC law. If that matters to you, use a different provider or Apple Intelligence.", bundle: LanguageManager.appBundle)
        default:
            return nil
        }
    }

    var body: some View {
        NavigationStack {
            consentScroll
        }
    }

    private var consentScroll: some View {
        ScrollView {
            consentBody
        }
        .navigationTitle(String(localized: "Share data with \(provider.displayName)?", bundle: LanguageManager.appBundle))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { consentActionBar }
        .interactiveDismissDisabled()
    }

    private var consentActionBar: some View {
        VStack(spacing: 10) {
            Button {
                onAccept()
                dismiss()
            } label: {
                Text(String(localized: "Send and remember for \(provider.displayName)", bundle: LanguageManager.appBundle))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            dontSendButton
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .background(AdaptiveMaterial.ultraThin(reduceTransparency))
    }
    private var consentBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            consentHeader
            whatTheyWillSeeSection
            howItLeavesSection
            dataUseSection
            dataResidencyNote
            whatWeDontShareSection
            privacyPolicyLink
        }
        .padding(20)
    }

    private var consentHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: provider.symbolName)
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "First send to \(provider.displayName)", bundle: LanguageManager.appBundle))
                    .font(.headline)
                Text(String(localized: "Vendor: \(provider.vendorName)", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var whatTheyWillSeeSection: some View {
        Text(String(localized: "What \(provider.displayName) will see", bundle: LanguageManager.appBundle))
            .font(.subheadline.bold())

        bulletList([
            String(localized: "Your HRV readings, heart rate, and resting heart rate", bundle: LanguageManager.appBundle),
            String(localized: "Your sleep totals + per-stage breakdown when computed", bundle: LanguageManager.appBundle),
            String(localized: "Your training load (ATL / CTL / TSB) + recent workouts", bundle: LanguageManager.appBundle),
            String(localized: "Today's steps, walking and running distance, and flights climbed from Apple Health", bundle: LanguageManager.appBundle),
            String(localized: "Your overnight vitals: blood oxygen, respiratory rate, and wrist temperature", bundle: LanguageManager.appBundle),
            String(localized: "Your profile: age, sex, weight, VO2 max, and heart-rate zones", bundle: LanguageManager.appBundle),
            String(localized: "Your route, current GPS and saved-route names during a workout, including the coach's spoken updates; your Get Me Back trail while it runs; the start points of your recent trails and GPS workouts; and your position when you ask for directions", bundle: LanguageManager.appBundle),
            String(localized: "Your saved home address and its coordinates, when you ask to be led home", bundle: LanguageManager.appBundle),
            String(localized: "Live weather + reverse-geocoded street name during a workout", bundle: LanguageManager.appBundle),
            String(localized: "Facts, notes and to-dos you or the assistant saved to its memory, which can include health conditions", bundle: LanguageManager.appBundle),
            String(localized: "Your notes, tags and morning check-ins on your recordings, which can mention symptoms or mood", bundle: LanguageManager.appBundle),
            String(localized: "The names, email addresses and notes of your saved email contacts, and your default email recipients, when the assistant looks up a contact or writes an email", bundle: LanguageManager.appBundle),
            String(localized: "The full text of every message you send", bundle: LanguageManager.appBundle)
        ])
    }

    @ViewBuilder
    private var howItLeavesSection: some View {
        Text(String(localized: "How it leaves your device", bundle: LanguageManager.appBundle))
            .font(.subheadline.bold())

        howItLeavesBullets
    }

    private var howItLeavesBullets: some View {
        bulletList([
            String(localized: "Sent over HTTPS directly to \(provider.vendorName)'s API. No Emuqu server in between.", bundle: LanguageManager.appBundle),
            String(localized: "Your API key (stored on-device in Keychain) authenticates the request.", bundle: LanguageManager.appBundle)
        ] + serverSearchBullets + [
            // Without this line Tavily is an
            // undisclosed third party while the sheet claims
            // "Nothing about you is sent anywhere we don't
            // show on this screen."
            String(localized: "If you've turned on web search and the assistant looks something up, the search query — which may reference what you asked — is sent to Tavily (tavily.com) to fetch results. Tavily may use queries to improve its search results.", bundle: LanguageManager.appBundle),
            Self.locationServicesBullet,
            String(localized: "Weather data: MET Norway (CC BY 4.0)", bundle: LanguageManager.appBundle),
            String(localized: "Subject to \(provider.vendorName)'s privacy policy — open it below.", bundle: LanguageManager.appBundle),
            String(localized: "Conversation history is stored on your device and Emuqu doesn't sync it to iCloud; a backup of your device can include it.", bundle: LanguageManager.appBundle)
        ])
    }

    /// Location-aware features call free, no-account geo services with the
    /// user's coordinates, truncated (~110 m) before they leave the device for
    /// reverse geocoding. The sheet says "the only places your data goes are
    /// the ones named on this screen", so every host is named, including both
    /// Overpass instances (`OverpassClient.endpoints`), which have different
    /// operators.
    static var locationServicesBullet: String {
        String(localized: "Location-aware features send your (approximate) coordinates to a few free services — Overpass (OpenStreetMap: nearby roads and trails, at overpass.private.coffee or overpass-api.de), MET Norway (weather during outdoor workouts) and OpenTopoData (elevation). Street names come from Apple's geocoder. No account, no Emuqu server; subject to each service's policy.", bundle: LanguageManager.appBundle)
    }

    /// Claude is the one provider that searches the web on its own side, with
    /// Anthropic's server tool, so its sheet names that route as well.
    private var serverSearchBullets: [String] {
        guard provider == .anthropic else { return [] }
        return [String(localized: "If you've turned on web search, Claude can also search the web itself: Anthropic receives the search query and runs the search.", bundle: LanguageManager.appBundle)]
    }

    @ViewBuilder
    private var dataUseSection: some View {
        let notes = Self.dataUseNotes(for: provider)
        if !notes.isEmpty {
            Text(String(localized: "How \(provider.vendorName) may use it", bundle: LanguageManager.appBundle))
                .font(.subheadline.bold())
            bulletList(notes)
        }
    }

    /// What each vendor's current API terms say about training or improving
    /// models on what it receives, how long it keeps it and whether people may
    /// review it. Sources:
    /// - Anthropic: Commercial Terms ("may not train models on Customer
    ///   Content from Services"); API data deleted within 30 days, flagged
    ///   content kept up to 2 years (privacy.claude.com).
    /// - OpenAI: API data not used for training unless opted in; abuse
    ///   monitoring logs kept up to 30 days, flagged content may be reviewed
    ///   (developers.openai.com "Your data").
    /// - Google: Gemini API Additional Terms. Unpaid Services: content used to
    ///   improve Google products and machine learning, human reviewers may
    ///   read it, do not submit sensitive or personal information. Paid
    ///   Services (a Cloud project with active billing): not used to improve
    ///   products, logged for a limited time for abuse detection.
    /// - xAI: no training on API data without permission; stored 30 days for
    ///   abuse audits (docs.x.ai security FAQ).
    /// - DeepSeek: privacy policy lists user input among the data used to
    ///   train its models, with an opt-out at privacy@deepseek.com; it does not
    ///   address human review.
    static func dataUseNotes(for provider: ProviderID) -> [String] {
        switch provider {
        case .apple: []
        case .anthropic: [anthropicDataUse]
        case .openai: [openAIDataUse]
        case .gemini: geminiDataUseNotes
        case .grok: [xAIDataUse]
        case .deepseek: [deepSeekDataUse]
        }
    }

    private static var anthropicDataUse: String {
        String(localized: """
            Anthropic's terms for API keys say it does not train its models on what you send. It deletes it within 30 \
            days, except content its systems flag as breaking its usage policy, which it can keep for up to 2 years for \
            safety review.
            """, bundle: LanguageManager.appBundle)
    }

    private static var openAIDataUse: String {
        String(localized: """
            OpenAI does not use what you send through its API to train its models unless you opt in. It keeps it for up to \
            30 days to check for abuse, and its staff may review content its systems flag.
            """, bundle: LanguageManager.appBundle)
    }

    private static var xAIDataUse: String {
        String(localized: """
            xAI does not train on what you send through its API without your permission. It stores it for 30 days so it \
            can be checked if abuse is suspected, then deletes it.
            """, bundle: LanguageManager.appBundle)
    }

    private static var deepSeekDataUse: String {
        String(localized: """
            DeepSeek's privacy policy says it uses what you send to train and improve its models. You can opt out by \
            emailing privacy@deepseek.com. The policy does not say whether people review it.
            """, bundle: LanguageManager.appBundle)
    }

    /// Google's terms differ by whether the key's Cloud project has billing
    /// on, which the app cannot see, so both cases are stated.
    private static var geminiDataUseNotes: [String] {
        [
            String(localized: """
                With a free Gemini key, Google uses what you send, including your health data, to improve its products and AI \
                models, and human reviewers may read it. Google asks that personal or sensitive information not be sent this \
                way.
                """, bundle: LanguageManager.appBundle),
            String(localized: """
                With a key from a Google Cloud project that has billing turned on, Google does not use what you send to \
                improve its products and keeps it only for a limited time to detect misuse. Use a paid key if you choose \
                Gemini.
                """, bundle: LanguageManager.appBundle)
        ]
    }

    /// Data-residency note
    /// for PRC-hosted providers. DeepSeek's API and stored
    /// data are in the People's Republic of China, so the
    /// user's health + location data may be processed under
    /// PRC jurisdiction. Surface that explicitly rather than
    /// burying it in DeepSeek's policy link.
    @ViewBuilder
    private var dataResidencyNote: some View {
        if let residencyNote {
            Text(String(localized: "Where your data is processed", bundle: LanguageManager.appBundle))
                .font(.subheadline.bold())
            bulletList([residencyNote])
        }
    }

    @ViewBuilder
    private var whatWeDontShareSection: some View {
        Text(String(localized: "What we don't share", bundle: LanguageManager.appBundle))
            .font(.subheadline.bold())

        bulletList([
            String(localized: "Apple Intelligence is on-device. If you'd rather not share with \(provider.vendorName), switch to Apple Intelligence in Settings.", bundle: LanguageManager.appBundle),
            // Softer than the
            // absolute "nothing is sent anywhere we don't show"
            // — the geo backends + Tavily are disclosed
            // above, so the honest claim is "no analytics, and
            // the only third parties are the ones listed here."
            String(localized: "Emuqu has no analytics SDK and no ad tracking. The only places your data goes are the ones named on this screen.", bundle: LanguageManager.appBundle)
        ])
    }

    @ViewBuilder
    private var privacyPolicyLink: some View {
        if let url = provider.privacyPolicyURL {
            Link(destination: url) { privacyPolicyLabel }
        }
    }

    private var privacyPolicyLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.right.square")
            Text(String(localized: "\(provider.vendorName) privacy policy", bundle: LanguageManager.appBundle))
        }
        .font(.subheadline)
    }

    private var dontSendButton: some View {
        Button {
            onDecline()
            dismiss()
        } label: {
            Text(String(localized: "Don't send", bundle: LanguageManager.appBundle))
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { bulletRow($0) }
        }
    }

    private func bulletRow(_ item: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(item)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}
