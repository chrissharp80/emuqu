import HealthKit

/// Centralised safe accessors for HealthKit type
/// constants. The Apple-provided identifiers (`heartRate`,
/// `heartRateVariabilitySDNN`, `vo2Max`, etc.) almost always resolve
/// on iOS, but `HKQuantityType.quantityType(forIdentifier:)` is
/// declared to return Optional and can return nil on:
///   • feature-gated identifiers a device tier doesn't support
///   • a future iOS deprecation that strips the identifier
///   • mismatched simulator / build SDK / runtime SDK combinations
///
/// A force-unwrap here is a crash waiting on a configuration, and
/// the refactor spec demands explicit error handling at boundaries
/// with no silent fallbacks. This helper gives every call site one
/// uniform pattern: ask for a type, get nil + a warning log if it's
/// not available, and let the caller short-circuit gracefully.
///
/// Naming `HKTypes` (not `HealthKitTypes`) keeps call sites short:
///
///     guard let sdnnType = HKTypes.quantity(.heartRateVariabilitySDNN) else { return }
///
/// All accessors are pure, thread-safe (return value types), and
/// free of side effects beyond a single debug-log line on miss.
enum HKTypes {
    /// Returns the HKQuantityType for `identifier`, or nil with a
    /// warning log. Use `guard let` at every call site and let the
    /// caller decide how to degrade (skip the query, fall back to a
    /// different sensor, etc.).
    static func quantity(
        _ identifier: HKQuantityTypeIdentifier,
        caller: StaticString = #function,
        file: StaticString = #file,
        line: UInt = #line
    ) -> HKQuantityType? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else {
            debugLog(
                "[HKTypes] quantity type '\(identifier.rawValue)' unavailable on this device — caller=\(caller) at \(file):\(line)",
                level: .warning
            )
            return nil
        }
        return type
    }

    /// Returns the HKCategoryType for `identifier`, or nil with a
    /// warning log. Same contract as `quantity(_:)`.
    static func category(
        _ identifier: HKCategoryTypeIdentifier,
        caller: StaticString = #function,
        file: StaticString = #file,
        line: UInt = #line
    ) -> HKCategoryType? {
        guard let type = HKCategoryType.categoryType(forIdentifier: identifier) else {
            debugLog(
                "[HKTypes] category type '\(identifier.rawValue)' unavailable — caller=\(caller) at \(file):\(line)",
                level: .warning
            )
            return nil
        }
        return type
    }
}
