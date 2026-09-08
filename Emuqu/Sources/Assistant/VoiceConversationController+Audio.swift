import AudioToolbox
import AVFoundation
import Combine
import Foundation
import Speech
import UIKit

// Holds voice-chat start cue, audio session interruption recovery,
// assistant streaming observation, TTS, permissions, system prompt,
// and the AVSpeechSynthesizerDelegate extension.

extension VoiceAudioPipeline {
    // MARK: - Voice-chat start cue
    //
    // Subtle "mic is hot" feedback the instant we flip into listening mode.
    // Matches the workout-start alert pattern in spirit (multi-modal so the
    // user learns it by feel + sound) but deliberately quieter — this fires
    // every single time the voice overlay opens, so a loud chime would be
    // annoying on repeat use. One short tone + one light haptic, no TTS.
    static let voiceStartChimeSoundID: SystemSoundID = 1057  // "Tink"

    @MainActor
    static func announceVoiceChatStart() {
        // Light haptic — "impact soft" was introduced for exactly this kind
        // of subtle UI confirmation.
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        AudioServicesPlaySystemSound(voiceStartChimeSoundID)
    }

    // MARK: - Audio session interruption recovery
    //
    // Phone call, Siri, alarm, another app grabbing the mic — all trigger
    // `AVAudioSession.interruptionNotification`. Without recovery the mic
    // goes dead and the chat silently breaks. iOS delivers:
    //   • .began — our audio is paused by the system; no action needed.
    //   • .ended — the interruption cleared; if .shouldResume option is set,
    //     we should re-activate the session + restart the engine + open a
    //     fresh recognition request so the next user turn captures cleanly.

    @MainActor
    func installInterruptionObserver() {
        removeInterruptionObserver() // idempotent
        controller.interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak controller] notification in
            let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in controller?.audio.handleAudioInterruption(typeRaw: typeRaw) }
        }
    }

    @MainActor
    func removeInterruptionObserver() {
        if let obs = controller.interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            controller.interruptionObserver = nil
        }
    }

    /// `.began` — the system pre-empted our audio (call, Siri, alarm). The
    /// recognition task is going to die; clear it so we re-arm cleanly on
    /// `.ended`. The engine itself resumes when the session reactivates.
    ///
    /// `.ended` — per spec §1, do NOT auto-resume voice mode. The user's
    /// context has shifted during the interruption (they took a call,
    /// answered Siri, heard an alarm). Silently resuming a voice conversation
    /// is worse UX than tearing down cleanly and showing a tap-to-resume
    /// affordance. The user regains control on purpose.
    @MainActor
    func handleAudioInterruption(typeRaw: UInt?) {
        guard let typeRaw,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
        else { return }
        switch type {
        case .began:
            debugLog("[VoiceConv] audio interrupted (began) — will attempt recovery on end")
            controller.recognitionTask?.cancel()
            controller.recognitionTask = nil
            controller.recognitionRequest?.endAudio()
            controller.recognitionRequest = nil
        case .ended:
            debugLog("[VoiceConv] audio interruption ended — tearing down, user must re-tap to resume")
            controller.stop()
        @unknown default:
            break
        }
    }

    /// Release the coordinator claim BEFORE deactivating the
    /// session. If BGAM is still up (indoor workout in progress), this lets
    /// it pick up session ownership without a category gap. And skip
    /// deactivation entirely while BGAM is still claiming the session —
    /// deactivating would kill its silent buffer and suspend the app's
    /// background-audio entitlement.
    @MainActor
    func teardownAudioPipeline() {
        controller.silenceTimer?.invalidate()
        controller.silenceTimer = nil
        controller.recognitionTask?.cancel()
        controller.recognitionTask = nil
        controller.recognitionRequest?.endAudio()
        controller.recognitionRequest = nil
        stopAudioEngineSafely()
        AppDependencies.current.services.audioSessionCoordinator.release(.voice)
        if AppDependencies.current.services.audioSessionCoordinator.isVoiceActive() == false,
           AppDependencies.current.collection.backgroundAudioManager.isRunning {
            debugLog("[VoiceConv] BGAM still active — leaving session up for it")
            return
        }
        deactivateAudioSession()
    }

    /// SafeObjC shims. Both can raise NSException on a
    /// degraded audio session; teardown happens AFTER user activity
    /// so any throw here would crash mid-action. The shim catches.
    @MainActor
    private func stopAudioEngineSafely() {
        var removeErr: NSError?
        _ = FRSafeRemoveTap(controller.audioEngine.inputNode, 0, &removeErr)
        guard controller.audioEngine.isRunning else { return }
        var stopErr: NSError?
        _ = FRSafeAudioEngineStop(controller.audioEngine, &stopErr)
    }

    /// Deactivate so Music / Podcasts / etc. resume on `.notifyOthersOnDeactivation`.
    ///
    /// Not `try?`, which would swallow
    /// every error. The genuinely benign case (deactivating an already-
    /// inactive session) is one specific OSStatus; everything else means
    /// the session is wedged active, which permanently blocks the mic on
    /// the next voice turn. So we log non-trivial failures and attempt
    /// a brief delayed retry — if the retry fails too, the user-visible
    /// permission error surfaces so they get a tap-to-recover instead of
    /// silent breakage.
    @MainActor
    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch let error as NSError {
            // 560030580 == kAudioSessionNotActiveError
            let isAlreadyInactive = error.domain == NSOSStatusErrorDomain && error.code == 560030580
            guard !isAlreadyInactive else { return }
            debugLog("[VoiceConv] AVAudioSession deactivate failed: \(error.localizedDescription) — scheduling recovery", level: .warning)
            Task { @MainActor [weak controller] in
                await sleepQuietly(500_000_000, context: "deactivateAudioSession")
                controller?.audio.retryDeactivateAudioSession()
            }
        }
    }

    /// Second and last attempt. A failure here is user-visible on purpose.
    @MainActor
    private func retryDeactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            debugLog("[VoiceConv] AVAudioSession deactivate succeeded on retry")
        } catch let retryError as NSError {
            debugLog("[VoiceConv] AVAudioSession deactivate retry failed: \(retryError.localizedDescription)", level: .error)
            controller.permissionError = "Microphone is currently held by another app. Try again in a moment, or restart the app if it persists."
        }
    }

    func armSilenceTimer() {
        controller.silenceTimer?.invalidate()
        controller.silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak controller] _ in
            Task { @MainActor in controller?.audio.silenceTimerTick() }
        }
    }

    /// One 0.2 s tick of the listening/speaking watchdog. Barge-in while the
    /// AI speaks; everything else only applies while we're listening.
    @MainActor
    private func silenceTimerTick() {
        if controller.state == .speaking {
            controller.checkForBargeIn()
            return
        }
        guard controller.state == .listening else { return }
        if hitMaxTurnDuration() { return }
        if restartedStalledRecognizer() { return }
        commitTurnIfSettled()
    }

    /// Max-turn safety cap: the controller.recognizer can stall silently in sustained
    /// noise. Force-finalize at 30 s regardless of controller.state.
    @MainActor
    private func hitMaxTurnDuration() -> Bool {
        guard let started = controller.turnStartedAt,
              Date().timeIntervalSince(started) >= controller.maxTurnDurationSec else { return false }
        debugLog("[VoiceConv] max-turn timeout (\(Int(controller.maxTurnDurationSec))s) — force-finalising")
        finalizeUserTurn()
        return true
    }

    /// The two recogniser watchdogs, both of which restart the recognition
    /// task rather than committing a turn.
    ///
    /// First-partial watchdog (spec §1): if the recogniser has received NO
    /// partials in `controller.firstPartialTimeoutSec` AND we're hearing voice-like audio
    /// (sustained RMS > floor), it's probably hung. Restart once — capped so a
    /// genuinely busted recogniser can't ping-pong.
    ///
    /// Long-idle restart: SFSpeechRecognizer self-terminates after ~60 s of
    /// silence (undocumented but observable) and the next user utterance
    /// vanishes. If 45 s have passed with no partials and no active voice
    /// (user thinking?), pre-emptively restart.
    @MainActor
    private func restartedStalledRecognizer() -> Bool {
        guard let started = controller.turnStartedAt, controller.lastTranscriptGrowthAt == nil,
              controller.firstPartialRestartsThisTurn == 0 else { return false }
        let elapsed = Date().timeIntervalSince(started)
        if elapsed >= controller.firstPartialTimeoutSec, controller.totalVoiceSecondsThisTurn >= 2.0 {
            controller.firstPartialRestartsThisTurn += 1
            debugLog("[VoiceConv] first-partial watchdog: no partials after \(Int(controller.firstPartialTimeoutSec))s despite \(String(format: "%.1f", controller.totalVoiceSecondsThisTurn))s voice — restarting recognition task", level: .warning)
            startFreshRecognitionTask()
            return true
        }
        guard controller.totalVoiceSecondsThisTurn < 0.5, elapsed >= controller.longIdleRestartSec else { return false }
        debugLog("[VoiceConv] long-idle (\(Int(controller.longIdleRestartSec))s) — pre-emptive recognition task restart", level: .warning)
        startFreshRecognitionTask()
        controller.turnStartedAt = Date() // reset the clock
        return true
    }

    /// The two end-of-turn triggers.
    ///
    /// Primary: RMS-VAD detected sustained voice and then silence.
    ///
    /// Backup: the transcript has substantive content and hasn't grown in
    /// `controller.stalledTranscriptCommitSec`. This catches the case where ambient noise
    /// keeps VAD alive but the recogniser has committed everything it heard.
    /// Without it, a user who pauses then says "how about now" ends up
    /// extending an existing partial transcript instead of starting a new turn.
    @MainActor
    private func commitTurnIfSettled() {
        if controller.totalVoiceSecondsThisTurn >= controller.minVoiceForTurnSec,
           let last = controller.lastVoiceDetectedAt,
           Date().timeIntervalSince(last) > controller.endOfTurnSilenceSec {
            debugLog("[VoiceConv] VAD silence trigger (\(String(format: "%.1f", controller.totalVoiceSecondsThisTurn))s voice, \(String(format: "%.1f", Date().timeIntervalSince(last)))s silence) — finalising")
            finalizeUserTurn()
            return
        }
        let trimmed = controller.partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= controller.stalledTranscriptMinChars,
              let lastGrowth = controller.lastTranscriptGrowthAt,
              Date().timeIntervalSince(lastGrowth) > controller.stalledTranscriptCommitSec else { return }
        debugLog("[VoiceConv] transcript stalled (\(trimmed.count) chars, no growth for \(String(format: "%.1f", Date().timeIntervalSince(lastGrowth)))s) — finalising")
        finalizeUserTurn()
    }

    @MainActor
    func finalizeUserTurn() {
        guard controller.state == .listening else {
            debugLog("[VoiceConv] finalizeUserTurn ignored — state=\(controller.state), not listening")
            return
        }
        controller.silenceTimer?.invalidate()
        controller.silenceTimer = nil
        guard controller.useWhisperKitForCurrentSession, AppDependencies.current.providers.whisperKitSTTBridge.modelReady else {
            completeFinalizeUserTurn()
            return
        }
        Task { @MainActor [weak controller] in await controller?.audio.finalizeUserTurnViaWhisperKit() }
    }

    /// WhisperKit path. When the user picked it as
    /// the STT provider AND its model is ready, await the
    /// per-turn transcription before running the rest of the
    /// finalize flow. Apple's `controller.partialTranscript` is overwritten with
    /// the WhisperKit result so the downstream "send to AI"
    /// logic sees the same shape regardless of which provider
    /// produced the text. If WhisperKit throws, we fall through to
    /// whatever Apple's controller.recognizer captured — voice mode never goes dark.
    @MainActor
    private func finalizeUserTurnViaWhisperKit() async {
        guard controller.state == .listening else { return }
        do {
            let whisperText = try await AppDependencies.current.providers.whisperKitSTTBridge.transcribeAndReset()
            if !whisperText.isEmpty { controller.partialTranscript = whisperText }
            debugLog("[VoiceConv] WhisperKit transcript: \(whisperText.count) chars")
        } catch {
            debugLog("[VoiceConv] WhisperKit transcribe failed: \(error.localizedDescription) — using Apple fallback", level: .warning)
        }
        completeFinalizeUserTurn()
    }

    /// VAD said the user spoke but the recogniser produced no text.
    ///
    /// Tail of `finalizeUserTurn()` — a separate method so the
    /// WhisperKit-await branch can re-enter the same logic after the async
    /// transcribe completes. Apple's path calls this directly; WhisperKit's
    /// path awaits its bridge and then hops here.
    ///
    /// Two distinct failure modes, treated differently (conflating them
    /// kills voice too aggressively):
    ///
    ///   • Mic genuinely dead: buffers == 0 (audio engine running but the tap
    ///     isn't delivering frames). Hard tear-down after 3 consecutive —
    ///     needs a full restart to fix. 3 rather than 2 tolerates one
    ///     more transient before nuking voice.
    ///   • Recognizer confused: buffers > 0 but transcript empty (mic IS
    ///     hearing audio, controller.recognizer isn't classifying it as speech). Keep
    ///     re-arming, just rotate the recognition task. AirPods auto-pause,
    ///     ambient noise, or low-volume speech land here. Tearing down voice
    ///     for these is hostile — the user can controller.speak again any second. Capped
    ///     at 6 so a runaway loop can't burn battery (or corrupt AVFAudio).
    @MainActor
    private func handleEmptyTranscript() {
        controller.consecutiveEmptyReArms += 1
        let micIsAlive = controller.buffersSinceTaskStart > 0
        if let message = emptyTranscriptGiveUpMessage(micIsAlive: micIsAlive) {
            controller.permissionError = message
            controller.stop()
            return
        }
        debugLog("[VoiceConv] empty transcript — re-arming listening (retry \(controller.consecutiveEmptyReArms), micAlive=\(micIsAlive), buffers=\(controller.buffersSinceTaskStart), peak=\(String(format: "%.4f", controller.peakRMSSinceTaskStart)))", level: .warning)
        controller.lastVoiceDetectedAt = nil
        controller.totalVoiceSecondsThisTurn = 0
        // Reset the turn clock so the watchdog doesn't immediately
        // re-fire the same 30s-elapsed condition.
        controller.turnStartedAt = Date()
        // When the mic is alive, rotate the recognition task so the
        // next utterance lands on a clean transcript instead of
        // accumulating partials in a confused one.
        if micIsAlive { startFreshRecognitionTask() }
        armSilenceTimer()
    }

    /// The user-facing message to controller.stop voice with, or nil to keep re-arming.
    @MainActor
    private func emptyTranscriptGiveUpMessage(micIsAlive: Bool) -> String? {
        let peak = String(format: "%.4f", controller.peakRMSSinceTaskStart)
        if !micIsAlive, controller.consecutiveEmptyReArms >= 3 {
            debugLog("[VoiceConv] \(controller.consecutiveEmptyReArms) consecutive empty re-arms with NO buffers — mic appears dead, tearing down voice (peak=\(peak))", level: .error)
            return "Couldn't hear you. Tap to try again — or check that AirPods aren't in another app."
        }
        if micIsAlive, controller.consecutiveEmptyReArms >= 6 {
            debugLog("[VoiceConv] \(controller.consecutiveEmptyReArms) recognizer-confused re-arms (buffers=\(controller.buffersSinceTaskStart) peak=\(peak)) — tearing down voice as a safety controller.stop", level: .error)
            return "I'm not picking up what you're saying. Tap to try again."
        }
        return nil
    }

    func completeFinalizeUserTurn() {
        let transcript = controller.partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        debugLog("[VoiceConv] finalizing turn, transcript=\(transcript.count) chars")
        guard !transcript.isEmpty else {
            handleEmptyTranscript()
            return
        }
        // Real transcript handed off — clear the empty-re-arm counter.
        controller.consecutiveEmptyReArms = 0
        guard !droppedAsEcho(transcript) else { return }
        dispatchTranscript(transcript)
    }

    /// Both echo guards. Returns true when the transcript was dropped as
    /// bleed-through of the AI's own speech and listening has been re-armed.
    ///
    /// Echo guard: if this transcript looks substantively like the AI's
    /// last response, treat it as speaker bleed-through and drop it.
    /// Even with the drain delay, a sentence-end can sneak through over
    /// AirPods; this is the second line of defence.
    ///
    /// The drop must not be silent: the user could controller.speak, the guard
    /// would drop their input, and they'd see / hear NOTHING — they'd tap to
    /// talk again, get the same silent treatment, and start questioning the
    /// app. So it logs at `.warning` (so it surfaces in Troubleshooting →
    /// "Recent Problems") AND shows a short user-facing banner. If the guard
    /// is wrong, the user sees that and re-speaks.
    private func droppedAsEcho(_ transcript: String) -> Bool {
        if controller.looksLikeEcho(of: transcript) {
            debugLog("[VoiceConv] 🔁 echo-guard dropped transcript (looked like bleed-through of AI's last reply): \"\(transcript)\" — re-arming listening", level: .warning)
            AppDependencies.current.assistant.assistantInbox.flashTransientNotice(
                "Voice input matched the AI's last reply — likely echo. Tap to retry."
            )
            reArmListening()
            return true
        }
        guard isMedicalRefusalEcho(transcript) else { return false }
        debugLog("[VoiceConv] 🔁 medical-refusal echo trap — dropping transcript that re-triggers a refusal already on screen: \"\(transcript)\"", level: .warning)
        reArmListening()
        return true
    }

    /// Medical-refusal echo trap. The canned AFib / arrhythmia
    /// refusal literally contains the words "AFib" and "arrhythmia" — the
    /// exact tokens MedicalQueryGuard matches. Because voice actually
    /// SPEAKS that refusal (speakCompletedTurn), a partial mic echo that
    /// the generic 0.6-overlap guard misses would re-fire the guard
    /// and replay the refusal — an audible loop on top of the visible one.
    /// If this transcript would itself re-trigger a refusal that's ALREADY
    /// the last thing on screen AND it shares ≥40% of its tokens with that
    /// refusal (i.e. it's a fragment of our own speech, not a freshly
    /// worded new question), it's the refusal's own echo.
    private func isMedicalRefusalEcho(_ transcript: String) -> Bool {
        guard case .refuse(let reply) = MedicalQueryGuard.evaluate(transcript),
              controller.assistantViewModel.turns.last(where: { $0.role == .assistant })?.text == reply
        else { return false }
        return controller.echoOverlapRatio(transcript: transcript, against: reply) >= 0.4
    }

    /// Hand the transcript to the shared chat view model. It appends a user
    /// turn, kicks off the streaming send, and the chat UI updates the
    /// moment the assistant turn starts filling in.
    private func dispatchTranscript(_ transcript: String) {
        debugLog("[VoiceConv] handing to AssistantViewModel: provider=\(AppDependencies.current.providers.providerRegistry.activeProvider.id.rawValue), available=\(AppDependencies.current.providers.providerRegistry.activeProvider.isAvailable)")
        let outcome = controller.assistantViewModel.send(text: transcript, fromVoice: true)
        debugLog("[VoiceConv] send outcome: \(outcome)")
        switch outcome {
        case .dispatched:
            if spokeInstantTurn() { return }
            // streaming turn — fall through to TTS observation setup below
        case .queued:
            handleQueuedSend()
            return
        case .rejectedEmpty, .rejectedNoProvider:
            handleRejectedSend()
            return
        case .requiresConsent(let provider):
            handleConsentRequired(provider)
            return
        }
        beginSpeakingWindow()
    }

    /// Canned/instant turns (MedicalQueryGuard AFib /
    /// arrhythmia refusal, DeterministicIntent $0 answers) append a
    /// COMPLETE assistant turn and return WITHOUT streaming, so
    /// `isStreaming` stays false and no `speakableTextCursor` is ever
    /// published for that turn. The streaming observer only speaks text up
    /// to that cursor — so these turns were NEVER spoken, and because the
    /// controller.synthesizer was never handed an utterance, its `didFinish` (the only
    /// thing that re-arms the mic) never fired. Voice wedged in `.speaking`
    /// forever — the user's "afib question just spins calculating." Speak the
    /// finished turn directly; `didFinish` then re-arms listening.
    private func spokeInstantTurn() -> Bool {
        guard !controller.assistantViewModel.isStreaming,
              let last = controller.assistantViewModel.turns.last,
              last.role == .assistant,
              !last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        debugLog("[VoiceConv] dispatched a complete (non-streamed) turn — speaking it directly so voice doesn't wedge in .speaking")
        speakCompletedTurn(last.text)
        return true
    }

    /// The previous AI turn was still streaming; the view-model queued this
    /// transcript and will dispatch on finishStream.
    ///
    /// Merely re-arming listening and hoping the
    /// user would controller.speak again is not enough: if they didn't, the queued turn would dispatch
    /// silently (text in chat, no TTS) and the user reported "messages not
    /// sending" because they never heard a spoken reply. So we eagerly
    /// subscribe to `$isStreaming` so the moment our queued send fires
    /// (isStreaming flips false → true after the in-flight one finishes), we
    /// hook up TTS observation for the new turn. The user's message IS
    /// accepted; this just connects the voice loop to the eventual response.
    ///
    /// The observer waits for the next "stream started" edge AFTER this
    /// point: we see isStreaming = true RIGHT NOW (the in-flight one), then
    /// false when it finishes, then true again when our queued send fires.
    private func handleQueuedSend() {
        debugLog("[VoiceConv] send queued behind in-flight stream — wiring deferred TTS observation, also re-arming listening")
        controller.partialTranscript = ""
        controller.lastVoiceDetectedAt = nil
        controller.totalVoiceSecondsThisTurn = 0
        wireQueuedTurnObserver()
        startFreshRecognitionTask()
        armSilenceTimer()
        controller.state = .listening
    }

    /// Real drop — provider unavailable or no transcript. Surface it.
    private func handleRejectedSend() {
        let providerName = AppDependencies.current.providers.providerRegistry.activeProvider.id.displayName
        let detail = controller.assistantViewModel.errorMessage
            ?? "Voice can't send right now (\(providerName) has no API key)."
        debugLog("[VoiceConv] ❌ send dropped: \(detail)", level: .warning)
        controller.permissionError = detail
        reArmListening()
    }

    /// Voice can't surface a sheet — the chat view owns the consent
    /// presentation. Tell the user to open Assistant once and accept the
    /// per-provider data-sharing notice; their voice question is dropped this
    /// turn (they'll re-ask once consent is granted).
    private func handleConsentRequired(_ provider: ProviderID) {
        debugLog("[VoiceConv] send blocked on per-provider consent for \(provider.rawValue) — surfacing UI hint and stopping voice", level: .warning)
        controller.permissionError = "Open the Assistant tab once to accept the data-sharing notice for \(provider.displayName), then ask again."
        controller.partialTranscript = ""
        controller.lastVoiceDetectedAt = nil
        controller.totalVoiceSecondsThisTurn = 0
        controller.stop()
    }

    /// Clear this turn's transcript + VAD accumulators and go back to
    /// listening on a fresh recognition task.
    private func reArmListening() {
        controller.partialTranscript = ""
        controller.lastVoiceDetectedAt = nil
        controller.totalVoiceSecondsThisTurn = 0
        startFreshRecognitionTask()
        armSilenceTimer()
        controller.state = .listening
    }

    /// Don't suspend the mic — keep it running so the user can interrupt
    /// by speaking ("hands-free barge-in"). Triggers go through
    /// controller.checkForBargeIn() which has stricter gates than the normal turn-
    /// commit path so passing noise / TTS tails don't false-positive.
    ///
    /// `controller.ttsStartedAt` is cleared here; the controller.synthesizer delegate sets it when
    /// audio actually begins playing. Until then barge-in is gated off (it
    /// also checks `controller.synthesizer.isSpeaking`) so ambient noise during the
    /// "thinking" pause can't cancel the response. The barge-in baselines
    /// reset for the same reason — only speech arriving AFTER the AI starts
    /// counts, not leftovers from listening controller.state.
    private func beginSpeakingWindow() {
        controller.partialTranscript = ""
        // Track the assistant turn dispatch() reserved as the LAST element.
        controller.activeAssistantIndex = controller.assistantViewModel.turns.indices.last
        controller.spokenCharCursor = 0
        controller.currentResponseText = ""
        controller.textChunker.reset()
        controller.ttsStartedAt = nil
        controller.bargeInBaselineLength = controller.partialTranscript.count
        controller.bargeInBaselineWordCount = VoiceConversationController.wordCount(controller.partialTranscript)
        controller.lastSubBargeInRMSAt = Date()
        startFreshRecognitionTask()
        // Re-arm the timer so controller.checkForBargeIn() ticks during .speaking.
        armSilenceTimer()
        controller.state = .speaking
        // Subscribe to the view model's published controller.state so we mirror the
        // assistant's growing turn into TTS as it streams.
        observeAssistantStreaming()
    }

    // MARK: - Assistant streaming observation
    //
    // Voice doesn't run its own LLM; it observes the shared AssistantViewModel
    // and mirrors the streaming assistant turn into TTS as new tokens arrive.

    /// When a voice send returns `.queued` (because a
    /// previous AI stream was still in flight), the queued turn will
    /// dispatch later. We need to detect that exact moment so we can
    /// hook up TTS observation for the assistant turn that's about to
    /// stream. Watches `$isStreaming` for the next false → true edge
    /// AFTER the current in-flight stream ends, then sets up the
    /// usual streaming observation. One-shot — auto-cancels after the
    /// transition fires.
    ///
    /// Only a stream that started AFTER this point counts: the one running now
    /// is the stream we queued behind. The view model finishes it and drains
    /// our queued send in one main-actor run, so the observation loop delivers
    /// `isStreaming == true` once for both writes; the stream generation is
    /// what tells the two streams apart (`VoiceTurnPolicy.queuedTurnStarted`).
    @MainActor
    func wireQueuedTurnObserver() {
        // Bump the controller.speak generation so any in-flight observation
        // callbacks from the previous turn no-op when their values land.
        controller.responseSpeakGeneration += 1
        let myGeneration = controller.responseSpeakGeneration
        let wired = Self.streamEdge(of: controller)
        let handle = ObservationLoop.observe(controller, read: Self.streamEdge, onChange: { controller, now in
            // Ignore late-arriving values from a previous wiring.
            guard controller.responseSpeakGeneration == myGeneration,
                  VoiceTurnPolicy.queuedTurnStarted(wiredTo: wired, now: now) else { return }
            controller.audio.beginQueuedTurnSpeaking()
        })
        controller.assistantObservers.append(handle)
    }

    private static func streamEdge(of controller: VoiceConversationController) -> VoiceTurnPolicy.StreamEdge {
        VoiceTurnPolicy.StreamEdge(
            isStreaming: controller.assistantViewModel.isStreaming,
            generation: controller.assistantViewModel.streamGeneration)
    }

    /// Our queued send just started streaming — reset the speaking-window
    /// controller.state and wire TTS observation to the new assistant turn.
    @MainActor
    private func beginQueuedTurnSpeaking() {
        controller.activeAssistantIndex = controller.assistantViewModel.turns.indices.last
        controller.spokenCharCursor = 0
        controller.currentResponseText = ""
        controller.textChunker.reset()
        controller.ttsStartedAt = nil
        controller.bargeInBaselineLength = controller.partialTranscript.count
        controller.bargeInBaselineWordCount = VoiceConversationController.wordCount(controller.partialTranscript)
        controller.lastSubBargeInRMSAt = Date()
        controller.state = .speaking
        observeAssistantStreaming()
        debugLog("[VoiceConv] queued turn dispatched — TTS observation now wired (assistantIdx=\(controller.activeAssistantIndex ?? -1))")
    }

    /// Drops any prior observation before opening a fresh pair, and bumps
    /// the controller.speak-generation so in-flight callbacks from the
    /// previous response no-op when they finally fire.
    ///
    /// The `isStreaming` half watches for the AI finishing, so the remainder
    /// drains and the mic reopens for the user's follow-up.
    @MainActor
    func observeAssistantStreaming() {
        controller.cancelAssistantObservers()
        controller.responseSpeakGeneration += 1
        let myGeneration = controller.responseSpeakGeneration
        let speaking = ObservationLoop.observe(
            controller, initial: true,
            read: { ($0.assistantViewModel.turns, $0.assistantViewModel.speakableTextCursor) }
        , onChange: { controller, pair in
            guard controller.responseSpeakGeneration == myGeneration else { return }
            controller.audio.speakUpToCursor(turns: pair.0, cursors: pair.1)
        })
        let wired = Self.streamEdge(of: controller)
        let finishing = ObservationLoop.observe(controller, read: Self.streamEdge, onChange: { controller, now in
            guard controller.responseSpeakGeneration == myGeneration,
                  VoiceTurnPolicy.spokenResponseFinished(wiredTo: wired, now: now),
                  controller.state == .speaking else { return }
            controller.audio.finishResponseFromAssistant()
        })
        controller.assistantObservers.append(contentsOf: [speaking, finishing])
    }

    /// Watch the assistant's growing text and feed deltas to TTS at sentence
    /// boundaries — BUT only up to the speakable cursor published by the
    /// view model. Text past the cursor hasn't yet cleared the "will the
    /// model call a tool?" decision point and may still be rewound if a
    /// tool_use arrives. Speaking it prematurely causes the "Based on your
    /// data… oh wait" glitch the spec §4 streaming rule prevents.
    ///
    /// If no cursor is published yet, treat it as 0 — we're mid-round and
    /// nothing has been marked safe.
    @MainActor
    private func speakUpToCursor(turns: [ChatTurn], cursors: [UUID: Int]) {
        guard let idx = controller.activeAssistantIndex, idx >= 0, idx < turns.count else { return }
        let turn = turns[idx]
        guard turn.role == .assistant else { return }
        let safeLen = min(cursors[turn.id] ?? 0, turn.text.count)
        guard safeLen > controller.spokenCharCursor else { return }
        let start = turn.text.index(turn.text.startIndex, offsetBy: controller.spokenCharCursor)
        let end = turn.text.index(turn.text.startIndex, offsetBy: safeLen)
        let delta = String(turn.text[start ..< end])
        controller.spokenCharCursor = safeLen
        controller.currentResponseText = String(turn.text.prefix(safeLen))
        if let chunk = controller.textChunker.append(delta: delta) { controller.speak(chunk) }
    }

    @MainActor
    func finishResponseFromAssistant() {
        if let remainder = controller.textChunker.finalize() { controller.speak(remainder) }
        speakErrorRecoveryLineIfNeeded()
        // Tear the subscriptions down — they'll re-arm next time the user
        // finalises a turn. Keeping them live would cause us to react to
        // typed turns the user makes from the chat input bar.
        // Bump the generation FIRST so any lingering Combine publication
        // that was already in flight when finalize() ran no-ops in its
        // sink instead of pushing one more utterance after the response
        // is supposedly over.
        controller.responseSpeakGeneration += 1
        controller.cancelAssistantObservers()
        controller.activeAssistantIndex = nil
        controller.spokenCharCursor = 0
        // Synthesizer delegate handles the actual transition back to listening
        // when its queue drains.
    }

    /// Voice-mode network / API failure
    /// recovery. User-reported scenario: voice chat is happening,
    /// a network error fires, the chat banner shows the error
    /// text, but the voice UI dies silently — user keeps walking,
    /// says something into AirPods, hears nothing back, eventually
    /// looks at the phone, dismisses the banner, has to tap the
    /// talk button again to start over. Brutal hands-free UX.
    ///
    /// The fix: if the stream ended with `errorMessage` set AND we
    /// captured zero spoken text (so the controller.synthesizer queue is
    /// empty and `didFinish` will never fire on its own), controller.speak a
    /// short recovery line ourselves. That line drains through
    /// the synth normally; its `didFinish` delegate then triggers
    /// `scheduleListenAfterAudioDrain` → `beginUserTurn` and the
    /// mic is hot for the user's next utterance — no tap required.
    /// Also clear `errorMessage` so the visible banner doesn't
    /// keep nagging once the audio has already announced the
    /// failure.
    ///
    /// Only fires when we got NOTHING. Partial responses already
    /// drain through the synth and re-arm listening through the
    /// existing path; piling a recovery line on top of a
    /// half-complete answer would be hostile UX.
    @MainActor
    private func speakErrorRecoveryLineIfNeeded() {
        guard controller.assistantViewModel.errorMessage != nil,
              controller.currentResponseText.isEmpty,
              !controller.synthesizer.isSpeaking else { return }
        debugLog("[VoiceConv] AI stream errored with no text emitted — speaking recovery line + auto re-arming listening", level: .warning)
        controller.speak("Couldn't reach the AI. Try again.")
        controller.assistantViewModel.errorMessage = nil
    }

    /// Speak a COMPLETE assistant turn that arrived without streaming
    /// (MedicalQueryGuard refusal, DeterministicIntent answer). Mirrors the
    /// speaking-window setup the streaming path runs at the tail of
    /// `completeFinalizeUserTurn`, but hands the whole text to the
    /// controller.synthesizer in one utterance instead of feeding cursor-gated deltas.
    /// The synth's `didFinish` delegate re-arms the mic via
    /// `scheduleListenAfterAudioDrain`, so voice recovers exactly as it does
    /// after a streamed response — no wedged `.speaking` controller.state.
    @MainActor
    func speakCompletedTurn(_ text: String) {
        // No LLM backs a canned turn; clear any stale task so the
        // `didFinish` re-arm guard (`controller.state == .speaking, controller.llmTask == nil`)
        // can fire.
        cancelLLM()
        controller.partialTranscript = ""
        controller.spokenCharCursor = 0
        controller.currentResponseText = text
        controller.textChunker.reset()
        // Synth delegate stamps controller.ttsStartedAt when audio actually begins;
        // until then barge-in is gated off.
        controller.ttsStartedAt = nil
        controller.bargeInBaselineLength = 0
        controller.bargeInBaselineWordCount = 0
        controller.lastSubBargeInRMSAt = Date()
        startFreshRecognitionTask()
        armSilenceTimer()
        controller.state = .speaking
        controller.speak(text)
    }

    func cancelLLM() {
        controller.llmTask?.cancel()
        controller.llmTask = nil
    }
}
