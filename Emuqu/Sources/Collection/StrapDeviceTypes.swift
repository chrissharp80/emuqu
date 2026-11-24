import Foundation

/// The two value types a strap is described by: one found in a scan, and one
/// the app has paired with before.
///
/// `PolarManager.DiscoveredDevice` and `PolarManager.KnownDevice` are
/// typealiases for them.
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
