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

    /// For a failure to START a recording: nothing has been recorded yet, so
    /// a lost connection must not promise that "your recording is still on
    /// the device" as the transfer-path messages do.
    static func humanizeStartFailure(_ error: Error) -> String {
        #if canImport(PolarBleSdk)
            if let polar = error as? PolarErrors {
                switch polar {
                case .deviceNotFound, .deviceNotConnected:
                    return String(localized: "Lost connection to your strap before recording started. Move closer (within 2 m), make sure it's worn, then try again.", bundle: LanguageManager.appBundle)
                default:
                    break
                }
            }
        #endif
        return humanize(error)
    }

    #if canImport(PolarBleSdk)
        /// Connection- and transfer-level failures the user can act on by
        /// moving closer, re-wetting the pad, or retrying.
        private static func humanizePolar(_ error: PolarErrors) -> String {
            switch error {
            case .deviceNotFound:
                return String(localized: "Lost connection to your strap mid-transfer. Move closer to the strap (within 2 m), make sure it's worn (wet sensor pad), then tap Retry. Your recording is still on the device.", bundle: LanguageManager.appBundle)
            case .deviceNotConnected:
                return String(localized: "Strap is no longer connected. Reconnect from the Record screen and try again — your recording is still on the device.", bundle: LanguageManager.appBundle)
            case .timeout:
                return String(localized: "The strap stopped responding mid-transfer. Polar's protocol can stall under BLE pressure. Tap Retry — your data is still on the strap.", bundle: LanguageManager.appBundle)
            case .notificationNotEnabled, .serviceNotFound:
                return String(localized: "Strap reconnected but BLE handshake isn't ready yet. Wait 5–10 seconds and try again.", bundle: LanguageManager.appBundle)
            case .operationNotSupported:
                return String(localized: "This strap doesn't support this operation. Update the strap firmware in Polar Beat / Polar Flow if available.", bundle: LanguageManager.appBundle)
            case .unableToStartStreaming:
                return String(localized: "Strap refused to start streaming. Disconnect from the Record screen, reconnect, then try again.", bundle: LanguageManager.appBundle)
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
                return String(localized: "Polar's protocol hit an internal error. Try again. If it keeps failing, force-quit the app and the strap (remove from the chest pad for 30 s) and reconnect.", bundle: LanguageManager.appBundle)
            case let .deviceError(description):
                return String(localized: "Strap reported an error: \(description). Try again, or remove the strap from the chest pad for 30 s to restart it.", bundle: LanguageManager.appBundle)
            case let .polarOfflineRecordingError(description):
                return String(localized: "Offline recording error from the strap: \(description).", bundle: LanguageManager.appBundle)
            case .invalidArgument:
                return String(localized: "Internal SDK error (invalid argument). Try again; if it persists, send a diagnostic from Settings → Troubleshooting.", bundle: LanguageManager.appBundle)
            case .invalidSensorSettingValue:
                return String(localized: "Internal SDK error (invalid sensor setting). Try again; if it persists, send a diagnostic from Settings → Troubleshooting.", bundle: LanguageManager.appBundle)
            case .dateTimeFormatFailed:
                return String(localized: "Couldn't parse the recording's timestamp. Disconnect / reconnect and try again.", bundle: LanguageManager.appBundle)
            case let .fileError(description):
                return String(localized: "Couldn't read recording data from the strap: \(description). Try again; the data is still on the strap until you start a new recording.", bundle: LanguageManager.appBundle)
            default:
                return String(localized: "The strap reported an error. Try again; your recording is still on the device.", bundle: LanguageManager.appBundle)
            }
        }
    #endif
}
