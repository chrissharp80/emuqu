import Foundation

/// The Polar SDK's own log stream, filtered, and the narration of a
/// disconnect.
///
/// Its own type because `PolarManager` is over the aggregate type-size
/// threshold and neither of these touches the manager: one is a string filter
/// with two sinks, the other is a few log lines explaining what a disconnect
/// means.
enum PolarSDKLogBridge {
    /// The SDK is extremely chatty. These five patterns are the high-frequency
    /// noise — raw PMD hex fires on every heartbeat packet, and scan discovery
    /// repeats every few seconds per device — and dropping them is what keeps
    /// a real connection or error event visible in the console.
    private static let suppressed = [
        "PMD Data",
        "Factor not stored",
        " HEX ",
        "peripheral with session discovered",
        "Scanning next"
    ]

    /// Into the debug log, always. The strap's own setup — service discovery,
    /// notification enabling, the readiness check — is only visible here, and
    /// a connection that never delivers heart rate cannot be diagnosed without
    /// it. The logger records on the main actor once per burst, so a connect's
    /// few hundred lines cost one hop, not one each.
    nonisolated static func message(_ str: String) {
        guard !suppressed.contains(where: str.contains) else { return }
        debugLog("[PolarSDK] \(str)")
    }

    /// A drop mid-session is not an error: the SDK reconnects on its own and
    /// the session keeps buffering when the strap returns. What is left to do
    /// is say what happened, and why the device identity is being kept.
    static func narrateDisconnect(wasStreaming: Bool, pairingError: Bool) {
        guard wasStreaming else {
            debugLog("[PolarManager] Device disconnected (not streaming)")
            return
        }
        debugLog("[PolarManager] 🔌 Device disconnected during a session — keeping its identity while it reconnects")
        if pairingError {
            debugLog("[PolarManager] Pairing failure reported on disconnect", level: .warning)
        }
    }

    /// A feature the app does not act on, named rather than swallowed, so a
    /// log shows everything the strap offered on a connection.
    nonisolated static func noteFeatureReady(_ feature: String) {
        debugLogExternal("strap reported feature ready: \(feature)", cause: .strap)
    }
}
