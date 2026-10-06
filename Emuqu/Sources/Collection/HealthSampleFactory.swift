import Foundation
import HealthKit

// MARK: - Health Sample Factory
//
// Every HealthKit sample Emuqu writes is built here.
//
// `HKQuantitySample` and `HKCategorySample` raise an Objective-C
// `NSInvalidArgumentException` when the end date precedes the start date, and
// `HKQuantity` raises one for a NaN or infinite value. Swift cannot catch
// either, so one bad interval in a merged, recovered or decoded series ends
// the app in a release build. The factory returns nil for those inputs
// instead, and callers drop that sample.
//
// A backwards interval is dropped, not swapped: a sample written over the
// swapped span would put a reading at a time it was not measured, and
// Guideline 5.1.3(ii) forbids writing inaccurate data into Health.

enum HealthSampleFactory {
    /// Whether HealthKit accepts a sample over `start...end`: both dates are
    /// real instants and the end is not before the start. An instantaneous
    /// sample (`end == start`) is valid.
    static func isValidInterval(start: Date, end: Date) -> Bool {
        start.timeIntervalSinceReferenceDate.isFinite
            && end.timeIntervalSinceReferenceDate.isFinite
            && end >= start
    }

    /// A quantity sample, or nil when the value is not finite or the interval
    /// runs backwards.
    static func quantitySample(
        type: HKQuantityType,
        value: Double,
        unit: HKUnit,
        start: Date,
        end: Date,
        metadata: [String: Any]? = nil
    ) -> HKQuantitySample? {
        guard value.isFinite, isValidInterval(start: start, end: end) else { return nil }
        return HKQuantitySample(
            type: type, quantity: HKQuantity(unit: unit, doubleValue: value),
            start: start, end: end, metadata: metadata
        )
    }

    /// A category sample, or nil when the interval runs backwards.
    static func categorySample(
        type: HKCategoryType,
        value: Int,
        start: Date,
        end: Date,
        metadata: [String: Any]? = nil
    ) -> HKCategorySample? {
        guard isValidInterval(start: start, end: end) else { return nil }
        return HKCategorySample(type: type, value: value, start: start, end: end, metadata: metadata)
    }
}
