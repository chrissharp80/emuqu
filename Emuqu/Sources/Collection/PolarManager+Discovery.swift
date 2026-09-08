import Foundation

// BLE scanning and connect/disconnect live on `StrapDiscoveryCoordinator`;
// `PolarManager` is over the aggregate type-size threshold. These forwarders
// keep every existing call site working.

extension PolarManager {
    /// Built on demand — a value with no state of its own, so it neither
    /// outlives the manager nor retains it.
    var discovery: StrapDiscoveryCoordinator { StrapDiscoveryCoordinator(manager: self) }

    func startScanning() { discovery.startScanning() }
    func stopScanning() { discovery.stopScanning() }
    func connect(deviceId: String) { discovery.connect(deviceId: deviceId) }
    func connectToLastDevice() { discovery.connectToLastDevice() }
    func disconnect() { discovery.disconnect() }
    func cancelConnection() { discovery.cancelConnection() }
    func cancelFetch() { discovery.cancelFetch() }

    func updateProgress(
        _ stage: PolarManager.FetchProgress.Stage, progress: Double,
        attempt: Int = 1, maxAttempts: Int = 5, message: String = ""
    ) async {
        await discovery.updateProgress(
            stage, progress: progress, attempt: attempt, maxAttempts: maxAttempts, message: message
        )
    }
}
