import Foundation

/// Device facts for logs and provenance, readable from any isolation domain.
///
/// `UIDevice.current` is main-actor isolated, and the places that want a
/// model name or an OS version — crash logs, debug exports, session
/// provenance, the keyboard-latency signpost — run wherever they run. These
/// come from `ProcessInfo` and `uname`, which have no isolation and answer
/// the same questions.
enum DeviceInfo {
    /// The marketing family, e.g. "iPhone" or "iPad" — what `UIDevice.model` reports.
    static var model: String {
        let id = machineIdentifier
        if id.hasPrefix("iPad") { return "iPad" }
        if id.hasPrefix("iPhone") { return "iPhone" }
        if id.hasPrefix("iPod") { return "iPod touch" }
        return id
    }

    /// The hardware identifier, e.g. "iPhone16,1".
    static var machineIdentifier: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(bytes: raw.prefix { $0 != 0 }, encoding: .utf8) ?? "unknown"
        }
    }

    /// "iOS" on the phone; kept as a constant because that is the only
    /// platform this app ships on and `UIDevice.systemName` said the same.
    static let systemName = "iOS"

    /// "17.5"-style version string, matching `UIDevice.systemVersion`.
    static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
