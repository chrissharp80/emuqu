import Foundation
#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

// User-friendly translations for `PolarBleSdk.PolarErrors`. The Polar
// SDK's enum doesn't conform to `LocalizedError`, so the system's
// synthesised `localizedDescription` falls back to "The operation
// couldn't be completed. (PolarBleSdk.PolarErrors error 3.)" — opaque
// enough that a user can't even tell whether to retry, restart, or
// give up. (Real tester report: the alert showed `error 3`
// while a 2 m 22 s recording sat un-retrieved on the H10. Error 3 is
// `deviceNotFound` — the strap dropped off Bluetooth mid-transfer;
// the data was still on the strap and the right user action was
// "move closer, try again".)
//
// The mapping below is hand-written from `PolarErrors.swift` in the
// SDK source, with messages tuned to the typical recovery action for
// each case. Anything that isn't a Polar error falls through to the
// platform's `localizedDescription`.

enum PolarErrorMessages {
    /// Convert any Error into a short, action-oriented message. Use
    /// this instead of `error.localizedDescription` whenever a Polar
    /// SDK error might surface to the user (alerts, retry banners,
    /// "fetch failed" copy). Always returns SOMETHING — for non-Polar
    /// errors we fall back to the platform string so other systems
    /// (URLSession, HealthKit, etc.) keep their own messaging.
    static func humanize(_ error: Error) -> String {
        #if canImport(PolarBleSdk)
            if let polar = error as? PolarErrors {
                return humanizePolar(polar)
            }
        #endif
        return error.localizedDescription
    }

    #if canImport(PolarBleSdk)
        /// Connection- and transfer-level failures the user can act on by
        /// moving closer, re-wetting the pad, or retrying.
        private static func humanizePolar(_ error: PolarErrors) -> String {
            switch error {
            case .deviceNotFound:
                return "Lost connection to your strap mid-transfer. Move closer to the strap (within 2 m), make sure it's worn (wet sensor pad), then tap Retry. Your recording is still on the device."
            case .deviceNotConnected:
                return "Strap is no longer connected. Reconnect from the Record screen and try again — your recording is still on the device."
            case .timeout:
                return "The strap stopped responding mid-transfer. Polar's protocol can stall under BLE pressure. Tap Retry — your data is still on the strap."
            case .notificationNotEnabled, .serviceNotFound:
                return "Strap reconnected but BLE handshake isn't ready yet. Wait 5–10 seconds and try again."
            case .operationNotSupported:
                return "This strap doesn't support this operation. Update the strap firmware in Polar Beat / Polar Flow if available."
            case .unableToStartStreaming:
                return "Strap refused to start streaming. Disconnect from the Record screen, reconnect, then try again."
            default:
                return humanizePolarProtocol(error)
            }
        }

        /// Protocol- and data-level failures. These are rarer and usually mean
        /// the SDK or the strap's own state machine is unhappy rather than the
        /// radio link.
        private static func humanizePolarProtocol(_ error: PolarErrors) -> String {
            switch error {
            case .messageEncodeFailed, .messageDecodeFailed, .polarBleSdkInternalException:
                return "Polar's protocol hit an internal error. Try again. If it keeps failing, force-quit the app and the strap (remove from the chest pad for 30 s) and reconnect."
            case let .deviceError(description):
                return "Strap reported an error: \(description). Try again, or remove the strap from the chest pad for 30 s to restart it."
            case let .polarOfflineRecordingError(description):
                return "Offline recording error from the strap: \(description)."
            case .invalidArgument:
                return "Internal SDK error (invalid argument). Try again; if it persists, share a diagnostic via Settings → Crash Reports."
            case .invalidSensorSettingValue:
                return "Internal SDK error (invalid sensor setting). Try again; if it persists, share a diagnostic via Settings → Crash Reports."
            case .dateTimeFormatFailed:
                return "Couldn't parse the recording's timestamp. Disconnect / reconnect and try again."
            case let .fileError(description):
                return "Couldn't read recording data from the strap: \(description). Try again; the data is still on the strap until you start a new recording."
            default:
                return "The strap reported an error. Try again; your recording is still on the device."
            }
        }
    #endif
}
