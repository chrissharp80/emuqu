import Foundation

/// The Polar SDK's own log stream, filtered, and the narration of a
/// disconnect.
///
/// Its own type because `PolarManager` is over the aggregate type-size
/// threshold and neither of these touches the manager: one is a string filter
/// with two sinks, the other is five log lines explaining what a disconnect
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

    nonisolated static func message(_ str: String) {
        guard !suppressed.contains(where: str.contains) else { return }
        if AppDependencies.current.app.runtimeLogger.isEnabled {
            AppDependencies.current.app.runtimeLogger.log("[PolarSDK] \(str)", file: "PolarSDK", line: 0)
        }
        #if DEBUG
            print("[PolarSDK] \(str)")
        #endif
    }

    /// A drop mid-stream is not an error and must not be treated as one: the
    /// streaming error handler owns the reconnect, and stopping here — or
    /// setting `lastError` — would take that decision away from it. What is
    /// left to do is say what happened, and why the device identity is being
    /// kept.
    static func narrateDisconnect(wasStreaming: Bool, pairingError: Bool) {
        guard wasStreaming else {
            debugLog("[PolarManager] Device disconnected (not streaming)")
            return
        }
        debugLog("[PolarManager] 🔌 Device disconnected during streaming")
        debugLog("[PolarManager] ⚠️ Common causes: other apps (SnoreLab, Polar Beat), iOS Bluetooth power management, or signal loss")
        if pairingError {
            debugLog("[PolarManager] Pairing failure reported on disconnect", level: .warning)
        }
        debugLog("[PolarManager] Reconnect logic will attempt to restore streaming")
        debugLog("[PolarManager] Preserving device ID for reconnection")
    }

    /// The two errors the connect-time HR subscription answers with while the
    /// strap is still publishing its services: `notificationNotEnabled` and
    /// `gattDisconnected`. Neither is the app failing — the subscription itself
    /// is what prompts the H10 to enable HR notifications, and the SDK retries
    /// until it does. They log as external, so they carry the cause and stay
    /// out of the user-facing Recent Problems list.
    ///
    /// This is the RIGHT fix for that noise. The wrong one — deferring the
    /// subscription until `feature_hr` reports ready — cost a user a whole
    /// night: the feature became ready 3 times in the build that subscribed
    /// immediately and 0 times in the build that waited, because the wait was
    /// for an event only the subscription causes. See
    /// `check_hr_monitor_subscribes_immediately.sh`.
    nonisolated static func noteHRMonitorError(_ error: Error) {
        let text = "\(error)"
        guard !text.contains("notificationNotEnabled"), !text.contains("gattDisconnected") else {
            debugLogExternal(
                "H10 was not ready for the HR subscription yet (\(text)) — the SDK retries and it comes up",
                cause: .strap
            )
            return
        }
        debugLog("[PolarManager] HR monitoring error: \(text)", level: .warning)
    }

    /// Every other feature the strap announces, named rather than swallowed.
    ///
    /// `feature_polar_h10_exercise_recording` is requested in `PolarSDKFactory`
    /// and drives the PRIMARY overnight source, and across two field logs it
    /// never reported ready once — while `feature_hr` and
    /// `feature_polar_online_streaming` did, repeatedly. Five consecutive
    /// nights ran on BLE streaming alone, and nothing in the log said which
    /// feature was missing, only that "recording never started". Naming what
    /// the SDK DOES offer is what separates "the app asked wrongly" from "this
    /// strap never published the service".
    nonisolated static func noteFeatureReady(_ feature: String) {
        debugLogExternal("strap reported feature ready: \(feature)", cause: .strap)
    }
}
