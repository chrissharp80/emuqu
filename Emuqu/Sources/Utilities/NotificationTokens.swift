import Foundation
import os
import UIKit

/// Holds `NotificationCenter` block-observer tokens so a `deinit` can remove
/// them without touching a non-`Sendable` stored property.
///
/// A token from `addObserver(forName:object:queue:using:)` is not removed
/// automatically, so the owner must keep it and remove it on dealloc. Under
/// strict concurrency a nonisolated `deinit` may not read an isolated,
/// non-`Sendable` property — but it may read this, because the lock is
/// `Sendable` and the tokens live inside it.
struct NotificationTokens: Sendable {
    private let tokens = OSAllocatedUnfairLock<[any NSObjectProtocol]>(uncheckedState: [])

    init() {}

    /// Keeps a token until `removeAll(from:)`.
    func add(_ token: any NSObjectProtocol) {
        tokens.withLockUnchecked { $0.append(token) }
    }

    /// Removes every kept token from `center` and forgets them. Safe to call
    /// from `deinit`.
    func removeAll(from center: NotificationCenter = .default) {
        let held = tokens.withLockUnchecked { held -> [any NSObjectProtocol] in
            defer { held.removeAll() }
            return held
        }
        for token in held { center.removeObserver(token) }
    }
}

extension NotificationTokens {
    /// When a file that could not be read while the phone was locked may have
    /// become readable: on unlock, and on becoming active, since a suspended
    /// app can miss the unlock notification.
    static let protectedDataMayBeAvailable = [
        UIApplication.protectedDataDidBecomeAvailableNotification,
        UIApplication.didBecomeActiveNotification
    ]

    /// Runs `handler` on the posting thread after each of
    /// `protectedDataMayBeAvailable` (and any `extra` names), keeping the
    /// tokens until `removeAll(from:)`.
    func observeProtectedDataMayBeAvailable(
        on center: NotificationCenter = .default,
        also extra: [Notification.Name] = [],
        _ handler: @escaping @Sendable () -> Void
    ) {
        for name in Self.protectedDataMayBeAvailable + extra {
            add(center.addObserver(forName: name, object: nil, queue: nil) { _ in handler() })
        }
    }
}
