import Foundation

/// Holds the four AI provider implementations and tracks which one + which
/// model is currently selected for the chat tab.
///
/// The selection is persisted in UserDefaults — keys never go through here;
/// they live in `APIKeyStore`.
@Observable
@MainActor
final class ProviderRegistry {
    // MARK: - Singleton

    static let shared = ProviderRegistry()

    // MARK: - Providers

    let apple = AppleFoundationProvider()
    let anthropic = AnthropicProvider()
    let openai = OpenAIProvider()
    let gemini = GeminiProvider()
    let grok = GrokProvider()
    let deepseek = DeepSeekProvider()

    var allProviders: [AIProvider] {
        [apple, anthropic, openai, gemini, grok, deepseek]
    }

    /// Friendly display name for a model identified by its (provider, apiID)
    /// pair. Used by chat bubbles to render "Sonnet 4.6" instead of the raw
    /// "claude-sonnet-4-6-20251022" API string. Falls back to the apiID
    /// itself when the model isn't in the catalog (e.g. a stored chat from
    /// a deprecated model).
    func displayName(forApiID apiID: String, providerID: ProviderID) -> String {
        if let provider = allProviders.first(where: { $0.id == providerID }),
           let model = provider.availableModels.first(where: { $0.apiID == apiID }) {
            return model.displayName
        }
        return apiID
    }

    // MARK: - Selection (persisted)

    private static let providerKey = "assistant.activeProvider"
    private static let modelKey = "assistant.activeModelID"

    private(set) var activeProvider: AIProvider
    private(set) var activeModel: ModelOption
    /// Cached availability for the active provider.
    /// Each `AIProvider.isAvailable` call hits the Keychain via
    /// `AppDependencies.current.providers.apiKeyStore.hasKey(for:)` → `SecItemCopyMatching`,
    /// which is synchronous and ~1-3 ms. Hot paths (chat input bar's
    /// `canSend`, send button's color, prefab chip's enabled state)
    /// were calling this 3-4 times per render. Per keystroke that's
    /// a noticeable main-thread block — the user-reported "keyboard
    /// threading sucks" was this. Now: cache the result here as a
    /// observable property, refresh only when keys change or active
    /// provider changes. View renders read the cached bool — zero
    /// Keychain access per keystroke.
    private(set) var activeProviderAvailable: Bool = false
    /// Same idea for Apple specifically — `AppleFoundationProvider.isAvailable`
    /// calls `SystemLanguageModel.default.availability` (Foundation
    /// Models framework hop). Cached so repeated reads in the input
    /// bar don't pay the cost.
    private(set) var appleAvailable: Bool = false

    private init() {
        let apple = AppleFoundationProvider()
        let all: [AIProvider] = [
            apple, AnthropicProvider(), OpenAIProvider(),
            GeminiProvider(), GrokProvider(), DeepSeekProvider()
        ]
        let restored = Self.restoreSelection(from: all, fallback: apple)
        activeProvider = restored.provider
        activeModel = restored.model

        // `refreshAvailabilityCache()` must run on EVERY branch, not
        // only the third (nothing-available). If the first two
        // branches `return` early, the availability cache stays
        // at its default `false`. Result: existing users with saved
        // keys had `activeProviderAvailable = false`, which fed
        // `composerState.canSend = false`, which kept the send button
        // permanently disabled until they manually changed providers
        // or updated a key. Restructured to a single end-of-init call
        // that runs on every path.
        refreshAvailabilityCache()
    }

    /// Restore last selection if it's still available, else fall back.
    private static func restoreSelection(
        from all: [AIProvider], fallback: AIProvider
    ) -> (provider: AIProvider, model: ModelOption) {
        let defaults = UserDefaults.standard
        let savedProviderRaw = defaults.string(forKey: providerKey)
        let savedModelID = defaults.string(forKey: modelKey)

        // Try to restore exactly what the user picked last
        if let raw = savedProviderRaw,
           let providerID = ProviderID(rawValue: raw),
           let provider = all.first(where: { $0.id == providerID }),
           provider.isAvailable,
           let model = provider.availableModels.first(where: { $0.apiID == savedModelID }) {
            return (provider, model)
        }
        // Otherwise: prefer Apple (free) if available, then any
        // provider with a key
        if let firstAvailable = all.first(where: { $0.isAvailable }) {
            return (firstAvailable, firstAvailable.availableModels.first(where: { $0.isDefault })
                ?? firstAvailable.availableModels[0])
        }
        // Nothing available — show Apple by default; UI will gate sending.
        return (fallback, AppleFoundationProvider.model)
    }

    /// Recompute the cached availability bools. Call:
    ///   - After a key is set/removed (via `keysChanged()`)
    ///   - After `setActive(...)` swaps the active provider
    ///   - At app launch via deferred init
    func refreshAvailabilityCache() {
        AppDependencies.current.app.keyboardPerfSignpost.event("ProviderRegistry.refreshAvailabilityCache")
        let active = activeProvider.isAvailable
        let apple = self.apple.isAvailable
        if activeProviderAvailable != active { activeProviderAvailable = active }
        if appleAvailable != apple { self.appleAvailable = apple }
    }

    // MARK: - Selection API

    /// True when at least one provider is callable (Apple available OR any key set).
    var anyProviderAvailable: Bool {
        allProviders.contains(where: \.isAvailable)
    }

    /// Providers that have a chance of working right now.
    /// (Apple always shows; paid providers only show when their key is set
    /// AND the corresponding `FeatureFlags` kill switch is on.
    /// Toggling a switch off in Settings → AI Assistant
    /// removes the provider from the picker without requiring key removal.)
    var visibleProviders: [AIProvider] {
        allProviders.filter { provider in
            guard provider.id == .apple || AppDependencies.current.providers.apiKeyStore.hasKey(for: provider.id) else { return false }
            return Self.flagEnabled(for: provider.id)
        }
    }

    /// Map ProviderID → FeatureFlags.Key. Apple is always allowed (no
    /// kill switch — it runs on-device, no rate-limit / TOS concerns).
    private static func flagEnabled(for id: ProviderID) -> Bool {
        switch id {
        case .apple: return true
        case .anthropic: return AppDependencies.current.app.featureFlags.value(for: .providerAnthropicEnabled)
        case .openai: return AppDependencies.current.app.featureFlags.value(for: .providerOpenAIEnabled)
        case .gemini: return AppDependencies.current.app.featureFlags.value(for: .providerGeminiEnabled)
        case .grok: return AppDependencies.current.app.featureFlags.value(for: .providerGrokEnabled)
        case .deepseek: return AppDependencies.current.app.featureFlags.value(for: .providerDeepSeekEnabled)
        }
    }

    func setActive(provider: AIProvider, model: ModelOption? = nil) {
        let chosen: ModelOption = if let model, provider.availableModels.contains(model) {
            model
        } else {
            provider.availableModels.first(where: { $0.isDefault })
                ?? provider.availableModels[0]
        }
        activeProvider = provider
        activeModel = chosen
        persist()
        refreshAvailabilityCache()
    }

    func setActive(model: ModelOption) {
        guard let provider = allProviders.first(where: { $0.id == model.providerID }) else { return }
        activeProvider = provider
        activeModel = model
        persist()
        refreshAvailabilityCache()
    }

    /// Call after a key is added/removed so the registry can re-evaluate
    /// availability for the active provider.
    func keysChanged() {
        // If the active provider just lost its key, fall back to any working one.
        if !activeProvider.isAvailable, let fallback = visibleProviders.first(where: { $0.isAvailable }) {
            setActive(provider: fallback)
        }
        refreshAvailabilityCache()
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(activeProvider.id.rawValue, forKey: Self.providerKey)
        defaults.set(activeModel.apiID, forKey: Self.modelKey)
    }
}
