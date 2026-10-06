import SwiftUI

// MARK: - AI Assistant settings sections
//
// Each section is a property named for its own header, with
// its fields, input rows and footer split out so nothing runs past twenty
// lines or nests past two (as one `body` they were 349 lines nested six deep).
//
// They live here because the split pushed the struct past SwiftLint's 500-line
// `type_body_length`, the same reason `RecordView+Sections.swift` and
// `BiometricsSettingsPage+Sections.swift` exist. Every member is a computed
// property or method on `AIAssistantSettingsPage` itself, so the list and its
// focus state are exactly what they were inline.

extension AIAssistantSettingsPage {
    // MARK: - Settings list
    //
    // Each section is a property named for its own
    // header, and each keeps the comment that explains why it exists.

    var settingsList: some View {
        List {
            connectedModelsSection
            onDeviceSection
            routingSection
            webSearchSection
            emailDefaultsSection
            memorySection
            languageSection
            clipboardSection
            speechRecognizerSection
            providerAvailabilitySection
            disclosureSection
        }
    }

    var connectedModelsSection: some View {
        Section {
            connectedModelsFields
        } header: {
            Text(String(localized: "Connected Models", bundle: LanguageManager.appBundle))
        } footer: {
            connectedModelsFooter
        }
    }

    @ViewBuilder
    var connectedModelsFields: some View {
        ForEach(registry.allProviders.filter(\.requiresKey), id: \.id) { provider in
            providerKeyRow(provider)
        }
    }

    /// Reads `refreshToken` so the row's key status redraws after a save or
    /// removal; the editor itself keeps its identity, so its "Key saved." /
    /// "Key removed." footer stays visible.
    func providerKeyRow(_ provider: AIProvider) -> some View {
        _ = refreshToken
        return NavigationLink {
            APIKeyEditorView(provider: provider, onChange: keysChanged)
        } label: {
            providerKeyRowLabel(provider)
        }
    }

    func providerKeyRowLabel(_ provider: AIProvider) -> some View {
        HStack(spacing: 10) {
            Image(systemName: provider.id.symbolName)
                .frame(width: 24)
                .foregroundStyle(Color.accentColor)
            providerKeyRowText(provider)
            Spacer()
        }
    }

    func providerKeyRowText(_ provider: AIProvider) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(provider.id.displayName)
                .font(.body)
            Text(keyStatus(for: provider))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    var connectedModelsFooter: some View {
        Text(String(localized: "Keys are stored in the iOS Keychain on this device only. They are never synced to iCloud and are sent only to the corresponding provider.", bundle: LanguageManager.appBundle))
    }

    var onDeviceSection: some View {
        Section {
            onDeviceFields
        } header: {
            Text(String(localized: "On-Device", bundle: LanguageManager.appBundle))
        } footer: {
            onDeviceFooter
        }
    }

    @ViewBuilder
    var onDeviceFields: some View {
        onDeviceToggle
    }

    var onDeviceToggle: some View {
        ForEach([ProviderID.apple], id: \.self) { providerID in
            onDeviceRow(providerID)
        }
    }

    func onDeviceRow(_ providerID: ProviderID) -> some View {
        HStack(spacing: 10) {
            Image(systemName: providerID.symbolName)
                .frame(width: 24)
                .foregroundStyle(Color.accentColor)
            onDeviceToggleLabel(providerID)
            Spacer()
        }
    }

    func onDeviceToggleLabel(_ providerID: ProviderID) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(providerID.displayName)
                .font(.body)
            Text(applePathStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    var onDeviceFooter: some View {
        Text(String(localized: "Apple Intelligence runs entirely on this iPhone. No data leaves the device. Requires iOS 26 with Apple Intelligence enabled.", bundle: LanguageManager.appBundle))
    }

    /// Three-mode routing picker per the
    /// adaptive-routing spec (not a binary toggle).
    /// Quick / Auto / Deep / Manual maps to RoutingMode.
    var routingSection: some View {
        Section {
            routingFields
        } header: {
            Text(String(localized: "AI routing", bundle: LanguageManager.appBundle))
        } footer: {
            routingFooter
        }
    }

    @ViewBuilder
    var routingFields: some View {
        routingModePicker
        if registry.activeProvider.id == .apple {
            routingCaption(settingsManager.settings.routingMode.blurb)
            noCloudProviderNotice
        } else {
            routingCaption(String(
                localized: "\(registry.activeProvider.id.displayName) is selected, so every turn goes to it and the routing mode has no effect.",
                bundle: LanguageManager.appBundle
            ))
        }
    }

    func routingCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Routing only acts while Apple Intelligence is the selected model
    /// (`TurnRouter.preTierDecision` sends every turn to a selected cloud
    /// model), so the picker is disabled otherwise rather than offering
    /// modes that would do nothing.
    var routingModePicker: some View {
        Picker(String(localized: "AI routing", bundle: LanguageManager.appBundle), selection: Bindable(settingsManager).settings.routingMode) {
            ForEach(RoutingMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .disabled(registry.activeProvider.id != .apple)
    }

    @ViewBuilder
    var noCloudProviderNotice: some View {
        if settingsManager.settings.routingMode != .manual,
           !TierProviderMapper.hasCloudProvider(in: registry) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                noCloudProviderText
            }
        }
    }

    var noCloudProviderText: some View {
        Text(String(localized: "No cloud model is set up, so every mode answers on Apple Intelligence.", bundle: LanguageManager.appBundle))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    var routingFooter: some View {
        Text(String(localized: """
            Routing applies while Apple Intelligence is the selected model. In Quick, Auto and Deep, voice \
            turns and requests to send email, get directions or search the web go to a cloud model whose \
            data-sharing notice you've accepted, if you have one. Manual keeps every turn on the selected model. \
            If the model a turn goes to fails, Auto and Deep may answer with another model whose notice you've \
            accepted, and Quick with Apple Intelligence; Manual and a selected cloud model never switch.
            """, bundle: LanguageManager.appBundle))
    }

    /// Web Search (Tavily)
    ///
    /// Off by default. The user must opt in AND supply a Tavily key.
    /// We surface BOTH controls together so the dependency is visible
    /// (you can't just flip the toggle and have it work) and the
    /// "Get a Tavily API key" link is one tap away from where the key
    /// gets pasted.
    var webSearchSection: some View {
        Section {
            webSearchFields
        } header: {
            Text(String(localized: "Web Search", bundle: LanguageManager.appBundle))
        } footer: {
            webSearchFooter
        }
    }

    @ViewBuilder
    var webSearchFields: some View {
        webSearchToggle
        tavilyKeyRow
        tavilyKeyActions
        tavilyKeyLink
    }

    var webSearchToggle: some View {
        Toggle(isOn: Binding(
            get: { settingsManager.settings.enableWebSearch },
            set: { settingsManager.settings.enableWebSearch = $0 }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Allow web search", bundle: LanguageManager.appBundle))
                    .font(.body)
                Text(String(localized: "The AI can look up authoritative sources (research papers, manufacturer docs) for questions Emuqu's own data can't answer.", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!canSearchWeb)
    }

    /// Web search has two routes: Tavily, with its own key, and Anthropic's
    /// server-side search, which rides the Claude key.
    var canSearchWeb: Bool {
        let keys = dependencies.providers.apiKeyStore
        return keys.hasServiceKey(for: .tavilyWebSearch) || keys.hasKey(for: .anthropic)
    }

    var tavilyKeyRow: some View {
        HStack {
            tavilyKeyField
            tavilyKeyVisibilityButton
        }
    }

    @ViewBuilder
    private var tavilyKeyField: some View {
        if tavilyKeyShown {
            TextField("tvly-…", text: $tavilyKeyDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
        } else {
            SecureField(tavilyKeyPlaceholder, text: $tavilyKeyDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
        }
    }

    private var tavilyKeyVisibilityButton: some View {
        Button {
            tavilyKeyShown.toggle()
        } label: {
            Image(systemName: tavilyKeyShown ? "eye.slash" : "eye")
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tavilyKeyShown
            ? String(localized: "Hide key", bundle: LanguageManager.appBundle)
            : String(localized: "Show key", bundle: LanguageManager.appBundle))
    }

    var tavilyKeyActions: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                saveTavilyKeyButton
                Spacer()
                removeTavilyKeyButton
            }
            if tavilyKeySaveFailed {
                Text(String(localized: "The key couldn't be saved to the keychain. Try again.", bundle: LanguageManager.appBundle))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Keeps the typed key in the field when the Keychain write fails, so
    /// the user can retry without pasting it again.
    var saveTavilyKeyButton: some View {
        Button {
            let stored = dependencies.providers.apiKeyStore.setServiceKey(tavilyKeyDraft, for: .tavilyWebSearch)
            tavilyKeySaveFailed = !stored
            if stored { tavilyKeyDraft = "" }
            refreshToken = UUID()
        } label: {
            Label(String(localized: "Save key", bundle: LanguageManager.appBundle), systemImage: "key.fill")
        }
        .disabled(tavilyKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @ViewBuilder
    var removeTavilyKeyButton: some View {
        if dependencies.providers.apiKeyStore.hasServiceKey(for: .tavilyWebSearch) {
            Button(role: .destructive, action: removeTavilyKey) {
                Label(String(localized: "Remove key", bundle: LanguageManager.appBundle), systemImage: "trash")
            }
        }
    }

    func removeTavilyKey() {
        dependencies.providers.apiKeyStore.removeServiceKey(for: .tavilyWebSearch)
        // Turn search off when no route is left, so the toggle cannot sit on
        // while greyed out and the AI does not keep getting `missingKey` errors.
        if !canSearchWeb {
            settingsManager.settings.enableWebSearch = false
        }
        refreshToken = UUID()
    }

    @ViewBuilder
    var tavilyKeyLink: some View {
        if let tavilyURL = URL(string: "https://app.tavily.com/sign-in") {
            Link(destination: tavilyURL) {
                Label(String(localized: "Get a Tavily API key", bundle: LanguageManager.appBundle), systemImage: "link")
                    .font(.callout)
            }
        }
    }

    @ViewBuilder
    var webSearchFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: """
                When enabled, the AI may search the web for questions your on-device data can't answer — research, hardware specs, \
                firmware updates. With a Tavily key the search goes to Tavily; on Claude, Anthropic runs it. Tavily searches for \
                research and hardware questions are limited to authority sources (PubMed, manufacturer docs, established \
                training-science blogs), and both routes block known content-farm sites.
                """, bundle: LanguageManager.appBundle))
            Text(String(localized: "Web results are reference material, not medical advice. The AI is rule-bound to cite source URLs and never synthesise new training/diet protocols from search content.", bundle: LanguageManager.appBundle))
                .foregroundStyle(.secondary)
            Text(String(localized: "Your Tavily key is stored in the iOS Keychain on this device, never synced to iCloud. Search queries are sent to Tavily — see their privacy policy.", bundle: LanguageManager.appBundle))
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
    }

    /// Email defaults moved to Settings →
    /// Profile (used app-wide now: morning report PDF, workout
    /// PDF, AND the AI's email-compose action). Two categories
    /// — recovery and training — let the user route different
    /// email types to different recipients. Pointer below.
    var emailDefaultsSection: some View {
        Section {
            Text(String(localized: "Email defaults moved to Profile", bundle: LanguageManager.appBundle))
                .font(.callout.weight(.medium))
                .foregroundStyle(AppTheme.textPrimary)
            // NOTE: kept as a LocalizedStringKey literal (not String(localized:))
            // so SwiftUI still renders the **bold** markdown. The key is still
            // localizable via the app's .strings; wrapping in String(localized:)
            // would flatten the bold.
            Text("Set them in **Settings → Profile**. The defaults pre-fill the morning report PDF, the workout PDF, AND any email the AI composes — set once, every email surface knows.", bundle: LanguageManager.appBundle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var memorySection: some View {
        Section {
            memoryFields
        } header: {
            Text(String(localized: "What the AI Remembers", bundle: LanguageManager.appBundle))
        } footer: {
            memoryFooter
        }
    }

    @ViewBuilder
    var memoryFields: some View {
        rememberedFactsList
        addFactRow
        forgetEverythingButton
        autoRememberToggle
    }

    @ViewBuilder
    var rememberedFactsList: some View {
        rememberedFactsBody
    }

    @ViewBuilder
    var rememberedFactsBody: some View {
        if facts.facts.isEmpty {
            noRememberedFactsText
        } else {
            rememberedFactRows
        }
    }

    var noRememberedFactsText: some View {
        Text(String(localized: "Nothing remembered yet. Long-press any chat message and tap “Remember this” to add it here, or type a new fact below.", bundle: LanguageManager.appBundle))
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    var rememberedFactRows: some View {
        ForEach(facts.facts) { fact in
            rememberedFactRow(fact)
        }
        .onDelete(perform: forgetFacts)
    }

    func rememberedFactRow(_ fact: UserFactsStore.Fact) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(fact.text)
                .font(.callout)
            Text(fact.createdAt.formatted(date: .abbreviated, time: .omitted))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    func forgetFacts(at indexSet: IndexSet) {
        for i in indexSet {
            facts.remove(facts.facts[i].id)
        }
    }

    var addFactRow: some View {
        HStack {
            TextField(String(localized: "Add a fact (e.g., \"I'm training for a marathon\")", bundle: LanguageManager.appBundle), text: $newFactText, axis: .vertical)
                .lineLimit(1 ... 3)
            Button {
                facts.add(newFactText)
                newFactText = ""
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(newFactText.trimmingCharacters(in: .whitespaces).isEmpty ? Color(.tertiaryLabel) : Color.accentColor)
            }
            .disabled(newFactText.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel(String(localized: "Add fact", bundle: LanguageManager.appBundle))
        }
    }

    @ViewBuilder
    var forgetEverythingButton: some View {
        if !facts.facts.isEmpty {
            Button(role: .destructive) {
                showClearFactsConfirm = true
            } label: {
                Label(String(localized: "Forget everything", bundle: LanguageManager.appBundle), systemImage: "trash")
            }
        }
    }

    var autoRememberToggle: some View {
        Toggle(isOn: Bindable(facts).autoExtractEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Auto-remember things", bundle: LanguageManager.appBundle))
                    .font(.body)
                Text(String(localized: "After each chat, ask the model to identify any new facts about you and add them automatically. Free on Apple, ~fraction of a cent on connected models.", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    var memoryFooter: some View {
        Text(String(localized: "These notes are added to every AI conversation so the assistant has context across sessions. Stored on this device only — never sent anywhere except the AI provider you're chatting with at the time.", bundle: LanguageManager.appBundle))
    }

    /// Bilingual users on a non-English-locale phone
    /// (e.g. Japanese OS) sometimes prefer the AI in English.
    /// Without this toggle the AI mirrors device locale + the
    /// voice TTS / speech recognizer pick the OS language too.
    var languageSection: some View {
        languageToggle
    }

    var languageToggle: some View {
        Section {
            Toggle(isOn: Bindable(settingsManager).settings.forceAIEnglish) {
                languageToggleLabel
            }
        } header: {
            Text(String(localized: "Language", bundle: LanguageManager.appBundle))
        }
    }

    var languageToggleLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "Always respond in English", bundle: LanguageManager.appBundle))
                .font(.body)
            Text(String(localized: "Override the device language for AI conversations and voice. Useful if your phone is set to another language but you prefer the AI in English.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Clipboard preservation toggle. Default ON
    /// so dictated ideas survive interruptions; OFF restores
    /// the 60 s security expiration.
    var clipboardSection: some View {
        clipboardToggle
    }

    var clipboardToggle: some View {
        Section {
            Toggle(isOn: Bindable(settingsManager).settings.preserveClipboardForPaste) {
                clipboardToggleLabel
            }
        } header: {
            Text(String(localized: "Clipboard", bundle: LanguageManager.appBundle))
        }
    }

    var clipboardToggleLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "Keep copied content until I paste it", bundle: LanguageManager.appBundle))
                .font(.body)
            Text(String(
                localized: "When on, copies from chat (including the in-progress dictation saved when an alert preempts you) stay on the clipboard until you paste them or copy something else. When off, Emuqu's clipboard writes auto-clear after 60 seconds for added privacy.",
                bundle: LanguageManager.appBundle
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Speech-to-text provider toggle. Apple by
    /// default; WhisperKit is opt-in. Switching takes effect at
    /// the start of the NEXT voice session — an in-flight one
    /// keeps using whatever it started with.
    var speechRecognizerSection: some View {
        Section {
            speechRecognizerPicker
        } header: {
            Text(String(localized: "Speech recognizer", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(
                localized: "WhisperKit downloads a ~100 MB on-device model the first time it's used. After that it transcribes per-turn (no live partials) but handles wind / footfall noise better than Apple's default. Apple stays as the fallback if WhisperKit fails.",
                bundle: LanguageManager.appBundle
            ))
                .font(.footnote)
        }
    }

    var speechRecognizerPicker: some View {
        Picker(String(localized: "Speech recognizer", bundle: LanguageManager.appBundle), selection: Bindable(settingsManager).settings.preferredSTTProvider) {
            ForEach(STTProviderKind.allCases.filter { $0.supports(languageCode: appLanguageCode) }) { kind in
                sttOptionLabel(kind)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    /// The app language's ISO 639 code. The recognizer picker leaves out
    /// recognizers that can't transcribe it (WhisperKit's English-only model).
    private var appLanguageCode: String? {
        LanguageManager.appLocale.language.languageCode?.identifier
    }

    func sttOptionLabel(_ kind: STTProviderKind) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kind.displayName).font(.body)
            Text(kind.subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .tag(kind)
    }

    /// Per-provider kill switches surfaced
    /// in-app. Toggling off a provider hides it from the picker
    /// (registry filters by FeatureFlags) so a user / support can
    /// disable a provider without uninstalling the app or rotating
    /// keys. The medical-query guard is shown as a read-only status
    /// row: nothing in the app switches it off.
    var providerAvailabilitySection: some View {
        Section {
            providerAvailabilityFields
        } header: {
            Text(String(localized: "Provider availability", bundle: LanguageManager.appBundle))
        } footer: {
            providerAvailabilityFooter
        }
    }

    @ViewBuilder
    var providerAvailabilityFields: some View {
        providerFlagToggleList
        medicalGuardStatusRow
    }

    var providerFlagToggleList: some View {
        providerFlagToggleRows
    }

    var providerFlagToggleRows: some View {
        ForEach(providerFlagToggles, id: \.flag) { entry in
            Toggle(isOn: bindingFor(flag: entry.flag)) {
                providerFlagToggleLabel(entry)
            }
        }
    }

    func providerFlagToggleLabel(_ entry: ProviderFlagEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title).font(.body)
            Text(entry.subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    var medicalGuardStatusRow: some View {
        HStack {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(Color.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Medical-query guard", bundle: LanguageManager.appBundle)).font(.body)
                Text(String(localized: "Active. Refuses AFib / arrhythmia / symptom queries before any provider call.", bundle: LanguageManager.appBundle))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    var providerAvailabilityFooter: some View {
        Text(String(localized: "Kill switches let you disable a cloud provider without removing its API key. Useful during a provider outage or terms-of-service change. Apple Intelligence runs on-device and has no switch.", bundle: LanguageManager.appBundle))
            .font(.footnote)
    }

    var disclosureSection: some View {
        Section {
            Text(String(
                localized: "AI responses are informational coaching from the data this app collected. They are not medical diagnosis or treatment. For health decisions, talk to a qualified clinician.",
                bundle: LanguageManager.appBundle
            ) + " " + String(
                localized: "Emuqu screens questions and replies on this device for medical red flags and points you to a clinician, but it cannot control what those services do with your data or everything they say. Long-press any reply to report it.",
                bundle: LanguageManager.appBundle
            ))
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text(String(localized: "Disclosure", bundle: LanguageManager.appBundle))
        }
    }

    func keyStatus(for provider: AIProvider) -> String {
        if let preview = dependencies.providers.apiKeyStore.maskedPreview(for: provider.id) {
            return String(localized: "Connected · key \(preview)", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Not set up — tap to add a key", bundle: LanguageManager.appBundle)
    }
}
