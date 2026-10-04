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
    /// A start is waiting on the authorization answer; a second start (iOS
    /// sends it twice) must not begin another wait. `stop()` clears it, so a
    /// workout that ended during the wait does not start a session afterwards.
    private var startPending = false
    /// The sport of the pending start, applied once authorization resolves.
    private var pendingSportRaw: String?

    /// Most recent HKWorkoutSession start failure, shown under the live
    /// metrics so the user knows wrist-HR fallback won't fire. nil when start
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
    ///
    /// `sportRaw` is the iPhone's `Sport` raw value; it sets the session's
    /// activity and location so watchOS shows the right workout.
    func start(sportRaw: String?) {
        if session != nil || startPending { return }
        guard !hasRequestedAuth else { return startWorkoutSession(sportRaw: sportRaw) }
        // Most launches already requested this from `WatchApp.onAppear`, but a
        // fresh install where the user taps Start before that settles has
        // not: wait for the answer, or the session throws for lack of it.
        startPending = true
        pendingSportRaw = sportRaw
        Task {
            await requestAuthorizationIfNeeded()
            finishPendingStart()
        }
    }

    /// Starts the session the authorization wait held back, unless `stop()`
    /// cancelled it in the meantime.
    private func finishPendingStart() {
        guard startPending else { return }
        startPending = false
        if session == nil { startWorkoutSession(sportRaw: pendingSportRaw) }
    }

    private func startWorkoutSession(sportRaw: String?) {
        let config = Self.configuration(forSport: sportRaw)
        do {
            try beginSession(with: config)
            Task { @MainActor in self.lastStartError = nil }
        } catch {
            noteStartFailure(error)
        }
    }

    /// The iPhone's `Sport` raw values → HealthKit activity and location. An
    /// unknown or missing sport is `.other` / `.unknown`, which turns on no
    /// sport-specific collection such as GPS distance.
    static func configuration(forSport sportRaw: String?) -> HKWorkoutConfiguration {
        let config = HKWorkoutConfiguration()
        let (activity, location) = activityAndLocation(forSport: sportRaw)
        config.activityType = activity
        config.locationType = location
        return config
    }

    private static func activityAndLocation(
        forSport sportRaw: String?
    ) -> (HKWorkoutActivityType, HKWorkoutSessionLocationType) {
        switch sportRaw {
        case "run", "trail_run": (.running, .outdoor)
        case "treadmill": (.running, .indoor)
        case "walk": (.walking, .outdoor)
        case "hike": (.hiking, .outdoor)
        case "bike": (.cycling, .outdoor)
        case "indoor_bike", "air_bike": (.cycling, .indoor)
        case "row": (.rowing, .indoor)
        case "crossfit": (.crossTraining, .indoor)
        default: (.other, .unknown)
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
        startPending = false
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
    /// A session watchOS ended or failed on its own (another workout app
    /// took over, say) is let go. Held on to, it made every later `start()`
    /// return early, so no keep-alive and no wrist-HR fallback until the
    /// Watch app was relaunched.
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .ended || toState == .stopped else { return }
        Task { @MainActor in self.forget(workoutSession) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.forget(workoutSession) }
    }

    @MainActor
    private func forget(_ workoutSession: HKWorkoutSession) {
        guard session === workoutSession else { return }
        session = nil
        builder = nil
    }
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
