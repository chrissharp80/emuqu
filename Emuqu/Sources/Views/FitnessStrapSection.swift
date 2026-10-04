import SwiftUI

/// The hero, recent-workout and workout-history surfaces on the fitness
/// tab.
///
/// Split out of `FitnessTabView`, the same shape as [MorningDetailCards],
/// [MorningReanalysisControls] and [RecoveryScoreCharts].
///
/// Deliberately NOT a `View`. It returns the same view trees from the same
/// positions, so SwiftUI identity, animation and `@State` behaviour are
/// unchanged; the snapshot suite pins that.
@MainActor
struct FitnessStrapSection {
    let collector: RRCollector
    let archiveSignal: ArchiveSignal
    let units: UnitsPreference
    let trainingCache: TrainingMetricsCache
    /// Read for the training-load pause (integration off or a break).
    let settings: UserSettings

    /// Date helpers and the delete action stay owned by the view and arrive as
    /// closures — they read view state this type does not hold.
    let recentWorkoutEntries: () -> [SessionArchiveEntry]
    let withinDays: (Date, Int) -> Bool
    let relativeDate: (Date) -> String
    let formattedDate: (Date) -> String
    let deleteWorkout: (UUID) -> Void

    @Binding var lastCompletedSession: HRVSession?
    @Binding var latestWorkoutSession: HRVSession?
    /// The newest workout's file couldn't be read; the hero says so instead
    /// of spinning.
    @Binding var latestWorkoutLoadFailed: Bool
    @Binding var selectedHistorySession: HRVSession?
    @Binding var meanHRR1m7d: Double?
}

// MARK: - Forwarders

// The strap and workout-history surfaces live here, out of
// FitnessTabView. `strapSection` is rebuilt on each access from the
// view's live state, and every mutation travels back through a binding.

extension FitnessTabView {
    var strapSection: FitnessStrapSection {
        FitnessStrapSection(
            collector: collector,
            archiveSignal: archiveSignal,
            units: units,
            trainingCache: trainingCache,
            settings: settingsManager.settings,
            recentWorkoutEntries: { recentWorkoutEntries() },
            withinDays: { withinDays($0, $1) },
            relativeDate: { relativeDate($0) },
            formattedDate: { formattedDate($0) },
            deleteWorkout: { deleteWorkout($0) },
            lastCompletedSession: $lastCompletedSession,
            latestWorkoutSession: $latestWorkoutSession,
            latestWorkoutLoadFailed: $latestWorkoutLoadFailed,
            selectedHistorySession: $selectedHistorySession,
            meanHRR1m7d: $meanHRR1m7d
        )
    }

    func heroCard(latest: SessionArchiveEntry?) -> some View {
        strapSection.heroCard(latest: latest)
    }

    var trajectoryLinkCard: some View { strapSection.trajectoryLinkCard }

    func summaryTileGrid(entries: [SessionArchiveEntry]) -> some View {
        strapSection.summaryTileGrid(entries: entries)
    }

    func recentWorkoutsList(entries: [SessionArchiveEntry]) -> some View {
        strapSection.recentWorkoutsList(entries: entries)
    }

    var heroReloadKey: String { strapSection.heroReloadKey }

    func loadLatestWorkoutSession() async { await strapSection.loadLatestWorkoutSession() }
}
