import Foundation
import HealthKit
import UIKit

extension DeviceProvenance {
    /// Provenance for a session streamed live from the connected Polar strap —
    /// the overnight start and the pause/resume restart stamp the same thing.
    @MainActor
    static func streaming(from link: StrapLinkState) -> DeviceProvenance {
        DeviceProvenance.current(
            deviceId: link.connectedDeviceId ?? "unknown",
            deviceModel: link.connectedDeviceType?.displayName ?? "Polar device",
            firmwareVersion: nil,
            recordingMode: .streaming
        )
    }
}
