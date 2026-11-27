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
// duplicate the canonical workout the iOS app writes. Stopping ends the
// session and discards the builder's workout rather than finishing it.
final class WatchWorkoutManager: NSObject, ObservableObject {
    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    /// True once we've successfully requested HK authorization. The
    /// Watch app needs its own auth grant — iOS auth doesn't transfer.
    /// Without this, the first `HKWorkoutSession(...)` call throws and
    /// the keep-alive never starts, so the Watch app drops out mid-
    /// workout and needs a soft restart.
    private var hasRequestedAuth = false
    /// A start is waiting on the authorization answer or on a recovery (see
    /// `finishPendingStart`); a second start (iOS sends it twice) must not
    /// begin another wait. `stop()` clears it, so a workout that ended during
    /// the wait does not start a session afterwards.
    private var startPending = false
    /// The sport of the pending start, applied once the wait resolves.
    private var pendingSportRaw: String?
    /// The authorization request a pending start waits on is outstanding.
    private var authorizationInFlight = false
    /// watchOS is handing back a session that was running when the app was
    /// ended (`recoverActiveSession`); a start waits for it rather than
    /// running a second session beside it.
    private var recoveryPending = false
    /// The running session is one `recoverActiveSession` took over, which the
    /// iPhone has not yet asked for (`start`).
    private var sessionWasRecovered = false
    /// What the iPhone last said while a recovery was outstanding: true for a
    /// start (it is recording), false for a stop or a report that it is not
    /// recording, nil for nothing yet. `finishRecovery` applies it to the
    /// session it takes over, which did not exist yet when the iPhone spoke.
    private var phoneRecordingDuringRecovery: Bool?

    /// Most recent HKWorkoutSession start failure, shown under the live
    /// metrics so the user knows wrist-HR fallback won't fire. nil when start
    /// succeeded or hasn't been attempted. Silently swallowing the start
    /// error makes strap-drop fallback look broken when the real cause is
    /// missing HK auth.
    @Published private(set) var lastStartError: String?

    /// The Watch ended its own session without the iPhone: the wrist End with
    /// the iPhone out of reach, or the iPhone app silent for
    /// `WatchMessageDecoding.phoneSilenceLimit`. The live screen says so
    /// instead of showing the last numbers as if the workout were still
    /// running. Cleared when a session starts again.
    @Published private(set) var endedWithoutPhone = false

    /// When the iPhone app last sent the Watch anything; see
    /// `watchForPhoneSilence`.
    private var lastPhoneContact = Date()
    private var phoneSilenceTask: Task<Void, Never>?
    /// The session was ended because the iPhone app went quiet, and the
    /// iPhone has not been heard from since.
    private var endedForPhoneSilence = false
    /// The sport of the running (or silence-ended) session, to restart it with.
    private var sessionSportRaw: String?
    private var phoneMessagesTask: Task<Void, Never>?

    /// Request HK authorization on Watch. Idempotent; a no-op after the
    /// first successful call. The system shows its prompt only for types
    /// not yet decided, so after the first answer this is silent.
    func requestAuthorizationIfNeeded() async {
        guard !hasRequestedAuth, HKHealthStore.isHealthDataAvailable() else { return }
        let toShare: Set<HKSampleType> = [
            HKQuantityType.workoutType()
        ]
        // Heart rate is the only type the Watch reads; the workout type is
        // shared because the live session needs it.
        let toRead: Set<HKObjectType> = [HKQuantityType(.heartRate)]
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
        // The iPhone is recording, so a recovered session is this workout's.
        sessionWasRecovered = false
        if recoveryPending { phoneRecordingDuringRecovery = true }
        if session != nil || startPending { return }
        sessionSportRaw = sportRaw
        endedWithoutPhone = false
        startPending = true
        pendingSportRaw = sportRaw
        // Most launches already requested this from `WatchApp.onAppear`, but a
        // fresh install where the user taps Start before that settles has
        // not, and neither has a relaunch watchOS made in the background:
        // wait for the answer, or the session throws for lack of it.
        if !hasRequestedAuth, !authorizationInFlight { awaitAuthorization() }
        finishPendingStart()
    }

    private func awaitAuthorization() {
        authorizationInFlight = true
        Task {
            await requestAuthorizationIfNeeded()
            authorizationInFlight = false
            finishPendingStart()
        }
    }

    /// Starts the session a start is holding, once nothing it waits on is
    /// outstanding (the authorization answer, a recovery), unless `stop()`
    /// cancelled it in the meantime. A recovered session already running is
    /// kept, not joined by a second one.
    private func finishPendingStart() {
        guard startPending, !authorizationInFlight, !recoveryPending else { return }
        startPending = false
        if session == nil { startWorkoutSession(sportRaw: pendingSportRaw) }
    }

    // MARK: - Recovery after a relaunch

    /// watchOS ended the app while its workout session ran (a crash, memory
    /// pressure) and relaunched it to hand the session back
    /// (`WatchAppDelegate.handleActiveWorkoutRecovery`). The session is taken
    /// over, so the start the iPhone's state then asks for keeps it instead of
    /// running a second one beside it. If the iPhone reports it is not
    /// recording, the session is stopped like any other, also when the report
    /// arrives before watchOS has handed the session back.
    ///
    /// `@Sendable`: HealthKit calls back on its own queue.
    func recoverActiveSession() {
        recoveryPending = true
        phoneRecordingDuringRecovery = nil
        healthStore.recoverActiveWorkoutSession { @Sendable recovered, _ in
            // An error means there was no session to hand back; a pending
            // start then runs a new one.
            Task { @MainActor in self.finishRecovery(recovered) }
        }
    }

    /// A session that started while the recovery was outstanding (none
    /// should: a start waits for it) keeps running, and the recovered one is
    /// ended rather than left beside it. What the iPhone said during the wait
    /// (`phoneRecordingDuringRecovery`) then applies to the session taken
    /// over: after a start it is the iPhone's workout's session, and after a
    /// stop or a not-recording report it is stopped at once.
    private func finishRecovery(_ recovered: HKWorkoutSession?) {
        recoveryPending = false
        let phoneRecording = phoneRecordingDuringRecovery
        phoneRecordingDuringRecovery = nil
        if let recovered, session == nil {
            adopt(recovered, askedForByPhone: phoneRecording == true)
            if phoneRecording == false { stop() }
        } else {
            recovered?.end()
        }
        finishPendingStart()
    }

    private func adopt(_ recovered: HKWorkoutSession, askedForByPhone: Bool) {
        let recoveredBuilder = recovered.associatedWorkoutBuilder()
        recovered.delegate = self
        recoveredBuilder.delegate = self
        session = recovered
        builder = recoveredBuilder
        sessionWasRecovered = !askedForByPhone
        watchForPhoneSilence()
    }

    /// The iPhone reports it is not recording, and was not before either (a
    /// stop it reports goes to `stop()`). A recovered session the iPhone never
    /// asked for is stopped, rather than holding the sensor until the
    /// phone-silence check ends it; a session started for the iPhone's
    /// workout is left to the iPhone's stop. While watchOS has not yet
    /// handed the session back, the report is kept for `finishRecovery`.
    func notePhoneNotRecording() {
        if recoveryPending { phoneRecordingDuringRecovery = false }
        guard sessionWasRecovered else { return }
        stop()
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
        // `@Sendable`: HealthKit calls this on its own queue, and a closure
        // formed in this main-actor type would otherwise assert main there.
        let attempt = ObjectIdentifier(started)
        workoutBuilder.beginCollection(withStart: Date()) { @Sendable collecting, error in
            guard !collecting, let error else { return }
            Task { @MainActor in self.noteStartFailure(error, of: attempt) }
        }
        watchForPhoneSilence()
    }

    /// Not fatal — the phone stays authoritative for the canonical recording —
    /// but the user needs to know wrist-HR fallback will not fire for this
    /// session, or a strap drop leaves a dead HR display with no explanation.
    ///
    /// `attempt` is the session the failed start made (nil when none was
    /// made). HealthKit reports a failed collection later, so the message is
    /// shown only while that session is still the current one: a report for
    /// a session already stopped, or replaced by a new start, says nothing
    /// about the workout on the wrist now.
    private func noteStartFailure(_ error: Error, of attempt: ObjectIdentifier? = nil) {
        let message = String(localized: "Wrist HR fallback not started: \(error.localizedDescription). Open Emuqu on your iPhone to verify Apple Health permissions.")
        Task { @MainActor in
            guard Self.failureIsCurrent(attempt, current: self.session.map(ObjectIdentifier.init)) else { return }
            self.lastStartError = message
        }
    }

    /// Whether a start failure belongs to the session now running: one with
    /// no session of its own (the start threw) always does.
    nonisolated static func failureIsCurrent(_ attempt: ObjectIdentifier?, current: ObjectIdentifier?) -> Bool {
        guard let attempt else { return true }
        return attempt == current
    }

    func stop() {
        // Idempotent. iOS sends stopWorkout via dual-channel
        // (sendMessage + transferUserInfo) so the Watch may see it twice;
        // the references are cleared first, so the second call finds no
        // session and ends nothing twice.
        startPending = false
        endedForPhoneSilence = false
        sessionWasRecovered = false
        if recoveryPending { phoneRecordingDuringRecovery = false }
        phoneSilenceTask?.cancel()
        phoneSilenceTask = nil
        guard let session, let builder else { return }
        self.session = nil
        self.builder = nil
        // Discarded rather than finished — the iOS app owns the canonical
        // HKWorkout. `end()` ends the session and `discardWorkout()` stops the
        // builder's collection and throws its workout away; neither takes a
        // callback, so nothing of this teardown runs later on HealthKit's
        // queue.
        session.end()
        builder.discardWorkout()
    }

    // MARK: - Ending without the iPhone

    /// The wrist Stop. The iPhone stays the one that ends and saves the
    /// workout, so the Watch's own session normally ends when the iPhone
    /// reports it stopped. With the iPhone unreachable that report may never
    /// come — the iPhone app may have been closed or crashed — so the Watch
    /// ends its session here and stops the heart-rate sensor, while the stop
    /// request stays queued for the iPhone.
    func noteWristStop(phoneReachable: Bool) {
        guard WatchMessageDecoding.endsSessionOnWristStop(phoneReachable: phoneReachable) else { return }
        stop()
        endedWithoutPhone = true
    }

    /// Follows the messages `sessionManager` takes from the iPhone app for
    /// the life of the app; each one is phone contact. Each is noted after
    /// the session manager has applied it, so `isRecording` is the iPhone's
    /// state in that message. Safe to call repeatedly; only the first sticks.
    func followPhoneMessages(of sessionManager: WatchSessionManager) {
        guard phoneMessagesTask == nil else { return }
        let messages = sessionManager.$messagesReceived.dropFirst().values
        phoneMessagesTask = Task { [weak self, weak sessionManager] in
            for await _ in messages {
                self?.notePhoneContact(phoneRecording: sessionManager?.isRecording ?? false)
            }
        }
    }

    /// Called for every message from the iPhone app. A session the Watch
    /// ended for silence starts again when the iPhone is back and still
    /// recording, so the rest of the workout keeps its keep-alive.
    func notePhoneContact(phoneRecording: Bool) {
        lastPhoneContact = Date()
        guard endedForPhoneSilence else { return }
        endedForPhoneSilence = false
        if phoneRecording { start(sportRaw: sessionSportRaw) }
    }

    /// While the session runs, checks once a minute whether the iPhone app
    /// has gone quiet for longer than `WatchMessageDecoding.phoneSilenceLimit`
    /// and, if so, ends the session: a recording iPhone sends its state every
    /// second, so that long without a word means the iPhone app is gone, and
    /// the session would otherwise hold the heart-rate sensor and the workout
    /// indicator until the iPhone app next opened.
    private func watchForPhoneSilence() {
        phoneSilenceTask?.cancel()
        lastPhoneContact = Date()
        phoneSilenceTask = Task { [weak self] in
            await self?.checkForPhoneSilence()
        }
    }

    /// Returns once the session has ended, or when cancelled because it
    /// ended or restarted elsewhere.
    private func checkForPhoneSilence() async {
        do {
            repeat {
                try await Task.sleep(for: WatchMessageDecoding.phoneSilenceCheckInterval)
            } while !endIfPhoneSilent()
        } catch {
            // swallow-ok: Task.sleep throws only CancellationError; stop() cancelled the check
            return
        }
    }

    /// True when it ended the session (or there is none left to watch).
    private func endIfPhoneSilent() -> Bool {
        guard session != nil else { return true }
        guard WatchMessageDecoding.phoneSilenceExceeded(lastContact: lastPhoneContact, now: Date()) else { return false }
        stop()
        endedForPhoneSilence = true
        endedWithoutPhone = true
        return true
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
