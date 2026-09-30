import Combine
import Foundation
import HealthKit
import WatchConnectivity

// Runs an HKWorkoutSession on the Watch for two reasons:
//   1. Keep-alive — while the iOS phone is recording via Polar, the Watch
//      keeps a parallel session running so wrist HR is dense (1 Hz) and the
//      Watch stays awake.
//   2. HR fallback — if the phone's Polar strap disconnects (sweat, user
//      takes it off during HRR capture), the Watch's wrist HR is forwarded
//      back to the phone so HRR capture can still succeed.
//
// The Watch session never writes a standalone HKWorkout — that would
// duplicate the canonical workout the iOS app writes. We call
// `session.end()` without finalizing into a saved workout.
final class WatchWorkoutManager: NSObject, ObservableObject {
    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    /// True once we've successfully requested HK authorization. The
    /// Watch app needs its own auth grant — iOS auth doesn't transfer.
    /// Without this, the first `HKWorkoutSession(...)` call throws and
    /// the keep-alive never starts, so the Watch app drops out mid-
    /// workout (reported bug: "watch app drops out, requires soft restart").
    private var hasRequestedAuth = false

    /// Most recent HKWorkoutSession start failure, surfaced to the Watch UI
    /// so the user knows wrist-HR fallback won't fire. nil when start
    /// succeeded or hasn't been attempted. Silently swallowing the start
    /// error makes strap-drop fallback look broken when the real cause is
    /// missing HK auth.
    @Published private(set) var lastStartError: String?

    /// Request HK authorization on Watch. Idempotent; a no-op after the
    /// first successful call. The system shows its prompt only for types
    /// not yet decided, so after the first answer this is silent.
    func requestAuthorizationIfNeeded() async {
        guard !hasRequestedAuth, HKHealthStore.isHealthDataAvailable() else { return }
        let toShare: Set<HKSampleType> = [
            HKQuantityType.workoutType()
        ]
        let toRead: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType.workoutType()
        ]
        do {
            try await healthStore.requestAuthorization(toShare: toShare, read: toRead)
            hasRequestedAuth = true
        } catch {
            // Non-fatal. The next `start()` will surface a useful error.
            await MainActor.run {
                self.lastStartError = String(localized: "Apple Health authorization failed: \(error.localizedDescription)")
            }
        }
    }

    /// Idempotent. iOS sends `startWorkout` over both `sendMessage` and
    /// `transferUserInfo` so the Watch reliably receives it, which means the
    /// Watch may see two `start` calls for one workout. Without the guard the
    /// second builds a fresh session on top of the first, leaking it and
    /// confusing the delegate callbacks.
    func start() {
        if session != nil { return }
        // Most launches already requested this from `WatchApp.onAppear`, but a
        // fresh install where the user taps Start before that settles does not.
        if !hasRequestedAuth {
            Task { await requestAuthorizationIfNeeded() }
        }
        startWorkoutSession()
    }

    private func startWorkoutSession() {
        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = .outdoor
        do {
            try beginSession(with: config)
            Task { @MainActor in self.lastStartError = nil }
        } catch {
            noteStartFailure(error)
        }
    }

    private func beginSession(with config: HKWorkoutConfiguration) throws {
        let started = try HKWorkoutSession(healthStore: healthStore, configuration: config)
        let workoutBuilder = started.associatedWorkoutBuilder()
        workoutBuilder.dataSource = HKLiveWorkoutDataSource(
            healthStore: healthStore, workoutConfiguration: config
        )
        started.delegate = self
        workoutBuilder.delegate = self
        session = started
        builder = workoutBuilder
        started.startActivity(with: Date())
        workoutBuilder.beginCollection(withStart: Date()) { _, _ in }
    }

    /// Not fatal — the phone stays authoritative for the canonical recording —
    /// but the user needs to know wrist-HR fallback will not fire for this
    /// session, or a strap drop leaves a dead HR display with no explanation.
    private func noteStartFailure(_ error: Error) {
        let message = String(localized: "Wrist HR fallback not started: \(error.localizedDescription). Open Emuqu on your iPhone to verify Apple Health permissions.")
        Task { @MainActor in self.lastStartError = message }
    }

    func stop() {
        // Idempotent. iOS sends stopWorkout via dual-channel
        // (sendMessage + transferUserInfo) so the Watch may see it twice.
        // Without this guard the second call invokes stopActivity on an
        // already-stopping session and queues a redundant endCollection
        // callback, which can race with the first callback's `session = nil`
        // and resurrect a phantom session reference.
        guard let session, let builder else { return }
        self.session = nil
        self.builder = nil
        session.stopActivity(with: Date())
        builder.endCollection(withEnd: Date()) { _, _ in
            // Discard rather than finalize — the iOS app owns the canonical
            // HKWorkout. Captured locally to avoid retaining `self` past the
            // teardown that already nulled out the references.
            session.end()
        }
    }

    private func forwardLatestHR(_ bpm: Int) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage([
            "type": "watchHRSample",
            "heartRate": bpm
        ], replyHandler: nil)
    }
}

extension WatchWorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {}
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {}
}

extension WatchWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let hrType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(hrType) else { return }
        let stats = workoutBuilder.statistics(for: hrType)
        // Type-safe unit construction. A string form like
        // `HKUnit(from: "count/min")` would crash silently if the string
        // ever drifted; the canonical typed form can't.
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        if let quantity = stats?.mostRecentQuantity()?.doubleValue(for: bpmUnit) {
            let bpm = Int(quantity.rounded())
            Task { @MainActor in self.forwardLatestHR(bpm) }
        }
    }
}
