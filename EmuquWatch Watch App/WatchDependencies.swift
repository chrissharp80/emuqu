import Foundation

/// The Watch app's long-lived objects, in one place: the Watch target's
/// composition root, in the same shape as the phone's `AppDependencies`,
/// which the Watch target does not compile.
///
/// - `Type.shared` is read here and nowhere else in the Watch target
///   (`scripts/check_no_shared_outside_root.sh` enforces it).
/// - Every accessor resolves when it is read, so nothing is built until it is
///   asked for.
/// - `WatchApp` reads `WatchDependencies.current` at launch and hands the
///   objects to the view tree; no other Watch file reads the container.
/// - A substitute goes on a fresh container's `overrides`, and that container
///   is assigned to `current` before `WatchApp` is built.
///
/// The target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so the
/// container and `current` are main-actor isolated, as is everything that
/// reads them.
struct WatchDependencies {
    /// Substitutes, if any.
    let overrides = Overrides()

    /// The container in force. The app never sets it.
    static var current = WatchDependencies()

    /// The WatchConnectivity session and the live state the Watch shows.
    var sessionManager: WatchSessionManager {
        overrides.sessionManager ?? WatchSessionManager.shared
    }

    /// The Watch's own Bluetooth link to a heart-rate strap.
    var strapConnector: WatchStrapConnector {
        overrides.strapConnector ?? WatchStrapConnector.shared
    }

    /// Substitutes for the objects above; nil means the process-wide instance.
    final class Overrides {
        var sessionManager: WatchSessionManager?
        var strapConnector: WatchStrapConnector?
    }
}
