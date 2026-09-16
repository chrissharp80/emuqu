import Foundation
#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

/// Which strap errors mean "not ready yet" rather than "failed".
///
/// The SDK refuses a call that needs a feature whose notifications are not
/// enabled yet, and it does so locally, before any radio traffic:
/// `notificationNotEnabled` from a readiness check, or `gattDisconnected` from
/// a stream opened before the service's transport exists. Both are safe to
/// retry on the same link. Everything else is a real outcome of the call.
enum StrapErrorClassifier {
    static func isNotReadyYet(_ error: Error) -> Bool {
        if case PolarManager.PolarError.featureNotReady = error { return true }
        #if canImport(PolarBleSdk)
            if let polar = error as? PolarErrors {
                switch polar {
                case .notificationNotEnabled: return true
                case let .deviceError(description): return description.contains("notificationNotEnabled")
                default: return false
                }
            }
            if let gatt = error as? BleGattException {
                if case .gattDisconnected = gatt { return true }
                return false
            }
        #endif
        return false
    }
}
