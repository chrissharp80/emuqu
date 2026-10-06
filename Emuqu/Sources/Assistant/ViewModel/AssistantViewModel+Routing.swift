import Foundation
import os

// Provider routing and stream dispatch: choosing which model answers a turn,
// then driving the stream and its stages.
//
// Lives on `AssistantTurnRouter` rather than `AssistantViewModel`: the
// aggregate type-size gate counts a type across all its files, so keeping
// these ~750 lines on the view-model would leave it just as large.

extension AssistantTurnRouter {
    // MARK: - Smart-route provider selection

    /// Adaptive-routing dispatch.
    ///
    /// A non-Apple selection, or Manual mode, always answers with the
    /// user's pick. With Apple selected, the Routing setting applies:
    ///   • **Quick** → Tier 1 (Apple Intelligence)
    ///   • **Deep** → Tier 3: a consented Grok, then DeepSeek
    ///     (`TierProviderMapper`), Apple when neither is consented
    ///   • **Auto** → session-sticky NL embedding classifier
    ///     (`SmartProviderRouter.route`); its mid and deep tiers reach the
    ///     same consented Grok or DeepSeek
    ///
    /// Tiers with no provider of their own collapse to Apple — the
    /// spec's "work with what's there." `Mapping.collapsed` is only
    /// logged. The Tier-3 spend cap counts Deep turns that resolve to a
    /// cloud model; a Deep turn that stays on Apple costs nothing and is
    /// not counted.
    func resolveProviderForThisTurn() -> (provider: AIProvider, model: ModelOption, tier: SmartProviderRouter.Tier?) {
        // Imperative shell around the pure
        // `TurnRouter.route(inputs:)` (bottom of this file). Snapshot
        // live state → pure decision → translate back to live objects.
        // Every singleton read and side effect (classifier call,
        // session-state bumps, Tier-3 cap counter, debug logging)
        // happens here; the branch logic itself is pure and
        // parity-tested in TurnRouterTests.
        let base = makeTurnRouterInputs(tierStage: nil)
        let inputs = TurnRouter.needsTierProposal(inputs: base)
            ? base.with(tierStage: makeTierStageInputs(mode: base.routingMode))
            : base
        let decision = TurnRouter.route(inputs: inputs)
        for line in decision.logLines {
            debugLog(line)
        }
        return (liveProvider(for: decision.providerID), decision.model, decision.tier)
    }

    /// Build the pure-routing snapshot from live singletons. This is
    /// the ONLY place `resolveProviderForThisTurn`'s decision inputs
    /// are read — owner.registry, consent tracker, settings, and the voice
    /// flag are captured as values so `TurnRouter.route` stays pure.
    func makeTurnRouterInputs(tierStage: TurnRouter.TierStage?) -> TurnRouter.Inputs {
        var providerStates: [ProviderID: TurnRouter.ProviderState] = [:]
        for provider in owner.registry.allProviders {
            providerStates[provider.id] = TurnRouter.ProviderState(
                isAvailable: provider.isAvailable && ProviderRegistry.isEnabled(provider.id),
                isConsented: !AppDependencies.current.providers.providerConsentTracker.requiresConsent(provider.id),
                supportsTools: Self.providerSupportsTools(provider),
                defaultOrFirstModel: provider.availableModels.first(where: { $0.isDefault })
                    ?? provider.availableModels.first
            )
        }
        return TurnRouter.Inputs(
            routingMode: AppDependencies.current.app.settingsManager.settings.routingMode,
            selectedProviderID: owner.registry.activeProvider.id,
            selectedProviderIsAvailable: owner.registry.activeProvider.isAvailable,
            selectedModel: owner.registry.activeModel,
            isVoiceTurn: owner.nextSendIsVoice,
            providerOrder: owner.registry.allProviders.map(\.id),
            providers: providerStates,
            tierStage: tierStage
        )
    }

    /// Impure half of the tier stage. Runs ONLY when
    /// `TurnRouter.needsTierProposal` confirms the turn reaches tier
    /// routing (active provider is Apple, mode isn't Manual, not a
    /// voice turn) — so the side effects below fire only on turns that
    /// actually reach tier routing.
    ///
    /// Adversarial-spend cap, impure half: increment + check the
    /// daily Tier 3 counter only when this turn proposes Deep AND Deep
    /// resolves to a cloud model. A Deep turn that stays on Apple costs
    /// nothing, so it neither counts toward the cap nor gets downgraded to
    /// Auto (which could move it from the device to a cloud). The downgrade
    /// decision itself lives in `TurnRouter` (pure), keyed off this flag.
    func makeTierStageInputs(mode: RoutingMode) -> TurnRouter.TierStage? {
        guard let proposedTier = proposeTier(mode: mode) else { return nil }
        let mappings = mappingSnapshots(for: proposedTier)
        let tier3CapReached = proposedTier == .deep
            && mappings[.deep].map { $0.providerID != .apple } == true
            && !AppDependencies.current.providers.smartProviderRouter.recordTier3UsageAndCheck()
        let latestUserMessage = owner.turns.reversed().first(where: { $0.role == .user })?.text
        return TurnRouter.TierStage(
            proposedTier: proposedTier,
            tier3CapReached: tier3CapReached,
            mappings: mappings,
            messageRequiresTools: latestUserMessage.map { Self.messageRequiresTools($0) } ?? false
        )
    }

    /// The tier this turn proposes, or nil for Manual mode — which is
    /// unreachable here (`needsTierProposal` is false for it), and preserves
    /// the original switch's "unreachable, exhausted above" arm: no tier stage
    /// means `TurnRouter` returns the user's pick.
    private func proposeTier(mode: RoutingMode) -> SmartProviderRouter.Tier? {
        switch mode {
        case .quick:
            return .quick
        case .deep:
            return .deep
        case .auto:
            // Find the latest user turn — that's the one we're about
            // to answer. Walk backwards in case the assistant
            // placeholder was already appended.
            guard let message = owner.turns.reversed().first(where: { $0.role == .user })?.text else {
                return owner.sessionState.currentTier
            }
            owner.sessionState.turnCount += 1
            let routed = AppDependencies.current.providers.smartProviderRouter.route(message: message, in: owner.sessionState)
            owner.sessionState.currentTier = routed
            return routed
        case .manual:
            return nil
        }
    }

    /// Mapping snapshots for every tier this turn can resolve to:
    /// the proposal, plus `.auto` — the only downgrade target when
    /// the Tier-3 cap fires. `TierProviderMapper.mapping` is a
    /// read-only resolution, so snapshotting the extra tier has no
    /// observable effect. A mapping onto a provider switched off in Settings
    /// is replaced by Apple, so the switch stops routed traffic too.
    private func mappingSnapshots(
        for proposedTier: SmartProviderRouter.Tier
    ) -> [SmartProviderRouter.Tier: TurnRouter.MappingSnapshot] {
        var candidateTiers: [SmartProviderRouter.Tier] = [proposedTier]
        if proposedTier == .deep { candidateTiers.append(.auto) }
        var mappings: [SmartProviderRouter.Tier: TurnRouter.MappingSnapshot] = [:]
        for tier in candidateTiers {
            mappings[tier] = enabledMappingSnapshot(TierProviderMapper.mapping(for: tier, registry: owner.registry))
        }
        return mappings
    }

    private func enabledMappingSnapshot(_ mapping: TierProviderMapper.Mapping) -> TurnRouter.MappingSnapshot {
        let apple = owner.registry.apple
        guard !ProviderRegistry.isEnabled(mapping.provider.id), apple.isAvailable,
              let appleModel = apple.availableModels.first(where: { $0.isDefault }) ?? apple.availableModels.first
        else {
            return TurnRouter.MappingSnapshot(
                providerID: mapping.provider.id, model: mapping.model, collapsed: mapping.collapsed
            )
        }
        return TurnRouter.MappingSnapshot(providerID: .apple, model: appleModel, collapsed: true)
    }

    /// Translate a pure `TurnRouter.Decision` provider ID back to the
    /// live `AIProvider` instance. Prefers the active provider on an
    /// ID match so branches that historically returned
    /// `owner.registry.activeProvider` keep returning the same instance;
    /// provider classes are stateless (Apple's session cache is a
    /// static), so this is parity hygiene, not behavior.
    func liveProvider(for id: ProviderID) -> AIProvider {
        if owner.registry.activeProvider.id == id { return owner.registry.activeProvider }
        return owner.registry.allProviders.first(where: { $0.id == id }) ?? owner.registry.activeProvider
    }

    /// Whether a provider can invoke the ACTION tools (mail, contacts,
    /// directions, routes, web search). Apple gets the read-only fact
    /// catalog through `AppleFoundationToolAdapter`, but action-intent turns
    /// are still routed to a cloud provider, so Apple counts as toolless here.
    static func providerSupportsTools(_ provider: AIProvider) -> Bool {
        provider.id != .apple
    }

    /// Heuristic: does the user's message clearly require a tool call?
    /// Conservative — false negatives are fine (the model gracefully
    /// degrades to a hedged answer), but false positives would
    /// needlessly upgrade simple lookups to a paid provider. Action
    /// verbs only; nouns alone aren't enough ("about email defaults"
    /// is a settings question, not a send-email request).
    static func messageRequiresTools(_ text: String) -> Bool {
        let t = text.lowercased()
        // Compose / send mail
        if t.contains("email"), ["send", "draft", "compose", " me ", " this", " that", " to "].contains(where: t.contains) { return true }
        if ["send to my", "send this to", "send that to"].contains(where: t.contains) { return true }
        // Contacts
        if ["add contact", "save contact", "add to contacts", "remove contact", "delete contact"].contains(where: t.contains) { return true }
        // Directions / navigation
        if ["directions to", "navigate to", "take me to", "lead me", "route me to"].contains(where: t.contains) { return true }
        // Routes library
        if t.contains("save this route") || t.contains("rename") && t.contains("route") { return true }
        return mentionsWebSearch(t)
    }

    /// Broad web-search detection, for bug #10
    /// ("Web search not functioning despite being enabled with
    /// API key configured") and #18 ("Web search not available
    /// without manually switching models — unnecessary friction").
    /// Narrow patterns ("search the web", "google ") miss the
    /// common phrasing — users ask "what's the latest…" / "look
    /// up X" / "current news on Y" expecting the AI to search
    /// without saying "search the web". Apple Intelligence has
    /// no web tool; without this override the user sees Coach
    /// confidently invent answers (or hedge) for anything
    /// post-training-cutoff.
    private static func mentionsWebSearch(_ t: String) -> Bool {
        [
            "search the web", "look up online", "google ",
            "look up ", "look it up",
            "what's the latest", "whats the latest", "latest news",
            "current news", "recent news",
            "what is happening", "what's happening",
            "today's weather", "current weather", "weather forecast"
        ].contains(where: t.contains)
    }

    // MARK: - Stream dispatch

    /// Keep
    /// the reserved turn's stable id and thread THAT through the
    /// stream, resolving the live index per access. The positional
    /// index is only used as the initial hint; the id is the source
    /// of truth.
    ///
    /// Any prior in-flight stream is cancelled before the reference is
    /// replaced. Without that, rapid sends would leak background tasks that
    /// keep consuming network + tokens after their UI turn is superseded.
    func dispatch() {
        let routed = routeTurnAndLogOverride()
        let (provider, model, voiceMode) = (routed.provider, routed.model, routed.voiceMode)
        guard provider.isAvailable else {
            owner.errorMessage = AssistantViewModel.unavailableMessage(for: provider.id)
            return
        }
        guard consentGateAllowsDispatch(provider: provider, voiceMode: voiceMode) else { return }
        let turnID = reserveAssistantPlaceholderTurn(provider: provider, model: model, tier: routed.tier).id
        owner.isStreaming = true
        owner.errorMessage = nil
        owner.streamGeneration += 1
        let myGeneration = owner.streamGeneration
        owner.streamTask?.cancel()
        owner.streamTask = Task { [weak owner, provider, model] in
            await owner?.router.runDispatchedTurn(
                provider: provider, model: model, voiceMode: voiceMode,
                turnID: turnID, generation: myGeneration
            )
        }
    }

    /// The body of the dispatch task: pre-flight metrics, context + tools
    /// assembly, system-prompt composition, the stream itself, then the
    /// post-stream effects.
    ///
    /// Post-stream effects must not
    /// run for a superseded generation. If the user tapped Stop
    /// (or a newer send started) the turn we were filling is no
    /// longer current — re-sending its content to a provider
    /// (auto-fact-extraction) after Stop, or nulling a newer
    /// turn's Apple owner.registry, are both wrong. Bail on a stale
    /// generation; `cancel()` already cleared the owner.registry and
    /// the new dispatch owns it now.
    ///
    /// Release the dispatcher's strong reference
    /// to the owner.registry once the Apple-routed turn is done. Without
    /// this, `AppDependencies.current.providers.appleToolDispatcher` retains the owner.registry
    /// across cloud-routed owner.turns and defeats `DataPurgeService`.
    private func runDispatchedTurn(
        provider: AIProvider,
        model: ModelOption,
        voiceMode: Bool,
        turnID: UUID,
        generation: Int
    ) async {
        await refreshPreFlightMetrics()
        let assembled = await assembleContextAndTools(provider: provider, model: model)
        let systemPrompt = await composeSystemPromptForTurn(
            rendered: assembled.rendered, voiceMode: voiceMode, tools: assembled.tools
        )
        await runStreamWithErrorPolicy(StreamAttempt(
            provider: provider, model: model, outbound: assembled.outbound,
            systemPrompt: systemPrompt, tools: assembled.tools,
            factRegistry: assembled.factRegistry, turnID: turnID, voiceMode: voiceMode
        ))
        dropEmptyAssistantTurn(turnID)
        await owner.tools.finishStream(generation: generation)
        guard owner.streamGeneration == generation else { return }
        if provider.id == .apple { AppDependencies.current.providers.appleToolDispatcher.setRegistry(nil) }
        applyPostStreamEffects(turnID: turnID)
    }

    /// Removes the reserved assistant turn when the round ended with no text
    /// (Stop before the first token, a safety block with no parts, a round
    /// with neither text nor a tool call). An empty assistant message in the
    /// history is rejected by Anthropic and Gemini on the next send.
    private func dropEmptyAssistantTurn(_ turnID: UUID) {
        guard let index = owner.liveTurnIndex(for: turnID),
              owner.turns[index].role == .assistant,
              owner.turns[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        owner.turns.remove(at: index)
        owner.store.save(owner.turns)
    }

    // MARK: - Dispatch stages

    /// Where one turn was routed. `tier` is nil when smart routing didn't
    /// classify the turn (the user's saved provider was used as-is).
    struct TurnRoute {
        let provider: AIProvider
        let model: ModelOption
        let tier: SmartProviderRouter.Tier?
        let voiceMode: Bool
    }

    /// Everything the dispatch loop needs to make one provider call.
    /// `rendered` is empty for tool-use providers (they pull facts on demand);
    /// `factRegistry` is nil only if assembly could not build one.
    struct AssembledContext {
        let rendered: String
        let outbound: [ChatTurn]
        let tools: [ToolSpec]
        let factRegistry: FactResolverRegistry?
    }

    /// Routing stage of `dispatch()`: resolve the
    /// provider/model/tier for this turn, consume the one-shot voice
    /// flag, and log smart-routing overrides.
    ///
    /// Smart per-turn routing: when the user has
    /// turned on Settings → Flo → Smart routing AND has both Apple
    /// Intelligence available AND a paid cloud provider configured,
    /// route lookup / email / summarize tasks to Apple (free,
    /// on-device) and reasoning tasks to the user's selected cloud
    /// provider. The user's saved active provider is the
    /// SOURCE OF TRUTH for which cloud model to use; we never
    /// promote a provider they didn't configure.
    ///
    /// Surface routing overrides: if smart-routing
    /// sent the turn to a provider that isn't the user's saved
    /// active selection, log it visibly so the user (and the
    /// Troubleshooting export) can see the swap rather than
    /// silently hearing "Sonnet here" when they picked Grok.
    func routeTurnAndLogOverride() -> TurnRoute {
        let routed = resolveProviderForThisTurn()
        let voiceMode = owner.nextSendIsVoice
        owner.nextSendIsVoice = false
        let saved = AppDependencies.current.providers.providerRegistry.activeProvider
        if routed.provider.id != saved.id {
            let tierLabel = routed.tier.map { String($0.rawValue) } ?? "n/a"
            debugLog(
                "[Assistant] smart-routing override: user selected \(saved.id.rawValue), this turn routed to \(routed.provider.id.rawValue) (tier=\(tierLabel))",
                level: .warning
            )
        }
        return TurnRoute(provider: routed.provider, model: routed.model, tier: routed.tier, voiceMode: voiceMode)
    }

    /// Consent last-gate stage of `dispatch()`.
    /// Returns false (and surfaces the consent sheet) when the routed
    /// provider lacks data-sharing consent.
    /// Consent must gate the provider the turn is
    /// ACTUALLY routed to, not just the saved active provider that
    /// send() checked. Voice-mode bypass and tier routing can
    /// resolve to a DIFFERENT cloud vendor (classic hole: active =
    /// Apple, which is consent-exempt, + a cloud key on file → the
    /// early check passed and the bypass shipped HRV/sleep/location
    /// context to a never-consented provider). PrivacyInfo.xcprivacy
    /// declares chat content leaves the device only after
    /// per-provider consent via ProviderConsentSheet — enforce that
    /// here, the last gate before the network. The resolution layer
    /// now prefers consented providers, so this should rarely fire;
    /// it is the hard guarantee.
    ///
    /// Pops the user turn `send()` appended so the post-consent re-send
    /// (acknowledgeConsentAndContinue → send) doesn't duplicate it.
    func consentGateAllowsDispatch(provider: AIProvider, voiceMode: Bool) -> Bool {
        guard AppDependencies.current.providers.providerConsentTracker.requiresConsent(provider.id) else { return true }
        if let last = owner.turns.last, last.role == .user {
            owner.turns.removeLast()
            owner.pendingConsentRequest = (provider: provider.id, text: last.text, fromVoice: voiceMode)
        }
        debugLog("[Assistant] dispatch blocked — routed provider \(provider.id.rawValue) has no data-sharing consent; surfacing consent sheet", level: .warning)
        return false
    }

    /// Placeholder-reservation stage of
    /// `dispatch()`. Returns the reserved turn's index AND stable id.
    ///
    /// The reserved turn's `UUID` is exposed too. The positional `Int` is only
    /// valid at the instant of reservation — any array mutation
    /// (clearConversation `owner.turns = []`, regenerateLast `remove(at:)`,
    /// the consent-gate `removeLast()`, owner.tools.handleStreamFailure removal)
    /// shifts every later index, so a lingering stream Task would write
    /// tokens into the WRONG turn. Callers thread the id and re-resolve
    /// the live index per access via `liveTurnIndex(for:)`.
    func reserveAssistantPlaceholderTurn(
        provider: AIProvider,
        model: ModelOption,
        tier: SmartProviderRouter.Tier?
    ) -> (index: Int, id: UUID) {
        // Reserve an empty assistant turn the stream fills in.
        // Tag with `.coach` so the chat
        // bubble can render the subsystem identification chip.
        // Also stamp the routed tier so the bubble can
        // render the tier indicator (• green / • blue / • purple).
        let assistantTurn = ChatTurn(
            role: .assistant,
            text: "",
            providerID: provider.id,
            modelID: model.apiID,
            subsystem: .coach,
            routedTierRaw: tier?.rawValue
        )
        owner.turns.append(assistantTurn)
        return (owner.turns.count - 1, assistantTurn.id)
    }

    /// Resolve
    /// the live array position of a reserved assistant turn by its
    /// stable `UUID`. Returns nil when the turn has been removed
    /// (cleared conversation, regenerate, failure removal) — every
    /// stream write/read site bails on nil instead of trusting a stale
    /// positional index that may now point at a different turn.
    func liveTurnIndex(for turnID: UUID) -> Int? {
        owner.turns.firstIndex(where: { $0.id == turnID })
    }

    /// Pre-flight metrics stage of `dispatch()`.
    ///
    /// Make sure training metrics are fresh BEFORE
    /// the model gets a turn. Without this the AI reads whatever
    /// was cached on the last dashboard open — user reported
    /// "AI shows CTL 17 ATL 18, dashboard shows 24/28" because
    /// the cache sync-snapshot returns stale data and only
    /// schedules a refresh for *next* time. Awaiting a refresh
    /// here costs at most one HealthKit fetch (~100–500 ms on a
    /// warm cache, no-op when already fresh) but guarantees the
    /// tools the LLM is about to call return the same numbers
    /// the user sees on the Load page.
    ///
    /// This deliberately does NOT block on the 400-day historical series
    /// (`awaitHistoricalSeries()`). That series is built in a fire-and-forget
    /// Task detached from `refresh()` (see TrainingMetricsCache) and feeds only
    /// `training.load.by_date(…)`, a single tool that returns `notRecorded`
    /// when the series isn't ready — the model can ask again or accept the
    /// answer. Waiting for the Banister replay (1–4 s on cold launch) would
    /// hold the first network call for that one tool; the detached build
    /// continues in the background and the next send hits warm cache.
    func refreshPreFlightMetrics() async {
        await AppDependencies.current.analysis.trainingMetricsCache.refresh()
    }

    /// Context + tools assembly stage of
    /// `dispatch()`: compact-render gating, token-aware truncation
    /// (+ dropped-turn summarization), cached fact owner.registry, BM25 tool
    /// retrieval, provider tool cap, Apple dispatcher publication, and
    /// the catalog-hash stability check.
    ///
    /// The compact-render dump is gated to Apple only. Sending the
    /// ~2 K-token dump to every cloud provider on every send would:
    ///   • double the input-token tax per send (~500 ms–2 s
    ///     longer time-to-first-token)
    ///   • break Anthropic's prompt cache, since the dump contains
    ///     per-second timestamps (`snapshot_age_sec`, `Generated:`
    ///     line, live HR, etc.) that change every turn — every send
    ///     would rebuild the cache prefix
    /// Cloud providers have full tool catalog access; if they need the
    /// headline numbers they call `dashboard.summary` or equivalent. One extra
    /// tool round trip (~1 s) for the queries that need it beats paying the
    /// dump cost on every single turn.
    ///
    /// Tool-use path: Apple on-device uses the rendered-context flow;
    /// every other provider builds a Fact Catalog tool schema and the dispatch
    /// loop resolves tools locally.
    ///
    /// Perf: owner.registry + tool schema are cached on the view-model —
    /// building both on every send (25 namespace resolvers + a full tree walk
    /// for the schema) is a real hit.
    ///
    /// Apple gets the tool catalog too. The `AppleFoundationToolAdapter` +
    /// `AppleToolDispatcher` pair makes the same `[ToolSpec]` reachable from
    /// inside an iOS-26 `LanguageModelSession(tools:)`, so Apple is not forced
    /// into `supportsToolUse = false`.
    ///
    /// The closing `owner.checkCatalogHashStability` is the byte-identity debug
    /// check: hash the serialised schema per-send
    /// and warn if it drifts for reasons other than availability boundary
    /// crossings. Log-only — it doesn't fail the send — because
    /// availability-driven changes (a new month, a first workout recorded) ARE
    /// expected. A cache-miss pattern correlated with a changed hash is the
    /// diagnostic signal.
    ///
    /// Token-aware truncation: producers expect alternating user/assistant
    /// ending with user, so the empty assistant placeholder we reserved is
    /// stripped first, then the oldest owner.turns drop until we're under the
    /// per-provider token budget. Dropped owner.turns get summarized so context
    /// isn't lost — one extra short call on the active provider, only when
    /// turns not yet in the summary have fallen out of the window.
    ///
    /// `owner.factRegistryAndTools()` is synchronous — no `await` (Swift 6 warns "no
    /// async operations occur within 'await'"). It is MainActor-isolated, but
    /// we're already inside a Task started from this @MainActor view-model, so
    /// isolation is satisfied without the keyword.
    func assembleContextAndTools(
        provider: AIProvider,
        model: ModelOption
    ) async -> AssembledContext {
        let supportsToolUse = provider.id != .apple
        let rendered = supportsToolUse ? "" : await owner.contextSource.currentContext().compactRender()
        let (outbound, dropped) = AssistantViewModel.truncateForSend(Array(owner.turns.dropLast()), provider: provider.id)
        let newlyDropped = owner.unsummarizedTurns(in: dropped)
        if !newlyDropped.isEmpty {
            await owner.updateSummaryWith(droppedTurns: newlyDropped, provider: provider, model: model, contextRendered: rendered)
        }
        let (factRegistry, allTools) = self.owner.factRegistryAndTools()
        factRegistry.beginTurn()
        let tools = AssistantViewModel.trimTools(
            retrieveTools(allTools, registry: factRegistry, outbound: outbound),
            to: provider.maxToolSchemaCount
        )
        publishAppleDispatcher(provider: provider, factRegistry: factRegistry)
        await owner.checkCatalogHashStability(newHash: factRegistry.catalogHash())
        return AssembledContext(rendered: rendered, outbound: outbound, tools: tools, factRegistry: factRegistry)
    }

    /// Per-request BM25 tool retrieval (`ToolRetriever`). The tools passed
    /// in are the compact schema (`CompactToolRouter.schema`: 21 read
    /// tools plus up to 18 action tools), which is under `targetK` of 40,
    /// so the retriever returns them unchanged; it filters only if that
    /// schema grows past `targetK`. Apple Intelligence, whose window holds
    /// only a few tools, ranks this list by relevance itself before it
    /// trims it (`AppleFoundationProvider.fittingTools`).
    ///
    /// The query is the last user message plus the previous user turn, so
    /// multi-turn references ("what about the day before") match.
    ///
    /// The caller applies the provider cap after this, so a cap tighter
    /// than the schema still gets the ranked subset rather than an
    /// arbitrary slice.
    private func retrieveTools(
        _ tools: [ToolSpec],
        registry: FactResolverRegistry,
        outbound: [ChatTurn]
    ) -> [ToolSpec] {
        let lastUserText = outbound.last(where: { $0.role == .user })?.text ?? ""
        let priorUserText = outbound.dropLast().last(where: { $0.role == .user })?.text ?? ""
        let query = priorUserText.isEmpty ? lastUserText : lastUserText + " " + priorUserText
        return ToolRetriever.retrieve(
            query: query, tools: tools, targetK: 40, catalogHash: registry.catalogHash()
        )
    }

    /// When Apple is the active provider, publish the owner.registry to
    /// `AppDependencies.current.providers.appleToolDispatcher` so the `Tool` adapter handlers can resolve
    /// calls. Cleared after the stream completes (via the `defer`-equivalent
    /// at the end of the dispatch task). Cloud providers don't need this —
    /// they emit `toolUse` stream events that flow through
    /// `CompactToolRouter` at the AssistantViewModel layer.
    private func publishAppleDispatcher(provider: AIProvider, factRegistry: FactResolverRegistry) {
        guard provider.id == .apple else { return }
        AppDependencies.current.providers.appleToolDispatcher.setRegistry(factRegistry)
    }

    /// Prompt-composition stage of `dispatch()`.
    /// `toolMode` is true for any provider with a non-empty tool catalog,
    /// including Apple.
    ///
    /// The recent user messages are handed over so the composer's
    /// `UserCorrectionDetector` can identify correction signals (asserted
    /// values, dashboard contradictions, explicit override requests) and
    /// decide what to suppress / inject this turn. They're cleared afterwards
    /// so a subsequent unrelated send can't leak signals into a different
    /// conversation.
    func composeSystemPromptForTurn(
        rendered: String,
        voiceMode: Bool,
        tools: [ToolSpec]
    ) async -> String {
        AssistantSystemPrompt.pendingRecentUserMessages = owner.turns.suffix(6)
            .filter { $0.role == .user && !$0.localOnly }
            .map(\.text)
        let systemPrompt = await AssistantSystemPrompt.compose(
            userFacts: snapshotUserFacts(),
            priorSummary: owner.priorSummary,
            contextRendered: rendered,
            compactAppReference: true,
            voiceMode: voiceMode,
            toolMode: !tools.isEmpty
        )
        AssistantSystemPrompt.pendingRecentUserMessages = []
        return systemPrompt
    }

    /// Everything one provider attempt needs. Bundled because the three
    /// error-policy arms all forward the same set unchanged.
    struct StreamAttempt {
        let provider: AIProvider
        let model: ModelOption
        let outbound: [ChatTurn]
        let systemPrompt: String
        let tools: [ToolSpec]
        let factRegistry: FactResolverRegistry?
        let turnID: UUID
        let voiceMode: Bool
    }

    /// Stream-execution stage of `dispatch()`:
    /// runs the tool-use loop under the error policy
    /// (cancellation / safety refusal / fallbackable provider failure).
    ///
    /// A safety refusal (`AIProviderError.isAppleGuardrail`) is shown as the
    /// answer and never re-sent to another provider: the Foundation Models
    /// acceptable-use terms forbid circumventing the framework's guardrails.
    /// Only failures that say nothing about the content (context overflow,
    /// model unavailable, network, auth, no credit) may move on to another
    /// provider, through `handleFallbackableFailure`, as far as the routing
    /// mode allows; `AIProviderError.isFallbackable` is false for a refusal,
    /// so it cannot take that path either.
    func runStreamWithErrorPolicy(_ attempt: StreamAttempt) async {
        do {
            try await owner.tools.runToolUseLoop(
                provider: attempt.provider, model: attempt.model, outbound: attempt.outbound,
                systemPrompt: attempt.systemPrompt, tools: attempt.tools,
                factRegistry: attempt.factRegistry, turnID: attempt.turnID
            )
        } catch is CancellationError {
            // swallow-ok: cancellation is the expected outcome of the user tapping
            // stop; the partial response is kept and the streaming flag is dropped
            // by the caller.
        } catch let error as AIProviderError where error.isFallbackable {
            await handleFallbackableFailure(error, attempt: attempt)
        } catch {
            await owner.tools.handleStreamFailure(error: error, turnID: attempt.turnID)
        }
    }

    /// Generic provider-failure fallback per
    /// user spec: "if I don't have an API key or credit
    /// then it should move to the next one." Auth failures,
    /// rate limits, network errors, and "model unavailable"
    /// all qualify. Walk the configured providers in
    /// preference order (user's chosen first — already
    /// tried — then other clouds, Apple last) and try each
    /// until one succeeds. If they all fail, surface the
    /// ORIGINAL error so the user sees their chosen
    /// provider's actual problem rather than e.g. "Gemini
    /// also rejected this."
    ///
    /// Log the primary failure reason BEFORE
    /// entering the fallback chain. Without this, the
    /// debug log only shows `fallback → openai:...` and
    /// the underlying cause (Anthropic 429? auth? stream
    /// format?) is invisible. The fallback message itself
    /// logs the destination, not the source.
    ///
    /// `TurnRouter.failureFallback` decides which models may step in: none
    /// with a cloud model selected or in Manual (every turn goes to the
    /// pick, and the error says so), Apple only in Quick, any accepted
    /// model in Auto and Deep.
    private func handleFallbackableFailure(_ error: AIProviderError, attempt: StreamAttempt) async {
        let chain = TurnRouter.allowedFallbacks(
            owner.tools.orderedFallbackProviders(after: attempt.provider),
            under: TurnRouter.failureFallback(
                mode: AppDependencies.current.app.settingsManager.settings.routingMode,
                selectedProviderID: owner.registry.activeProvider.id
            )
        )
        debugLog("[Assistant] primary \(attempt.provider.id.rawValue):\(attempt.model.apiID) failed (\(error.localizedDescription)) — \(chain.count) fallback(s) allowed", level: .warning)
        guard !chain.isEmpty else {
            let failure = PickedModelFailure(providerID: attempt.provider.id, underlying: error)
            await owner.tools.handleStreamFailure(error: failure, turnID: attempt.turnID)
            return
        }
        let succeeded = await owner.tools.tryFallbacks(
            chain, outbound: attempt.outbound,
            tools: attempt.tools, factRegistry: attempt.factRegistry,
            turnID: attempt.turnID, voiceMode: attempt.voiceMode
        )
        if !succeeded { await owner.tools.handleStreamFailure(error: error, turnID: attempt.turnID) }
    }

    /// Post-stream effects stage of `dispatch()`:
    /// CoachVoiceGuard scrub + optional auto-fact extraction.
    ///
    /// Resolves the live turn position by id.
    /// Only ever invoked for the current stream generation (the caller
    /// in `dispatch()` guards on `owner.streamGeneration == myGeneration`), so
    /// auto-fact-extraction never re-sends content for a cancelled /
    /// superseded turn.
    func applyPostStreamEffects(turnID: UUID) {
        guard let assistantIndex = liveTurnIndex(for: turnID),
              !owner.turns[assistantIndex].text.isEmpty else { return }
        scrubForCoachVoice(at: assistantIndex)
        extractFactsInBackground(from: assistantIndex)
    }

    /// FDA copy perimeter: scrub the assistant's accumulated reply
    /// through CoachVoiceGuard. Replaces forbidden phrases (see-a-
    /// doctor framings, danger-zone framings, speculative diagnoses)
    /// with generic deflections before the user sees the message.
    /// Streaming has already painted the raw deltas to the UI, so
    /// we overwrite the final turn text after the stream completes.
    ///
    /// Audit trail: the reason is public for telemetry; the original
    /// sentence stays private (it may carry user-specific physiological
    /// context).
    /// This is the LAST of three passes, not the
    /// only one. `StreamTextBuffer.flush` scrubs each sentence before it
    /// becomes visible and `VoiceConversationController.speak` scrubs every
    /// utterance; this whole-message pass remains for text that never went
    /// through the streaming buffer (a non-streaming provider, a canned turn,
    /// a regenerated message) and as a cheap invariant check. In the normal
    /// streaming case it finds nothing, which is the point.
    private func scrubForCoachVoice(at index: Int) {
        guard CoachVoiceGuard.containsProhibitedLanguage(owner.turns[index].text) else { return }
        let result = CoachVoiceGuard.scrub(owner.turns[index].text)
        guard result.didIntercept else { return }
        owner.turns[index].text = result.scrubbed
        for trigger in result.triggers {
            recordCoachVoiceInterception(reason: trigger.reason)
        }
    }

    /// Audit trail for a perimeter interception.
    ///
    /// The reason is `%{public}` because it names a rule, never user text; the
    /// matched sentence stays out of the log entirely because it carries the
    /// user's physiological context. Same contract the previous inline call had.
    func recordCoachVoiceInterception(reason: String) {
        os_log(
            "CoachVoiceGuard intercepted: %{public}@",
            log: OSLog(subsystem: "com.flow.recovery", category: "assistant"),
            type: .info,
            reason
        )
    }

    /// Optional: run cross-session memory extraction in the background
    /// after the visible response completes.
    private func extractFactsInBackground(from assistantIndex: Int) {
        guard owner.factsStore.autoExtractEnabled, assistantIndex >= 1 else { return }
        let userTurn = owner.turns[assistantIndex - 1]
        guard userTurn.role == .user else { return }
        let assistantText = owner.turns[assistantIndex].text
        Task.detached(priority: .background) {
            await self.owner.runAutoFactExtraction(userText: userTurn.text, assistantText: assistantText)
        }
    }

    func snapshotUserFacts() async -> String {
        owner.factsStore.systemPromptBlock()
    }
}
