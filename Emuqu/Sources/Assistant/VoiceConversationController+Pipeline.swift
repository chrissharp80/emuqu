import AVFoundation
import Foundation
import Speech
import UIKit

// The audio-pipeline lifecycle — engine start/stop, recognition task setup and
// restart.

extension VoiceAudioPipeline {
    // MARK: - Audio pipeline lifecycle
    //
    // The pipeline (audio session + engine tap + controller.recognizer) stays alive from
    // start() until controller.stop(). State transitions only swap the recognition REQUEST
    // so each "turn" (user turn, or barge-in watch) gets a clean transcript.
    // Keeping the mic hot is what enables voice interrupt while TTS is playing.

    func configureAudioSessionForConversation() throws {
        // Claim through the coordinator. This is what
        // stops a spoken workout cue's `.playback` claim from
        // clobbering us mid-conversation: the coordinator picks
        // `.playAndRecord` because voice has the strict-superset claim,
        // and the cue's claim is treated as satisfied by the same session.
        // Calling `setCategory` directly here AND for the cue would give a
        // last-writer-wins clobber.
        AppDependencies.current.services.audioSessionCoordinator.claim(.voice, mode: .voiceRecord)
        let session = AVAudioSession.sharedInstance()
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        debugLog("[VoiceConv] audio session ready: category=\(session.category.rawValue), mode=\(session.mode.rawValue), sampleRate=\(session.sampleRate)")
    }

    @MainActor
    /// Hard-resets the engine before any node is touched.
    ///
    /// The controller is a singleton and the engine gets reused across voice
    /// sessions; its cached node formats can drift out of sync with the
    /// current AVAudioSession config (especially when the session or a
    /// different subsystem like AVSpeechSynthesizer reconfigures audio
    /// between sessions). Querying outputFormat on a stale engine can return
    /// a format that no longer matches the bus, and installTap throws
    /// "Failed to create tap due to format mismatch" — as an Obj-C exception,
    /// which Swift can't catch → hard crash. Stop + reset forces the engine
    /// to re-initialise node controller.state from the live session.
    ///
    /// Every call here goes through SafeObjC shims. Bare-Swift calls would
    /// trust that `controller.stop`, `removeTap`, and `reset` never
    /// raise NSException. They DO — when the audio session is in a degraded
    /// controller.state (e.g. after a phone-call interruption, which a user
    /// log shows happening 5 minutes before workout start), any of these can
    /// raise `NSInternalInconsistencyException`. Swift's `try` doesn't catch
    /// it, so each is a latent SIGABRT on the workout-start path. All three
    /// return Swift errors via the shim and continue gracefully if the
    /// underlying call complains.
    ///
    /// Kept separate from `startAudioEngineAndRecognizer` to keep that method's
    /// cyclomatic complexity down; this pre-flight is four of its branches.
    private func resetAudioEngineSafely() {
        if controller.audioEngine.isRunning {
            var stopErr: NSError?
            if !FRSafeAudioEngineStop(controller.audioEngine, &stopErr) {
                debugLog("[VoiceConv] audioEngine.stop failed (continuing): \(stopErr?.localizedDescription ?? "?")", level: .warning)
            }
        }
        var removeTapErr: NSError?
        if !FRSafeRemoveTap(controller.audioEngine.inputNode, 0, &removeTapErr) {
            // Idempotent — "no tap to remove" surfaces as either no-op
            // or a recoverable error; either way we proceed.
            debugLog("[VoiceConv] removeTap pre-flight: \(removeTapErr?.localizedDescription ?? "no-op")", level: .info)
        }
        var resetErr: NSError?
        if !FRSafeAudioEngineReset(controller.audioEngine, &resetErr) {
            debugLog("[VoiceConv] audioEngine.reset failed (continuing): \(resetErr?.localizedDescription ?? "?")", level: .warning)
        }
    }

    func startAudioEngineAndRecognizer() async throws {
        guard let recognizer = controller.recognizer else { throw VoiceConversationController.VoiceError.recognizerUnavailable }
        guard recognizer.isAvailable else { throw VoiceConversationController.VoiceError.recognizerNotAvailable }
        debugLog("[VoiceConv] recognizer ready: locale=\(recognizer.locale.identifier), supportsOnDevice=\(recognizer.supportsOnDeviceRecognition)")
        try activateAudioSessionForListening()
        resetAudioEngineSafely()
        let input = controller.audioEngine.inputNode
        let format = try configuredInputFormat(of: input)
        controller.bufferLoggedNonSilent = false
        controller.bufferTickCount = 0
        try installMicTap(on: input, format: format)
        try prepareAudioEngine()
        try await startAudioEngineWithRetry()
        debugLog("[VoiceConv] audioEngine.isRunning=\(controller.audioEngine.isRunning)")
        // Note: we don't call startFreshRecognitionTask() here — beginUserTurn()
        // does it. Avoids the double-task-start that was logging two 'new
        // recognition task started' lines.
    }

    /// installTap fires on the audio render
    /// thread. With the controller now `@MainActor`-isolated, both
    /// `controller.recognitionRequest` and `auditBufferActivity` are MainActor
    /// controller.state. Hop via a Task. SFSpeechAudioBufferRecognitionRequest's
    /// `.append` is documented thread-safe so the buffer arrives
    /// promptly even with the dispatch hop; the audit logger reads
    /// and updates per-tick counters that must stay on MainActor for
    /// the observers downstream.
    ///
    /// The tap fires on the realtime audio render
    /// thread; AVFoundation only guarantees `buffer`'s backing
    /// store for the SYNCHRONOUS duration of this callback. Reading
    /// it inside the `Task { @MainActor }` below runs after the
    /// callback returns, when the engine may have recycled the
    /// store — a use-after-free / torn read (corrupt RMS → broken
    /// VAD/barge-in). Deep-copy synchronously, on this thread, now.
    private func makeMicTapBlock() -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [weak controller] buffer, _ in
            guard let bufferCopy = Self.deepCopyPCMBuffer(buffer) else { return }
            Task { @MainActor [weak controller] in controller?.audio.consumeMicBuffer(bufferCopy) }
        }
    }

    @MainActor
    private func consumeMicBuffer(_ bufferCopy: AVAudioPCMBuffer) {
        controller.recognitionRequest?.append(bufferCopy)
        // Only the user's turn: fed in every state, the bridge also took in
        // the assistant's own speech and transcribed it with the next turn.
        if controller.useWhisperKitForCurrentSession, controller.state == .listening {
            AppDependencies.current.providers.whisperKitSTTBridge.appendAudio(bufferCopy)
        }
        auditBufferActivity(bufferCopy)
    }

    /// Route through `FRSafeInstallTap`. Beta tester
    /// crash log (SIGABRT at signal 6, stack inside AVFAudio's
    /// installTap path at offset +1652) — `installTap` raises
    /// Objective-C `NSException` on a format-mismatch / already-
    /// tapped condition that the pre-flight `setVoiceProcessingEnabled`
    /// toggle can introduce. Swift can't catch NSException; the
    /// shim @try/@catches and returns a Swift error.
    ///
    /// Two-stage installTap. The format we read from
    /// `input.outputFormat(forBus: 0)` AFTER `setVoiceProcessingEnabled`
    /// is the format the input node will PRODUCE downstream, which on
    /// iOS 26 doesn't always match the input bus's actual current
    /// format until the engine is fully reconfigured. The mismatch
    /// raises `NSInvalidArgumentException` inside installTap and our
    /// ObjC shim catches it. Throwing and aborting the turn there
    /// leaves the controller in `now listening`
    /// controller.state but with no tap installed, so the mic produced no audio
    /// and the user's first message was the only one that worked
    /// (later toggles re-entered the same broken controller.state).
    ///
    /// The robust fallback is to retry with `nil` — `installTap`
    /// documents nil as "use the bus's current format," which is
    /// exactly what we want when our reading is stale. If that ALSO
    /// fails, we genuinely can't proceed and throw.
    private func installMicTap(on input: AVAudioInputNode, format: AVAudioFormat) throws {
        let tapBlock = makeMicTapBlock()
        var tapErr: NSError?
        var tapInstalled = FRSafeInstallTap(input, 0, 1024, format, tapBlock, &tapErr)
        if !tapInstalled {
            let firstReason = tapErr?.localizedDescription ?? "unknown installTap failure"
            debugLog("[VoiceConv] installTap with explicit format failed (\(firstReason)) — retrying with bus default format", level: .warning)
            tapErr = nil
            tapInstalled = FRSafeInstallTap(input, 0, 1024, nil, tapBlock, &tapErr)
        }
        guard tapInstalled else {
            let reason = tapErr?.localizedDescription ?? "unknown installTap failure"
            debugLog("[VoiceConv] installTap failed — \(reason)", level: .warning)
            throw VoiceConversationController.VoiceError.audioSessionUnavailable(reason: reason)
        }
    }

    /// Wrap `prepare()` too. Documented as non-throwing
    /// but the beta crash log frame distribution suggests the
    /// NSException may have come from prepare's graph realization
    /// rather than the tap install itself. Cheap insurance.
    private func prepareAudioEngine() throws {
        var prepErr: NSError?
        guard !FRSafePrepareAudioEngine(controller.audioEngine, &prepErr) else { return }
        removeMicTapBestEffort()
        let reason = prepErr?.localizedDescription ?? "unknown prepare failure"
        debugLog("[VoiceConv] audioEngine.prepare failed — \(reason)", level: .warning)
        throw VoiceConversationController.VoiceError.audioSessionUnavailable(reason: reason)
    }

    /// Swift `try` only catches Swift errors. The
    /// user's crash log showed AVFAudio raising an NSException
    /// through `startAndReturnError:` (frame 13–14 inside AVFAudio,
    /// SIGABRT at signal 6). Route the call through the tiny
    /// SafeObjC shim so the exception lands in a Swift `Error`
    /// we can react to instead of aborting the process.
    ///
    /// A user log captured
    /// `controller.audioEngine.start failed — coreaudio error -10868`
    /// exactly when AirPods Pro dropped mid-conversation and the
    /// engine retry fired DURING the audio route transition.
    /// -10868 is `kAudioUnitErr_FormatNotSupported`, which iOS
    /// raises transiently when the new audio route's format hasn't
    /// settled yet. The route change events in the same window
    /// (07:44:59 → 07:48:10) confirm the engine is restarting
    /// mid-transition. A short retry after a 200 ms breather
    /// lets the route settle. Two attempts is enough — if the
    /// session is genuinely unavailable after that, the user's
    /// hardware is in a controller.state we can't recover from without their
    /// intervention.
    private func startAudioEngineWithRetry() async throws {
        var startErr: NSError?
        if FRSafeStartAudioEngine(controller.audioEngine, &startErr) { return }
        let firstReason = startErr?.localizedDescription ?? "unknown failure"
        debugLog("[VoiceConv] audioEngine.start failed — \(firstReason) — retrying after 200 ms breather (route may be mid-transition)", level: .warning)
        await sleepQuietly(200_000_000, context: "startErr")
        startErr = nil
        if FRSafeStartAudioEngine(controller.audioEngine, &startErr) { return }
        removeMicTapBestEffort()
        let reason = startErr?.localizedDescription ?? "unknown failure"
        debugLog("[VoiceConv] audioEngine.start failed (after retry) — \(reason)", level: .warning)
        throw VoiceConversationController.VoiceError.audioSessionUnavailable(reason: reason)
    }

    /// Best-effort cleanup so a leftover tap doesn't poison the next call
    /// (which would then crash with "tap already installed").
    ///
    /// removeTap goes through the shim too: a failure in a
    /// wedged controller.state is exactly when removeTap is most likely to also throw.
    private func removeMicTapBestEffort() {
        var removeErr: NSError?
        _ = FRSafeRemoveTap(controller.audioEngine.inputNode, 0, &removeErr)
    }

    /// Tears down any existing task + request, then resets the per-task
    /// diagnostic counters so the next 1110 tells us truthfully whether audio
    /// was flowing THIS task.
    @MainActor
    func startFreshRecognitionTask() {
        guard let recognizer = controller.recognizer else { return }
        controller.recognitionTask?.cancel()
        controller.recognitionTask = nil
        controller.recognitionRequest?.endAudio()
        let request = makeRecognitionRequest(for: recognizer)
        controller.recognitionRequest = request
        controller.buffersSinceTaskStart = 0
        controller.peakRMSSinceTaskStart = 0
        controller.lastBufferRMS = 0
        debugLog("[VoiceConv] new recognition task started (onDevice=\(request.requiresOnDeviceRecognition))")
        controller.recognitionTask = recognizer.recognitionTask(with: request) { [weak controller] result, error in
            Task { @MainActor in controller?.audio.applyRecognition(result, error) }
        }
    }

    @MainActor
    private func applyRecognition(_ result: SFSpeechRecognitionResult?, _ error: Error?) {
        if let error {
            reportRecognitionError(error as NSError)
        } else if let result {
            handleTranscription(result.bestTranscription.formattedString)
        }
    }

    /// Prefer on-device recognition when supported — works offline, is
    /// faster, and avoids the silent failure when the device can't reach
    /// Apple's server-side controller.recognizer.
    ///
    /// `.search` biases the language model toward shorter chat-style
    /// utterances rather than long-form prose. Per Apple Developer Forums
    /// / Voice + Speech researchers: this commits faster than `.dictation`
    /// in interactive contexts.
    private func makeRecognitionRequest(for recognizer: SFSpeechRecognizer) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(iOS 16.0, *) { request.addsPunctuation = true }
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.taskHint = .search
        return request
    }

    /// Log a controller.recognizer failure at the right volume, then hand it to
    /// `handleRecognitionError` for recovery.
    ///
    /// Log-level gating. The 1110 "No speech detected" error
    /// fires NORMALLY when the user is silent OR when we're in `.speaking`
    /// (TTS is playing, mic is suppressed by half-duplex). Real-user logs
    /// were 70% these noise entries. Promote to .warning ONLY when the code
    /// isn't 1110 (truly anomalous), or when we were listening and zero
    /// audio buffers arrived — which suggests the audio engine actually
    /// died. Otherwise demote to .info so the diagnostic detail still ships
    /// but doesn't drown the log.
    private func reportRecognitionError(_ nsError: NSError) {
        let isSilenceCode = nsError.code == 1110 && nsError.domain == "kAFAssistantErrorDomain"
        let mightBeRealProblem = !isSilenceCode || (controller.state == .listening && controller.buffersSinceTaskStart == 0)
        let logLevel: DebugLogger.LogLevel = mightBeRealProblem ? .warning : .info
        debugLog("[VoiceConv] recognition error: \(nsError.domain):\(nsError.code) — \(nsError.localizedDescription)", level: logLevel)
        logAudioPipelineDiagnostic(level: logLevel)
        handleRecognitionError(nsError)
    }

    /// Enrich the warning with audio-pipeline controller.state so the exported error
    /// catalog (which filters to warnings/errors) tells us WHY the recogniser
    /// reported no speech:
    ///   • buffers=0            → mic tap dead; audio route or engine is broken.
    ///   • buffers>0, peak<0.01 → mic heard silence; phone in pocket, wrong
    ///                            route, user far away.
    ///   • buffers>0, peak>0.05 → audio flowed with real energy but Apple's
    ///                            recogniser didn't classify it as speech.
    ///
    /// This dump (buffers / peakRMS / engine controller.state /
    /// port type) is user-environment-fingerprinting in os_log if it ships in
    /// Release. The error code itself is always logged by the caller so a
    /// triage grep finds the failure; only the dump is DEBUG-only.
    private func logAudioPipelineDiagnostic(level: DebugLogger.LogLevel) {
        #if DEBUG
        let engineRunning = controller.audioEngine.isRunning
        let route = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType.rawValue ?? "unknown"
        let diag = "buffers=\(controller.buffersSinceTaskStart) peakRMS=\(String(format: "%.4f", controller.peakRMSSinceTaskStart)) lastRMS=\(String(format: "%.4f", controller.lastBufferRMS)) engine=\(engineRunning) route=\(route) state=\(controller.state)"
        debugLog("[VoiceConv] recognition error diagnostic: \(diag)", level: level)
        #endif
    }

    @MainActor
    func handleRecognitionError(_ error: NSError) {
        guard shouldRestartRecognition(after: error) else { return }
        // Cooldown guard — if we just restarted, don't loop.
        if let last = controller.lastRecognitionRestartAt,
           Date().timeIntervalSince(last) < controller.recognitionRestartCooldownSec {
            return
        }
        controller.lastRecognitionRestartAt = Date()
        debugLog("[VoiceConv] restarting recognition task after \(error.domain):\(error.code)")
        startFreshRecognitionTask()
    }

    /// Deliberately NOT a permissive `default → restart`. With one, a user
    /// reported "it didn't seem as able to hear me as it was before
    /// you 'improved' it": the permissive default
    /// meant ANY error during .listening triggered a fresh
    /// recognition task, including transient errors where the
    /// existing task was about to deliver a final result. That
    /// killed in-flight transcription mid-utterance and made
    /// recognition feel sluggish / drop words. The 1.5 s cooldown
    /// wasn't enough — the cancel-and-restart cycle itself drops
    /// any audio buffered in the task's internal pipeline.
    ///
    /// Back to the original: restart ONLY on the two known-safe
    /// codes (1110 "no speech" + 301 "cancelled"). Other errors
    /// mean the task is genuinely terminating; the next user
    /// turn's natural begin will start a fresh task. The
    /// "voice silently dies" failure mode the permissive default
    /// was meant to catch should be handled instead by the
    /// long-idle / first-partial / stalled-transcript watchdogs
    /// already in VoiceConversationController+Audio.swift, which
    /// are smarter about distinguishing dead-task from
    /// healthy-but-quiet states.
    ///
    /// Restarting the recognition task while TTS is playing
    /// thrashes AVAudio: every restart re-arms the mic loop, which competes
    /// with the speech synthesiser for the audio session and can interrupt
    /// playback mid-sentence. Only restart while we're genuinely listening;
    /// the natural .speaking → .listening transition at TTS end re-arms
    /// recognition cleanly.
    @MainActor
    private func shouldRestartRecognition(after error: NSError) -> Bool {
        VoiceTurnPolicy.shouldRestartRecognition(
            errorDomain: error.domain, errorCode: error.code, state: controller.state
        )
    }

    @MainActor
    func handleTranscription(_ text: String) {
        controller.partialTranscript = text
        // Track transcript growth as a SECONDARY commit signal (primary is
        // RMS-VAD silence). Without this backup, ambient noise that keeps the
        // RMS detector alive can prevent a turn from ever finalising even
        // though the recogniser has long since stopped picking up new words.
        if text.count != controller.lastTranscriptLength {
            controller.lastTranscriptLength = text.count
            controller.lastTranscriptGrowthAt = Date()
        }
    }

    /// Full audio-pipeline restart rather than just a new recognition task.
    ///
    /// On phone speaker, playing TTS through AVSpeechSynthesizer while the
    /// session is `.playAndRecord + .measurement` (no hardware AEC)
    /// triggers iOS feedback-protection that mutes the mic input. The
    /// mute does NOT clear automatically when TTS ends — the next
    /// recognition task fires against a silent input and eventually
    /// reports kAFAssistantErrorDomain:1110 with zero buffers received.
    /// A fresh SFSpeechAudioBufferRecognitionRequest alone is not enough
    /// because the tap itself is still attached to a muted bus.
    ///
    /// Stopping + resetting + restarting the engine (via
    /// startAudioEngineAndRecognizer, which already does all three)
    /// forces iOS to re-wire the input path from scratch and the mic
    /// comes back live. Cost is a small latency spike per turn (~50ms);
    /// benefit is reliable voice on speaker playback, which was the
    /// failure mode documented in a user's diagnostic export.
    @MainActor
    func beginUserTurn() async {
        resetTurnAccumulators()
        do {
            try await startAudioEngineAndRecognizer()
        } catch {
            debugLog("[VoiceConv] beginUserTurn audio restart failed: \(error.localizedDescription)", level: .error)
            controller.permissionError = String(localized: "Couldn't restart the mic: \(error.localizedDescription)", bundle: LanguageManager.appBundle)
            controller.stop()
            return
        }
        // The user ended voice while the engine was starting: close the mic
        // again rather than listening after End.
        guard controller.state != .idle else {
            controller.stop()
            return
        }
        // Fresh recognition request resets the transcript the engine holds.
        startFreshRecognitionTask()
        armSilenceTimer()
        controller.state = .listening
    }

    /// Everything a new turn has to forget: VAD voice + silence accumulators,
    /// the transcript-growth tracker behind the stalled-transcript backup, the
    /// turn-start stamp for the 30 s max-duration watchdog, and the empty-
    /// re-arm counter (capped across CONSECUTIVE empties, not lifetime, so a
    /// new user-driven turn always gets the full retry budget).
    @MainActor
    private func resetTurnAccumulators() {
        controller.partialTranscript = ""
        controller.lastVoiceDetectedAt = nil
        controller.totalVoiceSecondsThisTurn = 0
        controller.lastTranscriptGrowthAt = nil
        controller.lastTranscriptLength = 0
        controller.turnStartedAt = Date()
        controller.firstPartialRestartsThisTurn = 0
        controller.consecutiveEmptyReArms = 0
    }

    /// Deep-copy a PCM buffer captured in a realtime audio tap so it
    /// survives being read after the tap callback returns (the engine
    /// reuses the original's backing store). `nonisolated` — it runs on
    /// the audio render thread, never the main actor. Copies the raw
    /// AudioBufferList bytes so it's format-agnostic (float or int16).
    nonisolated static func deepCopyPCMBuffer(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: src.frameCapacity) else {
            return nil
        }
        copy.frameLength = src.frameLength
        let srcList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: src.audioBufferList))
        let dstList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard srcList.count == dstList.count else { return nil }
        for i in 0 ..< srcList.count {
            guard let sData = srcList[i].mData, let dData = dstList[i].mData else { continue }
            let bytes = min(Int(srcList[i].mDataByteSize), Int(dstList[i].mDataByteSize))
            memcpy(dData, sData, bytes)
            dstList[i].mDataByteSize = UInt32(bytes)
        }
        return copy
    }

    /// Computes RMS of the buffer and updates voice-activity-detection controller.state.
    /// Drives end-of-turn detection (silence after sustained voice) without
    /// trusting the recogniser's noisy transcript.
    func auditBufferActivity(_ buffer: AVAudioPCMBuffer) {
        controller.bufferTickCount += 1
        if controller.bufferTickCount == 1 || controller.bufferTickCount % 200 == 0 {
            debugLog("[VoiceConv] tap tick #\(controller.bufferTickCount), frames=\(buffer.frameLength)")
        }
        guard let rms = Self.rms(of: buffer) else { return }
        let now = Date()
        recordBufferRMS(rms)
        // Hop to the main actor for controller.state mutation. Buffers come on a high-priority
        // audio thread; we only need a quick atomic store of the most recent
        // voice timestamp + duration accumulator.
        Task { @MainActor [weak controller] in
            controller?.audio.processVAD(rms: rms, at: now)
        }
    }

    /// Root-mean-square amplitude of the buffer's first channel, or nil when
    /// the buffer carries no float samples.
    /// `internal` so the barge-in measurement can be tested. This decides
    /// whether the user is speaking over the assistant; too sensitive and the
    /// assistant cuts itself off on room noise, too dull and it talks over the
    /// user.
    static func rms(of buffer: AVAudioPCMBuffer) -> Float? {
        guard let channelData = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        var sumSquares: Float = 0
        for i in 0 ..< frames {
            let s = channelData[i]
            sumSquares += s * s
        }
        return sqrt(sumSquares / Float(frames))
    }

    /// Running summary for diagnostics — surfaced in the recognition error
    /// log so an exported error catalog answers "was audio even flowing
    /// when Apple reported no-speech-detected?" without the full verbose
    /// log attached.
    private func recordBufferRMS(_ rms: Float) {
        controller.buffersSinceTaskStart += 1
        if rms > controller.peakRMSSinceTaskStart { controller.peakRMSSinceTaskStart = rms }
        controller.lastBufferRMS = rms
        if !controller.bufferLoggedNonSilent, rms > 0.003 {
            controller.bufferLoggedNonSilent = true
            debugLog("[VoiceConv] ✅ first non-silent audio buffer received (rms=\(String(format: "%.4f", rms)))")
        }
    }

    /// Barge-in tracking: stamps the moment audio drops BELOW the (higher)
    /// barge-in threshold. `controller.checkForBargeIn` measures elapsed time since that
    /// stamp to require sustained loud voice.
    ///
    /// The `.speaking` branch is diagnostic — it logs when we see loud audio
    /// while the AI is speaking, so we can tell whether the mic is actually
    /// reading user voice (or just AI bleed-through) at the moment they try
    /// to interrupt.
    @MainActor
    func processVAD(rms: Float, at now: Date) {
        // Approximate buffer duration so we can tally "active voice time".
        if let last = controller.lastBufferAt {
            let dt = now.timeIntervalSince(last)
            if dt > 0, dt < 0.5, rms > controller.voiceRMSThreshold, controller.state == .listening {
                controller.totalVoiceSecondsThisTurn += dt
            }
        }
        controller.lastBufferAt = now
        if rms > controller.voiceRMSThreshold { controller.lastVoiceDetectedAt = now }
        if rms < controller.bargeInRMSThreshold {
            controller.lastSubBargeInRMSAt = now
        } else if controller.state == .speaking, controller.bufferTickCount % 5 == 0 {
            debugLog("[VoiceConv] 🔊 loud-audio during speaking: rms=\(String(format: "%.4f", rms))")
        }
    }

}

// MARK: - File-scope helpers
//
// Kept outside VoiceConversationController: each names no member of the
// type and calls nothing inside it, so none needs to be a member.
// `private` at file scope is fileprivate, so every call site in this
// file resolves the same way.

/// Defensive re-activation of the audio session
/// before we touch any AVAudioEngine node. Real crash log
/// (SIGABRT in AVFAudio at `controller.audioEngine.start()`) showed the
/// session can drop into an inactive controller.state between TTS finish
/// and `scheduleListenAfterAudioDrain` re-entering this
/// function — AirPods interruption, a workout cue's coordinator handoff,
/// or a route change while the drain delay sleeps. AVFAudio
/// then throws an uncatchable Obj-C `NSInternalInconsistency`
/// when start() is called against an inactive session. Bail
/// with a Swift-catchable error here instead of letting the
/// app crash.
///
/// setActive fails for a handful of typical reasons: another app holds
/// the session, a system alarm is active, or a focus-mode override.
/// Surface it as a recoverable error; the caller catches and shows
/// `controller.permissionError` to the user.
private func activateAudioSessionForListening() throws {
    do {
        try AVAudioSession.sharedInstance().setActive(true, options: [])
    } catch {
        debugLog("[VoiceConv] setActive(true) failed before engine start: \(error.localizedDescription)", level: .warning)
        throw VoiceConversationController.VoiceError.audioSessionUnavailable(reason: error.localizedDescription)
    }
}

/// Explicitly DISABLE voice processing. AUVoiceIO requires a properly
/// wired bidirectional audio graph and crashes with
/// "auou/vpio/appl, render err: -1" when that graph isn't connected.
///
/// IMPORTANT: this call can change the bus format, so we query
/// `outputFormat` AFTER it (not before) — otherwise the cached
/// format we install the tap with will not match the node's actual
/// format, and the Obj-C exception from installTap will crash.
///
/// `setVoiceProcessingEnabled` is documented as
/// throwing (Swift catches NSError) but has been observed to
/// raise NSException on stale controller.state (e.g. just after a session
/// route change). Shim catches both NSException and NSError.
private func configuredInputFormat(of input: AVAudioInputNode) throws -> AVAudioFormat {
    var vpErr: NSError?
    if FRSafeSetVoiceProcessing(input, false, &vpErr) {
        debugLog("[VoiceConv] voice processing disabled (half-duplex pattern)")
    } else {
        debugLog("[VoiceConv] setVoiceProcessingEnabled(false) failed: \(vpErr?.localizedDescription ?? "?")", level: .warning)
    }
    let format = input.outputFormat(forBus: 0)
    debugLog("[VoiceConv] input format after reset+vp-toggle: sampleRate=\(format.sampleRate), channels=\(format.channelCount)")
    // Fail loud with a clear message rather than let installTap
    // crash with an uncatchable Obj-C exception.
    guard format.sampleRate > 0, format.channelCount > 0 else {
        throw VoiceConversationController.VoiceError.audioInputUnusable(
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount)
        )
    }
    return format
}
