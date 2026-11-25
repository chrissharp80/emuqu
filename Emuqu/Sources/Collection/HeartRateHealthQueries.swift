import Foundation
import HealthKit

/// HealthKit's heart rate: reading night windows and daytime resting HR,
/// computing the stats the morning pipeline needs, and writing HR and resting
/// HR back.
///
/// A value over the parts it uses: queries run through `access`, and
/// exports replace their samples through `sampleReplacer`.
@MainActor
struct HeartRateHealthQueries {
    let access: HealthKitAccess
    let sampleReplacer: HealthSampleReplacer

}
