import AVFoundation
import Foundation

/// Speaks "Breathe in" and "Breathe out" in sync with the BreathingMandalaView's breath phase.
/// Uses AVSpeechSynthesizer for natural voice guidance.
@Observable
@MainActor
final class BreathingAudioManager: NSObject, AVSpeechSynthesizerDelegate {
    /// Whether the voice guide is on right now. Not persisted: the live
    /// view switches it off when it disappears, so a saved "on" could only
    /// come back after the app was killed mid-session — and then the pill
    /// said "Voice on" while nothing had started speaking.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                start()
            } else {
                stop()
            }
        }
    }

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
        case .breatheIn: text = String(localized: "Breathe in", bundle: LanguageManager.appBundle)
        case .breatheOut: text = String(localized: "Breathe out", bundle: LanguageManager.appBundle)
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
        // The app's language: the cue was English, in an American voice,
        // for everyone.
        utterance.voice = WorkoutVoiceCoach.appLanguageVoice()
        return utterance
    }

    // MARK: - Lifecycle

    /// The category goes through the coordinator, so a voice chat's or a
    /// recording keepalive's claim is never clobbered by the guide's.
    private func start() {
        AppDependencies.current.services.audioSessionCoordinator.claim(.breathingGuide, mode: .playback)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
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

        // Releasing the claim drops `.duckOthers`. The session is deactivated
        // only when nothing else (voice chat, recording keepalive) holds it.
        let coordinator = AppDependencies.current.services.audioSessionCoordinator
        coordinator.release(.breathingGuide)
        if !coordinator.hasActiveClaims() {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                debugLog("[BreathingAudio] Failed to deactivate audio session: \(error)")
            }
        }

        debugLog("[BreathingAudio] Stopped")
    }

    // No `deinit`: the only owner is `RecordView`'s `@State`, which lives for
    // the app's lifetime, and a nonisolated `deinit` cannot touch the
    // synthesizer anyway. `isEnabled = false` is the teardown path.
}
