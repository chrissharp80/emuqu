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

    var bestSplitDisplay: (pace: String, caption: String)? { stats.bestSplitDisplay }

    func hrrNarrative(drop: Int) -> String { WorkoutStatsCards.hrrNarrative(drop: drop) }

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

    // MARK: - Pure helpers that moved with the cards

    func elevationSeries(_ track: [CLLocation]) -> [FitnessSummaryCards.ElevationPoint] {
        WorkoutStatsCards.elevationSeries(track)
    }

    func hrrProvenanceLabel(_ p: HRRSample.Provenance) -> String {
        WorkoutStatsCards.hrrProvenanceLabel(p)
    }
}
