import SwiftUI

/// The device clock unless something sets another.
private struct CurrentDateKey: EnvironmentKey {
    static let defaultValue: @Sendable () -> Date = { Date() }
}

extension EnvironmentValues {
    /// Today, for the views that lay themselves out from it: the dashboard's
    /// recent-days strip and night ages, and the history calendar's month.
    /// The app never sets it, so they read the device clock each time; a
    /// preview or snapshot sets a fixed instant so the picture does not
    /// change with the date.
    var currentDate: @Sendable () -> Date {
        get { self[CurrentDateKey.self] }
        set { self[CurrentDateKey.self] = newValue }
    }
}
