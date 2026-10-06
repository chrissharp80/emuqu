import Foundation

// `TurnRouter`: a standalone pure decision core with no reference to the view
// model beyond being called by it. It has its own test suite,
// `TurnRouterTests`.

// MARK: - TurnRouter (pure routing core)

/// Pure decision core extracted from
/// `AssistantViewModel.resolveProviderForThisTurn()`.
///
/// `route(inputs:)` is a pure function over a value snapshot of
/// everything the routing policy reads: no singleton access, no session
/// mutation, no logging. The imperative shell
/// (`resolveProviderForThisTurn`) builds the snapshot, runs the
/// side-effectful tier proposal (SmartProviderRouter classification,
/// session-state bumps, Tier-3 cap counter), and emits the returned
/// `Decision.logLines` verbatim — so the routed result AND the debug
/// log stream for every input combination are pinned by
/// TurnRouterTests. Branch order is load-bearing.
@MainActor
enum TurnRouter {

    // MARK: Inputs

    /// One provider's routing-relevant state, snapshotted from
    /// `ProviderRegistry` + `ProviderConsentTracker` at the call site.
    struct ProviderState: Equatable {
        let isAvailable: Bool
        /// `!ProviderConsentTracker.requiresConsent(id)` — true when the
        /// provider may receive PHI/PII (consent recorded, or exempt
        /// like on-device Apple).
        let isConsented: Bool
        /// Snapshot of `AssistantViewModel.providerSupportsTools(_:)`:
        /// whether the provider can run the action tools.
        let supportsTools: Bool
        /// `availableModels.first(where: \.isDefault) ?? availableModels.first`
        /// — the model resolution every bypass / override branch uses.
        let defaultOrFirstModel: ModelOption?
    }

    /// Value snapshot of one `TierProviderMapper.Mapping`. The mapper
    /// stays the single source of truth (it has other call sites); the
    /// shell snapshots its resolution per candidate tier rather than
    /// this type replicating the mapping policy.
    struct MappingSnapshot: Equatable {
        let providerID: ProviderID
        let model: ModelOption
        let collapsed: Bool
    }

    /// Tier-stage inputs, supplied by the shell only when
    /// `needsTierProposal(inputs:)` is true — the proposal's side
    /// effects (classifier, session bumps, cap counter) must stay in
    /// the imperative shell and must not fire on early-return turns.
    struct TierStage: Equatable {
        /// Mode pin (Quick / Deep) or `SmartProviderRouter.route` result
        /// (Auto), computed by the shell.
        let proposedTier: SmartProviderRouter.Tier
        /// True when the proposal is `.deep` and
        /// `SmartProviderRouter.recordTier3UsageAndCheck()` reported the
        /// daily cap hit.
        let tier3CapReached: Bool
        /// `TierProviderMapper` resolutions for every tier this turn can
        /// land on (the proposal, plus `.auto` when a cap downgrade is
        /// possible).
        let mappings: [SmartProviderRouter.Tier: MappingSnapshot]
        /// `AssistantViewModel.messageRequiresTools` over the latest
        /// user message; false when the conversation has none.
        let messageRequiresTools: Bool
    }

    struct Inputs: Equatable {
        let routingMode: RoutingMode
        let selectedProviderID: ProviderID
        let selectedProviderIsAvailable: Bool
        let selectedModel: ModelOption
        let isVoiceTurn: Bool
        /// `registry.allProviders` enumeration order — the "first
        /// available consented cloud" branches are order-sensitive
        /// (see `appleVoiceBypass` below).
        let providerOrder: [ProviderID]
        let providers: [ProviderID: ProviderState]
        let tierStage: TierStage?

        /// Copy with the tier stage attached — lets the shell build the
        /// singleton-reading snapshot exactly once.
        func with(tierStage: TierStage?) -> Inputs {
            Inputs(
                routingMode: routingMode,
                selectedProviderID: selectedProviderID,
                selectedProviderIsAvailable: selectedProviderIsAvailable,
                selectedModel: selectedModel,
                isVoiceTurn: isVoiceTurn,
                providerOrder: providerOrder,
                providers: providers,
                tierStage: tierStage
            )
        }
    }

    // MARK: Decision

    struct Decision: Equatable {
        let providerID: ProviderID
        let model: ModelOption
        let tier: SmartProviderRouter.Tier?
        /// Debug-log lines in emission order. The shell prints these
        /// verbatim; TurnRouterTests pins the log stream
        /// character-for-character.
        let logLines: [String]
    }

    // MARK: Routing

    /// Pure routing decision — branch order is load-bearing (pinned by
    /// TurnRouterTests).
    static func route(inputs: Inputs) -> Decision {
        if let early = preTierDecision(inputs: inputs) {
            return early
        }
        return tierDecision(inputs: inputs)
    }

    /// True when routing falls through the early returns into the tier
    /// stage — i.e., the shell must run the impure tier proposal and
    /// attach a `TierStage` before calling `route`. Defined as "no
    /// early decision" so this gate can never drift from the decision
    /// logic itself.
    static func needsTierProposal(inputs: Inputs) -> Bool {
        preTierDecision(inputs: inputs) == nil
    }

    // MARK: Early returns (pre-tier)

    /// User direction: "i have no designs on making this
    /// tied to a provider. you've tied it to apple for me. i want that
    /// undone." When the user has explicitly picked a non-Apple cloud
    /// in the model picker, that's their pick — period. The smart
    /// router's classifier was sending short / lookup-flavored
    /// questions to Apple Intelligence (Tier 1) regardless of the
    /// user's selection, which is what produced the "no matter what i
    /// ask the answers are super short and only data or really light"
    /// complaint: Apple Intelligence's signature terse output, even
    /// though the user expected Grok-level reasoning.
    ///
    /// This early-return makes the smart router opt-in (it only
    /// engages when the user is on Apple — i.e., they don't have a
    /// paid key configured). For everyone else, their pick rules.
    /// The Routing setting (Quick / Auto / Deep) is retained for
    /// users whose active provider IS Apple, where tier-based
    /// escalation to a paid cloud actually adds value.
    ///
    /// Manual mode is the escape hatch: every turn goes to the user's pick.
    private static func preTierDecision(inputs: Inputs) -> Decision? {
        if inputs.selectedProviderID != .apple || inputs.routingMode == .manual {
            return userPick(inputs, tier: nil, logLines: [])
        }
        return inputs.isVoiceTurn ? appleVoiceBypass(inputs: inputs) : nil
    }

    /// Voice-mode bypass, reached only when Apple is the selected provider
    /// (a non-Apple pick has already been returned as-is above).
    ///
    /// Voice does not use SmartProviderRouter: utterances are short, so the
    /// classifier votes Quick and session stickiness locks every voice turn
    /// onto Apple. Production voice assistants keep one model for a voice
    /// session instead of re-routing per turn on heuristics. So voice goes
    /// to the first available consented cloud in registry order.
    ///
    /// Consented clouds only. Entering an API key
    /// is NOT consent under the app's own model
    /// (ProviderConsentSheet); without this filter the branch
    /// ships voice turns (with health + location context) to a
    /// vendor the user never saw a disclosure for, because the
    /// early consent check in send() only examines the active
    /// provider (Apple, exempt). No consented cloud → stay on
    /// Apple: an on-device, terser answer beats sending PHI to
    /// an unconsented vendor, and voice has no way to present
    /// the consent sheet mid-turn.
    private static func appleVoiceBypass(inputs: Inputs) -> Decision {
        guard let cloudID = firstConsentedCloud(inputs: inputs),
              let model = inputs.providers[cloudID]?.defaultOrFirstModel
        else {
            return userPick(
                inputs, tier: nil,
                logLines: ["[SmartRouter] voice-mode bypass: no consented cloud available — staying on Apple (on-device)"]
            )
        }
        return Decision(
            providerID: cloudID, model: model, tier: nil,
            logLines: ["[SmartRouter] voice-mode bypass → \(cloudID.rawValue):\(model.apiID) (Apple selected → routing to first consented cloud)"]
        )
    }

    // MARK: Tier stage

    /// Adversarial-spend cap: bound the worst case if a router is
    /// somehow flipped by adversarial input (Shafran 2025). The
    /// daily-counter increment happened in the shell (only for Deep
    /// proposals); the downgrade decision here is pure.
    private static func tierDecision(inputs: Inputs) -> Decision {
        guard let stage = inputs.tierStage else { return userPick(inputs, tier: nil, logLines: []) }
        var logLines: [String] = []
        var finalTier = stage.proposedTier
        if finalTier == .deep, stage.tier3CapReached {
            logLines.append("[SmartRouter] daily Tier 3 cap reached — downgrading to Auto for the rest of the day")
            finalTier = .auto
        }
        guard let mapping = stage.mappings[finalTier] else {
            return userPick(inputs, tier: finalTier, logLines: logLines)
        }
        logLines.append(mapping.collapsed
            ? "[SmartRouter] tier=\(finalTier) collapsed to \(mapping.providerID.rawValue) (no distinct provider available)"
            : "[SmartRouter] tier=\(finalTier) → \(mapping.providerID.rawValue):\(mapping.model.apiID)")
        if let override = actionIntentOverride(inputs: inputs, stage: stage, mapping: mapping, logLines: &logLines) {
            return Decision(providerID: override.id, model: override.model, tier: finalTier, logLines: logLines)
        }
        return Decision(
            providerID: mapping.providerID, model: mapping.model,
            tier: finalTier, logLines: logLines
        )
    }

    /// Total-function fallback: the user's own pick.
    ///
    /// Reached with `tier: nil` when no tier stage is attached — the Manual
    /// arm of the original tier switch ("unreachable, exhausted above";
    /// Manual is decided in `preTierDecision`). Reached with a tier when the
    /// stage carries no mapping for it, which is unreachable by construction
    /// (the shell snapshots a mapping for the proposed tier and for `.auto`,
    /// the only downgrade target).
    private static func userPick(
        _ inputs: Inputs,
        tier: SmartProviderRouter.Tier?,
        logLines: [String]
    ) -> Decision {
        Decision(
            providerID: inputs.selectedProviderID, model: inputs.selectedModel,
            tier: tier, logLines: logLines
        )
    }

    /// Action-intent override. AppleFoundationProvider's
    /// `send(...)` discards the `tools` argument, so Apple Intelligence
    /// can't call any of our action tools (assistant_email_compose,
    /// assistant_contacts_add, directions_routeTo, web_search, etc.).
    /// Without this override, the user asking "email this to me"
    /// routes to Apple (Quick tier or Auto-classified-as-quick) →
    /// Coach has no email tool → Coach denies the capability we
    /// explicitly registered. Bug report: "Coach
    /// incorrectly denied having email capability."
    ///
    /// When an action verb is in the message AND the resolved
    /// provider can't actually call tools, fall back to whichever
    /// tool-capable provider the user has configured. The chat
    /// bubble's tier indicator shows the override happened so the
    /// user can see why their Quick-mode turn went to Anthropic.
    ///
    /// Consented clouds only (same rationale as the
    /// voice-mode bypass): this override runs when the active provider is
    /// Apple, so the unconsented vendor would never have shown its
    /// disclosure sheet.
    private static func actionIntentOverride(
        inputs: Inputs,
        stage: TierStage,
        mapping: MappingSnapshot,
        logLines: inout [String]
    ) -> (id: ProviderID, model: ModelOption)? {
        let mappingSupportsTools = inputs.providers[mapping.providerID]?.supportsTools ?? true
        guard !mappingSupportsTools, stage.messageRequiresTools,
              let fallbackID = firstConsentedCloud(inputs: inputs),
              let fallbackModel = inputs.providers[fallbackID]?.defaultOrFirstModel
        else { return nil }
        logLines.append("[SmartRouter] action intent — \(mapping.providerID.rawValue) lacks tools; overriding to \(fallbackID.rawValue):\(fallbackModel.apiID)")
        return (fallbackID, fallbackModel)
    }

    // MARK: Shared helpers

    /// First available, consented, non-Apple cloud in registry
    /// enumeration order — the shared predicate of the voice-mode
    /// bypass fallback and the action-intent override.
    private static func firstConsentedCloud(inputs: Inputs) -> ProviderID? {
        inputs.providerOrder.first { id in
            guard id != .apple, let state = inputs.providers[id] else { return false }
            return state.isAvailable && state.isConsented
        }
    }
}

// MARK: - Failure fallback

extension TurnRouter {
    /// Which other models may answer a turn whose model failed (no key, no
    /// credit, rate limit, network, model unavailable).
    enum FailureFallback: Equatable {
        /// None: the error is shown.
        case none
        /// Apple Intelligence only, which keeps the turn on this iPhone.
        case onDeviceOnly
        /// Any model the user has accepted, Apple last.
        case anyAccepted
    }

    /// The fallback each routing promise allows. Routing acts only while
    /// Apple Intelligence is the selected model; with another model
    /// selected, or in Manual, "every turn goes to" the pick, so nothing
    /// else answers. Quick promises typed questions stay on this iPhone, so
    /// only Apple may step in. Auto and Deep already choose the model per
    /// turn, so any accepted model may.
    static func failureFallback(mode: RoutingMode, selectedProviderID: ProviderID) -> FailureFallback {
        guard selectedProviderID == .apple else { return .none }
        switch mode {
        case .manual: return .none
        case .quick: return .onDeviceOnly
        case .auto, .deep: return .anyAccepted
        }
    }

    /// `chain` cut to what `fallback` allows.
    static func allowedFallbacks(
        _ chain: [(AIProvider, ModelOption)],
        under fallback: FailureFallback
    ) -> [(AIProvider, ModelOption)] {
        switch fallback {
        case .none: []
        case .onDeviceOnly: chain.filter { $0.0.id == .apple }
        case .anyAccepted: chain
        }
    }
}

/// The error shown when the model a turn was sent to fails and no other
/// model may answer it (`TurnRouter.failureFallback`): which model failed,
/// why, and that the turn was not handed to another one.
struct PickedModelFailure: LocalizedError {
    let providerID: ProviderID
    let underlying: AIProviderError

    var errorDescription: String? {
        let reason = underlying.errorDescription ?? underlying.localizedDescription
        return String(
            localized: "\(providerID.displayName) couldn't answer: \(reason)\n\nFlo didn't hand this question to another model. Try again, or pick another model.",
            bundle: LanguageManager.appBundle
        )
    }
}
