import Foundation
import os

/// Dates formatted from a template in the app's selected language.
///
/// A fixed pattern such as "h:mm a" prints AM/PM in every language, including
/// the many that read a 24-hour clock, and "MMMM yyyy" puts month and year in
/// English order. A template ("jmm", "MMMMyyyy") lets the locale choose the
/// order, the separators and the clock. Formatters are cached per template and
/// language, so a chart that labels every hour does not build one per label.
enum LocalizedDateFormat {
    /// Unchecked because `DateFormatter` is not `Sendable`. Formatting from
    /// several threads is safe (Apple documents `DateFormatter` as
    /// thread-safe since iOS 7), and a cached formatter is never mutated after
    /// it is stored.
    private static let cache = OSAllocatedUnfairLock<[String: DateFormatter]>(uncheckedState: [:])

    static func string(from date: Date, template: String) -> String {
        formatter(template: template).string(from: date)
    }

    static func formatter(template: String) -> DateFormatter {
        let locale = LanguageManager.appLocale
        let key = "\(locale.identifier)|\(template)"
        return cache.withLockUnchecked { cache in
            if let cached = cache[key] { return cached }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate(template)
            cache[key] = formatter
            return formatter
        }
    }
}
