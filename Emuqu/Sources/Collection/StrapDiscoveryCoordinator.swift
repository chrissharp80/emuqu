import Foundation
#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

/// What a BLE scan has found, and the scan running now.
@Observable
@MainActor
final class StrapDiscoveryState {
    var discoveredDevices: [PolarManager.DiscoveredDevice] = []
    #if canImport(PolarBleSdk)
        @ObservationIgnored var searchTask: Task<Void, Never>?
    #endif
}

/// BLE scanning and the connect / disconnect lifecycle.
///
/// A value built on demand by the manager. It holds the link, what the scan
/// found, the pairings, and `prepareRadio`, which creates the SDK handle on
/// first use; it stores nothing of its own.
@MainActor
struct StrapDiscoveryCoordinator {
    let link: StrapLinkControl
    let found: StrapDiscoveryState
    let pairings: StrapPairings
    /// Creates the SDK handle and starts event delivery, once. The manager's,
    /// because the manager is what the SDK reports to.
    let prepareRadio: @MainActor @Sendable () -> Void

    private var state: StrapLinkState { link.state }

    // MARK: - Scanning

    func startScanning() {
        #if canImport(PolarBleSdk)
            prepareRadio()
            guard let api = readyToScan() else { return }
            beginSearch(api: api)
        #else
            state.lastError = PolarManager.PolarError.sdkNotAvailable
        #endif
    }

    #if canImport(PolarBleSdk)
        /// The SDK handle to scan with, or nil with the reason already logged:
        /// a scan started from any state but `.disconnected` fights the one
        /// already running.
        private func readyToScan() -> (any StrapRadio)? {
            guard state.connectionState == .disconnected else {
                debugLog("[PolarManager] startScanning: already in state \(state.connectionState)")
                return nil
            }
            guard let api = link.radio.strapAPI else {
                debugLog("[PolarManager] ERROR: api is nil, cannot scan")
                state.lastError = PolarManager.PolarError.sdkNotAvailable
                return nil
            }
            return api
        }

        /// The task captures the link state and the results weakly: a task
        /// that starts after they are gone does nothing. Once the weak loads
        /// succeed, the search holds them for as long as it runs; it ends when
        /// the SDK stream ends or fails, or when `stopScanning` (also called by
        /// `connect`) cancels the task.
        private func beginSearch(api: any StrapRadio) {
            found.discoveredDevices = []
            state.connectionState = .scanning
            debugLog("[PolarManager] Starting scan...")
            found.searchTask?.cancel()
            found.searchTask = Task { [weak state, weak found] in
                guard let state, let found else { return }
                await StrapDeviceSearch(state: state, found: found).consume(api: api)
            }
            debugLog("[PolarManager] Scan started")
        }
    #endif

    func stopScanning() {
        #if canImport(PolarBleSdk)
            debugLog("[PolarManager] stopScanning called")
            found.searchTask?.cancel()
            found.searchTask = nil
            if state.connectionState == .scanning {
                state.connectionState = .disconnected
            }
        #endif
    }

    // MARK: - Connection

    /// Stale info is cleared immediately so the UI doesn't show the previous
    /// device's data while connecting. `connectedDeviceId` is NOT set here —
    /// that waits for the `deviceConnected` callback, which prevents a brief
    /// state inconsistency where the UI shows connected before it's true.
    func connect(deviceId: String) {
        #if canImport(PolarBleSdk)
            prepareRadio()
            stopScanning()
            guard state.connectionState != .connected else { return }
            state.batteryLevel = nil
            state.firmwareVersion = nil
            state.hasReceivedSoftwareRevision = false
            state.pendingDeviceId = deviceId
            state.connectionState = .connecting
            do {
                try link.radio.strapAPI?.connectToDevice(deviceId)
            } catch {
                state.lastError = error
                state.pendingDeviceId = nil
                state.connectionState = .disconnected
            }
        #else
            state.lastError = PolarManager.PolarError.sdkNotAvailable
        #endif
    }

    func connectToLastDevice() {
        guard let deviceId = pairings.lastConnectedDeviceId else { return }
        connect(deviceId: deviceId)
    }

    func disconnect() {
        #if canImport(PolarBleSdk)
            guard let deviceId = state.connectedDeviceId else { return }
            link.noteUserDisconnect()
            do {
                try link.radio.strapAPI?.disconnectFromDevice(deviceId)
            } catch {
                state.lastError = error
            }
            state.connectedDeviceId = nil
            state.connectedDeviceType = nil
            state.pendingDeviceId = nil
            state.batteryLevel = nil
            state.firmwareVersion = nil
            state.hasReceivedSoftwareRevision = false
            state.connectionState = .disconnected
            // Don't reset recordingState or isRecordingOnDevice - device may continue recording internally
        #endif
    }

    /// Cancel an in-progress connection attempt. Safe to call from any state —
    /// only acts when `.connecting` with a known pending device.
    func cancelConnection() {
        #if canImport(PolarBleSdk)
            guard state.connectionState == .connecting, let deviceId = state.pendingDeviceId else { return }
            link.noteUserDisconnect()
            do {
                try link.radio.strapAPI?.disconnectFromDevice(deviceId)
            } catch {
                debugLog("[PolarManager] cancelConnection error (non-critical): \(error)")
            }
            state.pendingDeviceId = nil
            state.connectionState = .disconnected
        #endif
    }
}

#if canImport(PolarBleSdk)
    /// One scan's stream of discoveries, applied to the link state and the
    /// results.
    @MainActor
    private struct StrapDeviceSearch {
        let state: StrapLinkState
        let found: StrapDiscoveryState

        /// Uses async/await with the `.values` extension (matches the official
        /// Polar example pattern).
        ///
        /// A stream that ends without an error leaves `.scanning` too
        /// (`endSearch`), so the next scan is not refused as already running.
        func consume(api: any StrapRadio) async {
            do {
                try await forwardDiscoveries(api: api)
                guard !Task.isCancelled else { return }
                debugLog("[PolarManager] Search ended")
                await MainActor.run { self.endSearch() }
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

        private func failSearch(_ error: Error) {
            state.lastError = error
            state.connectionState = .disconnected
        }

        /// Only from `.scanning`: a connect begun from the results owns the
        /// state by then.
        private func endSearch() {
            guard state.connectionState == .scanning else { return }
            state.connectionState = .disconnected
        }

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
            if let index = found.discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                found.discoveredDevices[index] = device
                debugLog("[PolarManager] Updated device: \(device.name), total: \(found.discoveredDevices.count)")
            } else {
                found.discoveredDevices.append(device)
                debugLog("[PolarManager] Added new device: \(device.name), total: \(found.discoveredDevices.count)")
            }
        }
    }
#endif
