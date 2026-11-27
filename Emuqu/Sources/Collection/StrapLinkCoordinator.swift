import CoreBluetooth
import Foundation
#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

/// The strap link: what each SDK event does, how a lost link comes back, and
/// when a silent feed is acted on. Waiting on the link is `StrapLinkControl`'s.
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
///
/// One per `PolarManager`, which holds it. Every task it starts captures it
/// weakly, so an event or timer that fires after the manager is gone does
/// nothing.
@MainActor
final class StrapLinkCoordinator {
    let link: StrapLinkControl
    let stream: StrapStreamSession
    let battery: StrapBatteryUsageTracker
    let pairings: StrapPairings
    /// Reads the strap's recording status once per link.
    let recording: StrapRecordingCoordinator

    init(
        link: StrapLinkControl, stream: StrapStreamSession, battery: StrapBatteryUsageTracker,
        pairings: StrapPairings, recording: StrapRecordingCoordinator
    ) {
        self.link = link
        self.stream = stream
        self.battery = battery
        self.pairings = pairings
        self.recording = recording
    }

    private var state: StrapLinkState { link.state }
    private var runtime: StrapLinkRuntime { link.runtime }
    var feed: StrapHeartRateFeed { StrapHeartRateFeed(link: link, stream: stream) }

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
        // loop; until then an event for a coordinator already gone is dropped.
        runtime.deliveryTask = Task { [weak self] in
            for await event in events { self?.apply(event) }
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
        case let .battery(deviceId, level): battery.applyLevelUpdate(from: deviceId, batteryLevel: level)
        case let .deviceInformation(deviceId, uuid, value):
            state.applyFirmwareRevisionUpdate(from: deviceId, uuid: CBUUID(string: uuid), value: value)
        case let .deviceInformationKey(deviceId, key, value):
            state.applyFirmwareRevisionUpdate(from: deviceId, key: key, value: value)
        }
    }

    // MARK: - Connection

    private func noteConnecting(_ deviceId: String) {
        guard state.connectionState != .connected else { return }
        state.connectionState = .connecting
        debugLog("[PolarManager] Connecting to \(deviceId)")
    }

    private func linkEstablished(deviceId: String, name: String, peripheralId: UUID?) {
        let deviceType = PolarDeviceType.from(deviceName: name)
        let restoredDuringSession = runtime.reconnectTargetId != nil && stream.isStreaming
        clearPreviousLink()
        adoptConnectedDevice(deviceId: deviceId, name: name, deviceType: deviceType)
        state.readiness.linkEstablished()
        runtime.linkedAt = Date()
        runtime.linkedPeripheralId = peripheralId
        state.feedStatus = .settingUp
        if restoredDuringSession {
            stream.streamingReconnectCount += 1
            debugLog("[PolarManager] Strap link restored during session (\(stream.streamingReconnectCount) this session)")
        }
        runtime.signal.fire()
        let generation = state.readiness.generation
        feed.start(generation: generation)
        startHealthWatch(generation: generation)
        scheduleReadinessSettle(generation: generation)
        startRecordingStatusCheck(generation: generation, deviceId: deviceId, deviceType: deviceType)
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
        state.connectedDeviceId = deviceId
        state.connectedDeviceType = deviceType
        state.pendingDeviceId = nil
        state.connectionState = .connected
        pairings.lastConnectedTime = Date()
        pairings.saveLastConnectedTime()
        pairings.addKnownDevice(id: deviceId, name: name, deviceType: deviceType)
        battery.loadState(for: deviceId)
        debugLog("[PolarManager] Connected to \(deviceType.displayName)")
    }

    /// What a drop does.
    ///
    /// The device identity survives a drop while a session is buffering: the
    /// session's provenance and the reconnect both need it. The H10's own
    /// recording state is never touched — the strap keeps recording through a
    /// drop.
    private func linkDropped(deviceId: String, loss: StrapLinkLoss) {
        let wasLinked = state.readiness.isLinked
        guard wasLinked || state.connectionState == .connecting,
              deviceId == state.connectedDeviceId || deviceId == state.pendingDeviceId
        else {
            runtime.userDisconnectRequested = false
            return
        }
        let wasStreaming = stream.isStreaming
        runtime.cancelLinkTasks()
        link.releaseStandardHeartRate()
        state.readiness.linkLost()
        state.feedStatus = .waitingForStrap
        runtime.signal.fire()
        PolarSDKLogBridge.narrateDisconnect(wasStreaming: wasStreaming, pairingError: loss.needsUserRepair)
        clearLinkReadings(preserveDeviceIdentity: wasStreaming)
        respondToDrop(deviceId: deviceId, loss: loss, wasLinked: wasLinked, wasStreaming: wasStreaming)
    }

    private func respondToDrop(deviceId: String, loss: StrapLinkLoss, wasLinked: Bool, wasStreaming: Bool) {
        guard !consumeDeliberateDrop(deviceId: deviceId, wasStreaming: wasStreaming) else { return }
        switch loss {
        case .deviceCommand:
            // A strap told to restart or power off is not chased, so a
            // session buffering on it is told now, as for a lost pairing,
            // rather than waiting for beats that will not come.
            runtime.reconnectTargetId = nil
            if wasStreaming { stream.reconnectExhausted = true }
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
    ///
    /// A reset during a session arms the reconnect deadline like any other
    /// drop. Without it a strap that goes silent, is reset and never comes
    /// back never runs out of retries, so a streaming-only night is never
    /// paused to save what it had.
    private func consumeDeliberateDrop(deviceId: String, wasStreaming: Bool) -> Bool {
        if runtime.userDisconnectRequested {
            runtime.userDisconnectRequested = false
            runtime.reconnectTargetId = nil
            return true
        }
        guard runtime.linkResetInProgress else { return false }
        runtime.linkResetInProgress = false
        requestReconnect(to: deviceId)
        if wasStreaming { armReconnectDeadline() }
        return true
    }

    /// A lost pairing is not retried, and a session waiting on the strap is
    /// told now rather than after the reconnect window.
    private func pairingLost(reason: String, wasStreaming: Bool) {
        debugLog("[PolarManager] Strap pairing lost (\(reason)) — not reconnecting; the user has to pair again", level: .warning)
        runtime.reconnectTargetId = nil
        state.lastError = PolarManager.PolarError.pairingLost
        if wasStreaming { stream.reconnectExhausted = true }
    }

    /// Everything that describes the live link is stale the moment it drops,
    /// and showing a stale battery or heart rate is worse than showing none.
    private func clearLinkReadings(preserveDeviceIdentity: Bool) {
        state.connectionState = .disconnected
        state.pendingDeviceId = nil
        if !preserveDeviceIdentity {
            state.connectedDeviceId = nil
            state.connectedDeviceType = nil
        }
        state.batteryLevel = nil
        state.isBatteryReadingStale = false
        state.clearHeartRate()
        state.firmwareVersion = nil
        state.hasReceivedSoftwareRevision = false
    }

    /// Re-assert the connect to a strap that dropped unexpectedly. The SDK
    /// treats this as a no-op while it is already reconnecting. A drop can only
    /// have come from an existing SDK handle, so none is created here.
    private func requestReconnect(to deviceId: String) {
        runtime.reconnectTargetId = deviceId
        #if canImport(PolarBleSdk)
            do {
                try link.radio.strapAPI?.connectToDevice(deviceId)
            } catch {
                debugLog("[PolarManager] Reconnect request refused: \(error)")
            }
        #endif
    }

    /// A session gets `PolarReconnectPolicy.windowSeconds` for its strap to
    /// come back before the buffered stream is saved without it.
    private func armReconnectDeadline() {
        guard runtime.reconnectDeadlineTask == nil else { return }
        runtime.reconnectDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(PolarReconnectPolicy.windowSeconds))
            guard !Task.isCancelled, let self else { return }
            self.runtime.reconnectDeadlineTask = nil
            guard self.state.connectionState != .connected, self.stream.isStreaming else { return }
            debugLog("[PolarManager] ❌ Strap not back after \(Int(PolarReconnectPolicy.windowSeconds / 60)) min — ending the wait", level: .warning)
            self.stream.reconnectExhausted = true
        }
    }

    // MARK: - Bluetooth power

    /// CoreBluetooth does not always report each peripheral's drop when the
    /// radio goes off, so the link is treated as lost here. The later real
    /// callback, if any, finds nothing linked and is ignored.
    private func bluetoothPoweredOff() {
        debugLog("[PolarManager] Bluetooth powered off")
        guard state.readiness.isLinked, let deviceId = state.connectedDeviceId else { return }
        linkDropped(deviceId: deviceId, loss: .connectionLost)
    }

    private func bluetoothPoweredOn() {
        guard let deviceId = runtime.reconnectTargetId, state.connectionState != .connected else { return }
        debugLog("[PolarManager] Bluetooth powered on — reconnecting to the strap")
        requestReconnect(to: deviceId)
    }

    // MARK: - Readiness

    private func featureReported(deviceId: String, feature: StrapFeature) {
        guard deviceId == state.connectedDeviceId, state.readiness.isLinked else { return }
        state.readiness.markReady(feature)
        debugLog("[PolarManager] Strap feature ready: \(feature)")
        runtime.signal.fire()
    }

    private func summaryReported(deviceId: String, ready: Set<StrapFeature>, unavailable: Set<StrapFeature>) {
        guard deviceId == state.connectedDeviceId, state.readiness.isLinked else { return }
        state.readiness.applySummary(ready: ready, unavailable: unavailable)
        runtime.settledAt = runtime.settledAt ?? Date()
        let unreported = StrapFeature.allCases.filter { !ready.contains($0) && !unavailable.contains($0) }
        debugLog("[PolarManager] Strap readiness summary — ready: \(ready.map { "\($0)" }.sorted()), unavailable: \(unavailable.map { "\($0)" }.sorted()), not reported: \(unreported.map { "\($0)" })")
        runtime.signal.fire()
    }

    private func scheduleReadinessSettle(generation: Int) {
        runtime.settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.readinessSettleSec))
            guard !Task.isCancelled, let self,
                  self.state.readiness.generation == generation, !self.state.readiness.isSettled
            else { return }
            self.state.readiness.settleWithoutSummary()
            self.runtime.settledAt = Date()
            debugLogExternal("Strap sent no readiness summary \(Int(Self.readinessSettleSec)) s after connecting — its own per-call checks decide from here.", cause: .strap)
            self.runtime.signal.fire()
        }
    }

    // MARK: - Recording status on connect

    /// Whether the strap is already recording, and what it has stored, is
    /// read once per link as soon as its recording feature is usable. It
    /// restores `isRecordingOnDevice` and `hasStoredExercise` after a relaunch,
    /// which is what surfaces a night still sitting on the strap.
    private func startRecordingStatusCheck(generation: Int, deviceId: String, deviceType: PolarDeviceType) {
        let feature: StrapFeature = deviceType == .veritySense ? .offlineRecording : .h10Recording
        runtime.statusCheckTask = Task { [weak self] in
            guard let self else { return }
            await self.readRecordingStatus(feature: feature, generation: generation, deviceId: deviceId)
        }
    }

    private func readRecordingStatus(feature: StrapFeature, generation: Int, deviceId: String) async {
        do {
            try await checkStatusAndStoredExercises(feature: feature, generation: generation, deviceId: deviceId)
        } catch {
            guard !Task.isCancelled, state.readiness.generation == generation else { return }
            debugLogExternal("Couldn't read the strap's recording status after connecting — \(error)", cause: .strap)
        }
    }

    private func checkStatusAndStoredExercises(feature: StrapFeature, generation: Int, deviceId: String) async throws {
        let state = state
        let recording = recording
        _ = try await link.whenFeatureUsable(
            feature, until: Date().addingTimeInterval(Self.statusCheckWindowSec),
            while: { state.readiness.generation == generation },
            perform: { try await recording.checkRecordingStatus(deviceId: deviceId) }
        )
        guard state.readiness.generation == generation else { return }
        await recording.checkForStoredExercises(deviceId: deviceId)
    }

    // MARK: - Feed health

    private func startHealthWatch(generation: Int) {
        runtime.healthTask = Task { [weak self] in
            while await Self.healthCheckDue(), let self, self.state.readiness.generation == generation {
                self.evaluateFeedHealth()
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
        if state.feedStatus != decision.status {
            debugLog("[PolarManager] Heart-rate feed: \(state.feedStatus) → \(decision.status)")
            state.feedStatus = decision.status
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
            isLinked: state.readiness.isLinked,
            linkedAt: runtime.linkedAt,
            settledAt: runtime.settledAt,
            lastSampleAt: runtime.lastSampleAt,
            lastResubscribeAt: runtime.lastResubscribeAt,
            lastLinkResetAt: runtime.lastLinkResetAt,
            sessionActive: stream.isStreaming
        )
    }

    /// Drop and re-establish the link so the strap sets its services up again.
    private func resetLink(now: Date) {
        runtime.lastLinkResetAt = now
        debugLog("[PolarManager] Strap still silent after re-subscribing — resetting the link", level: .warning)
        link.beginLinkReset()
    }
}
