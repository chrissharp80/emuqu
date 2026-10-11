import CoreLocation
import SwiftUI

// Workout statistics cards live in `WorkoutStatsCards`, cut out of
// FitnessPostSummaryView.
//
// The forwarders return the same view trees and the same strings the extension
// would, so nothing about the rendered hierarchy or its identity differs.

extension FitnessPostSummaryView {
    /// The statistics-card builders for the session currently rendered.
    var stats: WorkoutStatsCards {
        WorkoutStatsCards(session: session, settingsManager: settingsManager, track: track)
    }

    // MARK: - Derived display values

    /// The fastest full split of the splits the splits card shows
    /// (`cachedSplits`, already resolved to the user's unit), labelled with
    /// that one unit. A partial split (under 90 % of the bucket — the tail of
    /// the workout) can't win, and its row-by-row length never picks the unit.
    var bestSplitDisplay: (pace: String, caption: String)? {
        guard let resolved = cachedSplits, resolved.splits.count >= 2 else { return nil }
        let bucket = resolved.isMile ? 1_609.344 : 1_000.0
        let fastest = resolved.splits
            .filter { $0.distanceMeters >= 0.9 * bucket && ($0.averagePaceSecPerKm ?? 0) > 0 }
            .min { ($0.averagePaceSecPerKm ?? 0) < ($1.averagePaceSecPerKm ?? 0) }
        guard let fastest, let pace = fastest.averagePaceSecPerKm,
              let paceStr = units.formatPace(secondsPerMeter: pace / 1_000)
        else { return nil }
        let unitLabel = LocalizedUnit.symbol(resolved.isMile ? UnitLength.miles : UnitLength.kilometers)
        let hrPart = fastest.averageHR.map { " · " + String(localized: "\(Int($0)) bpm", bundle: LanguageManager.appBundle) } ?? ""
        return (pace: paceStr, caption: "\(unitLabel) \(fastest.index)\(hrPart)")
    }

    // MARK: - Cards

    func hrChartCard(samples: [WorkoutSample]) -> some View {
        stats.hrChartCard(samples: samples)
    }

    func paceChartCard(samples: [WorkoutSample]) -> some View {
        stats.paceChartCard(samples: samples)
    }

    func powerChartCard(samples: [WorkoutSample]) -> some View {
        stats.powerChartCard(samples: samples)
    }

    func cadenceChartCard(samples: [WorkoutSample]) -> some View {
        stats.cadenceChartCard(samples: samples)
    }

    var elevationCard: some View { stats.elevationCard }

    var hrrCaptureBanner: some View { stats.hrrCaptureBanner }

    var hrrCard: some View { stats.hrrCard }
}
