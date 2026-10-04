import Foundation

// MARK: - Formatters
//
// The distance and duration strings the Coach Report email's sentences are
// built from. `formatDistance` is also used by the workout recovery service.

extension CoachReportGenerator {
    static func formatDistance(_ meters: Double?, units: UnitsPreference) -> String {
        guard let m = meters, m > 0 else { return "—" }
        if units == .imperial {
            return String(format: "%.2f mi", locale: LanguageManager.appLocale, m / 1609.344)
        }
        return String(format: "%.2f km", locale: LanguageManager.appLocale, m / 1_000)
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
