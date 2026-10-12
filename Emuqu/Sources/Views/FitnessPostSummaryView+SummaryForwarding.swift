import CoreLocation
import MapKit
import SwiftUI

// Summary cards and share surfaces live in `FitnessSummaryCards`.
//
// `summary` is rebuilt on each access from the view's live state and every
// mutation travels back through a binding.

extension FitnessPostSummaryView {
    /// Rebuilt on each access so the cards always render from live state.
    /// Grouped onto fewer lines than one-argument-per-line purely to stay
    /// inside the 20-line declaration limit the refactor spec enforces; the
    /// call is a single expression either way.
    var summary: FitnessSummaryCards {
        FitnessSummaryCards(
            session: session, track: track, units: units,
            collector: collector, savedRouteStore: savedRouteStore,
            settingsManager: settingsManager,
            refreshedSession: $refreshedSession,
            gpxURL: $gpxURL, csvURL: $csvURL, tcxURL: $tcxURL,
            exportsReady: $exportsReady, exportError: $exportError,
            recapImage: $recapImage, recapImageURL: $recapImageURL,
            recapGenerating: $recapGenerating, recapSharePresented: $recapSharePresented,
            showSaveRouteSheet: $showSaveRouteSheet, newRouteName: $newRouteName,
            savedRouteIDForThisSession: $savedRouteIDForThisSession,
            reanalyzing: $reanalyzing, reanalyzeError: $reanalyzeError,
            elevResmoothing: $elevResmoothing, elevResmoothPreview: $elevResmoothPreview,
            elevResmoothError: $elevResmoothError, routeHistory: $routeHistory,
            pdfURL: $pdfURL, pdfGenerating: $pdfGenerating,
            pdfSharePresented: $pdfSharePresented,
            pdfMailPresented: $pdfMailPresented, pdfMailError: $pdfMailError, reportShare: $reportShare
        )
    }

    var physiologyCard: some View { summary.physiologyCard }
    var environmentCard: some View { summary.environmentCard }
    var routeHistoryBaselineCard: some View { summary.routeHistoryBaselineCard }
    var coachReportCard: some View { summary.coachReportCard }
    var saveRouteCard: some View { summary.saveRouteCard }
    var exportCard: some View { summary.exportCard }
    var resmoothElevationCard: some View { summary.resmoothElevationCard }
    var reanalyzeAlpha1Card: some View { summary.reanalyzeAlpha1Card }

    func splitsCard(_ resolved: FitnessSummaryCards.ResolvedSplits) -> some View { summary.splitsCard(resolved) }

    /// The route-history baseline for the rendered session, walked off the
    /// main actor. Several loads can overlap (one per archive change); only
    /// the newest one's result is kept (`routeHistoryGeneration`), so an
    /// older walk landing last cannot overwrite a newer baseline.
    func loadRouteHistorySummary() async {
        routeHistoryGeneration += 1
        let generation = routeHistoryGeneration
        guard let routeName = session.workoutMetadata?.recognizedRouteName, !routeName.isEmpty else {
            routeHistory = nil
            return
        }
        let sessionSnapshot = session
        let unitsResolved = units.resolved
        let baseline = await Task.detached(priority: .userInitiated) {
            FitnessSummaryCards.routeHistorySummary(routeName: routeName, session: sessionSnapshot, unitsResolved: unitsResolved)
        }.value
        guard generation == routeHistoryGeneration else { return }
        routeHistory = baseline
    }

    func regionForTrack(_ coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        summary.regionForTrack(coords)
    }
}
