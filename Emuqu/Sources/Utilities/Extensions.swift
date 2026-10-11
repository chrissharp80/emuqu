import Foundation

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
