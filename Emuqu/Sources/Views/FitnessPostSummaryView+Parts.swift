import CoreLocation
import MapKit
import SwiftUI

// The summary screen's card builders. Each is a value rebuilt on every access
// from the view's live state, and every mutation travels back through a
// binding, so the view keeps all the state and the builders hold none:
// `FitnessSummaryCards` (summary and share surfaces), `WorkoutStatsCards`,
// `ThresholdCards` and `Alpha1ReportCards`.

extension FitnessPostSummaryView {
    // MARK: - Card builders

    /// Rebuilt on each access so the cards always render from live state.
    /// Grouped onto fewer lines than one-argument-per-line purely to stay
    /// inside the 20-line declaration limit; the
    /// call is a single expression either way.
    var summary: FitnessSummaryCards {
        FitnessSummaryCards(
            session: session, track: track, units: units,
            collector: collector, savedRouteStore: savedRouteStore, roadGeocoder: dependencies.location.roadGeocodingService,
            archive: dependencies.storage.sessionArchive, alpha1StatsCache: dependencies.app.alpha1StatsCache,
            settingsManager: settingsManager, refreshedSession: $refreshedSession,
            gpxExport: $gpxExport, csvExport: $csvExport, tcxExport: $tcxExport,
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

    /// The statistics-card builders for the session currently rendered.
    var stats: WorkoutStatsCards {
        WorkoutStatsCards(session: session, settingsManager: settingsManager, track: track)
    }

    /// The threshold-card builders for the session currently rendered.
    var thresholds: ThresholdCards {
        ThresholdCards(session: session, settings: .snapshot(of: settingsManager))
    }

    typealias Alpha1Stats = Alpha1ReportCards.Alpha1Stats

    /// The α1 report builders for the session currently rendered.
    var alpha1Report: Alpha1ReportCards {
        Alpha1ReportCards(session: session, statsCache: dependencies.app.alpha1StatsCache)
    }

    // MARK: - Derived display values

    /// The fastest full split of the splits the splits card shows
    /// (`cachedSplits`, already resolved to the user's unit), labelled with
    /// that one unit. A partial split (under 90 % of the bucket — the tail of
    /// the workout) can't win, and its row-by-row length never picks the unit.
    var bestSplitDisplay: (pace: String, caption: String)? {
        guard let resolved = cachedSplits, resolved.splits.count >= 2 else { return nil }
        let bucket = resolved.isMile ? UnitConstants.metersPerMile : 1_000.0
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
        let (sessionSnapshot, archive) = (session, dependencies.storage.sessionArchive)
        let unitsResolved = units.resolved
        let baseline = await Task.detached(priority: .userInitiated) {
            FitnessSummaryCards.routeHistorySummary(
                routeName: routeName, session: sessionSnapshot, unitsResolved: unitsResolved, archive: archive
            )
        }.value
        guard generation == routeHistoryGeneration else { return }
        routeHistory = baseline
    }
}
