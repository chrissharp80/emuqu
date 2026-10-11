import UIKit

/// One `beginBackgroundTask` assertion, ended exactly once — by the work that
/// asked for it or by iOS's expiration handler, whichever comes first.
///
/// iOS terminates an app whose expiration handler returns without ending the
/// task. Two callers used to log in the handler (or pass none) and end the task
/// only when their work finished, so a stop or a morning pass that outran the
/// background budget was killed mid-write instead of being suspended.
@MainActor
final class BackgroundTaskAssertion {
    /// Held strongly by the expiration handler as well as by this object, so
    /// the handler still ends the task at expiry if an owner drops the
    /// assertion without calling `end()`.
    private let token = BackgroundTaskToken()

    /// `onExpire` runs first, on the main actor, so a caller can wind its work
    /// down (skip an optional wait) before the assertion is released.
    init(name: String, onExpire: @escaping @MainActor () -> Void = {}) {
        let handlerToken = token
        handlerToken.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated {
                debugLog("[BackgroundTask] \(name) expired before its work finished", level: .warning)
                onExpire()
                handlerToken.end()
            }
        }
    }

    /// Idempotent: the second call — expiration then completion, or the
    /// reverse — does nothing.
    func end() {
        token.end()
    }
}

/// The task identifier, shared by the assertion and its expiration handler.
@MainActor
private final class BackgroundTaskToken {
    var identifier: UIBackgroundTaskIdentifier = .invalid

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
