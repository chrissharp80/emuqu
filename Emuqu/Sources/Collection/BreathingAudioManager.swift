import AVFoundation
import Foundation

/// Speaks "Breathe in" and "Breathe out" in sync with the BreathingMandalaView's breath phase.
/// Uses AVSpeechSynthesizer for natural voice guidance.
@Observable
@MainActor
final class BreathingAudioManager: NSObject, AVSpeechSynthesizerDelegate {
    var isEnabled = false {
        didSet {
            guard didFinishInit else { return }
            if isEnabled {
                start()
            } else {
                stop()
            }
            UserDefaults.standard.set(isEnabled, forKey: UserDefaultsKeys.breathingAudioEnabled)
        }
    }

    private var didFinishInit = false
    /// Built on first use: `RecordView` constructs this manager as `@State`,
    /// and SwiftUI evaluates that initial value on every parent render, so
    /// `init` must not touch the synthesizer.
    @ObservationIgnored private lazy var synthesizer: AVSpeechSynthesizer = {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        return synthesizer
    }()

    // Phase tracking — detect transitions to trigger speech
    private var lastSpokenCue: BreathCue = .none
    private var isActive = false

    private enum BreathCue {
        case none, breatheIn, breatheOut
    }

    override init() {
        super.init()
        let saved = UserDefaults.standard.bool(forKey: UserDefaultsKeys.breathingAudioEnabled)
        isEnabled = saved
        didFinishInit = true
    }

    // MARK: - Phase Sync

    /// Called from BreathingMandalaView's timer (~60fps) to sync speech with visual
    func updatePhase(_ phase: Double) {
        guard isActive else { return }

        // Determine which cue should play based on breath phase
        // Phase 0→0.5 = inhale, 0.5→1.0 = exhale (matches mandala breathGuideText)
        let cue: BreathCue = phase < 0.5 ? .breatheIn : .breatheOut

        // Only speak when crossing a boundary
        if cue != lastSpokenCue {
            lastSpokenCue = cue
            speak(cue)
        }
    }

    // MARK: - Speech

    /// SafeObjC shim. Same audio-session-degraded NSException
    /// risk as the other speak() sites.
    private func speak(_ cue: BreathCue) {
        // Don't interrupt — if still speaking the previous cue, skip
        guard !synthesizer.isSpeaking else { return }
        let text: String
        switch cue {
        case .breatheIn: text = "Breathe in"
        case .breatheOut: text = "Breathe out"
        case .none: return
        }
        var speakErr: NSError?
        if !FRSafeSpeak(synthesizer, Self.breathUtterance(text), &speakErr) {
            debugLog("[BreathingAudio] speak failed: \(speakErr?.localizedDescription ?? "?")", level: .warning)
        }
    }

    /// Slightly slower, lower-pitched and quieter than the default voice —
    /// calmer for a breathing cue.
    private static func breathUtterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
        utterance.pitchMultiplier = 0.9
        utterance.volume = 0.6
        utterance.postUtteranceDelay = 0
        if let voice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }
        return utterance
    }

    // MARK: - Lifecycle

    private func start() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
            try session.setActive(true)
        } catch {
            debugLog("[BreathingAudio] Audio session error: \(error.localizedDescription)")
        }

        isActive = true
        lastSpokenCue = .none
        debugLog("[BreathingAudio] Started (voice)")
    }

    private func stop() {
        isActive = false
        _ = FRSafeStopSpeaking(synthesizer, .immediate, nil)
        lastSpokenCue = .none

        // Deactivate audio session so .duckOthers stops affecting other apps' audio
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            debugLog("[BreathingAudio] Failed to deactivate audio session: \(error)")
        }

        debugLog("[BreathingAudio] Stopped")
    }

    // No `deinit`: the only owner is `RecordView`'s `@State`, which lives for
    // the app's lifetime, and a nonisolated `deinit` cannot touch the
    // synthesizer anyway. `isEnabled = false` is the teardown path.
}
