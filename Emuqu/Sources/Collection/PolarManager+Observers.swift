// `@preconcurrency`: CBUUID is an immutable value the SDK has not marked Sendable.
@preconcurrency import CoreBluetooth
import Foundation

#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

// MARK: - PolarBleApiObserver

#if canImport(PolarBleSdk)
    extension PolarManager: PolarBleApiObserver {
        nonisolated func deviceConnecting(_: PolarDeviceInfo) {
            Task { @MainActor in
                self.connectionState = .connecting
            }
        }

        nonisolated func deviceConnected(_ polarDeviceInfo: PolarDeviceInfo) {
            let deviceId = polarDeviceInfo.deviceId
            let deviceType = PolarDeviceType.from(deviceName: polarDeviceInfo.name)
            Task { @MainActor in
                self.adoptConnectedDevice(polarDeviceInfo, deviceId: deviceId, deviceType: deviceType)
                self.startHRMonitoring(deviceId: deviceId)
            }
            // NOTE: Do NOT check recording status or stored exercises here.
            // Those checks require BLE features that aren't ready yet at connection time.
            // They will be triggered by bleSdkFeatureReady() when features become available,
            // which avoids blocking polling loops that freeze the UI.
        }

        /// Per-device battery-usage counters are restored before the strap
        /// gets a chance to push the current % via Battery Service.
        /// If we restored after the callback, the "different value"
        /// check would compare against an empty baseline and reset
        /// the counter on every reconnect, blowing away weeks of
        /// tracked recording time.
        @MainActor
        private func adoptConnectedDevice(
            _ polarDeviceInfo: PolarDeviceInfo,
            deviceId: String,
            deviceType: PolarDeviceType
        ) {
            connectedDeviceId = deviceId
            connectedDeviceType = deviceType
            pendingDeviceId = nil
            connectionState = .connected
            lastConnectedTime = Date()
            saveLastConnectedTime()
            addKnownDevice(id: deviceId, name: polarDeviceInfo.name, deviceType: deviceType)
            loadBatteryUsageStateIfNeeded(for: deviceId)
            debugLog("[PolarManager] Connected to \(deviceType.displayName)")
        }

        nonisolated func deviceDisconnected(_: PolarDeviceInfo, pairingError: Bool) {
            Task { @MainActor in
                self.handleDisconnect(pairingError: pairingError)
            }
        }

        /// What a disconnect does, separated from the SDK callback that delivers
        /// it so a test can drive it (a bug here loses a whole night's
        /// recording, so it must not go untested).
        @MainActor
        func handleDisconnect(pairingError: Bool) {
            let wasStreaming = isStreaming
            logDisconnect(wasStreaming: wasStreaming, pairingError: pairingError)
            // Stop HR monitoring
            hrMonitorTask?.cancel()
            hrMonitorTask = nil
            clearConnectionState(preserveDeviceIdentity: wasStreaming)
        }

        /// Only a real pairing failure is surfaced — this fired as
        /// "Pairing error: false" on every streaming disconnect (pure noise).
        @MainActor
        private func logDisconnect(wasStreaming: Bool, pairingError: Bool) {
            PolarSDKLogBridge.narrateDisconnect(wasStreaming: wasStreaming, pairingError: pairingError)
        }

        /// CRITICAL: don't clear connectedDeviceId/Type while streaming — the
        /// reconnect logic needs them. `isRecordingOnDevice` is never reset here
        /// either: the H10 keeps recording internally through a BLE drop.
        @MainActor
        private func clearConnectionState(preserveDeviceIdentity: Bool) {
            connectionState = .disconnected
            if !preserveDeviceIdentity {
                connectedDeviceId = nil
                connectedDeviceType = nil
            }
            batteryLevel = nil
            isH10RecordingFeatureReady = false
            isHrStreamingReady = false
            isOfflineRecordingReady = false
            currentHeartRate = nil
            connectionHealthWarning = false
            firmwareVersion = nil
            hasReceivedSoftwareRevision = false
        }

        // MARK: - Live HR Monitoring

        /// Start HR monitoring for live display (separate from RR streaming).
        ///
        /// Subscribes IMMEDIATELY, and must keep doing so: asking the H10 for
        /// its HR stream is what prompts it to enable HR notifications, so
        /// waiting for `feature_hr` before subscribing waits for something only
        /// the subscribe can cause. Deferring it cost a user a whole night —
        /// see `check_hr_monitor_subscribes_immediately.sh`. The early error is
        /// noise; the subscription is not.
        func startHRMonitoring(deviceId: String) {
            guard let api else { return }
            hrMonitorTask?.cancel()
            // A task iterating the SDK's `AsyncThrowingStream` (Polar 8.2.0):
            // a stream that ends normally falls through, one that fails
            // throws, and cancellation exits without running either.
            hrMonitorTask = Task { [weak self] in
                await Self.runHRMonitor(api: api, deviceId: deviceId, manager: self)
            }
            debugLog("[PolarManager] Started live HR monitoring")
        }

        /// Drain the HR stream until it ends, fails, or the task is cancelled.
        ///
        /// Separate from `startHRMonitoring` so neither nests past the spec's
        /// depth limit. A stream that ends normally falls through, one that
        /// fails throws, and cancellation exits without running either.
        private static func runHRMonitor(api: PolarBleApi, deviceId: String, manager: PolarManager?) async {
            do {
                try await consumeHR(api: api, deviceId: deviceId, manager: manager)
                debugLog("[PolarManager] HR monitoring completed")
            } catch {
                guard !Task.isCancelled else { return }
                logHRMonitorError(error)
            }
            await MainActor.run {
                // The recording stream owns the reading while streaming.
                if manager?.isStreaming == false { manager?.currentHeartRate = nil }
            }
        }

        /// Forward each HR sample until the stream ends.
        private static func consumeHR(api: PolarBleApi, deviceId: String, manager: PolarManager?) async throws {
            for try await hrData in api.startHrStreaming(deviceId) {
                guard !Task.isCancelled else { return }
                guard let sample = hrData.first else { continue }
                await MainActor.run { manager?.currentHeartRate = Int(sample.hr) }
            }
        }

        /// `notificationNotEnabled` just means the HR feature wasn't
        /// enabled yet; the SDK retries and monitoring comes up, so
        /// it's benign — logging it as an "error" flooded the log
        /// with false failures (19× in one field log). Surface only
        /// genuine monitoring errors.
        nonisolated private static func logHRMonitorError(_ error: Error) { PolarSDKLogBridge.noteHRMonitorError(error) }
    }

    // MARK: - PolarBleApiDeviceInfoObserver

    extension PolarManager: PolarBleApiDeviceInfoObserver {
        nonisolated func batteryLevelReceived(_ identifier: String, batteryLevel: UInt) {
            Task { @MainActor in
                self.applyBatteryLevelUpdate(from: identifier, batteryLevel: batteryLevel)
            }
        }

        nonisolated func batteryChargingStatusReceived(_: String, chargingStatus _: BleBasClient.ChargeState) {
            // Battery charging status received
        }

        nonisolated func disInformationReceived(_ identifier: String, uuid: CBUUID, value: String) {
            Task { @MainActor in
                self.applyFirmwareRevisionUpdate(from: identifier, uuid: uuid, value: value)
            }
        }

        nonisolated func disInformationReceivedWithKeysAsStrings(_ identifier: String, key: String, value: String) {
            Task { @MainActor in
                self.applyFirmwareRevisionUpdate(from: identifier, key: key, value: value)
            }
        }
    }

    // MARK: - PolarBleApiDeviceFeaturesObserver

    extension PolarManager: PolarBleApiDeviceFeaturesObserver {
        /// Only the features we act on are handled; the rest are ignored to keep
        /// the log quiet. The two recording features share
        /// `markRecordingFeatureReady`, differing only in which flag they set
        /// and how their status failure reads.
        nonisolated func bleSdkFeatureReady(_ identifier: String, feature: PolarBleSdkFeature) {
            switch feature {
            case .feature_hr:
                Task { @MainActor in
                    self.isHrStreamingReady = true
                    debugLog("[PolarManager] HR streaming ready")
                }
            case .feature_polar_h10_exercise_recording:
                markRecordingFeatureReady(
                    identifier: identifier, readyLog: "[PolarManager] H10 recording ready, checking for existing data...",
                    statusErrorPrefix: "Couldn't read H10 recording status", markReady: { $0.isH10RecordingFeatureReady = true }
                )
            case .feature_polar_offline_recording:
                markRecordingFeatureReady(
                    identifier: identifier, readyLog: "[PolarManager] Offline recording ready (Verity Sense), checking for existing data...",
                    statusErrorPrefix: "Couldn't read Verity offline recording status", markReady: { $0.isOfflineRecordingReady = true }
                )
            case .feature_polar_online_streaming:
                Task { @MainActor in debugLog("[PolarManager] Online streaming ready") }
            default: PolarSDKLogBridge.noteFeatureReady("\(feature)")
            }
        }

        /// Flip the feature's ready flag, block the start button, then check
        /// immediately for existing data — no polling needed, and these methods
        /// suspend at BLE continuation points rather than blocking.
        nonisolated private func markRecordingFeatureReady(
            identifier: String,
            readyLog: String,
            statusErrorPrefix: String,
            markReady: @escaping @MainActor @Sendable (PolarManager) -> Void
        ) {
            Task { @MainActor in
                markReady(self)
                self.isCheckingRecordingStatus = true // Block start button while checking
                debugLog(readyLog)
            }
            Task { @MainActor in
                do {
                    _ = try await self.checkRecordingStatus(deviceId: identifier)
                } catch {
                    debugLogExternal("\(statusErrorPrefix) — \(error). Will retry.", cause: .strap)
                }
                await self.checkForStoredExercises(deviceId: identifier)
                self.isCheckingRecordingStatus = false
            }
        }
    }

    // MARK: - PolarBleApiPowerStateObserver

    extension PolarManager: PolarBleApiPowerStateObserver {
        nonisolated func blePowerOn() {
            // Bluetooth powered on
            Task { @MainActor in
                // Cancel any pending power-off teardown — if blePowerOn
                // arrives within the debounce window, the prior off was
                // a transient state during a route change, not a real
                // user-toggled Bluetooth disable. See `blePowerOff`.
                self.pendingPowerOffTeardown?.cancel()
                self.pendingPowerOffTeardown = nil
            }
        }

        /// A user log captured the
        /// failure mode this debounce defends against. AirPods Pro
        /// dropped during a walk (notification on another app
        /// grabbed the audio session), which triggered an iOS audio-
        /// route change. iOS briefly toggles the BLE radio during
        /// some route transitions; the Polar SDK faithfully reports
        /// the resulting transient `.poweredOff` even though the
        /// user didn't disable Bluetooth. Tearing down
        /// streaming state immediately means that when the reconnect
        /// attempt (already scheduled by the disconnect observer)
        /// fires 2 s later, it finds streaming stopped and
        /// bails. User-visible symptom: HR monitor "died" mid-
        /// workout for no reason.
        ///
        /// Fix: schedule the teardown 1.5 s out. If `blePowerOn`
        /// arrives within that window, cancel — radio was just
        /// power-cycled by iOS, not by the user. If the window
        /// expires without a power-on, the radio is genuinely off
        /// and we tear down as before.
        nonisolated func blePowerOff() {
            Task { @MainActor in self.scheduleDebouncedPowerOffTeardown() }
        }

        @MainActor
        private func scheduleDebouncedPowerOffTeardown() {
            pendingPowerOffTeardown?.cancel()
            pendingPowerOffTeardown = Task { @MainActor [weak self] in
                await sleepQuietly(1_500_000_000, context: "scheduleDebouncedPowerOffTeardown")
                guard !Task.isCancelled, let self else { return }
                self.pendingPowerOffTeardown = nil
                self.tearDownForConfirmedPowerOff()
            }
        }

        /// If we were streaming, stop cleanly so `isStreaming` doesn't stay true
        /// while the BLE radio is off and no data can flow. `reconnectExhausted`
        /// is signalled so RRCollector rescues the buffered data instead of
        /// leaving it in limbo.
        @MainActor
        private func tearDownForConfirmedPowerOff() {
            debugLog("[PolarManager] BLE powered off — cleaning up connection and streaming state (debounced confirmation, 1.5s elapsed without power-on)")
            let wasStreaming = isStreaming
            connectionState = .disconnected
            connectedDeviceId = nil
            connectedDeviceType = nil
            batteryLevel = nil
            firmwareVersion = nil
            hasReceivedSoftwareRevision = false
            guard wasStreaming else { return }
            debugLog("[PolarManager] BLE power-off during active streaming — stopping stream and signaling exhaustion")
            isRecordingOnDevice = false
            stopStreamingInternal()
            reconnectExhausted = true
        }
    }

    // MARK: - PolarBleApiLogger

    extension PolarManager: PolarBleApiLogger {
        /// The filter and the sinks live on `PolarSDKLogBridge`; only the
        /// conformance has to be here.
        nonisolated func message(_ str: String) { PolarSDKLogBridge.message(str) }
    }

    // MARK: - Test Hooks

    #if DEBUG && canImport(PolarBleSdk)
        extension PolarManager {
            /// One streamed HR sample as the Polar SDK delivers it, for tests.
            ///
            /// Mirrors the SDK's own per-sample fields so a test can drive
            /// `handleStreamedHRDataForTesting` with exactly the shape production
            /// receives. A named struct rather than a seven-member tuple: the type
            /// is `#if DEBUG` and reachable only from the test target, so naming
            /// the fields costs nothing and stops the members being addressed
            /// positionally.
            struct MockHRSample {
                let hr: UInt8
                let ppgQuality: UInt8
                let correctedHr: UInt8
                let rrsMs: [Int]
                let rrAvailable: Bool
                let contactStatus: Bool
                let contactStatusSupported: Bool
            }

            /// Exposes cumulative streamed time for unit tests without widening production API.
            var streamingCumulativeMsForTesting: Int64 {
                streamingCumulativeMs
            }

            /// Sets connection identity in tests so callback filtering logic can be exercised deterministically.
            func setConnectedDeviceForTesting(id: String?, type: PolarDeviceType? = nil) {
                connectedDeviceId = id
                connectedDeviceType = type
                connectionState = (id == nil) ? .disconnected : .connected
            }

            func applyBatteryLevelUpdateForTesting(identifier: String, batteryLevel: UInt) {
                applyBatteryLevelUpdate(from: identifier, batteryLevel: batteryLevel)
            }

            func applyFirmwareRevisionUpdateForTesting(identifier: String, uuid: CBUUID, value: String) {
                applyFirmwareRevisionUpdate(from: identifier, uuid: uuid, value: value)
            }

            func applyFirmwareRevisionUpdateForTesting(identifier: String, key: String, value: String) {
                applyFirmwareRevisionUpdate(from: identifier, key: key, value: value)
            }

            /// Initializes streaming internals for deterministic tests.
            func prepareStreamingStateForTesting(
                startTime: Date = Date(),
                cumulativeMs: Int64 = 0,
                existingPoints: [RRPoint] = []
            ) {
                streamingStartTime = startTime
                streamingCumulativeMs = cumulativeMs
                _streamedRRPoints = existingPoints
                streamedRRCount = _streamedRRPoints.count
                recentRRPoints = Array(_streamedRRPoints.suffix(Self.recentRRWindowSize))
                lastUIUpdateBeatCount = _streamedRRPoints.count
            }

            /// Test-only HR batch ingestion using the same timestamp accumulation model as production.
            func handleStreamedHRDataForTesting(
                _ hrData: [MockHRSample],
                fixedWallClockMs: Int64? = nil
            ) {
                let wallClockNow = fixedWallClockMs ?? streamingStartTime.map {
                    Int64(Date().timeIntervalSince($0) * 1000.0)
                } ?? 0
                for sample in hrData where sample.rrAvailable {
                    appendTestBeats(sample.rrsMs, wallClockMs: wallClockNow)
                }
                streamedRRCount = _streamedRRPoints.count
                if _streamedRRPoints.count - lastUIUpdateBeatCount >= Self.uiUpdateBeatInterval {
                    recentRRPoints = Array(_streamedRRPoints.suffix(Self.recentRRWindowSize))
                    lastUIUpdateBeatCount = _streamedRRPoints.count
                }
            }

            private func appendTestBeats(_ rrsMs: [Int], wallClockMs: Int64) {
                for rrInterval in rrsMs {
                    guard _streamedRRPoints.count < Self.maxStreamingBufferSize else { continue }
                    _streamedRRPoints.append(RRPoint(
                        t_ms: streamingCumulativeMs, rr_ms: rrInterval, wallClockMs: wallClockMs
                    ))
                    streamingCumulativeMs += Int64(rrInterval)
                }
            }
        }
    #endif

#endif
