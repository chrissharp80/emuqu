import AudioToolbox
import AVFoundation
import Combine
import Foundation
import Speech
import UIKit

// MARK: - Voice Conversation Controller
//
// Owns the STT → typed-chat-LLM → streaming-TTS loop for hands-free use
// during a workout.
//
// Flow:
//   user taps Talk → listening starts
//   user speaks; SFSpeechRecognizer transcribes with on-device recognition
//   on pause (VAD) or explicit button → transcript goes to the active AIProvider
//   provider streams tokens; we chunk them at sentence boundaries and enqueue
//   utterances to AVSpeechSynthesizer so the reply plays out as it arrives
//   user can tap Interrupt (or, when implemented, speak) to kill the current
//   TTS and jump back to listening mid-reply
//
// Trigger preemption:
//   WorkoutVoiceCoach routes spoken-tier events through `handleTrigger(_:)`
//   which cancels whatever the conversation is doing, speaks the alert line,
//   and then drops back to the state we were in before (usually idle).
//
// Conversation scope:
//   - Separate from the main AI tab's chat history (ephemeral per workout)
//   - Reuses the user's currently-selected provider + model from ProviderRegistry
//   - System prompt carries the "real data only, always optional" contract plus
//     a fact-sheet snapshot the controller's consumer provides on each turn
// The controller is `@MainActor`-isolated. The observed properties are
// only mutated from MainActor methods; the AV / Speech / NotificationCenter
// delegate callbacks are `nonisolated` and hop back via `Task { @MainActor
// in ... }`. The class-level annotation makes that contract explicit so
// Swift 6 strict-concurrency can verify it instead of relying on a reader
// to spot the @MainActor-on-every-method pattern. Full decomposition into
// `AudioSessionManager` / `SpeechRecognitionPipeline` / `TTSDispatcher` /
// `VoiceInterruptDetector` is deferred.
@Observable
@MainActor
final class VoiceConversationController: NSObject {
    /// Shared instance — there's only one mic + recognizer + synth at the
    /// hardware level, and we want the typed chat view AND any other surface
    /// (workout recording, future floating mic) to drive the same controller
    /// rather than fight for the audio session.
    static let shared = VoiceConversationController()

    /// Typed errors for the speech-recognition / audio-engine startup
    /// path, rather than stringly-typed `NSError(domain:code:)` values
    /// that are hard to discriminate at the call site.
    /// `localizedDescription` carries the user-facing copy so callers that
    /// surface `error.localizedDescription` keep working unchanged.
    enum VoiceError: LocalizedError {
        /// Speech recognizer couldn't be constructed for the current locale.
        case recognizerUnavailable
        /// Recognizer exists but reports `isAvailable == false` — typically a
        /// temporary system-side throttle.
        case recognizerNotAvailable
        /// `AVAudioSession.setActive(true)` threw (another app holds the
        /// session, system alarm active, focus mode override). The
        /// associated value is the underlying error's localizedDescription
        /// so the user-facing copy stays informative.
        case audioSessionUnavailable(reason: String)
        /// `AVAudioEngine.inputNode.outputFormat(forBus:)` returned a zero
        /// or single-channel format — happens when another app is holding
        /// the mic. Surfaced loudly because installTap on this format would
        /// crash with an uncatchable Obj-C exception.
        case audioInputUnusable(sampleRate: Double, channelCount: Int)

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable:
                return "Speech recognizer not created (locale unsupported?)"
            case .recognizerNotAvailable:
                return "Speech recognition isn't available right now (try again in a moment)."
            case .audioSessionUnavailable(let reason):
                return "Audio session unavailable (\(reason)). Try again in a moment."
            case .audioInputUnusable(let sampleRate, let channelCount):
                return "Audio input has no usable format (\(sampleRate) Hz, \(channelCount) ch) — is another app holding the mic?"
            }
        }
    }

    // MARK: State

    enum State: Equatable {
        case idle
        case starting   // sheet just opened, audio + permissions warming up
        case listening
        case thinking
        case speaking
        case triggerSpeaking

        /// Compact label suitable for the Watch's status pill. Keep
        /// stable strings — `WatchSessionManager.voiceChatStateLabel`
        /// switches on them.
        var watchLabel: String {
            switch self {
            case .idle: return "idle"
            case .starting: return "starting"
            case .listening: return "listening"
            case .thinking: return "thinking"
            case .speaking: return "speaking"
            case .triggerSpeaking: return "alert"
            }
        }
    }

    var state: State = .idle {
        didSet {
            // Mirror voice-chat state changes to the Watch
            // so the wrist UI clears its "Starting…" overlay the moment
            // iOS actually transitions to listening / speaking. The
            // Watch already knows iOS *received* the tap (replyHandler
            // confirms) but until this push it had no way to see what
            // happened next — barge-in barely got a flicker, "thinking"
            // was invisible, etc. Throttling isn't needed; state
            // transitions are infrequent (a few per minute at most).
            guard state != oldValue else { return }
            AppDependencies.current.services.watchConnectivityBridge.pushVoiceChatState(state.watchLabel)
        }
    }
    /// Partial live transcription as the user speaks (empty when not listening).
    var partialTranscript: String = ""
    /// The assistant's most recent response text — streams in as the LLM responds.
    var currentResponseText: String = ""
    /// Surfaced to the UI when the mic permission or speech authorization is denied.
    var permissionError: String?

    /// Has this voice session played the
    /// "Coach here." subsystem identification yet? First utterance per
    /// session gets the preamble so the user hears which AI mouth is
    /// speaking; subsequent utterances drop it. Reset to false on
    /// `start()`. The trigger-driven `playAIPromptTriggerNow` path
    /// also resets so a workout-coach interjection that pre-empted
    /// the conversation gets its own announcement.
    var hasAnnouncedSubsystem = false

    /// Capture: engine, recogniser, voice-activity detection.
    var audio: VoiceAudioPipeline {
        VoiceAudioPipeline(controller: self)
    }

    func beginUserTurn() async { await audio.beginUserTurn() }
    func finalizeUserTurn() { audio.finalizeUserTurn() }
    func finishResponseFromAssistant() { audio.finishResponseFromAssistant() }
    func observeAssistantStreaming() { audio.observeAssistantStreaming() }
    func startAudioEngineAndRecognizer() async throws { try await audio.startAudioEngineAndRecognizer() }

    /// Pure RMS over a buffer — no controller state. Kept reachable here for
    /// `VoiceAudioMeasurementTests`.
    static func rms(of buffer: AVAudioPCMBuffer) -> Float? { VoiceAudioPipeline.rms(of: buffer) }

    // The rest of the capture surface, reached by `+Speech` and `+Control`.
    func configureAudioSessionForConversation() throws { try audio.configureAudioSessionForConversation() }
    func installInterruptionObserver() { audio.installInterruptionObserver() }
    func removeInterruptionObserver() { audio.removeInterruptionObserver() }
    func teardownAudioPipeline() { audio.teardownAudioPipeline() }
    func startFreshRecognitionTask() { audio.startFreshRecognitionTask() }
    func cancelLLM() { audio.cancelLLM() }

    // MARK: Config hooks — set by the consumer

    /// Provides a current factual context snapshot to prepend to the system
    /// prompt. Called each time the user finishes a turn. Return nil to skip
    /// context injection.
    var contextSnapshotProvider: (() -> String?)?

    /// STT provider selected at session start. Captured
    /// at the start of the listening session so toggling the
    /// preference mid-conversation doesn't half-flip the pipeline
    /// (which would mix Apple and WhisperKit transcripts and confuse
    /// the user). Read by the audio tap (route buffers) and by
    /// `finalizeUserTurn` (which transcript to use). Set in `start()`.
    var useWhisperKitForCurrentSession: Bool = false

    /// Rate-limited stamp for the last recognition-task restart. Without this
    /// a persistent error like 1110 "no speech" would loop: task starts,
    /// errors immediately, we restart, errors immediately, forever.
    var lastRecognitionRestartAt: Date?
    /// Minimum gap between automatic recognition restarts. Short enough that
    /// the user's next utterance lands on a live task, long enough to avoid
    /// tight loops.
    let recognitionRestartCooldownSec: Double = 1.5

    /// Structured live-workout snapshot for the
    /// hallucination guard. Consumed by `speak(_:)` to
    /// cross-check numeric claims against the authoritative current
    /// snapshot before the synthesizer starts. Set by the recorder
    /// alongside `contextSnapshotProvider`. Optional — when nil the
    /// guard no-ops (e.g. assistant is talking outside an active
    /// workout) and the original text speaks unchanged.
    var liveWorkoutSnapshotProvider: (() -> WorkoutAIContext?)?

    // MARK: Internal

    /// Lazy to defer `AVSpeechSynthesizer` cold init until the first
    /// time the controller actually needs to speak. First init triggers
    /// AVFoundation to prep its audio graph (~50-150 ms on the main
    /// thread); eagerly allocating it at controller construction blocks
    /// the AI chat tab's text field availability at startup. Since we
    /// rarely need the synthesiser before the user's first voice
    /// interaction, lazy-ing it off the critical path is free.
    @ObservationIgnored lazy var synthesizer = AVSpeechSynthesizer()
    /// Cached choice of best installed voice — picker lives in
    /// VoiceConversationController+Audio.swift. Stored property has to
    /// be in the class body, not the extension.
    @ObservationIgnored lazy var bestVoice: AVSpeechSynthesisVoice? = pickBestVoice()
    @ObservationIgnored var recognizer: SFSpeechRecognizer?
    /// Lazy for the same reason as `synthesizer` — `AVAudioEngine()`'s
    /// init does IOKit work that can stall main for 50-200 ms. The
    /// engine isn't used until the user taps the mic button to start
    /// dictation; defer creation to then.
    @ObservationIgnored lazy var audioEngine = AVAudioEngine()
    @ObservationIgnored var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored var llmTask: Task<Void, Never>?
    /// Buffers streaming LLM text and emits complete sentences ready for TTS.
    /// Extracted from this controller so the sentence-chunking + markdown-
    /// stripping logic can be tested in isolation.
    let textChunker = SpokenTextChunker()
    /// Shared chat view model — voice turns land in the same conversation as
    /// typed turns, use the user's selected provider, same system prompt,
    /// same history. The voice controller is a pipe, not a parallel AI.
    /// Computed property (not stored) so the @MainActor-isolated `.shared`
    /// is only accessed from the @MainActor methods that read it.
    @MainActor
    var assistantViewModel: AssistantViewModel { AppDependencies.current.assistant.assistantViewModel }
    /// Combine subscriptions watching the view model's streaming response.
    var assistantObservers: [ObservationHandle] = []

    /// An `ObservationHandle` keeps its loop armed until cancelled — releasing
    /// it does not stop it, unlike a Combine cancellable.
    func cancelAssistantObservers() {
        assistantObservers.forEach { $0.cancel() }
        assistantObservers.removeAll()
    }
    /// Set true for the duration of a full `stop()`
    /// teardown. Prevents the auto-restart-listening branch in
    /// `stopAnyOngoingSpeech` from firing during the
    /// `stop() → cancel() → stopAnyOngoingSpeech()` re-entry chain,
    /// which crashes installTap with a format-mismatch exception
    /// (AVSpeechSynthesizer is still releasing its audio buffer when
    /// beginUserTurn tries to install a new mic tap, and the input
    /// bus format is mid-reconfigure).
    var isStoppingFully: Bool = false

    /// Monotonic identifier for each "speak the AI's response" cycle.
    /// `observeAssistantStreaming()` snapshots the value when it sets up
    /// the Combine sinks; `stopAnyOngoingSpeech()` and
    /// `finishResponseFromAssistant()` bump it. The sinks check the
    /// snapshotted value before pushing into TTS — pending Combine
    /// publications already in flight when stop fires no-op instead of
    /// queueing one last utterance after the user thought they'd
    /// silenced everything. Closes the "AI keeps talking after Stop"
    /// race the user kept reporting.
    var responseSpeakGeneration: Int = 0
    /// Index into `assistantViewModel.turns` of the assistant turn currently
    /// being streamed (set after calling `send(text:)`).
    var activeAssistantIndex: Int?
    /// Character count of the active assistant turn the last time we fed TTS,
    /// used to slice out the delta as new tokens arrive.
    var spokenCharCursor: Int = 0
    /// Saved state to restore after a trigger preemption.
    var preemptedState: State?

    // Pending triggers queue. If every threshold / mile-marker /
    // decoupling alert preempted the in-flight LLM stream + TTS, a
    // user mid-question would get their answer cut off and the
    // trigger would speak instead — perceived as the chat "dying."
    // So triggers enqueue when the AI is busy and drain when the
    // current response finishes (synth + LLM both idle), so the
    // user's answer always completes before the coaching alert
    // plays. When the AI is idle, triggers fire immediately.
    enum PendingTrigger {
        /// `.spoken` tier — message is the literal phrase to TTS.
        case spokenLiteral(String)
        /// `.aiSpoken` tier — message is a PROMPT for the model.
        case aiPrompt(String)
    }
    var pendingTriggers: [PendingTrigger] = []
    @ObservationIgnored var silenceTimer: Timer?
    /// Wall-clock moment the TTS started, so we can ignore any transcript
    /// ingested in the first half-second (echo bleed stabilises by then).
    var ttsStartedAt: Date?
    /// Diagnostic: logged once when the mic actually delivers non-silent audio.
    var bufferLoggedNonSilent = false
    /// Buffers received by the mic tap since the most recent recognition
    /// task started. If this stays 0, the tap isn't firing (audio route
    /// broken / engine stopped). If it grows but `peakRMSSinceTaskStart`
    /// stays near 0, the mic is hearing silence (user too far, wrong route).
    /// If it grows WITH real peak energy but the recogniser still fires
    /// 1110, the user's voice isn't being recognised as speech (accent,
    /// noise masking, on-device model not downloaded).
    var buffersSinceTaskStart: Int = 0
    var peakRMSSinceTaskStart: Float = 0
    var lastBufferRMS: Float = 0
    /// Diagnostic: counts tap invocations so we can confirm the engine is
    /// pushing buffers even if they're silent.
    var bufferTickCount = 0

    // MARK: - Voice activity detection (RMS-based)
    //
    // Transcript growth is unreliable: on-device speech recognition turns
    // background noise (wind, gnats, footsteps) into spurious words, so a
    // turn would never end. Instead we drive end-of-turn detection from raw
    // audio RMS — the actual loudness of the mic input. Quiet = silent =
    // finalise; loud above a threshold = voice = keep going.
    //
    // Thresholds chosen per Apple/community guidance:
    //   • -40 dBFS (~0.012 linear) sits between ambient room noise (-50 dBFS)
    //     and conversational speech (-25 to -10 dBFS) — picks up voice
    //     reliably without latching onto AC hum or distant traffic.
    //   • 250ms minimum sustained voice keeps a single cough or door-slam
    //     from triggering a turn finalize on its own.
    //   • 1.0s end-of-turn silence is the chat sweet-spot — long enough to
    //     allow brief mid-sentence pauses, short enough to feel responsive.
    let voiceRMSThreshold: Float = 0.012
    /// 1.2s — long enough for natural mid-sentence pauses ("um, well…
    /// I think…") without committing prematurely. Production voice apps
    /// use ~1.0–1.5s for chat-style; faster reads as "cutting you off".
    let endOfTurnSilenceSec: Double = 1.2
    let minVoiceForTurnSec: Double = 0.2
    /// Backup commit trigger: if transcript content hasn't grown in this many
    /// seconds, commit anyway. Set well above the silence threshold so it only
    /// fires when the recogniser has truly stopped picking up words (not just
    /// during a thoughtful pause).
    let stalledTranscriptCommitSec: Double = 3.0
    let stalledTranscriptMinChars: Int = 4
    /// Hard cap on how long a single user turn can stay open. SFSpeechRecognizer
    /// can silently stall in sustained noise (recognizer buffers fill, no
    /// partials emit). Without a cap the turn never commits. Per spec §1: at
    /// 30s force-finalize whatever transcript exists; if it's empty, send a
    /// signal turn so the user gets a "I didn't catch that" response rather
    /// than silent swallow.
    let maxTurnDurationSec: Double = 30.0
    /// When the current user turn started (listening state entered).
    var turnStartedAt: Date?

    /// Empty-transcript re-arm cap. After the max-turn watchdog finalizes
    /// with an empty transcript, we re-arm and let the user try again. But
    /// if the mic is genuinely dead (audio engine running but tap isn't
    /// delivering buffers — seen during a Watch HKWorkoutSession
    /// conflict) the re-arm path with no
    /// `turnStartedAt` reset re-fires the same 30s-elapsed condition every
    /// 200ms forever, hundreds of cycles per second, eventually crashing
    /// AVFAudio. Cap at 2 retries; after that, tear voice down so the user
    /// gets a clear "couldn't hear you" instead of a runaway loop.
    var consecutiveEmptyReArms: Int = 0
    let maxConsecutiveEmptyReArms: Int = 2

    /// First-partial watchdog. `SFSpeechRecognizer` can hang silently
    /// (audio routing change, resource pressure, no error emitted) —
    /// if no partial ever arrives but the tap is seeing voice-like
    /// RMS, restart the recognition task once. Post-MVP spec §1 item.
    let firstPartialTimeoutSec: Double = 5.0
    /// Number of recognition-task restarts triggered by the first-
    /// partial watchdog within the current listening turn. Capped at
    /// 1 so a genuinely stuck recognizer can't burn cycles. After the
    /// cap, the watchdog logs and falls through to the 30s max-turn
    /// timeout.
    var firstPartialRestartsThisTurn: Int = 0

    /// Long-idle recognizer restart. `SFSpeechRecognizer` self-terminates
    /// after ~60s of silence with a silent success callback — the mic
    /// stays hot but the recogniser is dead, and the next utterance
    /// vanishes. While listening with no active turn, if no partials
    /// have arrived for 45s, proactively restart to stay ahead of the
    /// kill. Post-MVP spec §1 item.
    let longIdleRestartSec: Double = 45.0
    /// Bumped each time the transcript's character count grows.
    var lastTranscriptGrowthAt: Date?
    var lastTranscriptLength: Int = 0
    /// Most recent moment RMS exceeded the voice threshold.
    var lastVoiceDetectedAt: Date?
    /// Cumulative time the user has been "actively speaking" this turn.
    /// Prevents finalising a turn from a single noise blip.
    var totalVoiceSecondsThisTurn: Double = 0
    /// Most recent buffer's wall-clock arrival time, for accumulating duration.
    var lastBufferAt: Date?

    // MARK: - Barge-in detection (hands-free interrupt)
    //
    // While the AI is speaking we keep the mic + recognizer running so the
    // user can interrupt by speaking ("never mind", "stop", or just talking
    // over the response). Without proper AEC the mic hears the TTS too, so
    // gnats and tail audio trigger false positives unless several gates
    // agree: high RMS + sustained duration + word-content + echo rejection.
    /// RMS bar for barge-in. Set just above ambient so normal speaking volume
    /// over AirPods crosses it. Phone-speaker mode may need this raised to
    /// avoid AI's own audio retriggering interrupt (a future tunable).
    let bargeInRMSThreshold: Float = 0.018
    /// Continuous voice duration above the threshold required to trigger.
    /// Short enough to catch one-word interrupts ("stop", "no").
    let bargeInSustainedSec: Double = 0.3
    /// Min new transcript chars during the speaking window before barge-in
    /// can fire. Filters out single-word echo flashes from TTS tails.
    let bargeInMinNewChars: Int = 10
    /// Min NEW recognized words (in the user's locale) during the speaking
    /// window before barge-in can fire. The RMS gate alone was tripping on
    /// wind, passing cars, and footsteps — sustained loud audio that wasn't
    /// speech. Requiring 2+ transcribed words means SFSpeechRecognizer had
    /// to successfully decode language, which noise can't fake. If the user
    /// really wants to interrupt, they just have to say two words ("stop
    /// talking", "hey wait", "never mind") — which they were going to do
    /// anyway.
    let bargeInMinNewWords: Int = 2
    /// When we last saw RMS BELOW the barge-in threshold (for "sustained" math).
    var lastSubBargeInRMSAt: Date?
    /// Transcript char count when state entered .speaking. Barge-in only
    /// considers content past this baseline.
    var bargeInBaselineLength: Int = 0
    /// Transcript WORD count when state entered .speaking — paired with the
    /// char baseline. Noise doesn't produce word-count deltas; only decoded
    /// speech does.
    var bargeInBaselineWordCount: Int = 0
    /// When TTS started — gives a 600ms grace period so the very first words
    /// of the AI's response don't trigger interrupt before the user could
    /// realistically have decided to speak.
    var bargeInGracePeriodSec: Double = 0.6

    // MARK: - Background survival
    //
    // Chat needs to keep running when the screen locks — during a walk the
    // user doesn't want to babysit the phone. Three mechanisms combine:
    //   1) `audio` UIBackgroundMode + `.playAndRecord` session — Apple-supported
    //      path for foreground audio to continue into background.
    //   2) BackgroundAudioManager silent-audio keepalive — only if nothing else
    //      is already holding the app alive (workout, overnight HRV). We track
    //      `didStartBackgroundAudio` so we never tear down keepalive that
    //      another subsystem put up.
    //   3) Audio-session interruption recovery — phone calls, alarms, and Siri
    //      can yank the session out from under us; `interruptionObserver`
    //      re-arms the engine when the interruption ends.

    /// Whether THIS controller called BackgroundAudioManager.startBackgroundAudio.
    /// Only this controller's stop() may tear down audio it started — never
    /// another subsystem's.
    var didStartBackgroundAudio = false
    /// NotificationCenter observer for AVAudioSession interruptions.
    /// Retained so we can remove it on stop().
    @ObservationIgnored var interruptionObserver: NSObjectProtocol?

    override init() {
        super.init()
        // Cold-start: init only wires the
        // synthesizer delegate (cheap, no I/O). SFSpeechRecognizer
        // construction is deferred to boot() so the recognizer's locale-
        // table loading can't show up on the synchronous launch path.
        // start()'s existing nil-recognizer guard makes that delay safe —
        // if the user taps the mic before boot() lands, we surface
        // VoiceError.recognizerUnavailable cleanly instead of crashing.
        synthesizer.delegate = self
    }

    /// Post-first-frame recognizer construction.
    /// Skipped entirely when `enableVoiceMode` is false. Idempotent — second call
    /// is a no-op once `recognizer` is non-nil.
    @MainActor
    func boot() {
        guard recognizer == nil else { return }
        guard UserSettings.performanceFlag(.enableVoiceMode) else { return }
        // `forceAIEnglish` setting overrides the OS locale
        // for speech recognition too, so a user with a Japanese-locale
        // phone can speak English to the AI when they've opted into
        // English-only AI responses.
        let forceEnglish = AppDependencies.current.app.settingsManager.settings.forceAIEnglish
        let targetLocale = forceEnglish ? Locale(identifier: "en-US") : Locale.current
        recognizer = SFSpeechRecognizer(locale: targetLocale)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }
}
