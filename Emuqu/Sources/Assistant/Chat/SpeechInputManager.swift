import AVFoundation
import Foundation
import Speech

/// Apple on-device speech recognition for the Assistant tab's hands-free input.
///
/// Tap-to-talk: a single instance lives for the duration of one recording, owned
/// by `AssistantViewModel`. `start()` requests permissions, configures the audio
/// engine, and begins streaming partial transcripts to `transcript`. `stop()`
/// returns the final string. `cancel()` aborts without yielding anything.
///
/// Uses `requiresOnDeviceRecognition = true` so transcripts never leave the device
/// — consistent with the rest of Emuqu's data-local stance.
@Observable
@MainActor
final class SpeechInputManager {
    private(set) var transcript: String = ""
    private(set) var isRecording: Bool = false
    private(set) var lastError: String?

    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    /// Lazy — `AVAudioEngine()` cold init blocks main for 50-200 ms (IOKit
    /// work to wire up the audio hardware). Dictation is a user-initiated
    /// action (mic button tap); there's no reason to pay that cost when
    /// the AI chat tab first appears. Lazy-ing it ensures the text field
    /// is responsive immediately — audio engine spins up only on
    /// `start()`.
    @ObservationIgnored private lazy var engine = AVAudioEngine()

    init() {
        // Recognizer instantiation is cheap — just a wrapper around
        // on-device speech framework state. Keep eager.
        recognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    /// Whether the device supports on-device recognition for the chosen locale.
    var isAvailable: Bool {
        guard let recognizer, recognizer.isAvailable else { return false }
        return recognizer.supportsOnDeviceRecognition
    }

    /// Requests both microphone and speech-recognition permissions, then starts
    /// the audio engine and recognition task. Throws on permission denial or
    /// audio configuration failure.
    ///
    /// Configure the audio session THROUGH THE COORDINATOR, not by
    /// grabbing `.record` on the shared session directly. Dictation is
    /// one of several audio consumers (BGAM keepalive during indoor
    /// workouts / overnight HRV, the voice conversation controller); a
    /// direct `setCategory` here raced BGAM's `.playback` health-check
    /// restart, which clobbered the record category and left the mic
    /// dead — the reported "mic works half the time". The coordinator
    /// resolves the strict-superset category (`.playAndRecord` because
    /// dictation claims `.voiceRecord`) so every claimant is satisfied
    /// by one session. It owns setCategory; we own setActive.
    ///
    /// If activating the session or starting the engine fails, the dictation
    /// claim is released before the error propagates: `stop()` is a no-op
    /// while not recording, so a claim left behind here would keep
    /// `hasActiveClaims()` true for the rest of the process.
    func start() async throws {
        guard !isRecording else { return }
        try await requestPermissions()
        guard let recognizer, recognizer.isAvailable else { throw SpeechError.unavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request
        try claimSessionAndStartEngine(appendingTo: request)
        transcript = ""
        lastError = nil
        isRecording = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handleRecognition(result: result, error: error as NSError?)
        }
    }

    /// Claims the audio session for dictation and starts the engine, handing
    /// the claim back if either step fails.
    private func claimSessionAndStartEngine(appendingTo request: SFSpeechAudioBufferRecognitionRequest) throws {
        AppDependencies.current.services.audioSessionCoordinator.claim(.dictation, mode: .voiceRecord)
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            try startEngine(appendingTo: request)
        } catch {
            releaseSessionIfIdle()
            throw error
        }
    }

    /// Reset, tap, prepare and start the shared engine.
    ///
    /// Every AVAudio mutating call goes through SafeObjC.
    /// Each can raise NSException on a degraded audio session (post-
    /// interrupt recovery, route change). Swift's `try` only catches
    /// NSError. The dictation button in AssistantChatView is used
    /// mid-workout — an uncaught NSException here would SIGABRT the workout.
    private func startEngine(appendingTo request: SFSpeechAudioBufferRecognitionRequest) throws {
        let inputNode = engine.inputNode
        let recordingFormat = resetEngineAndReadFormat(inputNode)
        var removeErr: NSError?
        _ = FRSafeRemoveTap(inputNode, 0, &removeErr) // idempotent
        var tapErr: NSError?
        let tapInstalled = FRSafeInstallTap(inputNode, 0, 1024, recordingFormat, Self.tapBlock(appendingTo: request), &tapErr)
        guard tapInstalled else { throw SpeechError.unavailable }
        var prepErr: NSError?
        guard FRSafePrepareAudioEngine(engine, &prepErr) else { throw removeTapAndFail(inputNode) }
        var startErr: NSError?
        guard FRSafeStartAudioEngine(engine, &startErr) else { throw removeTapAndFail(inputNode) }
    }

    /// The microphone tap. Built outside the main actor because the engine
    /// calls it on its audio thread: a closure written inline here would
    /// inherit this type's main-actor isolation, which Swift 6 asserts on
    /// entry — a crash on the first buffer. Appending to a buffer recognition
    /// request from the tap is the framework's intended use.
    nonisolated private static func tapBlock(
        appendingTo request: SFSpeechAudioBufferRecognitionRequest
    ) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [weak request] buffer, _ in request?.append(buffer) }
    }

    /// Hard-reset the reused engine before reading its format. `engine`
    /// is lazy and lives for the manager's lifetime, so it survives
    /// across dictations; its cached node formats drift out of sync
    /// with the live session after the first use (or after any route
    /// change / other subsystem reconfiguring audio between dictations).
    /// Reading `outputFormat` off a stale engine returns a format that
    /// no longer matches the bus, and `installTap` then fails with a
    /// format mismatch — the other half of "mic works half the time".
    /// Stop + reset forces the engine to re-derive node state from the
    /// current session before we query the format. (Mirrors the same
    /// guard in VoiceConversationController.startAudioEngineAndRecognizer.)
    private func resetEngineAndReadFormat(_ inputNode: AVAudioInputNode) -> AVAudioFormat {
        var preStopErr: NSError?
        _ = FRSafeAudioEngineStop(engine, &preStopErr)
        var preRemoveErr: NSError?
        _ = FRSafeRemoveTap(inputNode, 0, &preRemoveErr)
        var resetErr: NSError?
        _ = FRSafeAudioEngineReset(engine, &resetErr)
        return inputNode.outputFormat(forBus: 0)
    }

    /// Best-effort cleanup so a stale tap doesn't poison the next call, then
    /// the error the caller throws.
    private func removeTapAndFail(_ inputNode: AVAudioInputNode) -> SpeechError {
        var cleanupErr: NSError?
        _ = FRSafeRemoveTap(inputNode, 0, &cleanupErr)
        return SpeechError.unavailable
    }

    /// Codes 203 / 216 are "no speech" and 301 is "cancelled" — all benign on
    /// stop, so they're filtered out rather than surfaced as an error.
    private func handleRecognition(result: SFSpeechRecognitionResult?, error: NSError?) {
        if let result {
            let text = result.bestTranscription.formattedString
            Task { @MainActor in self.transcript = text }
        }
        guard let error, ![203, 216, 301].contains(error.code) else { return }
        Task { @MainActor in self.lastError = error.localizedDescription }
    }

    /// Stop recording and return the final transcript. Safe to call multiple times.
    @discardableResult
    func stop() -> String {
        guard isRecording else { return transcript }
        var removeErr: NSError?
        _ = FRSafeRemoveTap(engine.inputNode, 0, &removeErr)
        var stopErr: NSError?
        _ = FRSafeAudioEngineStop(engine, &stopErr)
        request?.endAudio()
        task?.finish()
        releaseSessionIfIdle()
        isRecording = false
        return transcript
    }

    /// Abort without preserving the transcript.
    func cancel() {
        var removeErr: NSError?
        _ = FRSafeRemoveTap(engine.inputNode, 0, &removeErr)
        var stopErr: NSError?
        _ = FRSafeAudioEngineStop(engine, &stopErr)
        request?.endAudio()
        task?.cancel()
        releaseSessionIfIdle()
        transcript = ""
        isRecording = false
    }

    /// Release the dictation claim and deactivate the session ONLY if no
    /// other subsystem still holds a claim. Dictation is a transient,
    /// foreground action that can fire while BGAM's keepalive (indoor
    /// workout / overnight HRV) or a voice conversation is live; blindly
    /// deactivating the shared session would silence their audio and, for
    /// BGAM, drop the background-collection keepalive. When we ARE the last
    /// claimant, deactivation is correct — it frees the mic and un-ducks.
    private func releaseSessionIfIdle() {
        AppDependencies.current.services.audioSessionCoordinator.release(.dictation)
        guard !AppDependencies.current.services.audioSessionCoordinator.hasActiveClaims() else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Permissions

    enum SpeechError: LocalizedError {
        case micDenied, speechDenied, unavailable
        var errorDescription: String? {
            switch self {
            case .micDenied: String(localized: "Microphone access is off. Turn it on in Settings → Apps → Emuqu.", bundle: LanguageManager.appBundle)
            case .speechDenied: String(localized: "Speech recognition is off. Turn it on in Settings → Apps → Emuqu.", bundle: LanguageManager.appBundle)
            case .unavailable: String(localized: "On-device speech recognition isn't available on this device.", bundle: LanguageManager.appBundle)
            }
        }
    }

    private func requestPermissions() async throws {
        // Speech
        @ObservationIgnored let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            // `@Sendable`: the framework does not promise the main queue for
            // either callback, and a main-actor closure asserts it on entry.
            SFSpeechRecognizer.requestAuthorization { @Sendable status in cont.resume(returning: status) }
        }
        guard speechStatus == .authorized else { throw SpeechError.speechDenied }

        // Microphone
        let micGranted: Bool = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { @Sendable granted in cont.resume(returning: granted) }
        }
        guard micGranted else { throw SpeechError.micDenied }
    }
}
