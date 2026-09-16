import Foundation
#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

/// BLE scanning and the connect / disconnect lifecycle.
///
/// Its own type because `PolarManager` is over the aggregate type-size
/// threshold. It holds the manager strongly and is built on demand by it —
/// the shape `check_no_unowned.sh` requires, and the reason it requires it:
/// an `unowned` back-reference read inside a resumed continuation traps when
/// the owner has gone, which took four `RRCollector` tests down with
/// `signal abrt`. This type stores nothing, so it can neither outlive the
/// manager nor retain it, and the search task below crosses `await`
/// boundaries where that distinction is the whole difference.
@MainActor
struct StrapDiscoveryCoordinator {
    let manager: PolarManager

    // MARK: - Scanning

    func startScanning() {
        #if canImport(PolarBleSdk)
            manager.ensureApiReady()
            guard let api = readyToScan() else { return }
            beginSearch(api: api)
        #else
            manager.lastError = PolarManager.PolarError.sdkNotAvailable
        #endif
    }

    #if canImport(PolarBleSdk)
        /// The SDK handle to scan with, or nil with the reason already logged:
        /// a scan started from any state but `.disconnected` fights the one
        /// already running.
        private func readyToScan() -> (any StrapRadio)? {
            guard manager.connectionState == .disconnected else {
                debugLog("[PolarManager] startScanning: already in state \(manager.connectionState)")
                return nil
            }
            guard let api = manager.strapAPI else {
                debugLog("[PolarManager] ERROR: api is nil, cannot scan")
                manager.lastError = PolarManager.PolarError.sdkNotAvailable
                return nil
            }
            return api
        }

        /// The task captures the MANAGER weakly, not this coordinator: a
        /// successful weak load has to prove the manager is alive, because
        /// everything the search does afterwards goes through it. Capturing a
        /// value type that holds the manager strongly would keep it alive
        /// instead, which is the opposite of what a search task should do.
        private func beginSearch(api: any StrapRadio) {
            manager.discoveredDevices = []
            manager.connectionState = .scanning
            debugLog("[PolarManager] Starting scan...")
            manager.searchTask?.cancel()
            manager.searchTask = Task { [weak owner = manager] in
                await owner?.discovery.consumeDeviceSearch(api: api)
            }
            debugLog("[PolarManager] Scan started")
        }
    #endif

    #if canImport(PolarBleSdk)
        /// Uses async/await with the `.values` extension (matches the official
        /// Polar example pattern).
        fileprivate func consumeDeviceSearch(api: any StrapRadio) async {
            do {
                try await forwardDiscoveries(api: api)
            } catch {
                guard !Task.isCancelled else { return }
                debugLog("[PolarManager] Search error: \(error)")
                await MainActor.run { self.failSearch(error) }
            }
        }

        private func forwardDiscoveries(api: any StrapRadio) async throws {
            for try await deviceInfo in api.searchForDevice() {
                guard !Task.isCancelled else { break }
                await noteDiscovered(deviceInfo)
            }
        }

        private func noteDiscovered(_ deviceInfo: PolarDeviceInfo) async {
            debugLog("[PolarManager] Found: \(deviceInfo.name)")
            await MainActor.run { self.handleDiscoveredDevice(deviceInfo) }
        }

        @MainActor
        private func failSearch(_ error: Error) {
            manager.lastError = error
            manager.connectionState = .disconnected
        }
    #endif

    #if canImport(PolarBleSdk)
        private func handleDiscoveredDevice(_ info: PolarDeviceInfo) {
            debugLog("[PolarManager] handleDiscoveredDevice called: \(info.name), connectable: \(info.connectable)")

            // polarFilter(true) already filters to Polar devices only
            // Accept all discovered devices - don't filter by name here
            let device = PolarManager.DiscoveredDevice(
                id: info.deviceId,
                name: info.name,
                rssi: Int(info.rssi),
                deviceType: PolarDeviceType.from(deviceName: info.name)
            )

            // Update or add
            if let index = manager.discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                manager.discoveredDevices[index] = device
                debugLog("[PolarManager] Updated device: \(device.name), total: \(manager.discoveredDevices.count)")
            } else {
                manager.discoveredDevices.append(device)
                debugLog("[PolarManager] Added new device: \(device.name), total: \(manager.discoveredDevices.count)")
            }
        }
    #endif

    func stopScanning() {
        #if canImport(PolarBleSdk)
            debugLog("[PolarManager] stopScanning called")
            manager.searchTask?.cancel()
            manager.searchTask = nil
            if manager.connectionState == .scanning {
                manager.connectionState = .disconnected
            }
        #endif
    }

    // MARK: - Connection

    /// Stale info is cleared immediately so the UI doesn't show the previous
    /// device's data while connecting. `manager.connectedDeviceId` is NOT set here —
    /// that waits for the `deviceConnected` callback, which prevents a brief
    /// state inconsistency where the UI shows connected before it's true.
    func connect(deviceId: String) {
        #if canImport(PolarBleSdk)
            manager.ensureApiReady()
            stopScanning()
            guard manager.connectionState != .connected else { return }
            manager.batteryLevel = nil
            manager.firmwareVersion = nil
            manager.hasReceivedSoftwareRevision = false
            manager.pendingDeviceId = deviceId
            manager.connectionState = .connecting
            do {
                try manager.strapAPI?.connectToDevice(deviceId)
            } catch {
                manager.lastError = error
                manager.pendingDeviceId = nil
                manager.connectionState = .disconnected
            }
        #else
            manager.lastError = PolarManager.PolarError.sdkNotAvailable
        #endif
    }

    func connectToLastDevice() {
        guard let deviceId = manager.lastConnectedDeviceId else { return }
        connect(deviceId: deviceId)
    }

    func disconnect() {
        #if canImport(PolarBleSdk)
            guard let deviceId = manager.connectedDeviceId else { return }
            manager.link.noteUserDisconnect()
            do {
                try manager.strapAPI?.disconnectFromDevice(deviceId)
            } catch {
                manager.lastError = error
            }
            manager.connectedDeviceId = nil
            manager.connectedDeviceType = nil
            manager.pendingDeviceId = nil
            manager.batteryLevel = nil
            manager.firmwareVersion = nil
            manager.hasReceivedSoftwareRevision = false
            manager.connectionState = .disconnected
            // Don't reset recordingState or isRecordingOnDevice - device may continue recording internally
        #endif
    }

    /// Cancel an in-progress connection attempt. Safe to call from any state —
    /// only acts when `.connecting` with a known pending device.
    func cancelConnection() {
        #if canImport(PolarBleSdk)
            guard manager.connectionState == .connecting, let deviceId = manager.pendingDeviceId else { return }
            manager.link.noteUserDisconnect()
            do {
                try manager.strapAPI?.disconnectFromDevice(deviceId)
            } catch {
                debugLog("[PolarManager] cancelConnection error (non-critical): \(error)")
            }
            manager.pendingDeviceId = nil
            manager.connectionState = .disconnected
        #endif
    }

    /// Helper to update fetch progress on main thread
    func updateProgress(_ stage: PolarManager.FetchProgress.Stage, progress: Double, attempt: Int = 1, maxAttempts: Int = 5, message: String = "") async {
        await MainActor.run {
            manager.fetchProgress = PolarManager.FetchProgress(
                stage: stage,
                progress: progress,
                attempt: attempt,
                maxAttempts: maxAttempts,
                statusMessage: message
            )
        }
    }

    /// Cancel an ongoing fetch operation
    func cancelFetch() {
        manager.fetchCancelled = true
        debugLog("[PolarManager] Fetch cancellation requested")
    }
}
