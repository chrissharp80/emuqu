import AVFoundation
import Foundation

/// The coach lines `VoiceConversationController` speaks while it is in
/// `.triggerSpeaking`: alerts, mile markers, route lines and AI-worded
/// interjections (interval calls, the post-workout recovery line).
///
/// Each line claims the workout-cue audio session before it is spoken, as
/// `BackgroundAudioManager` asks of every spoken workout cue: `beginCue()`
/// runs off the main actor (activation can block for seconds after a phone
/// call), the line is handed to the synthesizer once the session is up, and
/// the line's finish or cancel callback ends its hold (`finished(_:)`). With
/// voice chat idle that activates the session for the line and deactivates
/// it afterwards, so other apps' audio is told to resume; with voice chat on,
/// its `.playAndRecord` claim keeps the category and the session stays up.
/// Lines are spoken in the order they were given, and a line still waiting
/// for the session counts as speech (`isBusy`), so the conversation does not
/// treat the coach as finished before it has started.
///
/// It also holds the scripted line an AI-worded interjection falls back to
/// (`fallback`): the line is said instead when the reply fails, comes back
/// empty, or has said nothing by `fallbackDeadlineNanoseconds`.
@MainActor
final class CoachCueSpeech {
    private struct Waiting {
        let utterance: AVSpeechUtterance
        let onUnqueued: @MainActor @Sendable () -> Void
    }

    private struct Held {
        let utterance: AVSpeechUtterance
        let token: BackgroundAudioManager.CueToken
        let audio: BackgroundAudioManager
    }

    private let synthesizer: AVSpeechSynthesizer
    private let audio: @MainActor () -> BackgroundAudioManager
    /// Lines waiting for the session, oldest first.
    private var waiting: [Waiting] = []
    /// Lines handed to the synthesizer, by utterance identity, with the hold
    /// each one ends. The entry keeps the utterance alive, so its identity
    /// can't be reused before its callback ends the hold.
    private var held: [ObjectIdentifier: Held] = [:]
    private var isClaiming = false
    /// Bumped whenever the fallback is armed, taken or dropped, so a deadline
    /// set for an earlier interjection does nothing.
    private var fallbackGeneration = 0

    /// The scripted line the AI interjection in flight falls back to. Cleared
    /// once any coach line is given to `speak`: the interjection has then said
    /// something, and saying the scripted line as well would repeat it.
    var fallback: String? {
        didSet { fallbackGeneration += 1 }
    }

    /// How long an AI interjection with a fallback may go without a word
    /// before the fallback is said instead. A cue later than this no longer
    /// marks the interval boundary it announces.
    static let fallbackDeadlineNanoseconds: UInt64 = 6_000_000_000

    init(
        synthesizer: AVSpeechSynthesizer,
        audio: @escaping @MainActor () -> BackgroundAudioManager = { AppDependencies.current.collection.backgroundAudioManager }
    ) {
        self.synthesizer = synthesizer
        self.audio = audio
    }

    /// True while the synthesizer speaks or a coach line waits for the session.
    var isBusy: Bool { synthesizer.isSpeaking || !waiting.isEmpty }

    /// Speak `utterance` once the cue session is up. `onUnqueued` runs when
    /// the synthesizer refuses it, so no finish callback is coming.
    func speak(_ utterance: AVSpeechUtterance, onUnqueued: @escaping @MainActor @Sendable () -> Void) {
        fallback = nil
        waiting.append(Waiting(utterance: utterance, onUnqueued: onUnqueued))
        guard !isClaiming else { return }
        isClaiming = true
        Task { await self.claimAndSpeakWaitingLines() }
    }

    /// One line at a time, in order: claim, then speak. A line dropped while
    /// its claim came up (`stopAll`) gives its hold straight back.
    private func claimAndSpeakWaitingLines() async {
        let manager = audio()
        while let next = waiting.first {
            let token = await Task.detached(priority: .userInitiated) { manager.beginCue() }.value
            guard let line = waiting.first, line.utterance === next.utterance else {
                manager.endCue(token)
                continue
            }
            waiting.removeFirst()
            held[ObjectIdentifier(line.utterance)] = Held(utterance: line.utterance, token: token, audio: manager)
            var speakErr: NSError?
            guard !FRSafeSpeak(synthesizer, line.utterance, &speakErr) else { continue }
            debugLog("[VoiceConv] synthesizer.speak failed (skipping coach line): \(speakErr?.localizedDescription ?? "?")", level: .warning)
            finished(ObjectIdentifier(line.utterance))
            line.onUnqueued()
        }
        isClaiming = false
    }

    /// The line with this identity finished or was cancelled: end its hold.
    /// Lines this object never handed to the synthesizer are ignored.
    func finished(_ utterance: ObjectIdentifier) {
        guard let line = held.removeValue(forKey: utterance) else { return }
        line.audio.endCue(line.token)
    }

    /// The conversation stopped its speech: drop the waiting lines and the
    /// fallback, and end the holds of the lines the synthesizer was told to
    /// stop, whether or not it reports each cancel.
    func stopAll() {
        waiting.removeAll()
        fallback = nil
        let stopped = held.values
        held.removeAll()
        for line in stopped { line.audio.endCue(line.token) }
    }

    /// The fallback, once: taking it clears it.
    func takeFallback() -> String? {
        defer { fallback = nil }
        return fallback
    }

    /// Runs `onStall` after `fallbackDeadlineNanoseconds` if the fallback armed now is
    /// still unused: nothing has been said for the interjection, and it has
    /// not failed or ended. Does nothing when there is no fallback.
    func armFallbackDeadline(onStall: @escaping @MainActor @Sendable () -> Void) {
        guard fallback != nil else { return }
        let armed = fallbackGeneration
        Task { [weak self] in
            await sleepQuietly(Self.fallbackDeadlineNanoseconds, context: "CoachCueSpeech.fallbackDeadline")
            guard let self, self.fallbackGeneration == armed, self.fallback != nil else { return }
            onStall()
        }
    }
}
