import CoreLocation
import SwiftUI

/// The post-workout summary cards and share surfaces: exports, the recap
/// image, route saving, reanalysis, elevation re-smoothing, and the PDF report.
///
/// Split out of `FitnessPostSummaryView` — roughly half of that view — in
/// the same way as [MorningDetailCards], [MorningReanalysisControls],
/// [RecoveryScoreCharts] and [FitnessStrapSection].
///
/// Wide initialiser, honestly: these surfaces drive two dozen pieces of view
/// state between them — the refreshed session, the export URLs and their
/// readiness, the recap image and its share sheet, the route-save sheet and
/// route history, reanalysis and elevation re-smoothing, and the PDF report's
/// file, sheets and errors. Every one travels back through a binding rather
/// than being duplicated here.
///
/// Deliberately NOT a `View`. It returns the same view trees from the same
/// positions, so SwiftUI identity, animation and `@State` behaviour are
/// unchanged; the snapshot suite pins that.
@MainActor
struct FitnessSummaryCards {
    let session: HRVSession
    let track: [CLLocation]
    let units: UnitsPreference
    let collector: RRCollector
    let savedRouteStore: SavedRouteStore

    let settingsManager: SettingsManager

    @Binding var refreshedSession: HRVSession?
    @Binding var gpxURL: URL?
    @Binding var csvURL: URL?
    @Binding var tcxURL: URL?
    @Binding var exportsReady: Bool
    @Binding var exportError: String?
    @Binding var recapImage: UIImage?
    @Binding var recapImageURL: URL?
    @Binding var recapGenerating: Bool
    @Binding var recapSharePresented: Bool
    @Binding var showSaveRouteSheet: Bool
    @Binding var newRouteName: String
    @Binding var savedRouteIDForThisSession: UUID?
    @Binding var reanalyzing: Bool
    @Binding var reanalyzeError: String?
    @Binding var elevResmoothing: Bool
    @Binding var elevResmoothPreview: (gain: Double, loss: Double)?
    @Binding var elevResmoothError: String?
    @Binding var routeHistory: FitnessSummaryCards.RouteHistorySummary?
    @Binding var pdfURL: URL?
    @Binding var pdfGenerating: Bool
    @Binding var pdfSharePresented: Bool
    @Binding var pdfMailPresented: Bool
    @Binding var pdfMailError: String?
    @Binding var reportShare: ReportShareState

    /// Share state for the PDF report and recap card beyond the cached PDF.
    struct ReportShareState {
        /// The file the open PDF share sheet or mail composer shows. Kept
        /// apart from the cache (`pdfURL`), which an archive refresh clears
        /// while a sheet may be up.
        var presentedURL: URL?
        /// Bumped whenever the cached exports are invalidated; a PDF render
        /// that started under an older value is not cached.
        var cacheGeneration = 0
        /// A failed PDF or recap-card render, shown in its own alert so an
        /// export-file rebuild (which rewrites `exportError`) cannot erase it.
        var error: String?
    }
}
