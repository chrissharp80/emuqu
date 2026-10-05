import AudioToolbox
import AVFoundation
import Foundation
import os
import UIKit

/// The multi-modal "recording has started" cue, lifted out of
/// `WorkoutRecorder`.
///
/// It is a self-contained mechanism: a few
/// pre-warmed statics, a handful of functions, and a file-scope voice cache
/// that between them touch no recorder state at all. As its own type the pre-warm
/// contract — `prepare()` at launch, never construct a feedback generator on
/// the workout-start hot path — is stated where it belongs instead of as a
/// comment on a property halfway down a lifecycle extension.
///
/// A namespace rather than an instance: every layer here is process-wide by
/// nature — one Taptic Engine, one speech synthesizer, one system sound.
enum WorkoutStartCue {
    // MARK: - Workout-start alert
    //
    // Multi-modal feedback so the user knows recording has actually begun
    // even if they just locked the phone. Three layers:
    //   1. Haptic success thump (always, even in silent mode).
    //   2. System "Sent" chime (plays at unsilenced volume; respects phone's
    //      ring/silent switch like any UI sound).
    //   3. Short spoken TTS via AVSpeechSynthesizer ("Walk started") —
    //      AirPods users hear this confirm their tap, and it's how
    //      iSmoothRun signals start.
    //
    // All three wrapped so if any single layer misbehaves (e.g. synthesizer
    // permission denied) the others still fire.
    static let startChimeSoundID: SystemSoundID = 1013  // system "Sent"
    /// Retained synthesizer so the utterance isn't deallocated mid-speech.
    /// Local-scoped `AVSpeechSynthesizer` goes out of scope the moment the
    /// function returns and the TTS stops with it. Static keeps it alive
    /// for the lifetime of the app — same instance reused across start
    /// announcements, which is fine (it queues if re-invoked).
    ///
    /// `nonisolated(unsafe)` because the synthesizer is called from
    /// `Task.detached` in `announceStart` (so the cue cannot queue behind the
    /// recording view's first mount) while its delegate is set on the main
    /// actor. Apple documents
    /// `AVSpeechSynthesizer` as thread-safe (its delegate callbacks and
    /// internal queueing serialize access), so opting out of strict-actor
    /// isolation here is correct rather than a soundness hole.
    nonisolated(unsafe) static let announceSynthesizer = AVSpeechSynthesizer()

    /// Ends the start cue's hold on the audio session when the utterance
    /// finishes or is cancelled. Retained here because a synthesizer holds its
    /// delegate weakly. Sendable, so the detached announce task tracks its
    /// utterance with it.
    @MainActor static let cueReleaser = CueAudioSessionReleaser(
        manager: AppDependencies.current.collection.backgroundAudioManager
    )

    /// Pre-warmed haptic generators. Init + first `.notificationOccurred` on a
    /// cold Taptic Engine has been observed in user logs to block the calling
    /// thread for hundreds of ms to several seconds — measurable as part of the
    /// 14-second hang between `announce.fire` and `step=location.startTracking`
    /// in `hrv_debug_log_1778675167.txt`. Keep one of each retained for the
    /// app's life and call `prepare()` at launch so the engine is warm when
    /// the user taps Start. Never construct UI*FeedbackGenerator() inline on
    /// the workout-start hot path again.
    @MainActor static let notificationFeedback = UINotificationFeedbackGenerator()
    @MainActor static let impactFeedback = UIImpactFeedbackGenerator(style: .heavy)

    /// `announceStart` is now fire-and-forget from the recorder's perspective:
    /// it owes nothing to start() except scheduling the user-feedback layers
    /// in priority order. Haptic + chime are sub-10 ms when the generators are
    /// pre-warmed (we warm at launch). Voice utterance build + speak() ALWAYS
    /// hops off the main actor — the speech daemon has been observed to stall
    /// the calling thread for tens of seconds on first cold use after an audio
    /// interruption (which the log file shows happened 11 minutes before this
    /// workout started).
    ///
    /// A user debug log
    /// showed a 14.65-second gap between the `phase.recording → announce.fire`
    /// log and the next synchronous log in start(). The only meaningful work
    /// between them is this function. The two known main-thread stallers are
    ///   (a) `AVSpeechSynthesisVoice.speechVoices()` enumeration via
    ///       `cachedCompactVoice`, which IPCs into the speech daemon and
    ///       blocks for up to tens of seconds on first cold call after an
    ///       audio session interruption, and
    ///   (b) initial Taptic Engine spin-up via `UINotificationFeedbackGenerator`
    ///       construction.
    /// Both are mitigated: voice is cached (see `cachedCompactVoice`)
    /// and haptic generators are pre-warmed. Belt-and-braces, the utterance
    /// build + speak() is hopped onto a detached Task so even if voice
    /// enumeration regresses, the main actor doesn't wait for it.
    @MainActor
    static func announceStart(sport: Sport) {
        let t0 = Date()
        // Pre-warmed generators (see `notificationFeedback` / `impactFeedback`
        // above). `.prepare()` is fired at launch; firing again here is a free
        // no-op on a warm engine.
        notificationFeedback.notificationOccurred(.success)
        let t1 = Date()
        // Secondary heavy thump so the user feels it through a pocket.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            impactFeedback.impactOccurred()
        }
        AudioServicesPlaySystemSound(startChimeSoundID)
        let t2 = Date()
        speakStartAnnouncementOffMain(sportName: sport.localizedName)
        let t3 = Date()
        let hapticMs = Int(t1.timeIntervalSince(t0) * 1000)
        let chimeMs = Int(t2.timeIntervalSince(t1) * 1000)
        let tailMs = Int(t3.timeIntervalSince(t2) * 1000)
        debugLog("[announceStart] inline haptic=\(hapticMs)ms chime=\(chimeMs)ms tail=\(tailMs)ms")
    }

    /// Capture `lang` on the calling actor (this method
    /// is @MainActor) BEFORE the detached hop. Doing
    /// `await MainActor.run { Locale.current.language... }`
    /// inside the detached Task serialises behind whatever
    /// else the main actor is doing — and at workout-start the
    /// main actor is rendering `FitnessRecordingView` for the first
    /// time (8 ObservedObjects, charts, map). A beta tester log
    /// showed `off-main utter+voice=11560ms` —
    /// 11.5 s of dead silence between Recorder.start returning
    /// and the "Walk started" announcement, because the MainActor
    /// hop was queued behind the view-mount work. The user
    /// perceived it as "took forever to start the workout."
    /// Passing the value in eliminates the hop entirely.
    @MainActor
    private static func speakStartAnnouncementOffMain(sportName: String) {
        // The app's language, not the phone's, for both words and voice: an
        // English "<sport> started" was read by the phone's voice.
        let lang = LanguageManager.appLocale.language.languageCode?.identifier ?? "en"
        let phrase = String(localized: "\(sportName) started", bundle: LanguageManager.appBundle)
        let audio = AppDependencies.current.collection.backgroundAudioManager
        let releaser = cueReleaser
        announceSynthesizer.delegate = releaser
        let announceWork = Task.detached(priority: .userInitiated) {
            await buildAndSpeakStartUtterance(phrase: phrase, lang: lang, audio: audio, releaser: releaser)
        }
        installAnnounceWatchdog(for: announceWork)
    }

    /// Runs off the main actor, including the cue's
    /// `AVAudioSession.setActive(true)` in `beginCue()`. That call
    /// synchronously blocks the calling thread while iOS negotiates
    /// with the audio service, and when the service is in a recovery
    /// state (e.g., after a phone-call interruption, as seen in user
    /// debug logs) the negotiation can take tens of seconds — on the
    /// main actor it would freeze the entire workout UI. The session
    /// is held only for this utterance: `releaser` ends this cue's hold
    /// when it finishes or is cancelled, and a callback for any other
    /// utterance can't end it.
    ///
    /// Speak via SafeObjC shim. NSException from
    /// a degraded speech daemon would otherwise crash the app.
    private static func buildAndSpeakStartUtterance(
        phrase: String,
        lang: String,
        audio: BackgroundAudioManager,
        releaser: CueAudioSessionReleaser
    ) async {
        let s0 = Date()
        let utterance = AVSpeechUtterance(string: phrase)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = Self.cachedCompactVoice(forLanguage: lang)
        utterance.volume = 0.9
        let s1 = Date()
        releaser.track(utterance, token: audio.beginCue())
        var speakErr: NSError?
        let speakOK = FRSafeSpeak(announceSynthesizer, utterance, &speakErr)
        let s2 = Date()
        let voiceMs = Int(s1.timeIntervalSince(s0) * 1000)
        let speakMs = Int(s2.timeIntervalSince(s1) * 1000)
        guard speakOK else {
            releaser.release(utterance)
            debugLog("[announceStart] off-main speak FAILED (utter+voice=\(voiceMs)ms): \(speakErr?.localizedDescription ?? "?")", level: .warning)
            return
        }
        debugLog("[announceStart] off-main utter+voice=\(voiceMs)ms speak.queue=\(speakMs)ms")
    }

    /// Wall-clock watchdog. The user's haptic + chime
    /// ALREADY fired by the time we're here. If the speech daemon
    /// is degraded (phone-call interruption recovery, route change,
    /// Bluetooth daemon stuck) and the utterance/voice prep
    /// OR speak() blocks, the workout-start UX shouldn't pay for
    /// it. After 800 ms we just stop waiting — the user lost the
    /// spoken "Walk started" but the workout already started.
    /// A beta tester log showed 11.5 s of this
    /// path stalling and being perceived as "took forever."
    ///
    /// Fire-and-forget: the synthesizer's own queue still picks up the
    /// utterance if the daemon recovers later; if not, the user got the
    /// haptic + chime which is the actually-important feedback.
    ///
    /// A finished task is not cancelled, so completion is tracked on its own:
    /// only work still running at 800 ms is reported as stalled.
    private static func installAnnounceWatchdog(for announceWork: Task<Void, Never>) {
        let finished = OSAllocatedUnfairLock(initialState: false)
        Task.detached(priority: .background) {
            await announceWork.value
            finished.withLock { $0 = true }
        }
        Task.detached(priority: .background) {
            await sleepQuietly(800_000_000, context: "installAnnounceWatchdog")
            guard !finished.withLock({ $0 }), !announceWork.isCancelled else { return }
            announceWork.cancel()
            debugLogExternal("[announceStart] the speech daemon didn't start inside 800 ms — started without the spoken cue; the haptic and chime already played", cause: .os)
        }
    }

    /// The main-actor entry point: it only reads the cache and never
    /// enumerates, so it can't block its caller on the speech service. On a
    /// miss it starts `prewarm(forLanguage:)` for that language and returns
    /// nil (the caller's default voice). The launch prewarm fills the app
    /// language before the first cue, so a main-actor caller normally gets a
    /// hit; after an in-app language change the first line misses and the
    /// next one finds the new language cached.
    ///
    /// `lang` is a language code ("en", "de") or a BCP-47 tag ("en-US").
    static func cachedCompactVoiceIfReady(forLanguage lang: String) -> AVSpeechSynthesisVoice? {
        if let cached = _voiceCacheLookup(voiceCacheKey(lang)) { return cached }
        prewarm(forLanguage: lang)
        return nil
    }

    /// Returns a compact (`.default` quality) voice that is guaranteed to
    /// be bundled with iOS — never an enhanced/premium voice.
    ///
    /// Guards against the workout-start hang.
    ///
    /// `AVSpeechSynthesisVoice(language:)` returns the system's "preferred"
    /// voice for the language, which on iOS 17+ is frequently an enhanced
    /// (premium) voice. The FIRST `speak()` against an enhanced voice that
    /// hasn't been downloaded blocks the main thread synchronously while
    /// iOS pulls the voice file. Observed in the wild as up to 60 seconds
    /// of total app unresponsiveness when the user tapped Start — the main
    /// actor was held by the announce Task, blocking every deferred Task
    /// (HR subscription, location tracking, pedometer, etc.) behind it.
    /// Force-quitting "fixed it" because partial-download state persisted,
    /// so the next launch's speak() returned quickly.
    ///
    /// Compact voices have `quality == .default` and ship in the system
    /// image — they never download. Prefer one in the user's language;
    /// fall back to any compact English voice; final fallback to
    /// `AVSpeechSynthesisVoice(language:)` (which may still hang, but at
    /// that point we've exhausted local options).
    ///
    /// Cached, so `speechVoices()` runs ONCE per language per app launch.
    /// Enumerates on the calling thread when the language isn't cached yet,
    /// so call it from a detached task: the first enumeration can block for
    /// seconds while the speech daemon starts.
    static func cachedCompactVoice(forLanguage lang: String) -> AVSpeechSynthesisVoice? {
        let key = voiceCacheKey(lang)
        if let cached = _voiceCacheLookup(key) { return cached }
        let voice = _enumerateCompactVoice(forLanguage: key)
        if let voice { _voiceCacheStore(key, voice) }
        return voice
    }

    /// Fill the voice cache for `lang` off the main actor, so neither the
    /// first workout cue nor launch waits on the speech daemon. A language
    /// already cached, or already being filled, starts nothing.
    static func prewarm(forLanguage lang: String) {
        let key = voiceCacheKey(lang)
        guard _voiceCacheLookup(key) == nil, _voicePrewarms.withLock({ $0.insert(key).inserted }) else { return }
        Task.detached(priority: .utility) {
            _ = cachedCompactVoice(forLanguage: key)
            _ = _voicePrewarms.withLock { $0.remove(key) }
        }
    }

    /// Voice languages are BCP-47 tags ("en-US"); a `Locale.identifier` uses
    /// an underscore ("en_US"). Normalise to the hyphen form so a prefix
    /// match and the cache key agree whichever form the caller passed.
    static func voiceCacheKey(_ lang: String) -> String {
        lang.replacingOccurrences(of: "_", with: "-")
    }

    /// The actual `speechVoices()` enumeration. This is the call documented at
    /// the top of `announceStart` as the staller — it IPCs into the speech
    /// daemon, so it runs on whatever thread calls it and callers keep it off
    /// the main actor. Kept isolated here so it has exactly ONE call site we
    /// can instrument or replace.
    private static func _enumerateCompactVoice(forLanguage lang: String) -> AVSpeechSynthesisVoice? {
        let t0 = Date()
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        debugLog("[VoiceCache] speechVoices() enumerated in \(ms)ms (count=\(voices.count), lang=\(lang))")
        if let preferred = voices.first(where: {
            $0.quality == .default && $0.language.hasPrefix(lang)
        }) {
            return preferred
        }
        if let englishFallback = voices.first(where: {
            $0.quality == .default && $0.language.hasPrefix("en")
        }) {
            return englishFallback
        }
        return AVSpeechSynthesisVoice(language: lang)
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

// MARK: - Voice cache

/// Lock-protected cache for compact-voice lookups. Lives at file scope (not
/// inside the extension) so both the sync and async accessors can read/write
/// without main-actor hopping just to touch the dictionary. The voices
/// themselves are immutable; reusing the same instance is safe.
///
/// the dictionary lives inside the lock (`uncheckedState`, since
/// `AVSpeechSynthesisVoice` is not marked Sendable) instead of beside it as a
/// `nonisolated(unsafe)` global, so there is no unguarded path to it.
private let _voiceCache = OSAllocatedUnfairLock<[String: AVSpeechSynthesisVoice]>(uncheckedState: [:])

private func _voiceCacheLookup(_ key: String) -> AVSpeechSynthesisVoice? {
    _voiceCache.withLockUnchecked { $0[key] }
}

private func _voiceCacheStore(_ key: String, _ value: AVSpeechSynthesisVoice) {
    _voiceCache.withLockUnchecked { $0[key] = value }
}

/// Cache keys a `prewarm(forLanguage:)` is enumerating right now, so repeated
/// misses for one language start one enumeration, not one per cue.
private let _voicePrewarms = OSAllocatedUnfairLock<Set<String>>(initialState: [])
