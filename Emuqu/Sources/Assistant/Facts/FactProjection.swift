import Foundation

/// Keeps only the fields a read tool's caller asked for (`fields`), so a long
/// period of nights or workouts stays small enough to return in one call.
/// Each kept record still carries what identifies it: its date, its session
/// type and its id.
enum FactProjection {
    static let identityFields: Set<String> = ["date", "session_type", "id"]

    /// The comma-separated field names in `raw`; none when it is absent or blank.
    static func fieldNames(from raw: String?) -> [String] {
        (raw ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `value` with each record cut to `fields` plus the identity fields; a
    /// list applies it to every item. No fields asked for leaves it whole,
    /// and a scalar or a missing value passes through.
    static func keep(fields: [String], in value: FactValue) -> FactValue {
        guard !fields.isEmpty else { return value }
        return keep(Set(fields).union(identityFields), in: value)
    }

    private static func keep(_ names: Set<String>, in value: FactValue) -> FactValue {
        switch value {
        case let .record(fields): .record(fields.filter { names.contains($0.key) })
        case let .list(items): .list(items.map { keep(names, in: $0) })
        default: value
        }
    }
}
