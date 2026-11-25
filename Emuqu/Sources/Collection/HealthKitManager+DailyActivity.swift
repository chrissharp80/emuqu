import Foundation
import HealthKit

// `DailyActivity` is nested on the manager, the type every caller names it
// through (`HealthKitManager.DailyActivity`);
// `VitalsHealthQueries.fetchDailyActivity` returns it.
extension HealthKitManager {
    struct DailyActivity: Identifiable, Equatable, Sendable {
        let date: Date
        let stepCount: Int
        let distanceMeters: Double
        let flightsClimbed: Int
        var id: Date { date }
    }
}
