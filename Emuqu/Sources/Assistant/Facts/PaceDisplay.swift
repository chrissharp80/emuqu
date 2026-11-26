import Foundation

/// Pace in the user's own units next to every pace a read tool returns.
///
/// Facts keep pace as seconds per kilometre. A model asked to say it in
/// miles has to convert, and in a simulated run it read 340 s/km as
/// "5:40 per mile" (the real figure is 9:07 per mile). Each
/// `…pace_sec_per_km…` value gets a sibling `…pace_display` string
/// ("9:07 /mi" or "5:40 /km"), so the model can quote the pace instead of
/// working it out.
enum PaceDisplay {
    /// `value` with display paces added. A bare number from a pace field
    /// (`field` names it) becomes a record holding the number and its display.
    static func annotate(_ value: FactValue, field: String? = nil, units: UnitsPreference = UnitsPreferenceStore.current) -> FactValue {
        switch value {
        case let .record(fields):
            return .record(annotated(fields, units: units))
        case let .list(items):
            return .list(items.map { annotate($0, units: units) })
        case let .double(seconds):
            guard let field, isPaceKey(field), let display = formatted(seconds, units: units) else { return value }
            return .record([field: value, displayKey(for: field): .string(display)])
        default:
            return value
        }
    }

    private static func annotated(_ fields: [String: FactValue], units: UnitsPreference) -> [String: FactValue] {
        var out = fields.mapValues { annotate($0, units: units) }
        for (key, value) in fields where isPaceKey(key) {
            guard case let .double(seconds) = value, let display = formatted(seconds, units: units) else { continue }
            out[displayKey(for: key)] = .string(display)
        }
        return out
    }

    static func isPaceKey(_ key: String) -> Bool {
        key.contains("pace_sec_per_km")
    }

    /// `current_pace_sec_per_km` → `current_pace_display`,
    /// `pace_sec_per_km_at_point` → `pace_display_at_point`.
    static func displayKey(for key: String) -> String {
        key.replacingOccurrences(of: "pace_sec_per_km", with: "pace_display")
    }

    private static func formatted(_ secondsPerKm: Double, units: UnitsPreference) -> String? {
        units.formatPace(secondsPerMeter: secondsPerKm / 1_000)
    }
}
