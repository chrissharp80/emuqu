import Foundation
// `@preconcurrency`: WCSession and its delegate closures predate Sendable.
@preconcurrency import WatchConnectivity

// The `WCSessionDelegate` conformance, split out of
// `WatchConnectivityBridge.swift`. Every method here is a callback
// from the framework; the bridge left behind is what the app calls into.

// MARK: - WCSessionDelegate

extension WatchConnectivityBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
        }

        guard activationState == .activated else { return }
        // No no-Watch cache to clear or mark: iOS activates
        // unconditionally and Apple's framework emits whatever it emits.

        // Push the current strap state to the Watch as the very first
        // thing iOS does after activation. The change observation set up
        // by `mirrorStrapState(from:)` only fires when something CHANGES; on a
        // cold launch with the strap already connected and stable, no
        // event fires and the Watch was sitting in "no strap" state
        // forever even though iOS knew otherwise. This call closes the
        // gap: every WCSession activation triggers a fresh push.
        Task { @MainActor in
            self.onWCSessionActivated?()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        // Reset the send-timeout circuit breaker when the
        // Watch becomes reachable again. iOS's `isReachable` flips can
        // come from the Watch app foregrounding, the Watch itself
        // waking, or the framework re-establishing the IDS channel —
        // any of which means `sendMessage` should work again.
        if session.isReachable {
            Self.resetTimeoutCount()
        }
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            // Wrist HR arrives only over the live channel; once it is gone,
            // the last reading is no longer current.
            if !reachable { self.latestWatchHR = nil }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let typeRaw = (message["type"] as? String) ?? "unknown"
        let payload = Self.plistData(message)
        Task { @MainActor in
            debugLog("[WatchBridge] didReceiveMessage type=\(typeRaw)")
            self.handleIncoming(Self.plistDictionary(payload))
        }
    }

    /// Reply-handler variant. The Watch uses this when it wants a round-trip
    /// confirmation — start / stop requests use it so the UI can show a real
    /// error ("Strap not connected") instead of silent optimism. For
    /// fire-and-forget messages the Watch still uses the non-reply path.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let typeRaw = (message["type"] as? String) ?? "unknown"
        let payload = Self.plistData(message)
        let reply = WCReplyBox(replyHandler)
        Task { @MainActor in
            debugLog("[WatchBridge] didReceiveMessage(reply) type=\(typeRaw)")
            reply.send(self.handleIncomingWithReply(Self.plistDictionary(payload)))
        }
    }

    /// Handle the `transferUserInfo` channel. The current Watch app sends to
    /// iOS with `sendMessage` and queues with `updateApplicationContext`, so
    /// nothing arrives here from it today. A user-info transfer is delivered
    /// whenever the iOS app next wakes, so it gets the same checks as a queued
    /// application context (`acceptsQueuedIntent`) before it is routed through
    /// `handleIncoming`.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let typeRaw = (userInfo["type"] as? String) ?? "unknown"
        let payload = Self.plistData(userInfo)
        Task { @MainActor in
            debugLog("[WatchBridge] didReceiveUserInfo type=\(typeRaw)")
            let snapshot = Self.plistDictionary(payload)
            guard self.acceptsQueuedIntent(snapshot) else { return }
            self.handleIncoming(snapshot)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// Pick up control intents the Watch queued via `updateApplicationContext`
    /// when the iPhone wasn't reachable at the time. Without this handler,
    /// any Watch tap that arrived during a backgrounded iPhone state was
    /// silently dropped — the user's "Watch did nothing" complaint.
    /// Dedupes against the last-seen timestamp so a context that's already
    /// been processed via `didReceiveMessage` (race during foreground
    /// transition) doesn't fire its action twice.
    ///
    /// An intent older than `maxQueuedIntentAge`, or past its `expiresAt`, is
    /// dropped: the context is delivered whenever the iPhone app next wakes,
    /// and a Start the user tapped and gave up on must not begin a workout
    /// hours later.
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let payload = Self.plistData(applicationContext)
        Task { @MainActor in
            let snapshot = Self.plistDictionary(payload)
            guard self.acceptsQueuedIntent(snapshot) else { return }
            self.handleIncoming(snapshot)
        }
    }

    /// Whether a queued Watch intent should still be acted on. Dropped when it
    /// was already processed (its `ts` is not newer than the last one seen),
    /// is older than `maxQueuedIntentAge`, is past its `expiresAt`, or is a
    /// stop, pause or resume tapped before the workout now recording began:
    /// that tap was meant for an earlier workout and must not end this one.
    private func acceptsQueuedIntent(_ snapshot: [String: Any]) -> Bool {
        let ts = (snapshot["ts"] as? Double) ?? 0
        if ts > 0, ts <= lastProcessedContextTimestamp { return false }
        if ts > 0 { lastProcessedContextTimestamp = ts }
        guard !Self.isStaleQueuedIntent(ts), !Self.isExpired(snapshot) else {
            debugLog("[WatchBridge] dropped a queued Watch intent from \(Int(Date().timeIntervalSince1970 - ts)) s ago", level: .warning)
            return false
        }
        guard !predatesCurrentWorkout(snapshot, ts: ts) else {
            debugLog("[WatchBridge] dropped a queued Watch workout control tapped before this workout started", level: .warning)
            return false
        }
        return true
    }

    /// A stop, pause or resume stamped before the recording workout's start.
    private func predatesCurrentWorkout(_ snapshot: [String: Any], ts: Double) -> Bool {
        guard ts > 0, let startedAt = liveWorkoutStartedAt,
              let typeRaw = snapshot[MessageKey.type.rawValue] as? String,
              let type = MessageType(rawValue: typeRaw)
        else { return false }
        let workoutControls: [MessageType] = [.stopWorkoutFromWatch, .pauseWorkoutFromWatch, .resumeWorkoutFromWatch]
        return workoutControls.contains(type) && ts < startedAt.timeIntervalSince1970
    }

    /// How long a queued Watch intent stays actionable: enough to pick up
    /// the iPhone after the Watch says "open iPhone".
    nonisolated private static let maxQueuedIntentAge: TimeInterval = 120

    nonisolated private static func isStaleQueuedIntent(_ ts: Double) -> Bool {
        ts > 0 && Date().timeIntervalSince1970 - ts > maxQueuedIntentAge
    }

    /// The Watch stamps every workout control it queues (start, stop, pause,
    /// resume, acknowledge) with `expiresAt`, seconds since 1970, one minute
    /// after the tap (`WatchSessionManager.withQueueExpiry`); past it, the tap
    /// no longer means "now". An intent without the stamp is judged by its
    /// `ts` alone (`isStaleQueuedIntent`).
    nonisolated private static func isExpired(_ snapshot: [String: Any]) -> Bool {
        guard let expiresAt = snapshot["expiresAt"] as? Double else { return false }
        return expiresAt < Date().timeIntervalSince1970
    }

    /// How old a live strap sample may be when it arrives. The Watch sends
    /// them only while the iPhone is reachable, so an older one was held up
    /// in transit and would show a stale heart rate as live.
    nonisolated private static let maxStrapSampleAge: TimeInterval = 5

    private static func isStaleStrapSample(_ message: [String: Any]) -> Bool {
        guard let ts = message["ts"] as? Double else { return false }
        let age = Date().timeIntervalSince1970 - ts
        guard age > maxStrapSampleAge else { return false }
        debugLog("[WatchBridge] dropped a Watch strap sample from \(Int(age)) s ago", level: .info)
        return true
    }

    private func handleIncoming(_ message: [String: Any]) {
        guard let typeRaw = message[MessageKey.type.rawValue] as? String,
              let type = MessageType(rawValue: typeRaw)
        else { return }
        switch type {
        case .watchHRSample:
            if let hr = message[MessageKey.heartRate.rawValue] as? Int { latestWatchHR = hr }
        case .watchStrapSample:
            handleWatchStrapSample(message)
        case .startVoiceChat:
            debugLog("[WatchBridge] received startVoiceChat from Watch")
            onStartVoiceChatFromWatch?()
        case .requestStrapState:
            onRequestStrapStateFromWatch?()
        case .requestCurrentState:
            replayCachedLiveState()
        case .startWorkoutFromWatch, .stopWorkoutFromWatch, .pauseWorkoutFromWatch, .resumeWorkoutFromWatch, .acknowledgeFinishedFromWatch:
            _ = handleIncomingWithReply(message)
        default:
            break
        }
    }

    /// Push the last live-state snapshot back over the transport, if we have
    /// one. Nothing to do before the first workout tick of the session.
    private func replayCachedLiveState() {
        guard let snapshot = Self.cachedLiveState() else { return }
        wcQueue.async { [weak self] in self?.transportLiveStatePayload(snapshot) }
    }

    /// The Watch can be paired DIRECTLY to a chest strap
    /// (`WatchStrapConnector`). Forward the sample into the same surface
    /// workout integrations read from. Stored so the recorder pipeline can
    /// prefer real strap RRs from the Watch when iOS's own PolarManager isn't
    /// holding the strap connection.
    ///
    /// This batch's RR samples are (a) kept on
    /// `latestWatchStrapRRMillis` for back-compat observers, and (b) APPENDED
    /// to `pendingWatchStrapRR` so the recorder can drain a full burst on its
    /// next tick. Without the queue, dense beat periods (3+ samples between
    /// two recorder ticks) lose samples to the simple overwrite.
    private func handleWatchStrapSample(_ message: [String: Any]) {
        guard !Self.isStaleStrapSample(message) else { return }
        if let hr = message["hr"] as? Int {
            latestWatchStrapHR = hr
        }
        let rrThisBatch = Self.rrMillis(in: message)
        if !rrThisBatch.isEmpty {
            latestWatchStrapRRMillis = rrThisBatch
            pendingWatchStrapRRLock.lock()
            pendingWatchStrapRR.append(contentsOf: rrThisBatch)
            // The Watch forwards whenever it holds the strap, workout or not,
            // and only a workout drains the queue. Kept to about the last ten
            // minutes of beats so it cannot grow for hours in between.
            if pendingWatchStrapRR.count > 1_000 {
                pendingWatchStrapRR.removeFirst(pendingWatchStrapRR.count - 1_000)
            }
            pendingWatchStrapRRLock.unlock()
        }
        latestWatchStrapAt = Date()
    }

    /// WatchConnectivity round-trips numeric arrays as `[Double]` on some
    /// paths and boxed `NSNumber` on others, so both spellings are accepted.
    private static func rrMillis(in message: [String: Any]) -> [Double] {
        if let rr = message["rrMillis"] as? [Double] { return rr }
        guard let rrAny = message["rrMillis"] as? [Any] else { return [] }
        return rrAny.compactMap { ($0 as? Double) ?? ($0 as? NSNumber)?.doubleValue }
    }

    /// The reply every Watch control message produces: "Phone not ready"
    /// when no handler is wired, the handler's own error string when it
    /// refuses, or a bare ok.
    ///
    /// Five case bodies in `handleIncomingWithReply` share this
    /// exact eight-line shape; inlined, they account for most of that
    /// function's cyclomatic complexity. The start case binds its two
    /// arguments into a matching no-argument closure before calling in, so
    /// every control message shares one reply contract.
    @MainActor
    private func controlReply(_ handler: (() -> String?)?) -> [String: Any] {
        guard let handler else {
            return [MessageKey.ok.rawValue: false, MessageKey.error.rawValue: String(localized: "Phone not ready", bundle: LanguageManager.appBundle)]
        }
        if let err = handler() {
            return [MessageKey.ok.rawValue: false, MessageKey.error.rawValue: err]
        }
        return [MessageKey.ok.rawValue: true]
    }

    /// Reply-producing counterpart. Runs the same intent routing as
    /// `handleIncoming` but returns a reply payload for the Watch to
    /// surface (success or error string). Non-control messages fall
    /// through with `{ok: true}` — stays backwards-compatible if a Watch
    /// build starts using reply handlers for types that don't need them.
    @MainActor
    private func startWorkoutReply(_ message: [String: Any]) -> [String: Any] {
        let sportRaw = (message[MessageKey.sport.rawValue] as? String) ?? "run"
        let zone = message[MessageKey.targetZone.rawValue] as? Int
        debugLog("[WatchBridge] received startWorkoutFromWatch sport=\(sportRaw) zone=\(zone.map(String.init) ?? "nil")")
        let start: (() -> String?)? = onStartWorkoutFromWatch.map { handler in
            { handler(sportRaw, zone) }
        }
        return controlReply(start)
    }

    private func handleIncomingWithReply(_ message: [String: Any]) -> [String: Any] {
        guard let typeRaw = message[MessageKey.type.rawValue] as? String,
              let type = MessageType(rawValue: typeRaw)
        else { return [MessageKey.ok.rawValue: false, MessageKey.error.rawValue: String(localized: "Unknown message", bundle: LanguageManager.appBundle)] }
        if let handler = controlHandler(for: type) {
            debugLog("[WatchBridge] received \(typeRaw)")
            return controlReply(handler)
        }
        switch type {
        case .startWorkoutFromWatch:
            return startWorkoutReply(message)
        case .startVoiceChat:
            return startVoiceChatReply()
        case .requestCurrentState:
            return currentStateReply()
        default:
            // Non-control types: just run the existing path.
            handleIncoming(message)
            return [MessageKey.ok.rawValue: true]
        }
    }

    /// The four plain stop/pause/resume/acknowledge controls, which differ only
    /// in which callback they invoke. Nil for everything else.
    private func controlHandler(for type: MessageType) -> (() -> String?)? {
        switch type {
        case .stopWorkoutFromWatch: return onStopWorkoutFromWatch
        case .pauseWorkoutFromWatch: return onPauseWorkoutFromWatch
        case .resumeWorkoutFromWatch: return onResumeWorkoutFromWatch
        case .acknowledgeFinishedFromWatch: return onAcknowledgeFinishedFromWatch
        default: return nil
        }
    }

    /// The Watch wires a reply handler on the voice-chat tap
    /// so it can surface a definite "Listening on iPhone" state instead of an
    /// optimistic "Chat started" plus silent failure. The toggle runs on the
    /// main actor (the closure is already wired to do so via
    /// `Task { @MainActor in ... }`) and we report back the resulting
    /// voice-controller state.
    ///
    /// The voice toggle starts an async `start()` — by the time we return it's
    /// typically still `.starting`. The Watch sees the next state pushed via
    /// the live-state path (see `pushVoiceChatState`).
    @MainActor
    private func startVoiceChatReply() -> [String: Any] {
        debugLog("[WatchBridge] received startVoiceChat from Watch (reply path)")
        guard AppDependencies.current.assistant.assistantViewModel.hasAcceptedDisclaimer else {
            return [MessageKey.ok.rawValue: false, "needsDisclaimer": true]
        }
        onStartVoiceChatFromWatch?()
        return [
            MessageKey.ok.rawValue: true,
            "voiceChatState": AppDependencies.current.assistant.voiceConversationController.state.watchLabel
        ]
    }

    /// The Watch relaunched (or foregrounded) and is asking
    /// whether a workout is live. Replying with the cached live-state snapshot
    /// directly makes restoration a single round-trip — the Watch feeds this
    /// straight into `apply()`, flips `isRecording`, jumps to the live screen,
    /// and re-arms its keep-alive HKWorkoutSession. When nothing is cached (no
    /// workout since launch) we reply with an explicit isRecording:false so
    /// the Watch correctly shows the Start screen.
    @MainActor
    private func currentStateReply() -> [String: Any] {
        debugLog("[WatchBridge] received requestCurrentState from Watch")
        if var snapshot = Self.cachedLiveState() {
            snapshot[MessageKey.type.rawValue] = MessageType.liveState.rawValue
            snapshot[MessageKey.ok.rawValue] = true
            return snapshot
        }
        return [
            MessageKey.ok.rawValue: true,
            MessageKey.type.rawValue: MessageType.liveState.rawValue,
            MessageKey.isRecording.rawValue: false
        ]
    }

    /// Push the voice-chat lifecycle state to the Watch so
    /// the wrist UI mirrors what the iPhone is doing (idle / listening
    /// / speaking / etc.). Called by `VoiceConversationController` on
    /// every state transition. Routes through `sendMessage` for live
    /// freshness; falls back to `transferUserInfo` for reliable delivery
    /// when the Watch is briefly unreachable, matching the strap-state
    /// push pattern.
    @MainActor
    func pushVoiceChatState(_ stateLabel: String) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let payload: [String: Any] = [
            "type": "voiceChatState",
            "voiceChatState": stateLabel,
            "ts": Date().timeIntervalSince1970
        ]
        if session.isReachable {
            // `@Sendable`: WatchConnectivity calls the error handler on its own
            // queue, and a closure inheriting this method's main-actor
            // isolation asserts main at entry.
            session.sendMessage(payload, replyHandler: nil) { @Sendable _ in
                // Errors are expected when the Watch app isn't in the
                // foreground; transferUserInfo (below) covers the
                // queued-delivery case.
            }
        }
        session.transferUserInfo(payload)
    }
}

extension WatchConnectivityBridge {
    /// WatchConnectivity payloads are property lists, so they round-trip
    /// through `Data` losslessly; `Data` is `Sendable` where `[String: Any]`
    /// is not, which is what lets a delegate callback hand the payload to
    /// the main actor.
    nonisolated static func plistData(_ dictionary: [String: Any]) -> Data {
        do {
            return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        } catch {
            debugLog("[WatchBridge] payload is not a property list, dropping it: \(error)", level: .warning)
            return Data()
        }
    }

    nonisolated static func plistDictionary(_ data: Data) -> [String: Any] {
        do {
            return try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] ?? [:]
        } catch {
            debugLog("[WatchBridge] payload failed to decode: \(error)", level: .warning)
            return [:]
        }
    }
}

/// WatchConnectivity's reply handler may be called from any queue, but the
/// SDK does not declare it `Sendable`; this box carries it to the main actor,
/// where the reply is computed, and back. Answering asynchronously keeps the
/// WatchConnectivity delegate queue free while the main actor is busy.
private struct WCReplyBox: @unchecked Sendable {
    private let handler: ([String: Any]) -> Void
    init(_ handler: @escaping ([String: Any]) -> Void) { self.handler = handler }
    func send(_ reply: [String: Any]) { handler(reply) }
}
