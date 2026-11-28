import Foundation
import os

/// "Now" for the assistant's reads of the user's history: the period a
/// question names ("this week", "last_7d"), the date and time the system
/// prompt states, and the lookups that say how many days ago a reading was.
///
/// It is the device clock. An evaluation that asks about a fixed dataset as
/// of a past moment pins it there (`pin(_:)`), because those reads otherwise
/// measure every period from the real today. The app never pins it, so in
/// the app `now` is always `Date()`.
///
/// A lock, not a task-local value: the fact resolvers run in detached tasks
/// (`FactResolveTimeout`), which do not inherit task-local values.
enum AppClock {
    private static let pinned = OSAllocatedUnfairLock<Date?>(initialState: nil)

    /// The pinned moment, else the device clock.
    static var now: Date {
        pinned.withLock { $0 } ?? Date()
    }

    /// Makes `now` read `date` until the returned scope's `end()`, which
    /// puts back whatever was pinned before.
    static func pin(_ date: Date) -> PinnedScope {
        pinned.withLock { current in
            let scope = PinnedScope(previous: current)
            current = date
            return scope
        }
    }

    /// The span during which a pinned moment is in force.
    struct PinnedScope: Sendable {
        fileprivate let previous: Date?

        /// Restores the moment pinned before this scope began, or the device clock.
        func end() {
            AppClock.pinned.withLock { $0 = previous }
        }
    }
}
