import SwiftUI

/// Build plan §4.2 D8 — Reading detail.
///
/// "Variant of HRV detail / Workout summary / Sleep detail depending on
/// session type. Same component instance, different data."
///
/// Used by History, Recent strip taps, and any other surface that needs
/// to push into a session's detail view without knowing the session type.
struct ReadingDetailDispatcher: View {
    @Environment(\.dependencies) var dependencies
    @Environment(RRCollector.self) private var collector
    private var settingsManager: SettingsManager { dependencies.app.settingsManager }
    let session: HRVSession
    let recentSessions: [HRVSession]

    var body: some View {
        if session.sessionType == .workout, let workout = session.workoutMetadata {
            WorkoutSummaryV2View(session: session, workout: workout)
        } else if let result = session.analysisResult {
            recoveryDetail(result)
        } else {
            EmptyState(
                glyph: "exclamationmark.circle",
                headline: "Reading not analysed yet",
                message: "This session hasn't been analysed. Re-analyse from the History row to compute the score."
            )
        }
    }

    /// For HRV / overnight / nap sessions, fall through to the unified Recovery
    /// Score detail (D2). It already includes the HRV breakdown, sleep
    /// snapshot, vitals, charts, engine room.
    private func recoveryDetail(_ result: HRVAnalysisResult) -> some View {
        RecoveryScoreDetailView(
            session: session,
            result: result,
            recentSessions: recentSessions,
            baselineStats: collector.baselineTracker.recoveryBaselineStats,
            totalSessionCount: collector.archive.entries.count,
            onReanalyze: nil
        )
    }
}
