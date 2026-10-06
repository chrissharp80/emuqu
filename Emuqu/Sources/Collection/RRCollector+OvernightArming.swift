import Foundation

// Arming the H10's own recording for a night, and winding the arming down
// when the night ends. Split out of `RRCollector+OvernightStreaming.swift`.

extension OvernightStreamingCoordinator {
    /// Arm the H10's internal recording for the night.
    ///
    /// The H10 enumerates its recording feature lazily and unpredictably — a
    /// minute after connecting in one field log, nearly four in another — and
    /// every fixed ceiling tried has turned out too short. So there is no
    /// ceiling: the arming waits on the strap's readiness for as long as the
    /// night lasts, across drops and reconnects, and arms the moment the SDK
    /// accepts the start. Starting a few minutes late costs nothing; streaming
    /// covers the opening minutes and the file still protects the rest of the
    /// night. It is off the critical path and ends the instant the night does
    /// (`endDeviceRecordingArming`).
    func launchDeviceRecordingLoop() {
        collector.isOvernightEnding = false
        collector.overnightArmingTask?.cancel()
        collector.overnightArmingTask = Task { [weak collector] in
            guard let collector else { return }
            let started = await collector.overnightStreaming.awaitDeviceRecordingStart()
            guard !started, !collector.isOvernightEnding else { return }
            // PRIMARY, not backup: `docs/ARCHITECTURE.md` puts H10 internal
            // recording first ("more stable, survives disconnects") and BLE
            // streaming second. A night that ran streaming-only ran on the
            // fallback, with no protection against a disconnect.
            debugLog("[RRCollector] ❌ H10 internal recording — the PRIMARY source — never armed before the night ended. This night ran on BLE streaming alone, with no protection against a disconnect.", level: .error)
        }
    }

    /// The night is ending (the morning stop or a pause). Marked before the
    /// stop sequence touches the stream or the link, so the link change it
    /// causes cannot wake the arming loop into clearing and starting the
    /// strap during the morning download — a field log showed exactly that.
    /// The loop is cancelled and waited for (bounded) before the caller goes
    /// on to stop and download the strap.
    func endDeviceRecordingArming() async {
        collector.isOvernightEnding = true
        guard let task = collector.overnightArmingTask else { return }
        collector.overnightArmingTask = nil
        task.cancel()
        do {
            try await StrapDeadline.race(
                seconds: Self.armingWindDownSeconds,
                timeout: PolarManager.PolarError.fetchFailed("arming did not wind down")
            ) { await task.value }
        } catch {
            debugLog("[RRCollector] Arming did not wind down within \(Self.armingWindDownSeconds) s: \(error)")
        }
    }

    /// Long enough for a strap call already in flight to answer.
    private static let armingWindDownSeconds: UInt64 = 15

    /// Whether this night still wants the strap armed.
    private var nightWantsArming: Bool {
        collector.isOvernightStreaming && !collector.isOvernightEnding && !Task.isCancelled
    }

    /// A refusal for a low battery, and the level the strap reported then.
    private struct BatteryRefusal {
        let level: Int?
    }

    /// Arms once. A refusal that can clear up is tried again on the strap's
    /// next change (a reconnect, a readiness report) or after
    /// `armingRetryInterval` on a link that does not change. A low-battery
    /// refusal is not tried again until the strap reports more charge than
    /// it had when it refused.
    private func awaitDeviceRecordingStart() async -> Bool {
        var batteryRefusal: BatteryRefusal?
        while nightWantsArming {
            if let refusal = batteryRefusal, !StrapRecordingPolicy.mayRetryArming(
                afterBatteryRefusalAt: refusal.level, batteryNow: collector.polarManager.batteryLevel
            ) {
                await waitBeforeRetrying()
                continue
            }
            do {
                try await armWhenStrapIsReady()
                return true
            } catch {
                batteryRefusal = noteArmingRefusal(error)
                await waitBeforeRetrying()
            }
        }
        return false
    }

    /// Wait for the next change on the strap link, or the retry interval,
    /// before trying again — unless the night is ending.
    private func waitBeforeRetrying() async {
        guard nightWantsArming else { return }
        _ = await collector.polarManager.linkRuntime.signal.wait(timeout: collector.armingRetryInterval)
    }

    /// Tell the user at once about a refusal only they can fix; log the rest.
    private func noteArmingRefusal(_ error: Error) -> BatteryRefusal? {
        let refusal = StrapRecordingPolicy.startRefusal(for: error)
        switch refusal {
        case .retryable:
            debugLog("[RRCollector] H10 internal recording not armed yet: \(error) — trying again on the strap's next change")
            return nil
        case .undownloadedRecordingOnStrap:
            surfaceArmingRefusal(error, refusal)
            return nil
        case .batteryTooLow:
            surfaceArmingRefusal(error, refusal)
            return BatteryRefusal(level: collector.polarManager.batteryLevel)
        }
    }

    /// Once per kind, so a retry every few minutes does not repeat the alert.
    private func surfaceArmingRefusal(_ error: Error, _ refusal: StrapRecordingPolicy.StartRefusal) {
        debugLogExternal("The strap refused to record to its own memory — \(error). This night records from the live stream.", cause: .strap)
        if let shown = collector.lastError, StrapRecordingPolicy.startRefusal(for: shown) == refusal { return }
        collector.lastError = error
    }

    private func armWhenStrapIsReady() async throws {
        try await collector.polarManager.link.whenFeatureUsable(
            .h10Recording, until: nil, while: { nightWantsArming },
            perform: attemptDeviceRecordingStart
        )
    }

    /// One attempt at arming the H10's internal recording. Any stale recording is
    /// stopped first so the fresh one holds THIS night only (else `startRecording`
    /// throws `alreadyRecording`), and rescued rather than dropped.
    private func attemptDeviceRecordingStart() async throws {
        try await collector.polarManager.recording.startFreshRecording(while: { nightWantsArming })
        let deviceName = collector.polarManager.connectedDeviceType?.displayName ?? "device"
        debugLog("[RRCollector] ✅ \(deviceName) internal recording started")
        // The strap is now capturing the full night to its own
        // flash memory — mark it so a mid-night BLE loss can't
        // trigger the destructive pause-and-fetch (see
        // RRCollector+Bindings reconnectExhausted handler).
        collector.overnightDeviceBackupActive = true
        if let shown = collector.lastError, StrapRecordingPolicy.startRefusal(for: shown) != .retryable {
            collector.lastError = nil
        }
    }

    /// Before a night that arms the H10's own recording: a strap whose last
    /// reported battery is low may refuse it. The night still starts; the
    /// Record screen shows the same warning before Start.
    func warnIfStrapBatteryMayRefuse() {
        let manager = collector.polarManager
        guard collector.useDeviceBackupForOvernight, StrapRecordingPolicy.strapMayRefuseToRecord(
            batteryLevel: manager.batteryLevel, deviceType: manager.connectedDeviceType
        ) else { return }
        debugLogExternal("Strap battery at \(manager.batteryLevel ?? 0)% — the H10 may refuse to record to its own memory tonight; the night still records from the live stream.", cause: .strap)
    }
}
