import Foundation
import os

// MARK: - Live Workout Broker
//
// One-way publish from WorkoutRecorder to AssistantContext. The recorder
// pushes its current live state each tick; the context builder pulls the
// latest snapshot on demand when composing context for the AI.
//
// Decoupled so ContextBuilder doesn't need to know about WorkoutRecorder,
// which would create a circular Assistant ↔ Collection dependency.
//
// Stale snapshots (older than `staleAfterSec`) are treated as nil — a
// workout that ended but left stale state won't mislead the AI into
// thinking you're still running. `clear()` is called at stop, so the
// staleness gate only matters for tick gaps mid-workout, not post-stop.
final class LiveWorkoutBroker: Sendable {
    static let shared = LiveWorkoutBroker()

    /// 12 s, not 5 s. With 5 s the AI
    /// "sometimes reads live session data correctly, other times the
    /// same tools return nothing." Root cause: the recorder publishes
    /// each tick (1 Hz) but the main actor can stall briefly during
    /// AI-chat streaming bursts or on-demand work, dropping the next
    /// tick by 5+ seconds. The freshness gate then rejects the
    /// snapshot and every tool returns `missing` until the next
    /// successful tick. 12 s comfortably swallows those bursts while
    /// still rejecting genuinely-stale state from a stopped workout
    /// (which is also explicitly cleared via `clear()` at stop).
    private static let staleAfterSec: TimeInterval = 12

    /// `OSAllocatedUnfairLock` rather than `NSLock` — same correctness
    /// contract, ~30%
    /// lower lock-acquire overhead, matters here because `publish()`
    /// fires every second during a workout. The lock is uncontended
    /// 99.9% of the time so the difference per acquire is small in
    /// absolute terms, but at 1 Hz over a long workout it adds up.
    /// Both readers (currentSnapshot from AI context builder,
    /// currentSamples from timeline tool) and the writer (publish
    /// from the recorder tick) go through the same primitive.
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private struct State {
        var snapshot: AssistantContext.LiveWorkoutSnapshot?
        var lastUpdate: Date?
        var samplesProvider: SamplesProvider?
        /// The provider's answer at the last publish.
        var samples: [WorkoutSample] = []
    }
    /// Provider for the recorder's recent-sample buffer, which lives on the
    /// main actor. The broker asks it once per `publish` (the recorder's
    /// main-actor tick) and keeps the answer, so `currentSamples()` hands the
    /// AI's `workout.live.timeline` tool and the context renderer the last N
    /// seconds of correlated HR / elevation / pace / power / α1 / METs
    /// samples from any thread without touching main-actor state. The
    /// buffer is a copy-on-write array, so keeping it costs a reference.
    typealias SamplesProvider = @Sendable () -> [WorkoutSample]

    private init() {}

    /// Called by WorkoutRecorder each tick while recording, on the main
    /// actor, where the samples provider can read the recorder's buffer.
    func publish(_ snapshot: AssistantContext.LiveWorkoutSnapshot) {
        let provider = lock.withLock { state in state.samplesProvider }
        let samples = provider?() ?? []
        lock.withLock { state in
            state.snapshot = snapshot
            state.lastUpdate = Date()
            state.samples = samples
        }
    }

    /// Called by WorkoutRecorder at start. The broker holds the
    /// closure for the life of the recording; `clear()` releases it
    /// and the kept samples so a stopped workout's samples can't leak
    /// through to a later AI question.
    func registerSamplesProvider(_ provider: @escaping SamplesProvider) {
        lock.withLock { state in
            state.samplesProvider = provider
        }
    }

    /// Called by WorkoutRecorder at stop (`tearDownLiveWorkoutServices`).
    /// No error path calls it. A start that fails after installing the
    /// provider leaves it registered until the next start replaces it;
    /// nothing publishes meanwhile, so no samples are kept and
    /// `currentSnapshot()` stays nil.
    func clear() {
        lock.withLock { state in
            state.snapshot = nil
            state.lastUpdate = nil
            state.samplesProvider = nil
            state.samples = []
        }
    }

    /// Called by ContextBuilder. Returns nil if no workout is active or the
    /// snapshot has gone stale.
    func currentSnapshot() -> AssistantContext.LiveWorkoutSnapshot? {
        lock.withLock { state in
            guard let snapshot = state.snapshot, let lastUpdate = state.lastUpdate else { return nil }
            if Date().timeIntervalSince(lastUpdate) > Self.staleAfterSec { return nil }
            return snapshot
        }
    }

    /// Called by `WorkoutLiveNamespace` when the AI invokes
    /// `workout.live.timeline`, and by the context renderer. Returns the
    /// recorder's per-tick sample buffer as of the last publish (at most one
    /// tick old) so the namespace can window / decimate it according to the
    /// AI's request. Safe from any thread: it reads only the lock. Returns
    /// empty when no workout is active.
    func currentSamples() -> [WorkoutSample] {
        lock.withLock { state in state.samples }
    }
}

// MARK: - Live HRV Broker
//
// Sibling to LiveWorkoutBroker for the RR/HRV recording path — quick
// streaming sessions, overnight recordings, paused state. The workout
// broker only fires during a WorkoutRecorder run; without this an
// overnight or quick session is invisible to the AI ("what's my beat
// count right now?" → "I don't know" even though the record screen
// shows 1,247 beats live on the user's face).
//
// Uses a **pull provider** rather than the workout broker's push model.
// RRCollector already publishes high-frequency state via Combine; asking
// it to also push to a broker each beat would be wasteful and adds a
// coupling point that can go stale. The provider closure lets the broker
// ask RRCollector for a snapshot on demand, at AI-request time.
final class LiveHRVBroker: Sendable {
    static let shared = LiveHRVBroker()

    /// Closure the collector installs at app init. Must be safe to call
    /// from any thread without an actor hop: the installed one reads a
    /// lock-protected mirror that the collector refreshes on the main actor.
    typealias Provider = @Sendable () -> AssistantContext.LiveHRVSnapshot?

    private let provider = OSAllocatedUnfairLock<Provider?>(initialState: nil)

    private init() {}

    /// Called once at app wiring time by the owner of RRCollector.
    func registerProvider(_ provider: @escaping Provider) {
        self.provider.withLock { $0 = provider }
    }

    /// Called by ContextBuilder / AssistantContextSource. Returns nil
    /// when no HRV session is active.
    func currentSnapshot() -> AssistantContext.LiveHRVSnapshot? {
        provider.withLock { $0 }?()
    }
}
