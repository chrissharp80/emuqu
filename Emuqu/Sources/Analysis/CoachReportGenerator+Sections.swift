import Foundation

// MARK: - Formatters
//
// The distance and duration strings the Coach Report email's sentences are
// built from. `formatDistance` is also used by the workout recovery service.

extension CoachReportGenerator {
    /// `UnitsPreference.formatDistance(meters:)` (`.auto` resolved against the
    /// locale, number and unit in the app language), or "—" without a
    /// positive distance.
    static func formatDistance(_ meters: Double?, units: UnitsPreference) -> String {
        guard let m = meters, m > 0 else { return "—" }
        return units.formatDistance(meters: m)
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
