import AVFoundation
import Foundation
import Speech
import UIKit

// The public control surface, split out of
// `VoiceConversationController.swift`: start / stop, interrupt, trigger
// handling and its queue. The state machine and settings stay in the main
// file; voice-activity detection lives in `+Pipeline.swift` and barge-in in
// `+Speech.swift`.

extension VoiceConversationController {
    // MARK: - Public control

    /// Toggle the conversation. Requests permissions on first use.
    @MainActor
    func toggle() {
        debugLog("[VoiceConv] toggle() in state=\(state), partialTranscript.count=\(partialTranscript.count)")
        switch state {
        case .idle: Task { await start() }
        case .starting: break // already on the way — ignore extra taps
        case .listening: finalizeUserTurn()
        case .speaking, .thinking: interrupt()
        case .triggerSpeaking: break
        }
    }

    /// Start the conversation. Requests mic + speech permissions, then opens
    /// the mic for the first user turn.
    ///
    /// Re-entrancy guard: `start()` is async with suspension points
    /// (permissions, audio activation). A second toggle while the first
    /// start() is suspended would interleave audio-engine setup —
    /// installTap on a half-configured engine throws an uncatchable
    /// Obj-C exception (seen in a crash log). State must be .idle
    /// for a fresh start; otherwise stop() and re-tap is the user path.
    ///
    /// It flips to `.starting` immediately so the UI shows "Connecting…"
    /// instead of "Tap to talk" during the permission/audio-warmup window.
    @MainActor
    func start() async {
        debugLog("[VoiceConv] start() entered, current state=\(state)")
        guard state == .idle else {
            debugLog("[VoiceConv] start() ignored — state=\(state) (not .idle); a session is already in flight", level: .warning)
            return
        }
        state = .starting
        permissionError = nil
        guard await ensurePermissions() else {
            debugLog("[VoiceConv] permissions failed", level: .warning)
            state = .idle
            return
        }
        guard state == .starting else { return } // ended while the permission prompts were up
        currentResponseText = ""
        partialTranscript = ""
        refreshLanguageForSession()
        pinSTTProviderForSession()
        // Re-arm the subsystem-identification preamble for this session.
        hasAnnouncedSubsystem = false
        openMicForFirstTurn()
    }

    /// Pin the STT provider for this session. The
    /// user can toggle the setting mid-conversation; doing so
    /// shouldn't mid-session-swap the recognizer (mixing Apple
    /// and WhisperKit transcripts is worse than either alone).
    /// Whatever they had selected at start() locks in until stop(). A
    /// WhisperKit preference falls back to Apple Speech when the app
    /// language isn't English (`STTProviderKind.effective`).
    ///
    /// When WhisperKit is the pick, kick off the model load early so it's
    /// likely ready by the time the user finishes their first utterance. The
    /// bridge is idempotent — safe to call repeatedly.
    @MainActor
    private func pinSTTProviderForSession() {
        let preferred = AppDependencies.current.app.settingsManager.settings.preferredSTTProvider
        useWhisperKitForCurrentSession = STTProviderKind.effective(preferred: preferred) == .whisperKit
        guard useWhisperKitForCurrentSession else { return }
        AppDependencies.current.providers.whisperKitSTTBridge.prepareModelIfNeeded()
        AppDependencies.current.providers.whisperKitSTTBridge.reset()
        debugLog("[VoiceConv] WhisperKit selected; preparing model")
    }

    /// NOTE: voice conversation does NOT use BackgroundAudioManager.
    /// Our own `.playAndRecord` session with a live mic tap keeps the app
    /// running in the background; BackgroundAudioManager only holds the
    /// session for the length of one spoken workout cue. All claims go
    /// through the `AudioSessionCoordinator`, which keeps `.playAndRecord`
    /// while voice holds its claim, so a cue never switches the category to
    /// `.playback` under the recogniser.
    ///
    /// `beginUserTurn()` handles `startAudioEngineAndRecognizer()` internally
    /// (it has to, for post-TTS mic re-unmute on speaker playback), so we
    /// don't call it separately — that would duplicate the engine start.
    ///
    /// The "mic is live" cue is a haptic + short "Tink" chime, matching the
    /// Siri-style start affordance. No TTS: the user is about to speak
    /// themselves and a spoken prompt would collide. It fires AFTER
    /// `beginUserTurn()` so the recognizer is already listening when the chime
    /// decays and the user starts talking.
    @MainActor
    private func openMicForFirstTurn() {
        do {
            try configureAudioSessionForConversation()
            installInterruptionObserver()
            Task { @MainActor in await beginUserTurn() }
            VoiceAudioPipeline.announceVoiceChatStart()
            debugLog("[VoiceConv] started OK, now listening")
        } catch {
            debugLog("[VoiceConv] start failed: \(error.localizedDescription)", level: .error)
            permissionError = String(localized: "Couldn't start the mic: \(error.localizedDescription)", bundle: LanguageManager.appBundle)
            state = .idle
        }
    }

    /// Fully stop the conversation: cancel any LLM stream, stop TTS, close the
    /// mic, return to idle. The chat thread itself is preserved (the user's
    /// typed history doesn't get nuked just because they ended a voice
    /// session).
    ///
    /// Set the teardown flag FIRST so the re-entry
    /// through `assistantViewModel.cancel()` →
    /// `stopAnyOngoingSpeech()` doesn't try to auto-restart
    /// listening mid-teardown (that crashes installTap
    /// with an AVAudio format-mismatch).
    @MainActor
    func stop() {
        isStoppingFully = true
        defer { isStoppingFully = false }
        cancelLLM()
        assistantViewModel.cancel()
        cancelAssistantObservers()
        activeAssistantIndex = nil
        spokenCharCursor = 0
        stopSynthesizer()
        removeInterruptionObserver()
        teardownAudioPipeline()
        releaseSTT()
        state = .idle
        partialTranscript = ""
        currentResponseText = ""
        textChunker.reset()
        preemptedState = nil
    }

    /// Drop any pending WhisperKit buffers so a future
    /// session doesn't transcribe leftover audio. Resetting the
    /// session flag lets the next start() re-read the user's
    /// current preference.
    @MainActor
    private func releaseSTT() {
        if useWhisperKitForCurrentSession { AppDependencies.current.providers.whisperKitSTTBridge.reset() }
        useWhisperKitForCurrentSession = false
    }

    /// User tap (or detected speech) while the AI is speaking → kill the
    /// current response and open the mic for a new turn.
    ///
    /// Bump the speak-generation token BEFORE stopping
    /// the synthesizer. Otherwise the synthesizer keeps playing
    /// ("tap mic to interrupt button should also interrupt it")
    /// because observation callbacks already in flight push the next
    /// chunk into speak() AFTER stopSynthesizer() returns. Same
    /// race that stopAnyOngoingSpeech() defends against.
    /// Bumping the generation makes any in-flight callback no-op
    /// before it can re-queue an utterance.
    @MainActor
    func interrupt() {
        cancelLLM()
        assistantViewModel.cancel()
        cancelAssistantObservers()
        activeAssistantIndex = nil
        spokenCharCursor = 0
        responseSpeakGeneration += 1
        stopSynthesizer()
        currentResponseText = ""
        textChunker.reset()
        // Reset the partial transcript so the fresh turn starts clean rather
        // than inheriting the barge-in fragment that caused the interrupt.
        partialTranscript = ""
        Task { @MainActor in await beginUserTurn() }
    }

    /// Preempt whatever's happening to run a prompt through the AI and speak
    /// the response. Doesn't append to the ongoing conversation — this is for
    /// trigger-driven interjections that shouldn't pollute the user's chat
    /// history with system-generated turns.
    ///
    /// The prompt itself is typically produced by a trigger rule; the
    /// conversation's contextSnapshotProvider injects real workout facts so
    /// the model can phrase the line with data, not guesses.
    /// Same queue-when-busy semantics as
    /// `handleTrigger`. The AI's mid-response answer to the user
    /// always finishes before a coaching interjection plays.
    @MainActor
    func speakAIResponse(toPrompt prompt: String) {
        if isBusyWithUserResponse() {
            pendingTriggers.append(.aiPrompt(prompt))
            capPendingTriggers()
            debugLog("[VoiceConv] AI interjection queued — chat mid-response (queue=\(pendingTriggers.count))")
            return
        }
        playAIPromptTriggerNow(prompt: prompt)
    }

    /// Cap pendingTriggers to 8. If the user holds a long chat turn
    /// while triggers fire faster than they can drain, the queue
    /// would grow unbounded — each entry holds a full prompt
    /// string. Drop oldest interjections when over: by the time we
    /// drain, anything more than ~8 alerts old is stale anyway.
    @MainActor
    func capPendingTriggers() {
        let maxPending = 8
        if pendingTriggers.count > maxPending {
            let drop = pendingTriggers.count - maxPending
            pendingTriggers.removeFirst(drop)
            debugLog("[VoiceConv] dropped \(drop) stale pending trigger(s) — queue cap=\(maxPending)", level: .warning)
        }
    }

    @MainActor
    func playAIPromptTriggerNow(prompt: String) {
        if preemptedState == nil { preemptedState = state }
        cancelLLM()
        _ = FRSafeStopSpeaking(synthesizer, .immediate, nil)
        silenceTimer?.invalidate()
        silenceTimer = nil
        startFreshRecognitionTask()
        partialTranscript = ""
        currentResponseText = ""
        textChunker.reset()
        state = .triggerSpeaking
        startAIInterjectionStream(prompt: prompt)
    }

    /// Interjections fire automatically (workout voice
    /// coach: split announcements, HR-zone nudges, route cues), so
    /// there is no moment to present a consent sheet. A cloud
    /// provider without recorded data-sharing consent must simply
    /// not receive the live HR/pace/street-name context this path
    /// ships — this `provider.send` is a cloud call with no
    /// consent check anywhere upstream. We skip
    /// the interjection and restore the voice state instead; the
    /// user enables it by accepting the provider notice in the
    /// Assistant tab once.
    @MainActor
    func startAIInterjectionStream(prompt: String) {
        let provider = AppDependencies.current.providers.providerRegistry.activeProvider
        guard InterjectionGate.maySend(to: provider.id, disclaimerAccepted: assistantViewModel.hasAcceptedDisclaimer) else {
            finishInterjectionAfterError()
            return
        }
        // Single-turn message list: just the prompt, no conversation history.
        // This is intentional — interjections shouldn't leak into the main chat.
        let stream = provider.send(
            messages: [ChatTurn(role: .user, text: prompt)],
            model: AppDependencies.current.providers.providerRegistry.activeModel,
            contextRendered: contextSnapshotProvider?() ?? "",
            systemPrompt: buildSystemPrompt()
        )
        ttsStartedAt = Date()
        llmTask?.cancel()
        llmTask = Task { [weak self] in await self?.consumeInterjection(stream) }
    }

    /// Drain an interjection stream into TTS. Interjections don't use tools,
    /// so a `toolUse` event from a provider is ignored. A failure fails
    /// silently — an interjection is never worth surfacing to the user.
    @MainActor
    private func consumeInterjection(_ stream: AsyncThrowingStream<AIStreamEvent, Error>) async {
        do {
            try await drainInterjection(stream)
        } catch {
            finishInterjectionAfterError()
        }
    }

    @MainActor
    private func drainInterjection(_ stream: AsyncThrowingStream<AIStreamEvent, Error>) async throws {
        for try await event in stream {
            if Task.isCancelled { return }
            applyInterjectionEvent(event)
        }
        // A stream that closes without `.done` still ends the interjection.
        if !Task.isCancelled, llmTask != nil { finishInterjection() }
    }

    @MainActor
    private func applyInterjectionEvent(_ event: AIStreamEvent) {
        switch event {
        case let .textDelta(delta): ingestInterjectionDelta(delta)
        case .done: finishInterjection()
        case .toolUse, .usage: break
        }
    }

    @MainActor
    func ingestInterjectionDelta(_ delta: String) {
        currentResponseText += delta
        if let chunk = textChunker.append(delta: delta) {
            speak(chunk)
        }
    }

    @MainActor
    func finishInterjection() {
        if let remainder = textChunker.finalize() {
            speak(remainder)
        }
        let spoken = currentResponseText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !spoken.isEmpty { lastInterjectionText = CoachVoiceGuard.scrub(spoken).scrubbed }
        llmTask = nil
        // State transition handled by the synthesizer delegate when the final
        // utterance finishes (restores preemptedState). With nothing queued
        // (the model chose to say nothing, or the speech already finished
        // while the stream was still open) no delegate call is coming, and
        // the mic stayed shut until the next trigger.
        if state == .triggerSpeaking, !synthesizer.isSpeaking { finishTriggerSpeech() }
    }

    @MainActor
    func finishInterjectionAfterError() {
        llmTask = nil
        let prior = preemptedState ?? .idle
        preemptedState = nil
        if prior == .listening || prior == .speaking {
            Task { @MainActor in await beginUserTurn() }
        } else {
            state = .idle
        }
    }

    /// Urgency tier for trigger dispatch. Routine = "respect the
    /// user's flow"; urgent = "interrupt anyway, this matters." The
    /// routine path queues when the user is mid-utterance or the AI
    /// is mid-response; the urgent path preempts unconditionally
    /// AFTER first saving the in-progress dictation to the
    /// clipboard so the user doesn't lose what they were saying.
    enum TriggerUrgency {
        case routine
        case urgent
    }

    /// Not a hard preempt (cancelLLM + stopSpeaking +
    /// state swap): that kills in-flight user responses, which the
    /// user perceives as "the chat session died." If the AI is
    /// busy, enqueue and play after the current response completes.
    /// Only fire immediately when the AI is idle.
    ///
    /// Urgency split. Per the user spec ("if my heart
    /// is exploding then interrupt me. even then, save my words to
    /// the clipboard"):
    ///   • routine triggers (mile markers, drift cues, terrain
    ///     calls) — queue while the user is mid-utterance / the AI
    ///     is mid-response. Existing behaviour, plus the
    ///     mid-utterance guard added in `isBusyWithUserResponse()`.
    ///   • urgent triggers (HR-spike alerts, threshold breaches,
    ///     strap-drop, future SOS) — preempt regardless. Before
    ///     preempting, copy the in-progress `partialTranscript` to
    ///     the system clipboard with a 60 s expiration so the user
    ///     can paste their lost words back in once the alert is
    ///     handled. The clipboard write mirrors the security
    ///     pattern used elsewhere in the app
    ///     (.localOnly + expirationDate).
    @MainActor
    func handleTrigger(message: String, urgency: TriggerUrgency = .routine) {
        switch urgency {
        case .routine:
            if isBusyWithUserResponse() {
                pendingTriggers.append(.spokenLiteral(message))
                capPendingTriggers()
                debugLog("[VoiceConv] routine trigger queued — user/AI busy, will play after (queue=\(pendingTriggers.count))")
                return
            }
            playSpokenTriggerNow(message: message)
        case .urgent:
            // Save the user's in-progress words BEFORE the preempt
            // wipes `partialTranscript` (playSpokenTriggerNow clears
            // it). User can paste them back once
            // they've heard the alert.
            saveInProgressWordsToClipboard(reason: "urgent alert preempting")
            playSpokenTriggerNow(message: message)
        }
    }

    /// Copy the live `partialTranscript` to the system clipboard so
    /// it survives an urgent preempt. No-op when there's nothing to
    /// save. 60-s expiration + `.localOnly` matches the per-message
    /// copy path elsewhere in the app — clipboard contents don't
    /// linger past the immediate paste-back window and never sync
    /// to other devices.
    @MainActor
    private func saveInProgressWordsToClipboard(reason: String) {
        let words = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        // Honor `preserveClipboardForPaste` (default
        // true). User feedback: an interrupting alert makes it easy to lose
        // the thread, so losing dictated ideas to a 60 s expiration was
        // actively hostile.
        // When the toggle is on, the urgent-alert clipboard save
        // sticks until the user pastes it or copies something else;
        // when off, the original 60 s security cap applies.
        // Routed through `PasteboardWriter`, which owns the `.localOnly` +
        // opt-out-expiry policy, so there is one copy of the rule across the
        // app's write sites.
        PasteboardWriter.copy(words)
        debugLog("[VoiceConv] saved \(words.count)-char partialTranscript to clipboard (\(reason))")
    }

    /// True when an AI conversation turn is
    /// in flight (LLM streaming OR synthesizer mid-utterance from the
    /// AI's reply). The workout-coach uses this to decide whether to
    /// re-announce the speaker before its alert preempts the AI — so
    /// the user hears a clear handoff instead of one continuous voice.
    @MainActor
    var isAIInFlight: Bool {
        if llmTask != nil { return true }
        if assistantViewModel.isStreaming { return true }
        if synthesizer.isSpeaking, state == .speaking { return true }
        return false
    }

    @MainActor
    func playSpokenTriggerNow(message: String) {
        // Snapshot the pre-preemption state once (don't overwrite if multiple
        // triggers fire in quick succession).
        if preemptedState == nil {
            preemptedState = state
        }
        cancelLLM()
        _ = FRSafeStopSpeaking(synthesizer, .immediate, nil)
        silenceTimer?.invalidate()
        silenceTimer = nil
        startFreshRecognitionTask()
        partialTranscript = ""
        state = .triggerSpeaking
        speak(message, voice: WorkoutVoiceCoach.appLanguageVoice())
    }

    /// AI is "busy with the user's response" when an LLM stream is in
    /// flight OR the synthesizer is still draining a non-trigger
    /// response. Triggers wait in the queue until both are clear.
    ///
    /// Also treat the USER as busy when they are
    /// mid-utterance (state .listening with a non-empty partial
    /// transcript) or the turn was just finalised but the LLM hasn't
    /// started yet (state .thinking). Otherwise a trigger firing
    /// during the user's spoken sentence calls
    /// `playSpokenTriggerNow()`, which wipes `partialTranscript`,
    /// erasing the in-progress dictation ("alerts wipe out my message").
    @MainActor
    func isBusyWithUserResponse() -> Bool {
        VoiceTurnPolicy.isBusyWithUserResponse(
            state: state,
            hasInFlightLLMTask: llmTask != nil,
            isStreamingResponse: assistantViewModel.isStreaming,
            synthesizerIsSpeaking: synthesizer.isSpeaking,
            hasPartialTranscript: !partialTranscript.isEmpty
        )
    }

    /// Drain the next pending trigger now if the AI is idle. Called
    /// from the synth `didFinish` delegate so triggers fire as soon
    /// as the in-flight response completes.
    @MainActor
    func drainPendingTriggersIfIdle() {
        guard !pendingTriggers.isEmpty else { return }
        guard !isBusyWithUserResponse() else { return }
        let next = pendingTriggers.removeFirst()
        switch next {
        case .spokenLiteral(let msg):
            playSpokenTriggerNow(message: msg)
        case .aiPrompt(let prompt):
            playAIPromptTriggerNow(prompt: prompt)
        }
    }
}

/// Whether an automatic AI line (a coach check-in, an interval call) may go
/// to the model: Flo is on, its notice accepted, and the provider has
/// data-sharing consent. The skip is logged with its reason.
enum InterjectionGate {
    @MainActor
    static func maySend(to provider: ProviderID, disclaimerAccepted: Bool) -> Bool {
        guard AssistantViewModel.aiIsAllowed(disclaimerAccepted: disclaimerAccepted) else {
            debugLog("[VoiceConv] interjection skipped — Flo is off or its notice isn't accepted", level: .info)
            return false
        }
        guard !AppDependencies.current.providers.providerConsentTracker.requiresConsent(provider) else {
            debugLog("[VoiceConv] interjection skipped — \(provider.rawValue) has no data-sharing consent", level: .warning)
            return false
        }
        return true
    }
}
