import Foundation

// Arming the H10's own recording for a night, and winding the arming down
// when the night ends.

extension OvernightStreamingCoordinator {
    /// Arm the H10's internal recording for the night.
    ///
    /// The H10 enumerates its recording feature lazily and unpredictably,
    /// anywhere from one to nearly four minutes after connecting, so no fixed
    /// ceiling is safe. So there is no
    /// ceiling: the arming waits on the strap's readiness for as long as the
    /// night lasts, across drops and reconnects, and arms the moment the SDK
    /// accepts the start. Starting a few minutes late costs nothing; streaming
    /// covers the opening minutes and the file still protects the rest of the
    /// night. It is off the critical path and ends the instant the night does
    /// (`endDeviceRecordingArming`).
    func launchDeviceRecordingLoop() {
        overnightRun.isEnding = false
        overnightRun.armingTask?.cancel()
        overnightRun.armingTask = Task { [weak self] in
            guard let self else { return }
            let started = await self.awaitDeviceRecordingStart()
            // A loop cancelled by a relaunch hands the night to its successor.
            guard !started, !overnightRun.isEnding, !Task.isCancelled else { return }
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
    /// strap during the morning download.
    /// The loop is cancelled and waited for (bounded) before the caller goes
    /// on to stop and download the strap.
    func endDeviceRecordingArming() async {
        overnightRun.isEnding = true
        guard let task = overnightRun.armingTask else { return }
        overnightRun.armingTask = nil
        task.cancel()
        do {
            try await Deadline.race(
                seconds: TimeInterval(Self.armingWindDownSeconds),
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
        streamingLifecycle.isOvernightStreaming && !overnightRun.isEnding && !Task.isCancelled
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
                afterBatteryRefusalAt: refusal.level, batteryNow: strapLink.batteryLevel
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
        _ = await strapLinkControl.runtime.signal.wait(timeout: overnightRun.armingRetryInterval)
    }

    /// Tell the user at once about a refusal only they can fix; log the rest.
    /// A refusal that lands once the night no longer wants the strap armed
    /// (the ending cancelled the attempt mid-way) is only logged: the ending
    /// deals with the strap, and the user has nothing to fix.
    private func noteArmingRefusal(_ error: Error) -> BatteryRefusal? {
        guard nightWantsArming else {
            debugLog("[RRCollector] H10 internal recording not armed: \(error) — the night no longer wants it")
            return nil
        }
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
            return BatteryRefusal(level: strapLink.batteryLevel)
        }
    }

    /// Once per kind, so a retry every few minutes does not repeat the alert.
    private func surfaceArmingRefusal(_ error: Error, _ refusal: StrapRecordingPolicy.StartRefusal) {
        debugLogExternal("The strap refused to record to its own memory — \(error). This night records from the live stream.", cause: .strap)
        if let shown = sessionState.lastError, StrapRecordingPolicy.startRefusal(for: shown) == refusal { return }
        sessionState.lastError = error
    }

    private func armWhenStrapIsReady() async throws {
        try await strapLinkControl.whenFeatureUsable(
            .h10Recording, until: nil, while: { nightWantsArming },
            perform: attemptDeviceRecordingStart
        )
    }

    /// One attempt at arming the H10's internal recording. Any stale recording is
    /// stopped first so the fresh one holds THIS night only (else `startRecording`
    /// throws `alreadyRecording`), and rescued rather than dropped.
    ///
    /// A start the strap answers only after the night stopped wanting it does
    /// not mark the night strap-backed (`settleLateArmedRecording`).
    private func attemptDeviceRecordingStart() async throws {
        try await strapRecorder.startFreshRecording(while: { nightWantsArming })
        guard nightWantsArming else {
            await settleLateArmedRecording()
            return
        }
        let deviceName = strapLink.connectedDeviceType?.displayName ?? "device"
        debugLog("[RRCollector] ✅ \(deviceName) internal recording started")
        // The strap is now capturing the full night to its own
        // flash memory — mark it so a mid-night BLE loss can't
        // trigger the destructive pause-and-fetch (see
        // RRCollector+Bindings reconnectExhausted handler).
        overnightRun.deviceBackupActive = true
        if let shown = sessionState.lastError, StrapRecordingPolicy.startRefusal(for: shown) != .retryable {
            sessionState.lastError = nil
        }
    }

    /// The strap accepted a start after the night stopped wanting it: an SDK
    /// answer that outlasted the arming's wind-down. The recording began at
    /// the end of the night or after it, so it holds none of the night. With
    /// no night streaming and no transfer using the strap, it is stopped, so
    /// the strap does not record into the day and the recorder does not show
    /// it as a recording. It is not marked downloaded, so the next start's
    /// rescue still keeps whatever it holds. A transfer using the strap, or a
    /// night started since, owns the strap and is left to it.
    private func settleLateArmedRecording() async {
        debugLog("[RRCollector] H10 internal recording started after the night stopped wanting it — not marking the night strap-backed", level: .warning)
        guard !streamingLifecycle.isOvernightStreaming, strapRecording.transfersInFlight == 0 else { return }
        await strapRecorder.stopDeviceRecordingIfNeeded(streamHoldsIt: false)
    }

    /// Before a night that arms the H10's own recording: a strap whose last
    /// reported battery is low may refuse it. The night still starts; the
    /// Record screen shows the same warning before Start.
    func warnIfStrapBatteryMayRefuse() {
        guard overnightRun.usesDeviceBackup, StrapRecordingPolicy.strapMayRefuseToRecord(
            batteryLevel: strapLink.batteryLevel, deviceType: strapLink.connectedDeviceType
        ) else { return }
        debugLogExternal("Strap battery at \(strapLink.batteryLevel ?? 0)% — the H10 may refuse to record to its own memory tonight; the night still records from the live stream.", cause: .strap)
    }
}
