import AVFoundation
import Foundation
import Speech
import UIKit

// Text-to-speech, permissions and the voice system prompt. The input side —
// start cue, interruption recovery, and streaming observation — lives in
// `VoiceConversationController+Audio.swift`.

extension VoiceConversationController {
    // MARK: - TTS

    /// Hallucination guard (item #9). Before TTS, scan
    /// the chunk for numeric claims that contradict the live
    /// workout snapshot and rewrite the offending span to the
    /// verified value. Logs every correction so we have observability
    /// on how often the model fabricates. No-op when there's no
    /// active workout snapshot.
    ///
    /// Routes through TTSTextNormalizer instead of
    /// PhoneticOverrides directly. The normalizer composes:
    ///   • domain abbreviations (BPM, HRV, VO2, Z1-Z5, etc.)
    ///   • pace strings ("8:45/mi" → "eight forty-five per mile")
    ///   • years ("2026" → "twenty twenty-six")
    ///   • ZIP code spell-out (handled inside PhoneticOverrides)
    ///   • homograph IPA hints ("live" → /laɪv/, AI-authored markup)
    /// PhoneticOverrides is the FINAL stage — it sees post-normalized
    /// text and emits the NSAttributedString.
    ///
    /// Wrap speak in the SafeObjC shim. The AI's TTS path
    /// is what the beta tester feared crashing their workout. After a
    /// phone-call interruption (logged 5 min before the workout
    /// started), AVSpeechSynthesizer.speak can raise
    /// NSInternalInconsistencyException on the first attempted
    /// utterance. Swift's `try` doesn't catch it — an uncaught
    /// NSException is SIGABRT. The shim @try/@catches.
    /// `voice` overrides `bestVoice` for scripted coach cues, which are
    /// localized to the app language rather than the AI's reply language.
    ///
    /// The spoken-form expansions ("zone one", "per minute") are English, so
    /// they apply only when the voice is.
    func speak(_ text: String, voice: AVSpeechSynthesisVoice? = nil) {
        let chosenVoice = voice ?? bestVoice
        let english = chosenVoice?.language.hasPrefix("en") ?? true
        let attributed = TTSTextNormalizer.normalize(
            announced(applyHallucinationGuard(to: perimeterScrubbed(text))), english: english
        )
        let utterance = AVSpeechUtterance(attributedString: attributed)
        utterance.voice = chosenVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.96
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        // Pre/post delays are deliberately ZERO — any non-zero value introduces
        // an audible gap between streamed sentence chunks and breaks the flow.
        // The synthesizer's internal queue handles back-to-back utterances.
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        var speakErr: NSError?
        if !FRSafeSpeak(synthesizer, utterance, &speakErr) {
            debugLog("[VoiceConv] synthesizer.speak failed (skipping TTS chunk): \(speakErr?.localizedDescription ?? "?")", level: .warning)
        }
    }

    /// The first audible chunk of each voice
    /// session prepends "Flo here." so the user hears WHO is
    /// speaking before content. Subsequent chunks drop the preamble
    /// so the conversation doesn't sound like a robot reciting its
    /// own name every other line.
    ///
    /// It also names the MODEL handling the session. The user's
    /// complaint was "I have no idea if it's apple or sonnet
    /// talking to me." With voice routing now session-sticky to
    /// the user's primary cloud (or Apple when no cloud is
    /// configured), naming the model once at session start
    /// settles that question without spoken UI instructions.
    /// Brief — one or two words appended to the existing preamble.
    private func announced(_ guarded: String) -> String {
        guard !hasAnnouncedSubsystem else { return guarded }
        hasAnnouncedSubsystem = true
        let modelTag = currentModelDisplayName()
        let preamble = AssistantSubsystem.voiceConversation.voiceAnnouncement
        // "Flo here. Sonnet." — the preamble is a whole sentence, so the
        // model name follows as its own rather than after a comma
        // ("Flo here., Sonnet.").
        return (modelTag.isEmpty ? preamble : "\(preamble) \(modelTag).") + " " + guarded
    }

    func stopSynthesizer() {
        _ = FRSafeStopSpeaking(synthesizer, .immediate, nil)
    }

    /// Short audible
    /// model identity for the voice-session preamble. Names the model
    /// that is answering this turn — the provider and model stamped on
    /// the reply being spoken, which routing (Apple selected → a consented
    /// cloud for voice) or a fallback may have changed from the picker's
    /// selection — and trims it to a 1-2 word form that sits naturally in
    /// "Flo here. Sonnet."-style preambles.
    ///
    /// Apple Intelligence is the wordy one, so it's just "Apple". Anthropic's
    /// "Sonnet" / "Haiku" / "Opus" and OpenAI's "GPT-5" / "GPT-5 mini" all
    /// reduce cleanly to the display name's first word.
    func currentModelDisplayName() -> String {
        let (providerID, displayName) = respondingModel()
        switch providerID {
        case .apple: return "Apple"
        case .anthropic: return displayName.split(separator: " ").first.map(String.init) ?? "Claude"
        case .openai: return displayName.split(separator: " ").first.map(String.init) ?? "GPT"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        case .deepseek: return "DeepSeek"
        }
    }

    /// The provider and model display name of the reply being spoken, or
    /// the picker's selection when no reply turn is active.
    private func respondingModel() -> (ProviderID, String) {
        let turns = assistantViewModel.turns
        guard let index = activeAssistantIndex, turns.indices.contains(index),
              let providerID = turns[index].providerID else {
            return (assistantViewModel.activeProviderID, assistantViewModel.activeModelDisplayName)
        }
        let name = turns[index].modelID.map {
            AppDependencies.current.providers.providerRegistry.displayName(forApiID: $0, providerID: providerID)
        } ?? providerID.displayName
        return (providerID, name)
    }

    /// Hallucination-guard pre-flight (item #9). Verifies each numeric
    /// claim in `text` against the live workout snapshot; replaces
    /// any contradicting span with the verified value and logs the
    /// correction so we can monitor the model's fabrication rate.
    /// Pure / order-preserving — substitutions happen back-to-front
    /// so earlier ranges stay valid.
    func applyHallucinationGuard(to text: String) -> String {
        guard let snapshot = liveWorkoutSnapshotProvider?() else { return text }
        let discrepancies = MetricsVerifier.verify(text, against: snapshot)
        guard !discrepancies.isEmpty else { return text }
        debugLog(MetricsVerifier.formatForLog(discrepancies), level: .warning)
        // Also stash the corrections so the NEXT AI turn's
        // system prompt can warn the model not to fabricate. Without
        // this, the guard silently rewrites every fabricated number
        // and the model never learns. Real-user log showed two
        // consecutive HR fabrications (claimed 72/71, actual 91/88) —
        // the model didn't change behaviour because nothing told it
        // to.
        MetricsVerifier.recordCorrections(discrepancies)
        // Apply substitutions back-to-front so earlier ranges remain
        // valid as the string mutates.
        var corrected = text
        let sorted = discrepancies.sorted { $0.range.lowerBound > $1.range.lowerBound }
        for d in sorted {
            corrected.replaceSubrange(d.range, with: d.actual)
        }
        return corrected
    }

    /// Push-to-talk / "send now" — forces the current listening turn to
    /// commit whatever transcript exists, regardless of VAD or silence
    /// state. PTT fallback: users need a visible lever when wind,
    /// sustained noise, or a recognizer stall keeps the turn from
    /// auto-finalising. No-op if the controller isn't currently listening.
    @MainActor
    func forceFinalizeTurn() {
        guard state == .listening else { return }
        debugLog("[VoiceConv] forceFinalizeTurn (PTT) — user-driven commit")
        finalizeUserTurn()
    }

    /// Public hook for "Stop" UI actions that live outside the voice flow
    /// (e.g. the chat Stop button). Kills the synthesizer AND drops any
    /// queued streaming observers so tokens arriving after Stop don't get
    /// re-queued for TTS. Safe to call when voice is idle — it's a no-op
    /// for the speaking-state transition path, but we ALWAYS bump the
    /// generation token + tear observers down so a stale observation
    /// callback can't queue a sneaky last utterance after stop.
    ///
    /// Race the generation guard closes: the user taps Stop, we call
    /// `synthesizer.stopSpeaking` + `cancelAssistantObservers()`,
    /// but an observation callback already on the runloop fires AFTER removeAll
    /// returns and pushes one more chunk into `speak(_:)` →
    /// `synthesizer.speak(...)`. The synthesizer happily plays it. Bumping
    /// `responseSpeakGeneration` lets the late callback drop on the floor
    /// instead of pushing through. The generation bump therefore comes FIRST,
    /// which guarantees any callback that hasn't yet returned no-ops even
    /// if it's mid-execution.
    @MainActor
    func stopAnyOngoingSpeech() {
        responseSpeakGeneration += 1
        _ = FRSafeStopSpeaking(synthesizer, .immediate, nil)
        textChunker.reset()
        cancelAssistantObservers()
        activeAssistantIndex = nil
        spokenCharCursor = 0
        let wasMidResponse = (state == .speaking || state == .thinking)
        guard wasMidResponse, !isStoppingFully else { return }
        scheduleListeningRestartAfterStop()
    }

    /// The auto-restart guards against:
    ///   (a) full teardown via `stop()` (`isStoppingFully` true) —
    ///       beginUserTurn during teardown re-allocates audio
    ///       state that's about to be torn down; pointless and
    ///       race-prone.
    ///   (b) the synthesizer-still-releasing window — a synchronous
    ///       beginUserTurn here can race AVSpeechSynthesizer's
    ///       audio-buffer release. installTap then crashes with
    ///       "Failed to create tap due to format mismatch" because
    ///       the input bus is mid-reconfigure. Deferring one runloop
    ///       tick + a 100 ms settle lets the synth fully release.
    ///
    /// State may have moved on by then (user pressed Stop again, scene
    /// backgrounded, etc.), so it is re-checked before resuming.
    @MainActor
    private func scheduleListeningRestartAfterStop() {
        Task { @MainActor [weak self] in
            await sleepQuietly(100_000_000, context: "scheduleListeningRestartAfterStop")
            guard let self, !self.isStoppingFully else { return }
            // Not `.idle`: that is where `stop()` leaves voice, and
            // restarting from it would reopen the mic the user just closed.
            guard self.state == .speaking || self.state == .thinking else { return }
            Task { @MainActor in await self.beginUserTurn() }
        }
    }

    // MARK: - Permissions

    func ensurePermissions() async -> Bool {
        guard await speechRecognitionAllowed() else { return false }
        return await micAllowed()
    }

    /// Speech recognition — log the existing status, request when undetermined.
    private func speechRecognitionAllowed() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        debugLog("[VoiceConv] current speech auth status: \(describe(status))")
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await requestSpeechAuthorization()
        case .denied:
            await report(String(localized: "Speech Recognition is denied. Open Settings → Emuqu → enable Speech Recognition.", bundle: LanguageManager.appBundle))
            return false
        case .restricted:
            await report(String(localized: "Speech Recognition is restricted on this device (e.g. by Screen Time or parental controls).", bundle: LanguageManager.appBundle))
            return false
        @unknown default:
            await report(String(localized: "Speech Recognition permission was not granted.", bundle: LanguageManager.appBundle))
            return false
        }
    }

    /// Show the system prompt and report the outcome.
    private func requestSpeechAuthorization() async -> Bool {
        debugLog("[VoiceConv] requesting speech recognition authorization (should show prompt)…")
        // `@Sendable`: the framework does not promise the main queue for this
        // callback, and a main-actor closure asserts it on entry.
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
        debugLog("[VoiceConv] speech auth result: \(describe(status))")
        let granted = status == .authorized
        if !granted { await report(String(localized: "Speech Recognition permission was not granted.", bundle: LanguageManager.appBundle)) }
        return granted
    }

    /// Microphone. The app targets iOS 17+ so we use AVAudioApplication only.
    private func micAllowed() async -> Bool {
        let status = AVAudioApplication.shared.recordPermission
        debugLog("[VoiceConv] current mic permission: \(describe(status))")
        switch status {
        case .granted:
            return true
        case .undetermined:
            debugLog("[VoiceConv] requesting mic permission (should show prompt)…")
            let granted = await AVAudioApplication.requestRecordPermission()
            debugLog("[VoiceConv] mic permission result: \(granted ? "granted" : "denied")")
            if !granted { await report(String(localized: "Microphone permission was not granted.", bundle: LanguageManager.appBundle)) }
            return granted
        case .denied:
            await report(String(localized: "Microphone access is denied. Open Settings → Emuqu → enable Microphone.", bundle: LanguageManager.appBundle))
            return false
        @unknown default:
            await report(String(localized: "Microphone permission was not granted.", bundle: LanguageManager.appBundle))
            return false
        }
    }

    /// Surface a permission failure on the main actor.
    private func report(_ message: String) async {
        await MainActor.run { self.permissionError = message }
    }

    func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .restricted: "restricted"
        case .authorized: "authorized"
        @unknown default: "unknown"
        }
    }

    func describe(_ perm: AVAudioApplication.recordPermission) -> String {
        switch perm {
        case .undetermined: "undetermined"
        case .denied: "denied"
        case .granted: "granted"
        @unknown default: "unknown"
        }
    }

    // MARK: - System prompt

    func buildSystemPrompt() -> String {
        Self.voiceCoachPersona + "\n\n" + Self.voiceCoachHardRules
    }

    /// The persona and the be-specific-or-be-silent contract.
    private static let voiceCoachPersona = """
        You are a voice coach companion for a runner/walker wearing AirPods. \
        You will be read aloud by a text-to-speech engine, so avoid markdown, \
        code fences, lists, and emoji. Speak in short, conversational sentences \
        — 1 to 3 at a time, no more.

        BE SPECIFIC OR BE SILENT — this is the whole job:
        - Every line MUST be anchored to a concrete number or observation from \
          the CONTEXT block and say what it MEANS. \
          "HR drifted 6% over the last mile at the same pace — that's a heat or \
          fuel signal; ease off if it climbs more." NOT "nice work" / "keep it \
          up" / "go for it" / "great run" / "you're doing great."
        - NEVER emit generic encouragement, praise, or filler. If nothing in the \
          context stands out as worth saying right now, SAY NOTHING — silence is \
          the correct output, not a motivational platitude.
        - Lead with the data point, then the cause-and-effect, then (optionally) \
          what to do. One specific useful sentence beats three vague ones.
        - Translate sports-science jargon to plain English ("above your usual \
          range", not "ACWR 1.4"; "carrying fatigue", not "TSB -12").
        """

    /// The two non-negotiables, kept separate so a persona edit can't
    /// accidentally reword them.
    private static let voiceCoachHardRules = """
        HARD RULES:
        - Only reference data that appears in the CONTEXT block. Do not invent \
          terrain, baselines, history, or metrics the user didn't mention. If you \
          don't have the data to make a SPECIFIC point, stay silent.
        - Never issue commands. Offer, don't order. Close observations with an \
          optional phrase like "your call", "if you feel like it", or "up to you".

        The user can interrupt you at any time.
        """
}

// MARK: - AVSpeechSynthesizerDelegate

// Every delegate callback is `nonisolated` and hops to the main actor with
// `Task { @MainActor in }`, so the conformance needs no `@preconcurrency`.
extension VoiceConversationController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        // TTS audio just started playing — mark the grace-period anchor HERE,
        // not when we optimistically set state=.speaking. Otherwise the grace
        // window elapses during the "thinking" pause before any sound plays
        // and barge-in fires on ambient noise.
        Task { @MainActor in
            if self.ttsStartedAt == nil || self.ttsStartedAt.map({ Date().timeIntervalSince($0) > 5 }) == true {
                self.ttsStartedAt = Date()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // If the synthesizer queue drained and we're still in speaking state,
            // transition back to idle. During trigger preemption, restore the
            // prior state. The check is made after the hop, on the controller's
            // own synthesizer: an utterance queued between this delegate call
            // and the hop must keep the speaking state, and the delegate's
            // parameter may not cross into the task.
            guard !self.synthesizer.isSpeaking else { return }
            switch state {
            case .triggerSpeaking where llmTask == nil: finishTriggerSpeech()
            case .speaking where llmTask == nil: finishResponseSpeech()
            default: break
            }
        }
    }

    /// Chain pending triggers before restoring the prior state.
    /// Multiple alerts queued during a long user response play
    /// one-after-another instead of each restoring → re-listening → next
    /// preempting.
    @MainActor
    func finishTriggerSpeech() {
        if !pendingTriggers.isEmpty {
            drainPendingTriggersIfIdle()
            return
        }
        let prior = preemptedState ?? .idle
        preemptedState = nil
        if prior == .listening || prior == .speaking {
            scheduleListenAfterAudioDrain()
        } else {
            state = .idle
        }
    }

    /// Critical: only restart listening when BOTH the synth queue
    /// is drained AND the LLM has stopped producing tokens. Without
    /// this guard, the synth can briefly drain between sentences
    /// while the LLM is still streaming new tokens — the mic
    /// re-opens and catches the next sentence playing through the
    /// speaker, transcribing the AI's own words.
    ///
    /// Drain any triggers that piled up during the user's
    /// response BEFORE re-arming the mic. Otherwise the user starts speaking
    /// again and the queued alerts never get a chance.
    @MainActor
    private func finishResponseSpeech() {
        if assistantViewModel.isStreaming {
            debugLog("[VoiceConv] synth idle but LLM still streaming — holding off mic restart")
            return
        }
        if textChunker.hasPendingContent {
            debugLog("[VoiceConv] synth idle but spoken buffer not empty — holding off mic restart")
            return
        }
        if !pendingTriggers.isEmpty {
            drainPendingTriggersIfIdle()
            return
        }
        scheduleListenAfterAudioDrain()
    }

    /// Restart listening after a delay long enough for the speaker's output
    /// buffer to fully drain. AVSpeechSynthesizer's didFinish fires when the
    /// synth's internal queue is empty, but audio still plays through the
    /// speaker for several hundred ms afterwards (audio output buffer +
    /// Bluetooth latency on AirPods + room reverb). Without this delay the
    /// mic re-opens during the tail of the last spoken word and transcribes
    /// the AI's own voice.
    ///
    /// 1.2s — empirically what AirPods + a typical room need before the
    /// last audible syllable of TTS has fully stopped. With voiceChat
    /// mode + AEC this would be ~150ms; without proper AEC this is the
    /// honest number.
    @MainActor
    func scheduleListenAfterAudioDrain() {
        Task { @MainActor [weak self] in
            await sleepQuietly(1_200_000_000, context: "scheduleListenAfterAudioDrain")
            self?.resumeListeningIfStillQuiet()
        }
    }

    /// Defensive: state may have changed during the drain delay (user tapped,
    /// trigger fired, sheet closed). Only restart if we're still in a
    /// "should be listening" state and the synth has stayed quiet.
    @MainActor
    private func resumeListeningIfStillQuiet() {
        guard !synthesizer.isSpeaking else { return }
        switch state {
        case .speaking, .triggerSpeaking:
            Task { @MainActor in await self.beginUserTurn() }
        default:
            break
        }
    }

    /// Hands-free interrupt during AI speech. Three gates, ALL required:
    ///   1. Grace period — first 600ms of TTS is immune so the AI's own
    ///      first syllables can't retrigger interrupt via echo.
    ///   2. Sustained loud voice — RMS above threshold for bargeInSustainedSec
    ///      continuously. Single peaks (cough, car horn, footstep) don't
    ///      sustain long enough. Necessary but not sufficient: wind, a
    ///      passing truck, a barking dog all sustain loud RMS too.
    ///   3. At least `bargeInMinNewWords` recognized words appeared in the
    ///      transcript AFTER TTS started. This is the critical gate: noise
    ///      doesn't decode into words; only speech does. Requiring the user
    ///      say "hey stop" or "never mind" rather than clear their throat is
    ///      the right trade — if they really want to interrupt, two words
    ///      is nothing; but it kills every wind/car/gnat false positive.
    ///
    /// This works best with AirPods (mic at mouth, TTS in ear = acoustic
    /// isolation). Phone speaker over-mixes TTS into the mic; the recognizer
    /// tends to transcribe its own words, which IS useful here — if the
    /// "words" are just echo we'd still fire. The echo check below is the
    /// guard against that.
    ///
    /// Gate 0 is `synthesizer.isSpeaking` — CRITICAL: only fire barge-in when
    /// the synthesizer is actually making sound. During the "thinking" window
    /// between send() and the first TTS sentence playing, any ambient noise
    /// would otherwise trigger interrupt() and cancel the in-flight LLM
    /// response — users see this as "I speak but nothing comes back".
    ///
    /// Gate 3 counts WORDS rather than characters because the recognizer
    /// occasionally emits single-char punctuation or corrections that don't
    /// represent actual speech. Gate 4 is the echo guard: if the "new words"
    /// are just the AI's own speech leaking through the mic, we compare
    /// against what the synthesizer has been speaking this turn and stay put.
    @MainActor
    func checkForBargeIn() {
        guard state == .speaking else { return }
        guard synthesizer.isSpeaking else { return }
        guard let ttsStart = ttsStartedAt,
              Date().timeIntervalSince(ttsStart) > bargeInGracePeriodSec else { return }
        guard let lastSub = lastSubBargeInRMSAt,
              Date().timeIntervalSince(lastSub) >= bargeInSustainedSec else { return }
        let newWords = Self.wordCount(partialTranscript) - bargeInBaselineWordCount
        guard newWords >= bargeInMinNewWords else { return }
        let candidate = String(partialTranscript.dropFirst(bargeInBaselineLength))
        guard !isLikelyEchoOfCurrentResponse(candidate) else { return }
        debugLog("[VoiceConv] 🛑 barge-in: \(newWords) new words decoded during sustained loud audio (\(String(format: "%.1f", Date().timeIntervalSince(lastSub)))s) — interrupting AI")
        interrupt()
    }

    /// Thin wrappers over `VoiceEchoHeuristics`, which owns the tokeniser and
    /// the thresholds. These supply the controller state each comparison runs
    /// against; the comparison itself is pure and tested.
    static func wordCount(_ text: String) -> Int {
        VoiceEchoHeuristics.wordCount(text)
    }

    /// Echo check specifically for in-flight TTS — compares against what the
    /// AI has STREAMED during the current turn, not what it said last turn.
    @MainActor
    func isLikelyEchoOfCurrentResponse(_ candidate: String) -> Bool {
        VoiceEchoHeuristics.isEchoOfInFlightResponse(
            candidate: candidate,
            streamedSoFar: currentResponseText
        )
    }

    /// Is `transcript` substantially the same text as the last thing the AI
    /// just said? Drops "echo" turns where the mic caught the speaker's tail
    /// audio despite the drain delay.
    @MainActor
    func looksLikeEcho(of transcript: String) -> Bool {
        let lastAssistant = assistantViewModel.turns.last(where: { $0.role == .assistant })?.text ?? ""
        return VoiceEchoHeuristics.looksLikeEcho(
            transcript: transcript,
            ofLastAssistantTurn: lastAssistant
        )
    }

    static func echoTokens(_ text: String) -> Set<String> {
        VoiceEchoHeuristics.tokens(text)
    }

    /// Used by the medical-refusal echo trap to tell a partial echo of the
    /// spoken refusal (high overlap) from a genuinely new question (low).
    func echoOverlapRatio(transcript: String, against reference: String) -> Double {
        VoiceEchoHeuristics.overlapRatio(of: transcript, against: reference)
    }
}

// MARK: - TTS voice choice

/// Picks the voice the conversation speaks with. Kept off
/// `VoiceConversationController` (which caches the result in `bestVoice`):
/// it reads no controller state.
@MainActor
enum ConversationVoicePicker {
    /// Honors the user's "force English AI" setting for
    /// voice synthesis too. Without this a Japanese-locale phone
    /// would speak with a Japanese voice even when the AI's text was being
    /// forced to English by the system prompt override.
    static func pick() -> AVSpeechSynthesisVoice? {
        let forceEnglish = AppDependencies.current.app.settingsManager.settings.forceAIEnglish
        let preferredLanguage = forceEnglish ? "en-US" : Locale.current.language.maximalIdentifier
        guard let chosen = bestInstalledVoice(matching: preferredLanguage) else {
            return AVSpeechSynthesisVoice(language: preferredLanguage)
                ?? AVSpeechSynthesisVoice(language: "en-US")
        }
        debugLog("[VoiceConv] selected TTS voice: \(chosen.name) (\(chosen.identifier)) quality=\(qualityName(chosen.quality))")
        // Helpful nudge if the device only has the basic voice installed.
        if chosen.quality == .default {
            debugLog("[VoiceConv] tip: only the default Apple voice is installed — Settings → Accessibility → Spoken Content → Voices → English → choose an Enhanced or Premium voice for a much more natural sound.", level: .warning)
        }
        return chosen
    }

    /// The best installed voice for the language family (en-US, en-GB, en-AU
    /// all match "en"), or nil when none is installed.
    ///
    /// Novelty voices (Bahh, Cellos, Trinoids, …) and any voice flagged
    /// personal are skipped — the latter need explicit user opt-in.
    ///
    /// Ranking is premium > enhanced > default; at equal quality it prefers
    /// voices whose identifier doesn't include ".compact.", which are the
    /// small / robotic legacy ones.
    private static func bestInstalledVoice(matching preferredLanguage: String) -> AVSpeechSynthesisVoice? {
        let langPrefix = preferredLanguage.split(separator: "-").first.map(String.init) ?? "en"
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.language.hasPrefix(langPrefix)
                && !voice.voiceTraits.contains(.isNoveltyVoice)
                && !voice.voiceTraits.contains(.isPersonalVoice)
        }
        return candidates.sorted { a, b in
            let qa = qualityRank(a.quality)
            let qb = qualityRank(b.quality)
            if qa != qb { return qa > qb }
            return !a.identifier.contains(".compact.") && b.identifier.contains(".compact.")
        }.first
    }

    static func qualityRank(_ q: AVSpeechSynthesisVoiceQuality) -> Int {
        switch q {
        case .premium: 3
        case .enhanced: 2
        case .default: 1
        @unknown default: 0
        }
    }

    static func qualityName(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: "premium"
        case .enhanced: "enhanced"
        case .default: "default"
        @unknown default: "unknown"
        }
    }
}

// MARK: - File-scope helpers
//
// Kept out of VoiceConversationController. Each names no member of the
// type and calls nothing that stayed behind, so none needed to be inside
// it. `private` at file scope is fileprivate, so every call site in this
// file resolves exactly as before.

/// The FDA output perimeter for everything the app says out loud.
///
/// Six call sites feed this method (streamed chunks via
/// `ingestInterjectionDelta`, the finalized remainder, completed turns,
/// the error-recovery line, the wake-word acknowledgement), and LLM
/// `textDelta` chunks would otherwise go straight from the provider to
/// `AVSpeechSynthesizer` unscrubbed. Scrubbing here rather than at
/// each call site means a future call site is covered by construction.
///
/// Ordering matters: scrub first, then `applyHallucinationGuard`, then the
/// session preamble. The perimeter must see the model's words, not a string
/// that already has "Flo here." glued to the front of it.
private func perimeterScrubbed(_ text: String) -> String {
    guard CoachVoiceGuard.containsProhibitedLanguage(text) else { return text }
    let result = CoachVoiceGuard.scrub(text)
    for trigger in result.triggers {
        debugLog("[VoiceConv] CoachVoiceGuard intercepted spoken output: \(trigger.reason)", level: .warning)
    }
    return result.scrubbed
}
