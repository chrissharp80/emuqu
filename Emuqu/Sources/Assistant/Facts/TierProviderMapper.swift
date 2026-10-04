import Foundation

/// Maps abstract tiers (Quick / Auto / Deep) to whatever
/// concrete (provider, model) pairs the user has actually configured.
///
/// **The "work with what's there" requirement** from the user spec.
/// Not everyone has every AI; some users will have only Apple
/// Intelligence, some will have Apple + Grok, some will have all six.
/// The mapper picks a backend for each tier from the available pool,
/// and collapses tiers when fewer providers exist:
///
///   - Quick → Apple Intelligence.
///   - Auto → Grok, then DeepSeek (consented ones only), on that
///     provider's default model; otherwise the user's chosen primary.
///   - Deep → the user's chosen primary. Tier routing runs only when that
///     primary is Apple, so in practice Deep takes Auto's consented
///     mid-tier cloud provider (it must never land on a weaker model
///     than Auto), and Apple only when no cloud provider is consented.
///
/// When a tier can't get what it wants (e.g. Apple-only user → Quick /
/// Auto / Deep all on Apple), the mapping is marked `collapsed`. The
/// routing layer logs that alongside the tier the turn was assigned to;
/// no screen shows it.
@MainActor
enum TierProviderMapper {
    struct Mapping {
        let provider: AIProvider
        let model: ModelOption
        /// True when this tier had to collapse to a lower tier's
        /// resolution because no distinct provider was available.
        /// Recorded in the routing log.
        let collapsed: Bool
    }

    /// Resolve a tier against the registry's currently-available
    /// providers. Always returns a Mapping — falls back to Apple if
    /// nothing else is configured (so the AI is never broken just
    /// because no cloud key is set).
    ///
    /// Design per user spec.
    ///   Quick (simple facts) → Apple Intelligence
    ///   Auto/Mid (middle questions) → Grok or DeepSeek if available;
    ///     otherwise the user's chosen primary
    ///   Deep (anything else, default conversational) → user's
    ///     chosen cloud primary (registry.activeProvider/activeModel);
    ///     with Apple as the primary, Auto's mid-tier cloud provider
    /// A rule like "Deep = strongest cloud by output price"
    /// routes users away from their selected provider whenever
    /// another configured key happens to be priced higher. That
    /// is wrong: if you pinned Claude, every Deep request should
    /// go to Claude, not jump to OpenAI because gpt-5.4 costs
    /// more per token. Manual mode already pins; this aligns Auto's
    /// Deep tier with user intent.
    static func mapping(
        for tier: SmartProviderRouter.Tier,
        registry: ProviderRegistry
    ) -> Mapping {
        switch tier {
        case .quick: return quickMapping(registry)
        case .auto: return autoMapping(registry)
        case .deep: return deepMapping(registry)
        }
    }

    /// Quick collapses to the user's chosen primary (cloud) when Apple isn't
    /// available, so we don't suddenly hand a Quick query to a model the user
    /// didn't pick.
    private static func quickMapping(_ registry: ProviderRegistry) -> Mapping {
        if registry.apple.isAvailable {
            return Mapping(provider: registry.apple, model: appleModel(registry), collapsed: false)
        }
        return chosenOrApple(registry)
    }

    /// Mid tier: prefer Grok, then DeepSeek (the cheap-but-capable mid-range
    /// models the spec calls out by name), then fall through to the user's
    /// primary if neither is configured. We deliberately do NOT use
    /// cheapest-cloud here — picking Gemini-Flash-Lite over the user's chosen
    /// Claude would surprise them.
    private static func autoMapping(_ registry: ProviderRegistry) -> Mapping {
        if let mid = midTierProvider(in: registry) {
            return Mapping(provider: mid.provider, model: mid.model, collapsed: false)
        }
        return chosenOrApple(registry)
    }

    /// Deep is the conversational default: the user's chosen cloud primary.
    /// When the primary IS Apple, Deep takes the same consented mid-tier cloud
    /// provider as Auto, collapsed: a question with more capability flags must
    /// never go to a weaker model (Apple's 4K window) than a one-flag question.
    /// Apple only when no cloud provider is consented.
    private static func deepMapping(_ registry: ProviderRegistry) -> Mapping {
        if let chosen = userChosenMapping(registry) {
            return Mapping(provider: chosen.0, model: chosen.1, collapsed: false)
        }
        if let mid = midTierProvider(in: registry) {
            return Mapping(provider: mid.provider, model: mid.model, collapsed: true)
        }
        return chosenOrApple(registry)
    }

    /// The user's chosen primary, then Apple, then the registry fallback —
    /// each marked collapsed because the tier couldn't get what it wanted.
    private static func chosenOrApple(_ registry: ProviderRegistry) -> Mapping {
        if let chosen = userChosenMapping(registry) {
            return Mapping(provider: chosen.0, model: chosen.1, collapsed: true)
        }
        if registry.apple.isAvailable {
            return Mapping(provider: registry.apple, model: appleModel(registry), collapsed: true)
        }
        return fallback(registry)
    }

    /// True when the user has at least one paid provider configured.
    /// Drives the Settings UX's "Deep mode unavailable" copy.
    static func hasCloudProvider(in registry: ProviderRegistry) -> Bool {
        cheapestCloud(in: registry) != nil
    }

    // MARK: - Internals

    private static func appleModel(_ registry: ProviderRegistry) -> ModelOption {
        // `AppleFoundationProvider` always advertises at least one model
        // today, but a future build flag could legitimately produce an
        // empty list. The active-registry fallback keeps the call safe
        // without crashing mid-conversation.
        registry.apple.availableModels.first(where: { $0.isDefault })
            ?? registry.apple.availableModels.first
            ?? registry.activeModel
    }

    private static func fallback(_ registry: ProviderRegistry) -> Mapping {
        // Unhappy path: nothing configured. Return the registry's
        // currently-active model so the chat layer's missing-key
        // handling fires consistently.
        Mapping(
            provider: registry.activeProvider,
            model: registry.activeModel,
            collapsed: true
        )
    }

    /// The user's chosen primary (provider, model).
    /// Returns nil when the chosen provider is Apple (callers handle
    /// Apple separately) or when the chosen provider isn't actually
    /// available (e.g., key was deleted but registry still has the
    /// stale selection) or its Settings switch is off. Skipping unavailable providers here lets
    /// the caller fall through cleanly.
    private static func userChosenMapping(_ registry: ProviderRegistry) -> (AIProvider, ModelOption)? {
        let provider = registry.activeProvider
        guard provider.id != .apple, provider.isAvailable, ProviderRegistry.isEnabled(provider.id) else { return nil }
        return (provider, registry.activeModel)
    }

    /// Middle-tier mapping per user spec: prefer Grok,
    /// then DeepSeek. The user explicitly named these as the mid-
    /// complexity providers. Picks the provider's default model so
    /// "mid" doesn't accidentally land on a heavyweight variant.
    ///
    /// Consented providers only. This mapper runs for
    /// users whose ACTIVE provider is Apple (consent-exempt), so the
    /// early consent check in `send()` never examines Grok/DeepSeek —
    /// without this check, auto-tier routing silently ships health context to a
    /// vendor whose ProviderConsentSheet the user never saw. A key on
    /// file is not consent. Unconsented mid-tier providers are skipped;
    /// the caller falls through to the user's primary / Apple.
    private static func midTierProvider(in registry: ProviderRegistry) -> (provider: AIProvider, model: ModelOption)? {
        for id in [ProviderID.grok, .deepseek] {
            if let pick = consentedProvider(id, in: registry) { return pick }
        }
        return nil
    }

    /// One mid-tier candidate, or nil when it's unconfigured, unavailable,
    /// switched off in Settings, unconsented, or exposes no models.
    private static func consentedProvider(
        _ id: ProviderID,
        in registry: ProviderRegistry
    ) -> (provider: AIProvider, model: ModelOption)? {
        guard ProviderRegistry.isEnabled(id),
              !AppDependencies.current.providers.providerConsentTracker.requiresConsent(id),
              let provider = registry.allProviders.first(where: { $0.id == id && $0.isAvailable }),
              let model = provider.availableModels.first(where: { $0.isDefault })
                  ?? provider.availableModels.first
        else { return nil }
        return (provider, model)
    }

    /// Pick the cheapest configured cloud provider's cheapest model.
    /// Heuristic: lowest input price per million tokens. Apple is
    /// excluded from this pool (it's the Quick tier's home).
    private static func cheapestCloud(in registry: ProviderRegistry) -> (provider: AIProvider, model: ModelOption)? {
        registry.allProviders
            .filter { $0.id != .apple && $0.isAvailable && ProviderRegistry.isEnabled($0.id) }
            .compactMap { provider -> (AIProvider, ModelOption, Decimal)? in
                guard let (model, price) = cheapestModel(of: provider) else { return nil }
                return (provider, model, price)
            }
            .min(by: { $0.2 < $1.2 })
            .map { ($0.0, $0.1) }
    }

    /// This provider's lowest-priced model, ignoring any without a listed price.
    private static func cheapestModel(of provider: AIProvider) -> (ModelOption, Decimal)? {
        provider.availableModels
            .compactMap { model -> (ModelOption, Decimal)? in
                guard let price = model.inputPricePerMTok else { return nil }
                return (model, price)
            }
            .min(by: { $0.1 < $1.1 })
    }

}
