import CoreBluetooth
import Foundation
#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

/// The strap link: what each SDK event does, how code waits for the strap to be
/// usable, how a lost link comes back, and when a silent feed is acted on.
///
/// ## The contract this follows
///
/// Polar's guidance is that a method needing a feature is called only after
/// `bleSdkFeatureReady` for that feature, on every connection. SDK 8.x breaks
/// its own half: its readiness check runs on a main run-loop timer with a
/// ten-second deadline and never reports a feature that becomes ready after
/// it, although its documentation says such features "will be reported via
/// `bleSdkFeatureReady`". An H10 on a busy phone routinely enables HR
/// notifications after that deadline. So the app waits for the report when it
/// comes, and when the SDK has finished checking without one
/// (`StrapFeatureWait.unconfirmed`) it lets the SDK's per-call guard decide —
/// that guard checks the characteristic locally and refuses before touching the
/// radio.
///
/// ## Reconnection belongs to the SDK
///
/// With `automaticReconnection` (on by default) the SDK re-issues the
/// CoreBluetooth connect when a link drops, and iOS keeps that request pending
/// until the strap is back in range — in the background too. The app does not
/// disconnect-and-reconnect on its own schedule; every such cycle restarts the
/// strap's service setup. It only re-asserts the connect after an unexpected
/// drop (idempotent in the SDK), stops for a lost pairing, and gives a session
/// a bounded window before declaring the strap gone.
@MainActor
struct StrapLinkCoordinator {
    let manager: PolarManager

    private var runtime: StrapLinkRuntime { manager.linkRuntime }
    private var feed: StrapHeartRateFeed { StrapHeartRateFeed(manager: manager) }

    /// With no readiness summary by now the SDK's own check has ended (its
    /// window is ten seconds after service discovery).
    static let readinessSettleSec: TimeInterval = 30
    /// How often the feed's health is evaluated while linked.
    static let healthCheckIntervalSec: TimeInterval = 5
    /// How long the strap's recording status check may wait for the recording
    /// feature after a connect.
    static let statusCheckWindowSec: TimeInterval = 120

    // MARK: - Event delivery

    /// Start applying SDK events. Idempotent.
    func startEventDelivery() {
        guard runtime.deliveryTask == nil else { return }
        let events = runtime.pump.events
        // The stream finishes when the runtime is released, which ends this
        // loop; until then an event for a manager already gone is dropped.
        runtime.deliveryTask = Task { [weak manager] in
            for await event in events { manager?.link.apply(event) }
        }
    }

    func apply(_ event: StrapEvent) {
        switch event {
        case let .connecting(deviceId): noteConnecting(deviceId)
        case let .connected(deviceId, name, peripheralId):
            linkEstablished(deviceId: deviceId, name: name, peripheralId: peripheralId)
        case let .disconnected(deviceId, loss): linkDropped(deviceId: deviceId, loss: loss)
        case let .featureReady(deviceId, feature): featureReported(deviceId: deviceId, feature: feature)
        case let .readinessSummary(deviceId, ready, unavailable):
            summaryReported(deviceId: deviceId, ready: ready, unavailable: unavailable)
        case .powerOn: bluetoothPoweredOn()
        case .powerOff: bluetoothPoweredOff()
        case let .battery(deviceId, level): manager.applyBatteryLevelUpdate(from: deviceId, batteryLevel: level)
        case let .deviceInformation(deviceId, uuid, value):
            manager.applyFirmwareRevisionUpdate(from: deviceId, uuid: CBUUID(string: uuid), value: value)
        case let .deviceInformationKey(deviceId, key, value):
            manager.applyFirmwareRevisionUpdate(from: deviceId, key: key, value: value)
        }
    }

    // MARK: - Connection

    private func noteConnecting(_ deviceId: String) {
        guard manager.connectionState != .connected else { return }
        manager.connectionState = .connecting
        debugLog("[PolarManager] Connecting to \(deviceId)")
    }

    private func linkEstablished(deviceId: String, name: String, peripheralId: UUID?) {
        let deviceType = PolarDeviceType.from(deviceName: name)
        let restoredDuringSession = runtime.reconnectTargetId != nil && manager.isStreaming
        clearPreviousLink()
        adoptConnectedDevice(deviceId: deviceId, name: name, deviceType: deviceType)
        manager.readiness.linkEstablished()
        runtime.linkedAt = Date()
        runtime.linkedPeripheralId = peripheralId
        manager.feedStatus = .settingUp
        if restoredDuringSession {
            manager.streamingReconnectCount += 1
            debugLog("[PolarManager] Strap link restored during session (\(manager.streamingReconnectCount) this session)")
        }
        runtime.signal.fire()
        let generation = manager.readiness.generation
        feed.start(generation: generation)
        startHealthWatch(generation: generation)
        scheduleReadinessSettle(generation: generation)
        startRecordingStatusCheck(generation: generation, deviceId: deviceId, deviceType: deviceType)
    }

    /// The standard Heart Rate Service subscription holds its own connection to
    /// the strap. It lets go whenever the SDK's link ends — a drop, the user's
    /// disconnect, a deliberate reset — or it would keep the physical link up
    /// after the app meant it to go down.
    private func releaseStandardHeartRate() {
        #if canImport(PolarBleSdk)
            manager.standardHeartRate.releaseAll()
        #endif
    }

    /// A new link supersedes everything the previous one was doing, and ends
    /// any wait for the strap to come back.
    private func clearPreviousLink() {
        runtime.cancelLinkTasks()
        runtime.reconnectDeadlineTask?.cancel()
        runtime.reconnectDeadlineTask = nil
        runtime.reconnectTargetId = nil
        runtime.linkResetInProgress = false
        runtime.userDisconnectRequested = false
    }

    /// Per-device battery-usage counters are restored before the strap gets a
    /// chance to push the current % via Battery Service. Restoring after the
    /// callback would compare against an empty baseline and reset the counter
    /// on every reconnect, blowing away weeks of tracked recording time.
    private func adoptConnectedDevice(deviceId: String, name: String, deviceType: PolarDeviceType) {
        manager.connectedDeviceId = deviceId
        manager.connectedDeviceType = deviceType
        manager.pendingDeviceId = nil
        manager.connectionState = .connected
        manager.lastConnectedTime = Date()
        manager.saveLastConnectedTime()
        manager.addKnownDevice(id: deviceId, name: name, deviceType: deviceType)
        manager.loadBatteryUsageStateIfNeeded(for: deviceId)
        debugLog("[PolarManager] Connected to \(deviceType.displayName)")
    }

    /// What a drop does.
    ///
    /// The device identity survives a drop while a session is buffering: the
    /// session's provenance and the reconnect both need it. The H10's own
    /// recording state is never touched — the strap keeps recording through a
    /// drop.
    private func linkDropped(deviceId: String, loss: StrapLinkLoss) {
        let wasLinked = manager.readiness.isLinked
        guard wasLinked || manager.connectionState == .connecting,
              deviceId == manager.connectedDeviceId || deviceId == manager.pendingDeviceId
        else {
            runtime.userDisconnectRequested = false
            return
        }
        let wasStreaming = manager.isStreaming
        runtime.cancelLinkTasks()
        releaseStandardHeartRate()
        manager.readiness.linkLost()
        manager.feedStatus = .waitingForStrap
        runtime.signal.fire()
        PolarSDKLogBridge.narrateDisconnect(wasStreaming: wasStreaming, pairingError: loss.needsUserRepair)
        clearLinkReadings(preserveDeviceIdentity: wasStreaming)
        respondToDrop(deviceId: deviceId, loss: loss, wasLinked: wasLinked, wasStreaming: wasStreaming)
    }

    private func respondToDrop(deviceId: String, loss: StrapLinkLoss, wasLinked: Bool, wasStreaming: Bool) {
        guard !consumeDeliberateDrop(deviceId: deviceId) else { return }
        switch loss {
        case .deviceCommand:
            runtime.reconnectTargetId = nil
        case let .pairingLost(reason):
            pairingLost(reason: reason, wasStreaming: wasStreaming)
        case .connectionLost:
            // A connection attempt that never became a link is the SDK's to
            // retry; only a real link is chased.
            guard wasLinked else { return }
            requestReconnect(to: deviceId)
            if wasStreaming { armReconnectDeadline() }
        }
    }

    /// A drop the app caused itself: the user's disconnect is left alone, and a
    /// health-policy reset reconnects straight away. True when it was one.
    private func consumeDeliberateDrop(deviceId: String) -> Bool {
        if runtime.userDisconnectRequested {
            runtime.userDisconnectRequested = false
            runtime.reconnectTargetId = nil
            return true
        }
        guard runtime.linkResetInProgress else { return false }
        runtime.linkResetInProgress = false
        requestReconnect(to: deviceId)
        return true
    }

    /// A lost pairing is not retried, and a session waiting on the strap is
    /// told now rather than after the reconnect window.
    private func pairingLost(reason: String, wasStreaming: Bool) {
        debugLog("[PolarManager] Strap pairing lost (\(reason)) — not reconnecting; the user has to pair again", level: .warning)
        runtime.reconnectTargetId = nil
        manager.lastError = PolarManager.PolarError.pairingLost
        if wasStreaming { manager.reconnectExhausted = true }
    }

    /// Everything that describes the live link is stale the moment it drops,
    /// and showing a stale battery or heart rate is worse than showing none.
    private func clearLinkReadings(preserveDeviceIdentity: Bool) {
        manager.connectionState = .disconnected
        manager.pendingDeviceId = nil
        if !preserveDeviceIdentity {
            manager.connectedDeviceId = nil
            manager.connectedDeviceType = nil
        }
        manager.batteryLevel = nil
        manager.currentHeartRate = nil
        manager.firmwareVersion = nil
        manager.hasReceivedSoftwareRevision = false
    }

    /// Re-assert the connect to a strap that dropped unexpectedly. The SDK
    /// treats this as a no-op while it is already reconnecting. A drop can only
    /// have come from an existing SDK handle, so none is created here.
    private func requestReconnect(to deviceId: String) {
        runtime.reconnectTargetId = deviceId
        #if canImport(PolarBleSdk)
            do {
                try manager.strapAPI?.connectToDevice(deviceId)
            } catch {
                debugLog("[PolarManager] Reconnect request refused: \(error)")
            }
        #endif
    }

    /// A session gets `PolarReconnectPolicy.windowSeconds` for its strap to
    /// come back before the buffered stream is saved without it.
    private func armReconnectDeadline() {
        guard runtime.reconnectDeadlineTask == nil else { return }
        runtime.reconnectDeadlineTask = Task { [weak manager] in
            try? await Task.sleep(for: .seconds(PolarReconnectPolicy.windowSeconds))
            guard !Task.isCancelled, let manager else { return }
            manager.linkRuntime.reconnectDeadlineTask = nil
            guard manager.connectionState != .connected, manager.isStreaming else { return }
            debugLog("[PolarManager] ❌ Strap not back after \(Int(PolarReconnectPolicy.windowSeconds / 60)) min — ending the wait", level: .warning)
            manager.reconnectExhausted = true
        }
    }

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
        manager.readiness.linkLost()
        manager.feedStatus = .waitingForStrap
        manager.currentHeartRate = nil
        runtime.signal.fire()
    }

    // MARK: - Bluetooth power

    /// CoreBluetooth does not always report each peripheral's drop when the
    /// radio goes off, so the link is treated as lost here. The later real
    /// callback, if any, finds nothing linked and is ignored.
    private func bluetoothPoweredOff() {
        debugLog("[PolarManager] Bluetooth powered off")
        guard manager.readiness.isLinked, let deviceId = manager.connectedDeviceId else { return }
        linkDropped(deviceId: deviceId, loss: .connectionLost)
    }

    private func bluetoothPoweredOn() {
        guard let deviceId = runtime.reconnectTargetId, manager.connectionState != .connected else { return }
        debugLog("[PolarManager] Bluetooth powered on — reconnecting to the strap")
        requestReconnect(to: deviceId)
    }

    // MARK: - Readiness

    private func featureReported(deviceId: String, feature: StrapFeature) {
        guard deviceId == manager.connectedDeviceId, manager.readiness.isLinked else { return }
        manager.readiness.markReady(feature)
        debugLog("[PolarManager] Strap feature ready: \(feature)")
        runtime.signal.fire()
    }

    private func summaryReported(deviceId: String, ready: Set<StrapFeature>, unavailable: Set<StrapFeature>) {
        guard deviceId == manager.connectedDeviceId, manager.readiness.isLinked else { return }
        manager.readiness.applySummary(ready: ready, unavailable: unavailable)
        runtime.settledAt = runtime.settledAt ?? Date()
        let unreported = StrapFeature.allCases.filter { !ready.contains($0) && !unavailable.contains($0) }
        debugLog("[PolarManager] Strap readiness summary — ready: \(ready.map { "\($0)" }.sorted()), unavailable: \(unavailable.map { "\($0)" }.sorted()), not reported: \(unreported.map { "\($0)" })")
        runtime.signal.fire()
    }

    private func scheduleReadinessSettle(generation: Int) {
        runtime.settleTask = Task { [weak manager] in
            try? await Task.sleep(for: .seconds(Self.readinessSettleSec))
            guard !Task.isCancelled, let manager,
                  manager.readiness.generation == generation, !manager.readiness.isSettled
            else { return }
            manager.readiness.settleWithoutSummary()
            manager.linkRuntime.settledAt = Date()
            debugLogExternal("Strap sent no readiness summary \(Int(Self.readinessSettleSec)) s after connecting — its own per-call checks decide from here.", cause: .strap)
            manager.linkRuntime.signal.fire()
        }
    }

    /// Suspends until `feature` has an answer on a live link, the deadline
    /// passes, `keepWaiting` turns false, or the task is cancelled. Waits
    /// across disconnects: a strap that drops and returns is still answered.
    func awaitFeature(
        _ feature: StrapFeature,
        until deadline: Date?,
        while keepWaiting: () -> Bool = { true }
    ) async -> StrapFeatureWait {
        while true {
            if let outcome = manager.readiness.waitOutcome(for: feature) { return outcome }
            guard keepWaiting(), !Task.isCancelled else { return .timedOut }
            let remaining = deadline?.timeIntervalSinceNow
            if let remaining, remaining <= 0 { return .timedOut }
            _ = await runtime.signal.wait(timeout: remaining)
        }
    }

    /// Suspends until the strap is connected, or the deadline passes.
    func awaitConnection(until deadline: Date) async -> Bool {
        while manager.connectionState != .connected {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, !Task.isCancelled else { return false }
            _ = await runtime.signal.wait(timeout: remaining)
        }
        return true
    }

    /// Suspends until the link is down, or the deadline passes.
    func awaitDisconnection(until deadline: Date) async -> Bool {
        while manager.readiness.isLinked {
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
            let generation = manager.readiness.generation
            do {
                let value = try await operation()
                confirm(feature, onGeneration: generation)
                return value
            } catch where StrapErrorClassifier.isNotReadyYet(error) {
                refusals += 1
                try await pauseBeforeRetrying(after: error, refusals: refusals, deadline: deadline)
            }
        }
    }

    /// An operation needing `feature` succeeded, which proves it usable — for
    /// the link it ran on, not one that has replaced it since.
    private func confirm(_ feature: StrapFeature, onGeneration generation: Int) {
        guard manager.readiness.generation == generation else { return }
        manager.readiness.confirm(feature)
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
    /// land past the deadline. A readiness change wakes the wait early.
    private func pauseBeforeRetrying(after error: Error, refusals: Int, deadline: Date?) async throws {
        let delay = StrapFeedHealth.resubscribeDelay(afterFailures: refusals)
        if let deadline, Date().addingTimeInterval(delay) >= deadline { throw error }
        _ = await runtime.signal.wait(timeout: delay)
    }

    /// Whether an operation needing `feature` may be attempted now.
    func isUsable(_ feature: StrapFeature) -> Bool {
        switch manager.readiness.waitOutcome(for: feature) {
        case .ready, .unconfirmed: true
        case .unavailable, .timedOut, nil: false
        }
    }

    /// Throws unless the strap has either reported `feature` or finished
    /// checking without reporting it.
    func requireUsable(_ feature: StrapFeature) throws {
        switch manager.readiness.waitOutcome(for: feature) {
        case .ready, .unconfirmed: return
        case .unavailable: throw PolarManager.PolarError.featureNotReady("\(feature) (not offered by this strap)")
        case .timedOut, nil: throw PolarManager.PolarError.featureNotReady("\(feature)")
        }
    }

    // MARK: - Recording status on connect

    /// Whether the strap is already recording, and what it has stored, is
    /// read once per link as soon as its recording feature is usable. It
    /// restores `isRecordingOnDevice` and `hasStoredExercise` after a relaunch,
    /// which is what surfaces a night still sitting on the strap.
    private func startRecordingStatusCheck(generation: Int, deviceId: String, deviceType: PolarDeviceType) {
        let feature: StrapFeature = deviceType == .veritySense ? .offlineRecording : .h10Recording
        runtime.statusCheckTask = Task { [weak manager] in
            guard let manager else { return }
            await Self.readRecordingStatus(manager, feature: feature, generation: generation, deviceId: deviceId)
        }
    }

    private static func readRecordingStatus(
        _ manager: PolarManager, feature: StrapFeature, generation: Int, deviceId: String
    ) async {
        do {
            try await checkStatusAndStoredExercises(manager, feature: feature, generation: generation, deviceId: deviceId)
        } catch {
            guard !Task.isCancelled, manager.readiness.generation == generation else { return }
            debugLogExternal("Couldn't read the strap's recording status after connecting — \(error)", cause: .strap)
        }
    }

    private static func checkStatusAndStoredExercises(
        _ manager: PolarManager, feature: StrapFeature, generation: Int, deviceId: String
    ) async throws {
        _ = try await manager.link.whenFeatureUsable(
            feature, until: Date().addingTimeInterval(statusCheckWindowSec),
            while: { manager.readiness.generation == generation },
            perform: { try await manager.checkRecordingStatus(deviceId: deviceId) }
        )
        guard manager.readiness.generation == generation else { return }
        await manager.checkForStoredExercises(deviceId: deviceId)
    }

    // MARK: - Feed health

    private func startHealthWatch(generation: Int) {
        runtime.healthTask = Task { [weak manager] in
            while await Self.healthCheckDue(), let manager, manager.readiness.generation == generation {
                manager.link.evaluateFeedHealth()
            }
        }
    }

    /// Sleeps one health interval; false once the watch has been cancelled.
    private static func healthCheckDue() async -> Bool {
        do {
            try await Task.sleep(for: .seconds(healthCheckIntervalSec))
            return true
        } catch {
            return false
        }
    }

    func evaluateFeedHealth(now: Date = Date()) {
        let decision = StrapFeedHealth.decide(feedHealthInputs(now: now))
        if manager.feedStatus != decision.status {
            debugLog("[PolarManager] Heart-rate feed: \(manager.feedStatus) → \(decision.status)")
            manager.feedStatus = decision.status
        }
        switch decision.action {
        case .none: break
        case .resubscribe:
            runtime.lastResubscribeAt = now
            debugLogExternal("Strap linked but silent — re-opening the heart-rate subscription over the same link.", cause: .strap)
            feed.restart()
        case .resetLink:
            resetLink(now: now)
        }
    }

    private func feedHealthInputs(now: Date) -> StrapFeedHealth.Inputs {
        StrapFeedHealth.Inputs(
            now: now,
            isLinked: manager.readiness.isLinked,
            linkedAt: runtime.linkedAt,
            settledAt: runtime.settledAt,
            lastSampleAt: runtime.lastSampleAt,
            lastResubscribeAt: runtime.lastResubscribeAt,
            lastLinkResetAt: runtime.lastLinkResetAt,
            sessionActive: manager.isStreaming
        )
    }

    /// Drop and re-establish the link so the strap sets its services up again.
    private func resetLink(now: Date) {
        runtime.lastLinkResetAt = now
        debugLog("[PolarManager] Strap still silent after re-subscribing — resetting the link", level: .warning)
        beginLinkReset()
    }

    /// Disconnect on purpose and let the drop handler reconnect straight away.
    /// Returns false when there was no link to reset.
    @discardableResult
    func beginLinkReset() -> Bool {
        #if canImport(PolarBleSdk)
            guard let deviceId = manager.connectedDeviceId, let api = manager.strapAPI, manager.readiness.isLinked else {
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
        guard manager.feedStatus != .live else { return }
        let wasSettingUp = manager.feedStatus == .settingUp
        manager.feedStatus = .live
        guard wasSettingUp, let linkedAt = runtime.linkedAt else { return }
        let seconds = date.timeIntervalSince(linkedAt)
        debugLog("[PolarManager] First heart-rate sample \(String(format: "%.1f", seconds)) s after the link came up")
    }
}
