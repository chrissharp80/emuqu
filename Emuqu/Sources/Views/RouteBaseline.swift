import Foundation

/// Distance-weighted pace baseline plus a sample-weighted mean HR over the
/// prior runs of a route (`FitnessSummaryCards.routeHistorySummary`).
struct RouteBaseline {
    var totalDistance: Double = 0
    var totalDuration: Double = 0
    var hrSum: Double = 0
    var hrCount: Int = 0

    init(priorRuns candidates: [HRVSession]) {
        for prior in candidates {
            accumulatePace(from: prior)
            accumulateHR(from: prior)
        }
    }

    /// Only efforts long enough to be a real repeat of the route contribute
    /// (>100 m and >60 s).
    private mutating func accumulatePace(from prior: HRVSession) {
        guard let dist = prior.workoutMetadata?.distanceMeters, dist > 100,
              let dur = prior.duration, dur > 60
        else { return }
        totalDistance += dist
        totalDuration += dur
    }

    /// Zero readings (strap dropouts) are left out.
    private mutating func accumulateHR(from prior: HRVSession) {
        for hr in (prior.workoutMetadata?.samples ?? []).compactMap(\.heartRate) where hr > 0 {
            hrSum += Double(hr)
            hrCount += 1
        }
    }
}
