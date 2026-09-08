import Foundation
import Observation

/// Published mirror of the Polar HR sensor's state.
///
/// Split out from `RRCollector` so views that care about BLE connection /
/// battery / device-recording state don't re-render on every archive,
/// streaming, or morning-processing property the collector also publishes.
///
/// Writers: `RRCollector+Bindings.setupBindings()` — the bindings subscribe
/// to `PolarManager` and push the values here.
///
/// Readers: inject via `@Environment(DeviceStatus.self) var deviceStatus`.
/// `RRCollector` keeps thin back-compat getters (e.g. `collector.isDeviceConnected`)
/// for code paths that haven't migrated yet; they read through to this object.
@MainActor
@Observable
final class DeviceStatus {
    var isDeviceConnected: Bool = false
    var isStreaming: Bool = false
    var hasStoredExercise: Bool = false
    var batteryLevel: Int?
    var isRecordingOnDevice: Bool = false
    var connectedDeviceType: PolarDeviceType?
    var recordingState: PolarManager.RecordingState = .idle
    var connectionState: PolarManager.ConnectionState = .disconnected
    var fetchProgress: PolarManager.FetchProgress?
}
