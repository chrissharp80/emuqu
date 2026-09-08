import SwiftUI

/// Settings page where the user manages BYOK API keys for connected models.
/// Reachable from Settings → AI Assistant.
struct AIAssistantSettingsPage: View {
    @Environment(\.dependencies) var dependencies
    var registry: ProviderRegistry { dependencies.providers.providerRegistry }
    var facts: UserFactsStore { dependencies.assistant.userFactsStore }
    var settingsManager: SettingsManager { dependencies.app.settingsManager }
    @State var refreshToken = UUID()
    @State var newFactText: String = ""
    @State var showClearFactsConfirm = false
    @State var tavilyKeyDraft: String = ""
    @State var tavilyKeyShown: Bool = false

    var body: some View {
        settingsList
            .navigationTitle(String(localized: "AI Assistant", bundle: LanguageManager.appBundle))
            .navigationBarTitleDisplayMode(.inline)
            .alert(String(localized: "Forget everything?", bundle: LanguageManager.appBundle), isPresented: $showClearFactsConfirm) {
                Button(String(localized: "Forget", bundle: LanguageManager.appBundle), role: .destructive) { facts.clear() }
                Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
            } message: {
                Text(String(localized: "The AI will lose all the cross-session notes you've added. Your chat history and recovery data are not affected.", bundle: LanguageManager.appBundle))
            }
    }

    // MARK: - Per-provider feature-flag toggles

    struct ProviderFlagEntry {
        let flag: FeatureFlags.Key
        let title: String
        let subtitle: String
    }

    var providerFlagToggles: [ProviderFlagEntry] {
        let pickerSubtitle = String(localized: "Available in the model picker when enabled.", bundle: LanguageManager.appBundle)
        return [
            .init(flag: .providerOpenAIEnabled,
                  title: "OpenAI",
                  subtitle: pickerSubtitle),
            .init(flag: .providerAnthropicEnabled,
                  title: "Anthropic",
                  subtitle: pickerSubtitle),
            .init(flag: .providerGeminiEnabled,
                  title: "Google Gemini",
                  subtitle: pickerSubtitle),
            .init(flag: .providerGrokEnabled,
                  title: "xAI Grok",
                  subtitle: pickerSubtitle),
            .init(flag: .providerDeepSeekEnabled,
                  title: "DeepSeek",
                  subtitle: pickerSubtitle)
        ]
    }

    /// Two-way binding into FeatureFlags. The `_ = refreshToken` read forces a
    /// view re-eval on toggle so the row redraws with the new value (the flag
    /// store isn't an ObservableObject by design — it's read from any actor).
    func bindingFor(flag: FeatureFlags.Key) -> Binding<Bool> {
        Binding(
            get: {
                _ = refreshToken
                return dependencies.app.featureFlags.value(for: flag)
            },
            set: { newValue in
                dependencies.app.featureFlags.set(newValue, for: flag)
                refreshToken = UUID()
            }
        )
    }

    /// Placeholder for the Tavily key field — shows the masked preview of
    /// the current key when one is saved, otherwise the format hint. Refresh
    /// is forced via `refreshToken` whenever the key is added/removed so
    /// the placeholder updates in place.
    var tavilyKeyPlaceholder: String {
        if let preview = dependencies.providers.apiKeyStore.maskedServicePreview(for: .tavilyWebSearch) {
            return preview
        }
        return "tvly-…"
    }

    var applePathStatus: String {
        let apple = registry.apple
        return apple.isAvailable ? String(localized: "Available", bundle: LanguageManager.appBundle) : String(localized: "Unavailable on this device or iOS version", bundle: LanguageManager.appBundle)
    }

    func keysChanged() {
        registry.keysChanged()
        refreshToken = UUID()
    }
}

// MARK: - Per-provider key editor

struct APIKeyEditorView: View {
    @Environment(\.dependencies) var dependencies
    let provider: AIProvider
    let onChange: () -> Void

    @State var keyText: String = ""
    @State var hasExistingKey: Bool = false
    @State var saveStatus: SaveStatus = .idle
    @State private var showWithdrawConfirm = false
    /// Observed rather than read through `.shared` at each call site: the row
    /// has to redraw the instant consent changes, and `acknowledgedProviders`
    /// already publishes exactly that.
    private var consent: ProviderConsentTracker { dependencies.providers.providerConsentTracker }
    /// Bound once rather than located at each call site below, so the
    /// dependency is visible in one place (the refactor spec's
    /// explicit-wiring rule).
    var keys: APIKeyStore { dependencies.providers.apiKeyStore }
    enum SaveStatus { case idle, saved, removed }

    @ViewBuilder
    var body: some View {
        Form {
            apiKeySection
            dataSharingSection
            keyUsageSection
        }
        .navigationTitle(provider.id.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            hasExistingKey = keys.hasKey(for: provider.id)
        }
        .alert(String(localized: "Stop sharing with this provider?", bundle: LanguageManager.appBundle), isPresented: $showWithdrawConfirm) {
            Button(String(localized: "Withdraw", bundle: LanguageManager.appBundle), role: .destructive) { withdrawConsent() }
            Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
        } message: {
            Text(String(localized: "Emuqu will stop sending your data to this provider. You'll be asked to agree again before it resumes. Data the provider already received is governed by their policy, not by this setting.", bundle: LanguageManager.appBundle))
        }
    }

    // MARK: - Data sharing

    /// Consent status and the withdrawal control.
    ///
    /// Before this existed, `ProviderConsentTracker.revoke(_:)` had no
    /// production caller: the user could agree to hosted processing and had no
    /// way to take it back short of deleting the app. Apple requires consent to
    /// be withdrawable somewhere the user can actually reach.
    @ViewBuilder
    private var dataSharingSection: some View {
        if ProviderConsentTracker.providersRequiringConsent.contains(provider.id) {
            Section {
                consentStatusRow
                withdrawConsentButton
            } header: {
                Text(String(localized: "Data Sharing", bundle: LanguageManager.appBundle))
            } footer: {
                Text(String(localized: "Emuqu asks once per provider before sending anything. Withdrawing takes effect immediately — the next request asks again.", bundle: LanguageManager.appBundle))
            }
        }
    }

    private var consentStatusRow: some View {
        LabeledContent {
            Text(consentStatusText).foregroundStyle(.secondary)
        } label: {
            Text(String(localized: "Sharing consent", bundle: LanguageManager.appBundle))
        }
    }

    /// "Agreed 25 Aug 2026" or "Not agreed" — the date comes from the consent
    /// record so the user can see which disclosure they actually accepted.
    private var consentStatusText: String {
        guard !consent.requiresConsent(provider.id) else {
            return String(localized: "Not agreed", bundle: LanguageManager.appBundle)
        }
        guard let granted = consent.consentGrantedAt(provider.id) else {
            return String(localized: "Agreed", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Agreed \(granted.formatted(date: .abbreviated, time: .omitted))", bundle: LanguageManager.appBundle)
    }

    @ViewBuilder
    private var withdrawConsentButton: some View {
        if !consent.requiresConsent(provider.id) {
            Button(role: .destructive) { showWithdrawConfirm = true } label: {
                Text(String(localized: "Withdraw consent", bundle: LanguageManager.appBundle))
            }
        }
    }

    private func withdrawConsent() {
        consent.revoke(provider.id)
        onChange()
    }

    private var apiKeySection: some View {
        Section {
            apiKeyField
            saveKeyButton
            removeKeyButton
        } header: {
            Text(String(localized: "API Key", bundle: LanguageManager.appBundle))
        } footer: {
            apiKeyStatusText
        }
    }

    private var apiKeyField: some View {
        SecureField(
            provider.id == .anthropic ? "sk-ant-..." :
                provider.id == .openai ? "sk-..." :
                "AIza...",
            text: $keyText
        )
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
    }

    private var saveKeyButton: some View {
        Button {
            keys.setKey(keyText, for: provider.id)
            keyText = ""
            hasExistingKey = keys.hasKey(for: provider.id)
            saveStatus = .saved
            onChange()
        } label: {
            Text(hasExistingKey ? String(localized: "Replace key", bundle: LanguageManager.appBundle) : String(localized: "Save key", bundle: LanguageManager.appBundle))
        }
        .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @ViewBuilder
    private var removeKeyButton: some View {
        if hasExistingKey {
            Button(role: .destructive) {
                removeKeyAndConsent()
            } label: {
                Text(String(localized: "Remove key", bundle: LanguageManager.appBundle))
            }
        }
    }

    /// Removing the key also withdraws consent.
    ///
    /// If these were separate, a user who removed a key
    /// to stop hosted processing would keep a live acknowledgement on file, and
    /// re-adding the key months later would resume sending with no second
    /// prompt — the user's clearest possible "stop" gesture leaving the door
    /// open. Revoking is the
    /// safer default: the cost of being wrong is one extra tap.
    private func removeKeyAndConsent() {
        keys.removeKey(for: provider.id)
        consent.revoke(provider.id)
        hasExistingKey = false
        saveStatus = .removed
        onChange()
    }

    @ViewBuilder
    private var apiKeyStatusText: some View {
        if let preview = keys.maskedPreview(for: provider.id), !hasExistingKey == false {
            Text(String(localized: "Currently saved: \(preview)", bundle: LanguageManager.appBundle))
        } else if saveStatus == .saved {
            Text(String(localized: "Key saved.", bundle: LanguageManager.appBundle))
        } else if saveStatus == .removed {
            Text(String(localized: "Key removed.", bundle: LanguageManager.appBundle))
        } else {
            Text("")
        }
    }

    private var keyUsageSection: some View {
        Section {
            if let url = provider.id.privacyPolicyURL {
                Link(String(localized: "\(provider.id.vendorName) privacy policy", bundle: LanguageManager.appBundle), destination: url)
            }
        } header: {
            Text(String(localized: "Where this key is used", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: "Your data and questions are sent to \(provider.id.vendorName) when you select a \(provider.id.displayName) model. Emuqu does not see, log, or modify what \(provider.id.vendorName) does with that data or what it sends back.", bundle: LanguageManager.appBundle))
        }
    }
}
