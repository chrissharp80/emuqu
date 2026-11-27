import Combine
import Foundation
import os.log
import SwiftUI

/// Owns the chat conversation, dispatches streaming sends to the active
/// `AIProvider`, and exposes published state to the chat view.
///
/// Narrow observable surface for the chat input bar.
/// See doc on AssistantViewModel.composerState for context. Update
/// only happens when isStreaming toggles or keys change, so streaming
/// tokens don't trigger input-bar re-renders.
@Observable
@MainActor
final class ComposerState {
    var canSend: Bool = false

    /// Update only if the value actually changes. Without this guard
    /// the observable would still publish on identical values
    /// (an `@Observable` property notifies on every assignment, equal
    /// or not), defeating the optimization.
    func update(canSend newValue: Bool) {
        if canSend != newValue { canSend = newValue }
    }

    /// A typed message that was held for the provider consent sheet and
    /// then declined. The input bar puts it back into the field and clears
    /// this, so declining the sheet doesn't throw away what the user wrote.
    var returnedDraft: String?
}

/// Shared singleton — both the typed chat view AND the voice layer consume
/// the same instance so a voice turn lands in the same thread as a typed
/// turn, using the same provider, same history, same context.
@Observable
@MainActor
final class AssistantViewModel: ToolRunnerHost, TurnRouterHost {

    // MARK: - Published state

    var turns: [ChatTurn] = []
    var isStreaming = false {
        didSet { composerState.update(canSend: !isStreaming && registry.activeProviderAvailable) }
    }
    var errorMessage: String?
    /// Destructive tool calls waiting for the user's yes in this conversation.
    let actionConfirmations = AssistantActionConfirmations()

    /// Narrow observable surface for the chat
    /// input bar. If the bar observed the full
    /// AssistantViewModel directly, EVERY
    /// observable change on the VM (including each streaming token's
    /// `turns` mutation) re-ran the input bar's body. With 50–200
    /// tokens per response, that's a re-render storm that saturates
    /// the main run loop and makes the keyboard feel stuck.
    ///
    /// The composer state publishes only what the bar actually
    /// renders against (canSend right now; can grow if other narrow
    /// fields surface). Streaming tokens DON'T touch this object —
    /// only `isStreaming` toggling at start/end and `keysChanged`
    /// updates do. So the input bar's body re-runs ~2× per
    /// conversation rather than ~200× per response.
    let composerState = ComposerState()
    /// Combine subscriptions held for the VM's lifetime — currently
    /// the registry availability subscription that drives composer
    /// state updates. Stored on the instance so the sink stays
    /// active while the VM is alive (singleton: process lifetime).
    @ObservationIgnored var composerStateObservation: ObservationHandle?

    /// Per-turn safe-to-speak cursor keyed by turn ID. Voice TTS reads only
    /// up to `speakableTextCursor[turn.id]` characters of the turn's text;
    /// characters past that may still be revised or discarded if a tool_use
    /// block arrives in the current round. The cursor advances at the end of
    /// a round that emitted text and NO tool_use, and — for voice latency —
    /// mid-stream at each published sentence until the round's first tool_use
    /// arrives (`StreamTextBuffer.flush`). A sentence spoken that way can turn
    /// out to precede a tool call; `StreamTextBuffer.rewindToRoundStart` then
    /// pulls the cursor back with the text and the voice controller re-syncs
    /// its own spoken position, so the next round is spoken from its start.
    ///
    /// Chat UI still sees text stream live (it reads `turns[idx].text`); only
    /// TTS waits for this cursor to avoid speaking lines the model then
    /// superseded by calling a tool instead.
    var speakableTextCursor: [UUID: Int] = [:]

    /// Cumulative summary of turns that have been dropped from the send window.
    /// Prepended to the system prompt of every send so the model retains context
    /// past the truncation boundary. Persisted sealed beside the history
    /// (`ConversationStore.saveSummary`): it restates the same conversation,
    /// injuries and medications included.
    var priorSummary: String?

    /// The newest dropped turn already folded into `priorSummary`. Only turns
    /// dropped after it are summarised, so an over-budget history does not
    /// trigger a summary call on every send. A summary that failed or timed
    /// out leaves it where it was, so the next send tries those turns again.
    /// In memory only: after a relaunch
    /// the first over-budget send folds the dropped turns once more.
    @ObservationIgnored var summarizedThroughTurnID: UUID?

    /// First-run disclaimer acceptance — stored in UserDefaults so it persists
    /// across launches but isn't synced to iCloud.
    var hasAcceptedDisclaimer: Bool {
        didSet {
            UserDefaults.standard.set(hasAcceptedDisclaimer, forKey: Self.disclaimerKey)
        }
    }

    // UserDefaults keys are compile-time-constant strings — `nonisolated`
    // so a background Task can read them without hopping to MainActor just
    // to grab a string.
    nonisolated static let disclaimerKey = "assistant.disclaimerAccepted"
    /// Where builds before the sealed summary file kept the summary, in plain
    /// text. Read once to move it into the file, then removed.
    nonisolated static let summaryKey = "assistant.priorSummary"

    // MARK: - Dependencies

    /// Every service the view model, its router and its tool runner read.
    let services: ChatServices
    let registry: ProviderRegistry

    /// Exposed for the
    /// voice-session preamble that names the model handling this
    /// session. Read-only; mutation still goes through `setProvider`
    /// / `setModel`.
    var activeProviderID: ProviderID { registry.activeProvider.id }
    var activeModelDisplayName: String { registry.activeModel.displayName }
    let store: ConversationStore
    let contextSource: AssistantContextSource
    let factsStore: UserFactsStore

    /// Per-conversation routing state. Tracks the
    /// currently-locked tier and the turn count (for the 3-turn settling
    /// window). Reset by `clearConversation()`.
    let sessionState = RoutingSessionState()

    @ObservationIgnored var streamTask: Task<Void, Never>?

    /// The reply the stream task is filling and the provider writing it,
    /// which a fallback changes. Set when the stream starts and by each
    /// attempt; cleared by `cancel()` and `finishStream`.
    @ObservationIgnored var streamingTurn: StreamingTurn?

    struct StreamingTurn: Equatable {
        let turnID: UUID
        let provider: ProviderID
    }

    /// Pending text to send the moment the current stream finishes. Set
    /// when `send(text:)` is called while `isStreaming == true` so the
    /// user's message isn't silently dropped — common with voice mode where
    /// the user might finish a follow-up question while the prior response
    /// is still wrapping up. Drained at the end of `finishStream` and
    /// cleared by `cancel()` / `clearConversation()`.
    var pendingSendOnFinish: (text: String, fromVoice: Bool)?

    /// Monotonic identifier for each in-flight stream. `dispatch()` bumps
    /// it before launching the task; `finishStream()` checks it before
    /// touching shared state. Without this guard, an OLD stream's
    /// `finishStream` (running after a user-cancel + immediate new send)
    /// would trample the NEW stream's `streamTask` / `isStreaming` and
    /// break the UI's send button. Voice mode chains turns rapidly
    /// enough to hit this.
    var streamGeneration: Int = 0

    /// The fact registry and its tool schema, built once. Building them
    /// allocates every namespace and its entries on the main actor, and
    /// neither changes between sends: entries read the settings and services
    /// they were handed each time they resolve. `invalidateFactRegistry()`
    /// drops both.
    var cachedFactRegistry: FactResolverRegistry?
    var cachedFactTools: [ToolSpec]?

    func factRegistryAndTools() -> (FactResolverRegistry, [ToolSpec]) {
        if let registry = cachedFactRegistry, let tools = cachedFactTools {
            return (registry, tools)
        }
        let registry = AppFactResolverFactory.build(
            archive: services.sessionArchive,
            settings: { [services] in services.settingsManager.settingsSnapshot },
            services: services.facts
        )
        // CompactToolRouter exposes 22 read tools + up to 20 action
        // tools instead of one tool per fact-catalog entry (~212).
        // The model picks fewer, well-described tools; the underlying
        // resolvers stay granular. See CompactToolRouter.swift.
        let tools = CompactToolRouter.schema(registry: registry)
        cachedFactRegistry = registry
        cachedFactTools = tools
        return (registry, tools)
    }

    /// Drops the cached registry so the next dispatch rebuilds. Called by
    /// the "Refresh data context" menu action (`invalidateContext()`) and
    /// whenever the session archive changes.
    fileprivate func invalidateFactRegistry() {
        cachedFactRegistry = nil
        cachedFactTools = nil
    }

    /// Cap `tools` at a provider's schema limit (`maxToolSchemaCount`) by
    /// keeping the first `cap` entries, in `ToolRetriever`'s order (ranked by
    /// relevance once the schema outgrows the retriever's target). When `cap`
    /// is nil or `tools.count <= cap`, returns the input unchanged — the
    /// compact schema (22 read tools plus up to 20 action tools) is under
    /// every provider's cap.
    static func trimTools(_ tools: [ToolSpec], to cap: Int?) -> [ToolSpec] {
        guard let cap, tools.count > cap, cap > 0 else { return tools }
        return Array(tools.prefix(cap))
    }

    // MARK: - Init

    /// AFM prewarm is DEFERRED to first send, deliberately absent here.
    ///
    /// Prewarming in init, the moment the user opens the chat tab, contends
    /// with iOS 26's keyboard, which most likely wants the same Apple
    /// Intelligence model: even at .utility priority, holding a
    /// `LanguageModelSession` competes with the keyboard's inline-prediction
    /// subsystem, and the first tap on the input can wait as long as 18 s for
    /// `keyboard.willShow`.
    ///
    /// Prewarming right before the first send still makes the first AI
    /// message snappy: the prewarm has the ~5-30 s the user spends typing to
    /// load the KV-cache. A user who sends within a second pays the prewarm
    /// cost on that first message, which is strictly better than every user
    /// paying it on first focus, every session.
    ///
    /// The stores default to the ones in `services`; a test hands in its own.
    init(
        services: ChatServices,
        registry: ProviderRegistry? = nil,
        store: ConversationStore? = nil,
        contextSource: AssistantContextSource? = nil,
        factsStore: UserFactsStore? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.services = services
        let resolvedRegistry = registry ?? services.providerRegistry
        self.registry = resolvedRegistry
        let store = store ?? services.conversationStore
        self.store = store
        self.contextSource = contextSource ?? services.assistantContextSource
        self.factsStore = factsStore ?? services.userFactsStore
        self.notificationCenter = notificationCenter
        turns = store.load()
        hasAcceptedDisclaimer = UserDefaults.standard.bool(forKey: Self.disclaimerKey)
        priorSummary = store.loadSummary(migratingFrom: UserDefaults.standard, key: Self.summaryKey)
        // A chat export shared in an earlier run is not needed any more.
        Self.removeChatExports()
        wireArchiveInvalidation()
        wireProtectedDataRecovery()
        wireComposerState(resolvedRegistry)
        wireConsentWithdrawal()
    }

    /// Withdrawing a provider's data-sharing consent, or switching the AI
    /// Assistant off, stops the turn being streamed at once, as the Settings
    /// footer promises: the next request would be refused anyway, and this
    /// also stops the reply still arriving and any tool call not yet made.
    private func wireConsentWithdrawal() {
        consentObservation = ObservationLoop.observe(self, read: { $0.services.providerConsentTracker.acknowledgedProviders }, onChange: { vm, _ in
            vm.stopTurnIfSharingWasWithdrawn()
        })
        assistantSwitchObservation = ObservationLoop.observe(self, read: { $0.services.settingsManager.settings.enableAIAssistant }, onChange: { vm, _ in
            vm.stopTurnIfSharingWasWithdrawn()
        })
    }

    /// Stops the streaming turn when its provider no longer has consent, or
    /// the AI Assistant was switched off. The stream ends as Stop ends it;
    /// the text already shown stays, marked incomplete so the next request
    /// leaves it out, and the banner says sharing with that provider is off.
    func stopTurnIfSharingWasWithdrawn() {
        guard isStreaming, let streaming = streamingTurn,
              services.providerConsentTracker.requiresConsent(streaming.provider)
                || !services.settingsManager.settings.enableAIAssistant else { return }
        debugLog("[Assistant] sharing with \(streaming.provider.rawValue) withdrawn mid-turn; stopping the turn", level: .warning)
        cancel()
        tools.handleStreamFailure(error: AIProviderError.consentWithdrawn(streaming.provider), turnID: streaming.turnID)
    }

    @ObservationIgnored private var consentObservation: ObservationHandle?
    @ObservationIgnored private var assistantSwitchObservation: ObservationHandle?

    /// The history, the summary and the remembered facts cannot be read while
    /// the phone is locked. When this view model was created in that state,
    /// all started empty; the stores hold their writes until they can merge,
    /// and this puts the full history and the summary back the moment the
    /// phone is unlocked.
    private func wireProtectedDataRecovery() {
        unlockObservers.observeProtectedDataMayBeAvailable { [weak self] in self?.scheduleRecoveryAfterUnlock() }
    }

    /// Notification callbacks arrive off the main actor; the recovery runs on it.
    nonisolated private func scheduleRecoveryAfterUnlock() {
        Task { @MainActor [weak self] in
            self?.recoverAfterUnlock()
        }
    }

    /// The summary is read again only while none is held and the store says
    /// the sealed one was unreadable, so a summary written since, or a
    /// cleared conversation, is never replaced.
    private func recoverAfterUnlock() {
        factsStore.recoverAfterUnlock()
        if priorSummary == nil, store.summaryNeedsReload {
            priorSummary = store.loadSummary(migratingFrom: UserDefaults.standard, key: Self.summaryKey)
        }
        guard store.needsReloadFromDisk, let merged = store.mergedWithDisk(turns, acknowledging: true) else { return }
        turns = merged
        store.save(turns)
    }

    /// Seeds composer state once at init. Subsequent updates fire
    /// from `isStreaming.didSet` and from observing the registry's availability
    /// cache, so the composer state updates when the user adds/removes a key.
    private func wireComposerState(_ registry: ProviderRegistry) {
        composerState.update(canSend: !isStreaming && registry.activeProviderAvailable)
        composerStateObservation = ObservationLoop.observe(self, read: { _ in registry.activeProviderAvailable }, onChange: { vm, available in
            vm.composerState.update(canSend: !vm.isStreaming && available)
        })
    }

    /// When the archive mutates (new workout
    /// accepted, session reanalyzed, sleep boundary edited) the cached
    /// fact registry's availability snapshot is stale and the AI sees
    /// an outdated catalog — workouts recorded after chat-open never
    /// surface until the user manually taps "Refresh data context".
    /// Listening for the archive notification posts the same
    /// invalidation automatically. The next send rebuilds the registry
    /// fresh against the live archive.
    private func wireArchiveInvalidation() {
        // `queue: nil`, not `.main`. A non-nil queue makes
        // `post` block the posting thread until the block finishes on that queue.
        // Archive writes post from background threads, so `.main` adds a
        // synchronous main-queue round-trip to every write (and deadlocks when
        // main was itself waiting on those writes). This block only schedules a
        // `Task { @MainActor }`, so running it on the posting thread is
        // equivalent — minus the blocking wait. See `ArchiveSignal.init`.
        //
        // The token is kept in `archiveObservers` and removed in `deinit`.
        archiveObservers.add(notificationCenter.addObserver(
            forName: .flowRecoveryArchiveChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.invalidateFactRegistry()
            }
        })
    }

    // Cancel any in-flight stream when this VM is torn
    // down (process tear-down or hot-reload). `Task.cancel()` is
    // nonisolated and Sendable so it's safe to call from deinit. Without this,
    // an orphan stream task could keep referencing `self` after release.
    deinit {
        streamTask?.cancel()
        unlockObservers.removeAll()
        archiveObservers.removeAll(from: notificationCenter)
    }

    /// The protected-data observers `wireProtectedDataRecovery` installs.
    @ObservationIgnored private let unlockObservers = NotificationTokens()
    /// The archive observer `wireArchiveInvalidation` installs, on
    /// `notificationCenter`.
    @ObservationIgnored private let archiveObservers = NotificationTokens()
    @ObservationIgnored private let notificationCenter: NotificationCenter

    // MARK: - Public API

    /// Whether anything may go to a model: the AI Assistant switch is on and
    /// the AI notice has been accepted. The Flo tab and Get Me Back ask for
    /// the notice first; the workout screen's voice bar and the coach's
    /// automatic check-ins reach the model without a screen of their own, so
    /// the check sits on the way out.
    static func aiIsAllowed(disclaimerAccepted: Bool, settings: UserSettings) -> Bool {
        disclaimerAccepted && settings.enableAIAssistant
    }

    /// Outcome of a `send(text:)` call. Lets callers (the voice controller
    /// in particular) tell apart "accepted, processing now" / "accepted,
    /// queued behind the in-flight stream" / "rejected" without poking at
    /// internal state. Voice's "did my message get lost?" guard fires on
    /// `.rejected` only — `.queued` is success, just deferred.
    enum SendOutcome {
        case dispatched    // user turn appended, stream kicked off
        case queued        // stream in flight, send will fire on finishStream
        case rejectedEmpty // input was whitespace
        case rejectedNoProvider
        /// Provider needs first-time PHI/PII sharing consent. The view
        /// should present `ProviderConsentSheet(provider:)`; on accept,
        /// call `acknowledgeProviderConsentAndSend(provider:text:fromVoice:)`.
        case requiresConsent(ProviderID)
    }

    /// Pending message awaiting per-provider consent. The view owns the
    /// presentation; this view-model just holds the text + voice flag so
    /// the user doesn't have to retype after accepting the sheet.
    /// `regenerate` marks a request held by `regenerateLast()`: accepting
    /// re-runs the regeneration instead of sending `text` as a new message.
    var pendingConsentRequest: PendingConsentRequest?

    struct PendingConsentRequest {
        let provider: ProviderID
        let text: String
        let fromVoice: Bool
        let regenerate: Bool
    }

    /// Send a free-form user message. `fromVoice` flags the next dispatch()
    /// so the system prompt includes the voice overlay (1–3 sentences, no
    /// headers, no lists). The flag is consumed per-send; the next typed
    /// turn reverts to the full persona.
    ///
    /// Keyboard-perf marker. The entry signpost anchors the
    /// trace to the first character commit (when the user types one
    /// character then taps Send, or when the prefab/voice path dispatches).
    /// The hand-off prompt asked us to measure the synchronous prefix
    /// specifically — the work below up to `dispatch()` is what the user
    /// feels as "the keyboard hangs again on first character."
    ///
    /// Provider-unavailable is a hard fail (no key) — surfaced rather than
    /// silently dropped. Queueing wouldn't help: the next `finishStream` hits
    /// the same wall.
    ///
    /// Third-party providers must have explicit
    /// per-provider consent before their first PHI/PII payload leaves
    /// the device. Apple Intelligence is on-device and exempt; the
    /// five hosted providers each prompt once. A voice question the
    /// deterministic shortcut answers on the device needs no consent, so
    /// that shortcut runs before the consent check.
    @discardableResult
    func send(text: String, fromVoice: Bool = false) -> SendOutcome {
        services.keyboardPerfSignpost.event("AssistantViewModel.send.entry")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejectedEmpty }
        if !answersWhileFloIsOff(trimmed), refusedWhileFloIsOff() { return .rejectedNoProvider }
        if medicalGuardRefused(trimmed) { return .dispatched }
        guard registry.canSend(to: registry.activeProvider) else {
            errorMessage = Self.unavailableMessage(for: registry.activeProvider.id, in: registry)
            return .rejectedNoProvider
        }
        if fromVoice, !isStreaming, servedDeterministically(trimmed) { return .dispatched }
        let activeProvider = registry.activeProvider.id
        if services.providerConsentTracker.requiresConsent(activeProvider) {
            pendingConsentRequest = PendingConsentRequest(provider: activeProvider, text: trimmed, fromVoice: fromVoice, regenerate: false)
            return .requiresConsent(activeProvider)
        }
        if isStreaming { return queueBehindStream(trimmed, fromVoice: fromVoice) }
        dispatchToProvider(trimmed, fromVoice: fromVoice)
        return .dispatched
    }

    /// Why a provider can't take a message: a cloud provider switched off in
    /// Settings or without a key, or Apple Intelligence, which has no key and
    /// is unavailable on this device (unsupported, turned off, or its model
    /// not downloaded yet).
    static func unavailableMessage(for id: ProviderID, in registry: ProviderRegistry) -> String {
        let bundle = LanguageManager.appBundle
        if id == .apple {
            return String(localized: "Apple Intelligence isn't available on this device right now. Choose another model in Settings → Flo.", bundle: bundle)
        }
        if !registry.isEnabled(id) {
            return String(localized: "\(id.displayName) is switched off. Turn it on or choose another model in Settings → Flo.", bundle: bundle)
        }
        return String(localized: "\(id.displayName) has no API key configured. Add one in Settings → Flo.", bundle: bundle)
    }

    /// AFib / arrhythmia / symptom queries are
    /// refused locally without ever reaching the LLM. The system prompt
    /// (AIProvider.swift base section "MEDICAL BOUNDARY") tells the
    /// model to do the same; this guard is the second leg — it works
    /// even when the prompt is ignored, truncated, or jailbroken, and
    /// it guarantees no PHI leaves the device for an off-topic query.
    ///
    /// Gated behind `FeatureFlags.medicalGuardEnabled`, which defaults on and
    /// which nothing in the app switches off: turning the guard off means
    /// shipping a build whose default is `false`. The system-prompt boundary
    /// applies either way. The self-harm reply is not behind the flag: no
    /// case justifies a person in crisis getting a model's answer instead of
    /// a crisis line.
    private func medicalGuardRefused(_ trimmed: String) -> Bool {
        let guardEnabled = services.featureFlags.value(for: .medicalGuardEnabled)
        guard guardEnabled || MedicalQueryGuard.classify(trimmed) == .selfHarm,
              case .refuse(let reply) = MedicalQueryGuard.evaluate(trimmed) else { return false }
        appendExchange(user: trimmed, assistant: reply, localOnly: true)
        debugLog("[Assistant] medical-query guard fired — refusing locally without provider call")
        return true
    }

    /// If a stream is in flight, queue the send rather than drop it. The
    /// user (or voice controller) gave us a real message, and it must not be
    /// lost just because the previous turn hasn't quite finished.
    /// `finishStream()` drains the queue. Latest-wins:
    /// multiple rapid sends collapse to the most recent — voice users
    /// don't want answers to questions they asked 30 seconds ago.
    private func queueBehindStream(_ trimmed: String, fromVoice: Bool) -> SendOutcome {
        pendingSendOnFinish = (text: trimmed, fromVoice: fromVoice)
        debugLog("[Assistant] send queued (mid-stream): \(trimmed.count) chars (fromVoice=\(fromVoice))")
        return .queued
    }

    /// Deterministic
    /// intent shortcut. ~30–50% of voice turns repeat a small set
    /// of factual lookups ("recovery score?", "RHR?", "how did I
    /// sleep?") that don't need an LLM. `DeterministicIntent.tryMatch`
    /// returns nil to fall through to the LLM (the safe default);
    /// a non-nil string means one of its narrow, hand-authored patterns
    /// matched AND the underlying fact is available right now. Stays
    /// on-device, costs $0, runs in <50 ms.
    ///
    /// Voice-only by design — text chat goes through the full LLM
    /// path because users typing tend to ask multi-part questions
    /// that the deterministic path would over-truncate.
    /// `DeterministicIntentTests` checks the patterns with example-based
    /// assertions; there is no measured precision gate. Not used while a
    /// stream is in flight: the voice send queues behind it instead, so the
    /// answer lands after the reply it follows.
    private func servedDeterministically(_ trimmed: String) -> Bool {
        let context = DeterministicIntent.MatchContext(
            now: Date(),
            archive: services.sessionArchive,
            userSettings: services.settingsManager.settings,
            liveWorkout: services.liveWorkoutBroker.currentSnapshot()
        )
        guard let answer = DeterministicIntent.tryMatch(trimmed, in: context) else { return false }
        appendExchange(user: trimmed, assistant: answer)
        debugLog("[Assistant] deterministic-intent hit — served at $0, no LLM call")
        return true
    }

    /// Append a complete user/assistant pair and persist it. Used by the two
    /// paths that answer without a provider call. `localOnly` marks both halves
    /// as never eligible to leave the device — see `ChatTurn.localOnly`.
    private func appendExchange(user: String, assistant: String, localOnly: Bool = false) {
        turns.append(ChatTurn(role: .user, text: user, localOnly: localOnly))
        turns.append(ChatTurn(role: .assistant, text: assistant, subsystem: .coach, localOnly: localOnly))
        store.save(turns)
    }

    /// AFM prewarm lives here, not in init (see the init note). Idempotent,
    /// detached at .utility, so this only kicks off the load on
    /// first send of the session. Only with Apple Intelligence selected and
    /// outside Deep: a cloud pick always answers with that cloud
    /// (`TurnRouter`), so loading the on-device model would only contend
    /// with the keyboard. By the time the LLM call
    /// actually fires (after fact-registry build + system prompt
    /// composition, ~50-200 ms) the model is partway loaded.
    /// Apple's `prewarm()` returns immediately and warms in the
    /// background. See AppleFoundationProvider.prewarm().
    private func dispatchToProvider(_ trimmed: String, fromVoice: Bool) {
        turns.append(ChatTurn(role: .user, text: trimmed))
        store.save(turns)
        nextSendIsVoice = fromVoice
        let mode = services.settingsManager.settings.routingMode
        if registry.activeProvider.id == .apple, mode != .deep {
            AppleFoundationProvider.prewarm()
        }
        services.keyboardPerfSignpost.event("AssistantViewModel.send.beforeDispatch")
        router.dispatch()
    }

    /// A message the guard answers with the emergency number gets the app's
    /// own reply even while Flo is off: that reply never reaches a model, and
    /// "Flo is off" is no answer to someone in crisis or hurt.
    private func answersWhileFloIsOff(_ trimmed: String) -> Bool {
        MedicalQueryGuard.classify(trimmed)?.namesEmergencyNumber == true
    }

    /// True, with the reason shown, when Flo is switched off or its notice
    /// hasn't been accepted (see `aiIsAllowed`).
    private func refusedWhileFloIsOff() -> Bool {
        guard !Self.aiIsAllowed(disclaimerAccepted: hasAcceptedDisclaimer, settings: services.settingsManager.settings) else { return false }
        errorMessage = String(localized: "Flo is off, or its notice hasn't been accepted yet. Open the Flo tab to turn it on.", bundle: LanguageManager.appBundle)
        return true
    }

    /// Send one of the pre-fab questions.
    func send(prefab question: PrefabQuestion) {
        send(text: question.prompt)
    }

    /// Called by the per-provider consent sheet when the user accepts.
    /// Records the acknowledgement and re-issues the pending send, or the
    /// pending regeneration.
    @discardableResult
    func acknowledgeConsentAndContinue() -> SendOutcome {
        guard let pending = pendingConsentRequest else { return .rejectedEmpty }
        services.providerConsentTracker.acknowledge(pending.provider)
        pendingConsentRequest = nil
        guard !pending.regenerate else {
            regenerateLast()
            return .dispatched
        }
        return send(text: pending.text, fromVoice: pending.fromVoice)
    }

    /// Called by the per-provider consent sheet when the user declines.
    /// Drops the pending message, hands a typed one back to the input bar
    /// (`ComposerState.returnedDraft`), and surfaces an info-level error so
    /// the user knows nothing was sent. A declined regeneration changed
    /// nothing (the previous reply is still in place), so there is no draft
    /// to hand back. A voice message is not put in the input bar: the user
    /// spoke it and declined to share it.
    ///
    /// No-op when nothing is pending: dismissing the sheet after Accept
    /// writes nil through the sheet's item binding, which lands here after
    /// the message has already been sent.
    func cancelPendingConsent() {
        guard let pending = pendingConsentRequest else { return }
        pendingConsentRequest = nil
        if !pending.fromVoice, !pending.regenerate { composerState.returnedDraft = pending.text }
        errorMessage = String(localized: "Message not sent — you must agree to share data with this provider before its first message.", bundle: LanguageManager.appBundle)
    }

    /// One-shot voice flag consumed by the next `dispatch()`. Set by
    /// VoiceConversationController before its send(); cleared inside dispatch.
    var nextSendIsVoice = false

    /// Last observed catalog schema hash. Used by
    /// `checkCatalogHashStability` to log warnings when the cacheable
    /// prefix changes unexpectedly. Purely diagnostic.
    var lastCatalogHash: String?

    /// Byte-identity check on the cacheable prefix, in every build (not
    /// only Debug); drift is logged as a warning. When the
    /// schema hash changes turn-to-turn, it means SOMETHING in the tool
    /// catalog shifted — usually benign (availability range crossed a
    /// month boundary, a new session was recorded bumping hasData for an
    /// entry), but occasionally a real bug (non-deterministic encoding,
    /// stale metadata source, a per-request field leaking in). Every
    /// drift event is logged with both hashes so we can correlate with
    /// cache-hit telemetry dips.
    func checkCatalogHashStability(newHash: String) async {
        defer { lastCatalogHash = newHash }
        guard let previous = lastCatalogHash else {
            debugLog("[Assistant] catalog hash initialised: \(String(newHash.prefix(12)))")
            return
        }
        guard previous != newHash else { return }
        debugLog("[Assistant] catalog hash changed \(String(previous.prefix(12))) → \(String(newHash.prefix(12))) — cache invalidation expected this turn", level: .warning)
    }

    /// Stop the in-flight stream. Any partial assistant text is kept.
    /// Drops the in-flight task reference AND flips `isStreaming` immediately
    /// so the UI re-enables (Send button, text field) the moment the user taps
    /// Stop or Clear — the network stream may take a second to tear down,
    /// which otherwise makes both buttons feel sluggish.
    ///
    /// Also tears down voice TTS if it's mid-utterance. Without this, Stop
    /// cancels the LLM but the synthesizer keeps reading whatever it had
    /// already buffered — the user taps Stop and the AI keeps talking.
    func cancel() {
        // Bump the generation BEFORE cancelling so the cancelled task's
        // eventual `finishStream` no-ops instead of trampling state for
        // any new send the user kicks off in the meantime.
        streamGeneration += 1
        streamTask?.cancel()
        streamTask = nil
        streamingTurn = nil
        isStreaming = false
        // Drop any queued pending message — user explicitly hit Stop.
        pendingSendOnFinish = nil
        // Drop the Apple dispatcher's strong ref
        // immediately on cancel so a stop-button tap during an Apple
        // turn doesn't leave the registry retained until the next send.
        services.appleToolDispatcher.setRegistry(nil)
        services.voiceConversationController.stopAnyOngoingSpeech()
    }

    /// Chat-bar dismiss for the error banner. Lets
    /// the user acknowledge a surfaced error (out of credits, 401,
    /// network) without nuking the whole conversation.
    func clearError() {
        errorMessage = nil
    }

    /// Wipe the conversation and start over. Does not affect API keys or settings.
    ///
    /// The streaming turn is stopped first, then the history file, its
    /// set-aside copies and the chat exports are erased. Only when all of them
    /// are gone does the screen clear, along with the summary, the routing
    /// state and the prompt audit (which quotes the chat). Otherwise the
    /// thread stays on screen with an error, so nothing claims a wipe that did
    /// not happen, and Clear can be tried again.
    func clearConversation() {
        cancel()
        factsStore.discardPendingExtractions()
        let historyErased = store.clear()
        let exportsErased = Self.removeChatExports()
        guard historyErased, exportsErased else {
            errorMessage = String(localized: "The conversation couldn't be fully erased. Try again.", bundle: LanguageManager.appBundle)
            return
        }
        resetConversationState()
        services.llmRequestAudit.clear()
        // The summary file went with the history (`ConversationStore.clear`);
        // this is the plain copy an older build left, if it was never moved.
        // UserDefaults writes block on synchronous disk sync — push off main.
        Task.detached(priority: .utility) {
            UserDefaults.standard.removeObject(forKey: Self.summaryKey)
        }
    }

    /// The in-memory side of a cleared conversation: turns, error, held
    /// consent request, summary and its anchor, speech cursors, the
    /// adaptive-routing session (a new conversation is classified afresh), and
    /// the number corrections waiting for the next prompt, which are about
    /// replies in the conversation just cleared.
    private func resetConversationState() {
        turns = []
        errorMessage = nil
        pendingConsentRequest = nil
        priorSummary = nil
        summarizedThroughTurnID = nil
        speakableTextCursor = [:]
        sessionState.currentTier = .quick
        sessionState.turnCount = 0
        MetricsVerifier.clearCorrections()
    }

    /// Serialize the current thread to Markdown and return a temporary file URL
    /// for sharing. Synchronous and on-main by design — a chat thread is tens
    /// of KB at most, so the write takes sub-millisecond. The point is to make
    /// the URL available at the moment `ShareLink` is instantiated so the
    /// native share sheet opens instantly instead of the UIActivityViewController
    /// cold-start path, which can hang 1–2 seconds (and up to a minute when
    /// the extension scan is cold — see shareRow in FitnessTabView).
    ///
    /// Earlier exports are deleted first, so at most one copy of the chat
    /// sits in the temporary directory; `clearConversation()` deletes that one,
    /// and the next launch deletes any left behind (`init`). The share target
    /// has to read the file, so it cannot be sealed with the app's key; it is
    /// written with complete file protection instead, unreadable whenever the
    /// phone is locked. It holds the whole thread, including the turns that
    /// never left the device.
    func exportConversation() -> URL? {
        guard !turns.isEmpty else { return nil }
        Self.removeChatExports()
        let filename = "\(Self.chatExportPrefix)\(Int(Date().timeIntervalSince1970)).md"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try Data(conversationMarkdown().utf8).write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            // Log the write error rather than swallowing it: a silent
            // failure leaves the ShareLink UI with no reason the
            // export produced no file.
            debugLog("[Assistant] exportConversation write failed: \(error.localizedDescription)", level: .warning)
            return nil
        }
    }

    private static let chatExportPrefix = "EmuquChat-"

    /// Delete every chat export (`EmuquChat-*.md`) left in the temporary
    /// directory, trying each one. True when none is left; a failure is
    /// logged, and a leftover file is retried next time.
    @discardableResult
    static func removeChatExports() -> Bool {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: directory.path)
        } catch {
            debugLog("[Assistant] listing old chat exports failed: \(error.localizedDescription)", level: .warning)
            return false
        }
        let exports = names.filter { $0.hasPrefix(chatExportPrefix) && $0.hasSuffix(".md") }
        return !exports.map { removeChatExport(directory.appendingPathComponent($0)) }.contains(false)
    }

    private static func removeChatExport(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            debugLog("[Assistant] removing an old chat export failed: \(error.localizedDescription)", level: .warning)
            return false
        }
    }

    /// The thread as Markdown: a titled header with a generation stamp, then
    /// one `## You` / `## Assistant` section per turn.
    private func conversationMarkdown() -> String {
        let stamp = Date().formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(LanguageManager.appLocale))
        let you = String(localized: "You", bundle: LanguageManager.appBundle)
        let assistant = String(localized: "Assistant", bundle: LanguageManager.appBundle)
        var lines = [
            "# " + String(localized: "Emuqu — Chat Export", bundle: LanguageManager.appBundle),
            "_" + String(localized: "Generated: \(stamp)", bundle: LanguageManager.appBundle) + "_",
            ""
        ]
        for turn in turns {
            lines.append(turn.role == .user ? "## \(you)" : "## \(assistant)")
            lines.append(turn.text.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Re-run the last assistant turn against the current question/context.
    /// Useful when the answer was bad or the user switched models and wants
    /// the new model's take.
    ///
    /// Runs `send`'s own gates first: nothing happens while Flo is off, and
    /// when the selected provider still needs consent the request is held
    /// for the consent sheet BEFORE the old reply is removed, so declining
    /// leaves the conversation as it was. The reply itself is removed by
    /// `dispatch(regenerating:)` once the routed provider may take the turn,
    /// so a provider that is switched off or has no key leaves it in place.
    func regenerateLast() {
        guard !isStreaming, !refusedWhileFloIsOff() else { return }
        // Find the last assistant turn, the one to replace.
        guard let lastAssistantIndex = turns.lastIndex(where: { $0.role == .assistant }) else { return }
        // A reply the app gave on the device — the crisis line, a medical
        // refusal — is not a model answer to reroll. Regenerating one sent the
        // message the guard had kept local to a provider.
        guard !turns[lastAssistantIndex].localOnly else { return }
        // Must have a user turn before it to regenerate from.
        guard lastAssistantIndex > 0, turns[lastAssistantIndex - 1].role == .user else { return }
        guard !holdRegenerationForConsent(userText: turns[lastAssistantIndex - 1].text) else { return }
        router.dispatch(regenerating: turns[lastAssistantIndex].id)
    }

    /// True, with the consent sheet requested, when the selected provider has
    /// no data-sharing consent yet. Routing only moves a turn to a consented
    /// provider, so the selected one is the only one that can need it.
    private func holdRegenerationForConsent(userText: String) -> Bool {
        let active = registry.activeProvider.id
        guard services.providerConsentTracker.requiresConsent(active) else { return false }
        pendingConsentRequest = PendingConsentRequest(provider: active, text: userText, fromVoice: false, regenerate: true)
        return true
    }

    /// Add a turn's text (or any string) to the cross-session memory store.
    /// A save that fails is shown, not left to look remembered.
    func remember(_ text: String) {
        guard factsStore.add(text, origin: .user) == .notSaved else { return }
        errorMessage = String(localized: "Your change couldn't be saved. Try again.", bundle: LanguageManager.appBundle)
    }

    /// The "Refresh data context" menu action. The context itself is rebuilt
    /// on every send; this wipes the per-session summary cache and the
    /// cached fact registry, then builds a context in the background so the
    /// summaries are regenerated before the user's next question.
    func invalidateContext() {
        services.analysisSummaryCache.clear()
        // Also drop the cached fact registry so the next
        // send rebuilds it fresh. The "Refresh data context" menu entry
        // is the user's gesture for "I want the AI to see the new data";
        // a stale registry would defeat that.
        invalidateFactRegistry()
        let source = contextSource
        Task.detached(priority: .utility) {
            _ = await source.currentContext()
        }
    }
}
