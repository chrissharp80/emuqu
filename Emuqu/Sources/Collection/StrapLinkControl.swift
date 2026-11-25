import Foundation
#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

/// What the other strap parts ask of the link: wait until the strap can serve
/// a feature, is connected or has gone; note a sample arriving; end a session's
/// wait; tear the link down for the user or reset it on purpose.
///
/// Holds the link's state, its runtime and the radio, and nothing else. What
/// each SDK event does is `StrapLinkCoordinator`'s.
@MainActor
struct StrapLinkControl {
    let state: StrapLinkState
    let runtime: StrapLinkRuntime
    let radio: StrapRadioSource

    // MARK: - Waiting on the link

    /// Suspends until `feature` has an answer on a live link, the deadline
    /// passes, `keepWaiting` turns false, or the task is cancelled. Waits
    /// across disconnects: a strap that drops and returns is still answered.
    func awaitFeature(
        _ feature: StrapFeature,
        until deadline: Date?,
        while keepWaiting: () -> Bool = { true }
    ) async -> StrapFeatureWait {
        while true {
            if let outcome = state.readiness.waitOutcome(for: feature) { return outcome }
            guard keepWaiting(), !Task.isCancelled else { return .timedOut }
            let remaining = deadline?.timeIntervalSinceNow
            if let remaining, remaining <= 0 { return .timedOut }
            _ = await runtime.signal.wait(timeout: remaining)
        }
    }

    /// Suspends until the strap is connected, or the deadline passes.
    func awaitConnection(until deadline: Date) async -> Bool {
        while state.connectionState != .connected {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, !Task.isCancelled else { return false }
            _ = await runtime.signal.wait(timeout: remaining)
        }
        return true
    }

    /// Suspends until the link is down, or the deadline passes.
    func awaitDisconnection(until deadline: Date) async -> Bool {
        while state.readiness.isLinked {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, !Task.isCancelled else { return false }
            _ = await runtime.signal.wait(timeout: remaining)
        }
        return true
    }

    /// Run `operation` once the strap can serve `feature`.
    ///
    /// Waits for readiness, runs the operation, and retries only the SDK's
    /// local "not ready yet" refusal — which happens before any radio traffic —
    /// until the deadline. Any other error is the operation's and is thrown.
    /// Success confirms the feature for the rest of the link.
    func whenFeatureUsable<T>(
        _ feature: StrapFeature,
        until deadline: Date?,
        while keepWaiting: () -> Bool = { true },
        perform operation: () async throws -> T
    ) async throws -> T {
        var refusals = 0
        while true {
            try await awaitUsable(feature, until: deadline, while: keepWaiting)
            let generation = state.readiness.generation
            do {
                let value = try await operation()
                confirm(feature, onGeneration: generation)
                return value
            } catch where StrapErrorClassifier.isNotReadyYet(error) {
                refusals += 1
                try await pauseBeforeRetrying(after: error, refusals: refusals, deadline: deadline, while: keepWaiting)
            }
        }
    }

    /// An operation needing `feature` succeeded, which proves it usable — for
    /// the link it ran on, not one that has replaced it since.
    private func confirm(_ feature: StrapFeature, onGeneration generation: Int) {
        guard state.readiness.generation == generation else { return }
        state.readiness.confirm(feature)
    }

    /// Returns once `feature` may be attempted; throws when the strap does not
    /// offer it or the deadline passed first.
    private func awaitUsable(_ feature: StrapFeature, until deadline: Date?, while keepWaiting: () -> Bool) async throws {
        switch await awaitFeature(feature, until: deadline, while: keepWaiting) {
        case .ready, .unconfirmed: return
        case .unavailable: throw PolarManager.PolarError.featureNotReady("\(feature) (not offered by this strap)")
        case .timedOut: throw PolarManager.PolarError.featureNotReady("\(feature)")
        }
    }

    /// Wait out a "not ready yet" refusal, or rethrow it when the retry would
    /// land past the deadline, the caller has stopped waiting (`keepWaiting`
    /// false, e.g. the user's Cancel on a transfer) or the task was
    /// cancelled, where the wait would return at once and the retries run
    /// back to back. A readiness change wakes the wait early.
    private func pauseBeforeRetrying(after error: Error, refusals: Int, deadline: Date?, while keepWaiting: () -> Bool) async throws {
        guard keepWaiting(), !Task.isCancelled else { throw error }
        let delay = StrapFeedHealth.resubscribeDelay(afterFailures: refusals)
        if let deadline, Date().addingTimeInterval(delay) >= deadline { throw error }
        _ = await runtime.signal.wait(timeout: delay)
    }

    /// Whether an operation needing `feature` may be attempted now.
    func isUsable(_ feature: StrapFeature) -> Bool {
        switch state.readiness.waitOutcome(for: feature) {
        case .ready, .unconfirmed: true
        case .unavailable, .timedOut, nil: false
        }
    }

    /// Throws unless the strap has either reported `feature` or finished
    /// checking without reporting it.
    func requireUsable(_ feature: StrapFeature) throws {
        switch state.readiness.waitOutcome(for: feature) {
        case .ready, .unconfirmed: return
        case .unavailable: throw PolarManager.PolarError.featureNotReady("\(feature) (not offered by this strap)")
        case .timedOut, nil: throw PolarManager.PolarError.featureNotReady("\(feature)")
        }
    }

    // MARK: - Acting on the link

    /// The session ended; nothing is waiting for the strap any more.
    func sessionEnded() {
        runtime.reconnectDeadlineTask?.cancel()
        runtime.reconnectDeadlineTask = nil
        runtime.signal.fire()
    }

    /// The user asked to disconnect or cancel a connection attempt. The link is
    /// torn down here rather than when the SDK's callback arrives, because the
    /// caller clears the device identity immediately and the callback then no
    /// longer matches a device; the flag covers a callback that still does.
    func noteUserDisconnect() {
        runtime.userDisconnectRequested = true
        runtime.reconnectTargetId = nil
        runtime.reconnectDeadlineTask?.cancel()
        runtime.reconnectDeadlineTask = nil
        runtime.cancelLinkTasks()
        releaseStandardHeartRate()
        state.readiness.linkLost()
        state.feedStatus = .waitingForStrap
        state.currentHeartRate = nil
        runtime.signal.fire()
    }

    /// The standard Heart Rate Service subscription holds its own connection to
    /// the strap. It lets go whenever the SDK's link ends — a drop, the user's
    /// disconnect, a deliberate reset — or it would keep the physical link up
    /// after the app meant it to go down.
    func releaseStandardHeartRate() {
        #if canImport(PolarBleSdk)
            radio.standardHeartRate.releaseAll()
        #endif
    }

    /// Disconnect on purpose and let the drop handler reconnect straight away.
    /// Returns false when there was no link to reset.
    @discardableResult
    func beginLinkReset() -> Bool {
        #if canImport(PolarBleSdk)
            guard let deviceId = state.connectedDeviceId, let api = radio.strapAPI, state.readiness.isLinked else {
                return false
            }
            runtime.linkResetInProgress = true
            releaseStandardHeartRate()
            do {
                try api.disconnectFromDevice(deviceId)
                return true
            } catch {
                runtime.linkResetInProgress = false
                debugLog("[PolarManager] Link reset refused: \(error)")
                return false
            }
        #else
            return false
        #endif
    }

    /// A sample arrived on the feed.
    ///
    /// The first one on a link is logged with how long the link took to
    /// deliver it — the number a slow connect is judged by.
    func noteSample(at date: Date = Date()) {
        runtime.lastSampleAt = date
        guard state.feedStatus != .live else { return }
        let wasSettingUp = state.feedStatus == .settingUp
        state.feedStatus = .live
        guard wasSettingUp, let linkedAt = runtime.linkedAt else { return }
        let seconds = date.timeIntervalSince(linkedAt)
        debugLog("[PolarManager] First heart-rate sample \(String(format: "%.1f", seconds)) s after the link came up")
    }
}
