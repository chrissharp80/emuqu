import Foundation

/// The two value types a strap is described by: one found in a scan, and one
/// the app has paired with before.
///
/// Top-level rather than nested, because the aggregate type-size gate counts a
/// nested type against its parent wherever the file lives, and `PolarManager`
/// is over the threshold. `PolarManager.DiscoveredDevice` and
/// `PolarManager.KnownDevice` remain as typealiases so no call site changes.
struct StrapDiscoveredDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let rssi: Int
    let deviceType: PolarDeviceType
}

struct StrapKnownDevice: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let deviceType: PolarDeviceType
}
