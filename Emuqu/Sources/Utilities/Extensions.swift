import Foundation
import os

// MARK: - Duration formatting
//
// Durations shown to the user go through `LocalizedDuration`
// (NavigationHeader.swift), which follows the app's language. This English
// "1h 23m" form is only its fallback when the system formatter returns nil.

enum DurationFormatter {
    /// "1h 23m" rounded to whole minutes. For long durations (overnight
    /// sleep, multi-hour rides) where seconds add noise.
    static func hoursMinutes(minutes: Int) -> String {
        let m = max(0, minutes)
        let h = m / 60
        let mm = m % 60
        if h > 0 {
            return mm > 0 ? "\(h)h \(mm)m" : "\(h)h"
        }
        return "\(mm)m"
    }
}

// MARK: - Bundle Extensions

extension Bundle {
    /// App version string (e.g., "1.0.0")
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    /// App build number (e.g., "42")
    var appBuild: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    /// Combined version and build string (e.g., "1.0.0 (42)")
    var appVersionString: String {
        "\(appVersion) (\(appBuild))"
    }
}

// MARK: - Once-only flags and continuations

extension OSAllocatedUnfairLock where State == Bool {
    /// Sets the flag. True only for the caller that found it clear, so of
    /// callers racing for one thing, exactly one goes ahead.
    func setIfClear() -> Bool {
        withLock { isSet -> Bool in
            defer { isSet = true }
            return !isSet
        }
    }
}

/// Resumes `continuation` with the first result it is given and drops the
/// rest, for a continuation a reply and its timeout race to resume. The flag
/// is an `OSAllocatedUnfairLock`, so the closure is `Sendable` with no
/// `nonisolated(unsafe)` escape.
func resumingOnce<T: Sendable>(_ continuation: CheckedContinuation<T, Error>) -> @Sendable (Result<T, Error>) -> Void {
    let resumed = OSAllocatedUnfairLock(initialState: false)
    return { result in
        if resumed.setIfClear() { continuation.resume(with: result) }
    }
}

/// `resumingOnce` for a continuation that cannot fail, resumed with a value
/// or nil.
func resumingOnce<T: Sendable>(_ continuation: CheckedContinuation<T?, Never>) -> @Sendable (T?) -> Void {
    let resumed = OSAllocatedUnfairLock(initialState: false)
    return { value in
        if resumed.setIfClear() { continuation.resume(returning: value) }
    }
}
