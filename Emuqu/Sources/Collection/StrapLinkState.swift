import CoreBluetooth
import Foundation

/// What the app shows and decides from about the strap link: which strap is
/// linked or being connected, its readiness and heart-rate feed, and the
/// readings it reports. One instance per `PolarManager`, which views observe it
/// through; each strap part that reads or writes the link holds it too.
@Observable
@MainActor
final class StrapLinkState {
    var connectionState: PolarManager.ConnectionState = .disconnected
    var connectedDeviceId: String?
    var connectedDeviceType: PolarDeviceType?
    /// Device ID of a connection attempt in progress (set during `.connecting`, cleared on connect/cancel).
    var pendingDeviceId: String?
    var lastError: Error?
    var batteryLevel: Int?

    /// Timestamp of the most recent battery level callback from the device.
    /// Reset on every callback regardless of whether the value actually changed.
    var lastBatteryUpdateTime: Date?

    /// True when the battery reading is judged stale. Computed from
    /// `StrapBatteryUsageTracker.hoursRecordedSinceBatteryChanged` vs the
    /// device's `specRecordingHours`, not from wall-clock elapsed time —
    /// wall-clock punished users who only connect to record (the strap reads
    /// the same %, gets called "stale", even though the user genuinely hasn't
    /// drained it).
    var isBatteryReadingStale: Bool = false

    /// Feature readiness for the current link. Replaced wholesale on every
    /// connect and disconnect; see `StrapReadiness`.
    var readiness = StrapReadiness.initial

    /// Whether heart rate is actually arriving, as opposed to merely connected.
    var feedStatus: StrapFeedHealth.Status = .waitingForStrap

    /// The strap's own heart-rate reading, live whenever a strap is linked —
    /// with or without a recording session.
    var currentHeartRate: Int?

    /// User-visible revision (prefers DIS software revision, falls back to firmware revision).
    var firmwareVersion: String?
    var hasReceivedSoftwareRevision = false

    private static let disFirmwareRevisionUUID = CBUUID(string: "2A26")
    private static let disSoftwareRevisionUUID = CBUUID(string: "2A28")

    /// Accept async device-info callbacks only from the currently connected device.
    /// `StrapBatteryUsageTracker` asks the same question before accepting a
    /// battery callback, so the rule has one copy.
    func isActiveDeviceInfoSource(_ identifier: String) -> Bool {
        guard let connectedId = connectedDeviceId else { return false }
        return connectedId == identifier
    }

    /// Polar's own sample apps treat software revision (2A28) as the user-visible
    /// firmware label. Firmware revision (2A26) is kept only as fallback.
    ///
    /// Polar's SDK fires this callback multiple times per
    /// connect (once per BLE characteristic discovered, sometimes
    /// 6–8x). We log only on actual change to avoid duplicates polluting
    /// the debug log. Same applies to the fallback path.
    func applyFirmwareRevisionUpdate(from identifier: String, uuid: CBUUID, value: String) {
        guard isActiveDeviceInfoSource(identifier) else { return }
        if uuid == Self.disSoftwareRevisionUUID {
            setFirmwareVersion(value, label: "Software revision (displayed as firmware)")
            hasReceivedSoftwareRevision = true
            return
        }
        guard uuid == Self.disFirmwareRevisionUUID, !hasReceivedSoftwareRevision else { return }
        setFirmwareVersion(value, label: "Firmware revision fallback")
    }

    private func setFirmwareVersion(_ value: String, label: String) {
        let isNew = firmwareVersion != value
        firmwareVersion = value
        if isNew {
            debugLog("[PolarManager] \(label): \(value)")
        }
    }

    func applyFirmwareRevisionUpdate(from identifier: String, key: String, value: String) {
        let normalizedKey = key.uppercased()
        guard normalizedKey == Self.disFirmwareRevisionUUID.uuidString ||
            normalizedKey == Self.disSoftwareRevisionUUID.uuidString else { return }
        applyFirmwareRevisionUpdate(from: identifier, uuid: CBUUID(string: normalizedKey), value: value)
    }
}
