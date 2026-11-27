import Foundation
@preconcurrency import WatchConnectivity

// The Watch's workout controls other than Start: End, Pause, Resume and the
// summary's Save & Done, sent live when the iPhone is reachable and queued
// when it is not.

extension WatchSessionManager {
    // MARK: - Workout controls (Watch → phone)

    /// Ask the iPhone to stop the active workout.
    @MainActor
    func requestStopWorkout() {
        sendControlMessage(
            payload: ["type": WatchMessageDecoding.stopIntentType],
            pendingStatus: String(localized: "Stopping on iPhone…"),
            successStatus: String(localized: "Workout stopped")
        )
    }

    /// Ask the iPhone to pause (user-initiated).
    @MainActor
    func requestPauseWorkout() {
        sendControlMessage(
            payload: ["type": "pauseWorkoutFromWatch"],
            pendingStatus: String(localized: "Pausing…"),
            successStatus: String(localized: "Paused")
        )
    }

    /// Ask the iPhone to resume a paused workout.
    @MainActor
    func requestResumeWorkout() {
        sendControlMessage(
            payload: ["type": "resumeWorkoutFromWatch"],
            pendingStatus: String(localized: "Resuming…"),
            successStatus: String(localized: "Resumed")
        )
    }

    /// User tapped Save & Done on the Watch summary screen. Tells the
    /// iPhone to dismiss its post-workout sheet too and clears the
    /// Watch's `justCompleted` banner locally.
    @MainActor
    /// For a workout the iPhone left unsaved (`workoutNotSaved`) the status
    /// says it was not saved: Done there lets it go.
    func requestAcknowledgeFinished() {
        justCompleted = false
        let notSaved = workoutNotSaved
        workoutNotSaved = false
        sendControlMessage(
            payload: ["type": "acknowledgeFinishedFromWatch"],
            pendingStatus: notSaved ? String(localized: "Workout not saved") : String(localized: "Saving…"),
            successStatus: notSaved ? String(localized: "Workout not saved") : String(localized: "Saved")
        )
    }

    @MainActor
    func sendControlMessage(
        payload: [String: Any],
        pendingStatus: String,
        successStatus: String
    ) {
        guard WCSession.isSupported() else {
            statusLine = Self.phoneUnreachableStatus
            return
        }
        let session = WCSession.default
        // Stamp the payload so receivers can dedupe if both the live message
        // and the queued context arrive (race during foreground transition).
        var enriched = payload
        enriched["ts"] = Date().timeIntervalSince1970

        showControlStatus(pendingStatus)

        guard session.isReachable else {
            return queueUnlessStart(enriched, on: session, pendingStatus: pendingStatus)
        }
        sendLiveControlMessage(enriched, on: session, pendingStatus: pendingStatus, successStatus: successStatus)
    }

    /// The iPhone is not reachable. A start is never queued
    /// (`requestStartWorkout`), and reachability can drop between that
    /// method's check and `sendControlMessage`'s, so a start is refused here;
    /// any other control is queued.
    @MainActor
    private func queueUnlessStart(_ payload: [String: Any], on session: WCSession, pendingStatus: String) {
        guard payload["type"] as? String != "startWorkoutFromWatch" else {
            return finishControlRequest(status: Self.phoneUnreachableStatus, isStart: true)
        }
        queueControlMessage(payload, on: session, pendingStatus: pendingStatus)
    }

    /// The iPhone is not reachable: queue the intent via applicationContext so
    /// it is not dropped. The phone picks up the latest the moment its
    /// WCSession delegate runs again; past `expiresAt` it ignores it.
    ///
    /// The context holds one intent, so a queued End is never replaced by a
    /// later Pause or Resume while the iPhone may still act on it: losing the
    /// End would leave the workout running. Once the iPhone has reported the
    /// workout stopped (`isRecording` false), the End no longer holds anything
    /// back.
    @MainActor
    private func queueControlMessage(_ payload: [String: Any], on session: WCSession, pendingStatus: String) {
        if WatchMessageDecoding.wouldDisplaceQueuedStop(
            payloadType: payload["type"] as? String, pending: session.applicationContext,
            phoneRecording: isRecording, now: Date().timeIntervalSince1970
        ) {
            let stopping = String(localized: "Stopping on iPhone…")
            return showControlStatus(String(localized: "\(stopping) (open iPhone)"))
        }
        do {
            try session.updateApplicationContext(Self.withQueueExpiry(payload))
            showControlStatus(String(localized: "\(pendingStatus) (open iPhone)"))
        } catch {
            showControlStatus(String(localized: "Couldn't reach iPhone: \(error.localizedDescription)"))
        }
    }

    /// `@Sendable` handlers: WatchConnectivity runs them on its own queue (see
    /// `sendLiveVoiceChatRequest`). Only the decoded status line and the
    /// intent's type and stamp cross the hop. Any answer to a start, refusal
    /// or error included, ends the "Starting…" wait: the iPhone's reason is
    /// the message to show, not a later "didn't acknowledge".
    private func sendLiveControlMessage(
        _ payload: [String: Any], on session: WCSession, pendingStatus: String, successStatus: String
    ) {
        let type = payload["type"] as? String
        let sentAt = payload["ts"] as? Double
        let isStart = type == "startWorkoutFromWatch"
        let sport = payload["sport"] as? String
        session.sendMessage(
            payload,
            replyHandler: { @Sendable [weak self] reply in
                let status = WatchMessageDecoding.controlReplyStatus(reply, sport: sport, successStatus: successStatus)
                Task { @MainActor in self?.finishControlRequest(status: status, isStart: isStart) }
            },
            errorHandler: { @Sendable [weak self] err in
                let failure = String(localized: "Couldn't reach iPhone: \(err.localizedDescription)")
                Task { @MainActor in
                    self?.failLiveControlRequest(type: type, sentAt: sentAt, pendingStatus: pendingStatus, failure: failure)
                }
            }
        )
    }

    /// The live send failed: reachability was stale, or the send timed out. A
    /// start is reported and dropped, as it is never queued. Every other
    /// control is queued as it would have been with the iPhone out of reach,
    /// so an End is not lost, and an End also ends the Watch's own session, as
    /// the wrist End does with the iPhone unreachable. The iPhone acting on
    /// one that did arrive and is then queued as well is harmless: a second
    /// End, Pause, Resume or acknowledge finds it already done.
    private func failLiveControlRequest(type: String?, sentAt: Double?, pendingStatus: String, failure: String) {
        guard let type, let sentAt, type != "startWorkoutFromWatch" else {
            return finishControlRequest(status: failure, isStart: type == "startWorkoutFromWatch")
        }
        queueControlMessage(["type": type, "ts": sentAt], on: WCSession.default, pendingStatus: pendingStatus)
        if type == WatchMessageDecoding.stopIntentType { workoutManager?.noteWristStop(phoneReachable: false) }
    }

    private func finishControlRequest(status: String, isStart: Bool) {
        if isStart { clearStartWorkoutRequest() }
        showControlStatus(status)
    }
}
