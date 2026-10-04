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
    /// (Combine's observable doesn't dedupe), defeating the
    /// optimization.
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
final class AssistantViewModel {
    static let shared = AssistantViewModel()

    // MARK: - Published state

    var turns: [ChatTurn] = []
    var isStreaming = false {
        didSet { composerState.update(canSend: !isStreaming && registry.activeProviderAvailable) }
    }
    var errorMessage: String?

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
    /// block arrives in the current round. The cursor advances ONLY at round
    /// boundaries where the round emitted text and NO tool_use — i.e. the
    /// text has passed the "will the model call a tool?" decision point.
    ///
    /// Chat UI still sees text stream live (it reads `turns[idx].text`); only
    /// TTS waits for this cursor to avoid speaking lines the model then
    /// superseded by calling a tool instead.
    var speakableTextCursor: [UUID: Int] = [:]

    /// Cumulative summary of turns that have been dropped from the send window.
    /// Prepended to the system prompt of every send so the model retains context
    /// past the truncation boundary.
    var priorSummary: String?

    /// The newest dropped turn already folded into `priorSummary`. Only turns
    /// dropped after it are summarised, so an over-budget history does not
    /// trigger a summary call on every send. In memory only: after a relaunch
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
    nonisolated static let summaryKey = "assistant.priorSummary"

    // MARK: - Dependencies

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
    /// currently-locked tier, turn count (for the 3-turn settling
    /// window), and the running summary embedding (topic-shift
    /// detection). Reset by `clearConversation()`.
    let sessionState = RoutingSessionState()

    @ObservationIgnored var streamTask: Task<Void, Never>?

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
    /// break the UI's send button. Race observed in practice when voice
    /// mode chains turns rapidly.
    var streamGeneration: Int = 0

    /// Cached because building the fact registry from
    /// scratch on every `dispatch()` (every send) is expensive — `AppFactResolverFactory.build`
    /// allocates ~25 namespace resolvers and their entries, all on the
    /// main thread. The output is a stateless lookup table (entries close
    /// over their data sources); rebuilding per-send is pure waste. Cache
    /// it on the view-model and invalidate via `invalidateFactRegistry()`
    /// only when the schema would actually change (none of the current
    /// inputs do — entries close over capturing closures that re-resolve
    /// `AppDependencies.current.app.settingsManager` on every read). The companion `cachedTools`
    /// avoids re-walking the schema for the LLM payload.
    var cachedFactRegistry: FactResolverRegistry?
    var cachedFactTools: [ToolSpec]?

    func factRegistryAndTools() -> (FactResolverRegistry, [ToolSpec]) {
        if let registry = cachedFactRegistry, let tools = cachedFactTools {
            return (registry, tools)
        }
        let registry = AppFactResolverFactory.build(
            archive: AppDependencies.current.storage.sessionArchive,
            settings: { AppDependencies.current.app.settingsManager.settingsSnapshot }
        )
        // CompactToolRouter exposes 21 read tools + up to 16 action
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
    /// compact schema (21 read tools plus up to 16 action tools) is under
    /// every provider's cap.
    static func trimTools(_ tools: [ToolSpec], to cap: Int?) -> [ToolSpec] {
        guard let cap, tools.count > cap, cap > 0 else { return tools }
        return Array(tools.prefix(cap))
    }

    // MARK: - Init

    /// AFM prewarm is DEFERRED to first send, deliberately absent here.
    ///
    /// Prewarming in init, the moment the user opens the chat tab, produced
    /// an 18-second gap in traces between first-tap-on-input and
    /// `keyboard.willShow` — strong candidate is iOS 26's keyboard wanting the
    /// same Apple Intelligence model that this prewarm is loading. Even at
    /// .utility priority, holding a `LanguageModelSession` contends with the
    /// keyboard's inline-prediction subsystem.
    ///
    /// The original spec ("Performance: AFM prewarm") wanted first AI message
    /// to be snappy. Moving the prewarm to right before the first send still
    /// achieves that — the user types their question, hits Send, prewarm has
    /// had ~5-30 s while they typed to load the KV-cache. The tradeoff is: if
    /// the user types VERY fast (sub-second to first send), they pay the
    /// prewarm cost on first message. That's strictly better than every user
    /// paying it on first focus, every session.
    init(
        registry: ProviderRegistry? = nil,
        store: ConversationStore = AppDependencies.current.assistant.conversationStore,
        contextSource: AssistantContextSource = AppDependencies.current.assistant.assistantContextSource,
        factsStore: UserFactsStore = AppDependencies.current.assistant.userFactsStore
    ) {
        let resolvedRegistry = registry ?? AppDependencies.current.providers.providerRegistry
        self.registry = resolvedRegistry
        self.store = store
        self.contextSource = contextSource
        self.factsStore = factsStore
        turns = store.load()
        hasAcceptedDisclaimer = UserDefaults.standard.bool(forKey: Self.disclaimerKey)
        priorSummary = UserDefaults.standard.string(forKey: Self.summaryKey)
        wireArchiveInvalidation()
        wireProtectedDataRecovery()
        wireComposerState(resolvedRegistry)
    }

    /// The history and the remembered facts cannot be read while the phone is
    /// locked. When this view model was created in that state, both started
    /// empty; the stores hold their writes until they can merge, and this puts
    /// the full history back on screen the moment the phone is unlocked.
    /// Becoming active is watched too: a suspended app can miss the unlock
    /// notification itself.
    private func wireProtectedDataRecovery() {
        for name in [UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.scheduleRecoveryAfterUnlock()
            }
        }
    }

    /// Notification callbacks arrive off the main actor; the recovery runs on it.
    nonisolated private func scheduleRecoveryAfterUnlock() {
        Task { @MainActor [weak self] in
            self?.recoverAfterUnlock()
        }
    }

    private func recoverAfterUnlock() {
        factsStore.recoverAfterUnlock()
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
    func wireArchiveInvalidation() {
        // `queue: nil`, not `.main`. A non-nil queue makes
        // `post` block the posting thread until the block finishes on that queue.
        // Archive writes post from background threads, so `.main` adds a
        // synchronous main-queue round-trip to every write (and deadlocks when
        // main was itself waiting on those writes). This block only schedules a
        // `Task { @MainActor }`, so running it on the posting thread is
        // equivalent — minus the blocking wait. See `ArchiveSignal.init`.
        NotificationCenter.default.addObserver(
            forName: .flowRecoveryArchiveChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.invalidateFactRegistry()
            }
        }
    }

    // Cancel any in-flight stream when this VM is torn
    // down (TestFlight/process tear-down or hot-reload). `Task.cancel()` is
    // nonisolated and Sendable so it's safe to call from deinit. Without this,
    // an orphan stream task could keep referencing `self` after release.
    deinit {
        streamTask?.cancel()
    }

    // MARK: - Public API

    var canSend: Bool {
        // Not `registry.activeProvider.isAvailable`,
        // which hits Keychain via APIKeyStore on every read. The
        // chat input bar reads `canSend` 3-4 times per render
        // (.disabled, send-button color, prefab chip enabled);
        // re-rendering on every keystroke would mean ~12 Keychain hits
        // per character typed. Reads the published cache instead; the
        // registry refreshes it on key/active-provider changes.
        !isStreaming && registry.activeProviderAvailable
    }

    /// Pre-fill the input with a question/topic. Used by Dashboard ✨ Ask AI affordances.
    var pendingDraft: String?

    /// Whether anything may go to a model: the AI Assistant switch is on and
    /// the AI notice has been accepted. The Flo tab and Get Me Back ask for
    /// the notice first; the workout screen's voice bar and the coach's
    /// automatic check-ins reach the model without a screen of their own, so
    /// the check sits on the way out.
    static func aiIsAllowed(disclaimerAccepted: Bool) -> Bool {
        disclaimerAccepted && AppDependencies.current.app.settingsManager.settings.enableAIAssistant
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
    var pendingConsentRequest: (provider: ProviderID, text: String, fromVoice: Bool)?

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
    /// five hosted providers each prompt once.
    @discardableResult
    func send(text: String, fromVoice: Bool = false) -> SendOutcome {
        AppDependencies.current.app.keyboardPerfSignpost.event("AssistantViewModel.send.entry")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejectedEmpty }
        if refusedWhileFloIsOff() { return .rejectedNoProvider }
        if medicalGuardRefused(trimmed) { return .dispatched }
        guard registry.activeProvider.isAvailable else {
            errorMessage = Self.unavailableMessage(for: registry.activeProvider.id)
            return .rejectedNoProvider
        }
        let activeProvider = registry.activeProvider.id
        if AppDependencies.current.providers.providerConsentTracker.requiresConsent(activeProvider) {
            pendingConsentRequest = (provider: activeProvider, text: trimmed, fromVoice: fromVoice)
            return .requiresConsent(activeProvider)
        }
        if isStreaming { return queueBehindStream(trimmed, fromVoice: fromVoice) }
        if fromVoice, servedDeterministically(trimmed) { return .dispatched }
        dispatchToProvider(trimmed, fromVoice: fromVoice)
        return .dispatched
    }

    /// Why a provider can't take a message: a cloud provider without a key,
    /// or Apple Intelligence, which has no key and is unavailable on this
    /// device (unsupported, turned off, or its model not downloaded yet).
    static func unavailableMessage(for id: ProviderID) -> String {
        let bundle = LanguageManager.appBundle
        if id == .apple {
            return String(localized: "Apple Intelligence isn't available on this device right now. Choose another model in Settings → Flo.", bundle: bundle)
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
        let guardEnabled = AppDependencies.current.app.featureFlags.value(for: .medicalGuardEnabled)
        guard guardEnabled || MedicalQueryGuard.classify(trimmed) == .selfHarm,
              case .refuse(let reply) = MedicalQueryGuard.evaluate(trimmed) else { return false }
        appendExchange(user: trimmed, assistant: reply, localOnly: true)
        debugLog("[Assistant] medical-query guard fired — refusing locally without provider call")
        return true
    }

    /// If a stream is in flight, queue the send rather than drop it. The
    /// user (or voice controller) gave us a real message; losing it because
    /// the previous turn hadn't quite finished is the symptom we keep
    /// hearing about. `finishStream()` drains the queue. Latest-wins:
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
    /// assertions; there is no measured precision gate.
    private func servedDeterministically(_ trimmed: String) -> Bool {
        let context = DeterministicIntent.MatchContext(
            now: Date(),
            archive: AppDependencies.current.storage.sessionArchive,
            userSettings: AppDependencies.current.app.settingsManager.settings
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
    /// first send of the session. By the time the LLM call
    /// actually fires (after fact-registry build + system prompt
    /// composition, ~50-200 ms) the model is partway loaded.
    /// Apple's `prewarm()` returns immediately and warms in the
    /// background. See AppleFoundationProvider.prewarm().
    private func dispatchToProvider(_ trimmed: String, fromVoice: Bool) {
        turns.append(ChatTurn(role: .user, text: trimmed))
        store.save(turns)
        nextSendIsVoice = fromVoice
        let mode = AppDependencies.current.app.settingsManager.settings.routingMode
        let activeIsApple = registry.activeProvider.id == .apple
        if mode != .deep, mode != .manual || activeIsApple {
            AppleFoundationProvider.prewarm()
        }
        AppDependencies.current.app.keyboardPerfSignpost.event("AssistantViewModel.send.beforeDispatch")
        dispatch()
    }

    /// True, with the reason shown, when Flo is switched off or its notice
    /// hasn't been accepted (see `aiIsAllowed`).
    private func refusedWhileFloIsOff() -> Bool {
        guard !Self.aiIsAllowed(disclaimerAccepted: hasAcceptedDisclaimer) else { return false }
        errorMessage = String(localized: "Flo is off, or its notice hasn't been accepted yet. Open the Flo tab to turn it on.", bundle: LanguageManager.appBundle)
        return true
    }

    /// Send one of the pre-fab questions.
    func send(prefab question: PrefabQuestion) {
        send(text: question.prompt)
    }

    /// Called by the per-provider consent sheet when the user accepts.
    /// Records the acknowledgement and re-issues the pending send.
    @discardableResult
    func acknowledgeConsentAndContinue() -> SendOutcome {
        guard let pending = pendingConsentRequest else { return .rejectedEmpty }
        AppDependencies.current.providers.providerConsentTracker.acknowledge(pending.provider)
        pendingConsentRequest = nil
        return send(text: pending.text, fromVoice: pending.fromVoice)
    }

    /// Called by the per-provider consent sheet when the user declines.
    /// Drops the pending message, hands a typed one back to the input bar
    /// (`ComposerState.returnedDraft`), and surfaces an info-level error so
    /// the user knows nothing was sent.
    ///
    /// No-op when nothing is pending: dismissing the sheet after Accept
    /// writes nil through the sheet's item binding, which lands here after
    /// the message has already been sent.
    func cancelPendingConsent() {
        guard let pending = pendingConsentRequest else { return }
        pendingConsentRequest = nil
        if !pending.fromVoice { composerState.returnedDraft = pending.text }
        errorMessage = String(localized: "Message not sent — you must agree to share data with this provider before its first message.", bundle: LanguageManager.appBundle)
    }

    /// One-shot voice flag consumed by the next `dispatch()`. Set by
    /// VoiceConversationController before its send(); cleared inside dispatch.
    var nextSendIsVoice = false

    /// Last observed catalog schema hash. Used by
    /// `checkCatalogHashStability` to log warnings when the cacheable
    /// prefix changes unexpectedly. Purely diagnostic.
    var lastCatalogHash: String?

    /// Debug-build byte-identity check on the cacheable prefix. When the
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
        isStreaming = false
        // Drop any queued pending message — user explicitly hit Stop.
        pendingSendOnFinish = nil
        // Drop the Apple dispatcher's strong ref
        // immediately on cancel so a stop-button tap during an Apple
        // turn doesn't leave the registry retained until the next send.
        AppDependencies.current.providers.appleToolDispatcher.setRegistry(nil)
        AppDependencies.current.assistant.voiceConversationController.stopAnyOngoingSpeech()
    }

    /// Chat-bar dismiss for the error banner. Lets
    /// the user acknowledge a surfaced error (out of credits, 401,
    /// network) without nuking the whole conversation.
    func clearError() {
        errorMessage = nil
    }

    /// Wipe the conversation and start over. Does not affect API keys or settings.
    /// Everything happens off the visible frame so the menu dismisses instantly:
    /// UI state clears on main, disk + UserDefaults writes run on background queues.
    func clearConversation() {
        cancel()
        turns = []
        errorMessage = nil
        priorSummary = nil
        summarizedThroughTurnID = nil
        speakableTextCursor = [:]
        // Reset adaptive-routing session state too. New
        // conversation = fresh tier classification on the first turn.
        sessionState.currentTier = .quick
        sessionState.turnCount = 0
        store.clear()
        // UserDefaults writes block on synchronous disk sync — push off main.
        Task.detached(priority: .utility) {
            UserDefaults.standard.removeObject(forKey: Self.summaryKey)
        }
    }

    /// Serialize the current thread to Markdown and return a temporary file URL
    /// for sharing. Synchronous and on-main by design — a chat thread is tens
    /// of KB at most, so the write takes sub-millisecond. The point is to make
    /// the URL available at the moment `ShareLink` is instantiated so the
    /// native share sheet opens instantly instead of the UIActivityViewController
    /// cold-start path, which can hang 1–2 seconds (and up to a minute when
    /// the extension scan is cold — see shareRow in FitnessTabView).
    func exportConversation() -> URL? {
        guard !turns.isEmpty else { return nil }
        let filename = "EmuquChat-\(Int(Date().timeIntervalSince1970)).md"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try conversationMarkdown().write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            // Log the write error rather than swallowing it: a silent
            // failure leaves the ShareLink UI with no reason the
            // export produced no file.
            debugLog("[Assistant] exportConversation write failed: \(error.localizedDescription)", level: .warning)
            return nil
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
    func regenerateLast() {
        guard !isStreaming else { return }
        // Find the last assistant turn and drop it.
        guard let lastAssistantIndex = turns.lastIndex(where: { $0.role == .assistant }) else { return }
        // A reply the app gave on the device — the crisis line, a medical
        // refusal — is not a model answer to reroll. Regenerating one sent the
        // message the guard had kept local to a provider.
        guard !turns[lastAssistantIndex].localOnly else { return }
        // Must have a user turn before it to regenerate from.
        guard lastAssistantIndex > 0, turns[lastAssistantIndex - 1].role == .user else { return }
        turns.remove(at: lastAssistantIndex)
        store.save(turns)
        dispatch()
    }

    /// Add a turn's text (or any string) to the cross-session memory store.
    func remember(_ text: String) {
        factsStore.add(text)
    }

    /// The "Refresh data context" menu action. The context itself is rebuilt
    /// on every send; this wipes the per-session summary cache and the
    /// cached fact registry, then builds a context in the background so the
    /// summaries are regenerated before the user's next question.
    func invalidateContext() {
        AppDependencies.current.assistant.analysisSummaryCache.clear()
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
