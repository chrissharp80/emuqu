import CoreLocation
import SwiftUI

/// The post-workout summary cards and share surfaces: exports, the recap
/// image, route saving, reanalysis, elevation re-smoothing, and the PDF report.
///
/// Split out of `FitnessPostSummaryView` — roughly half of that view — in
/// the same way as [MorningDetailCards], [MorningReanalysisControls],
/// [RecoveryScoreCharts] and [FitnessStrapSection].
///
/// Wide initialiser, honestly: these surfaces drive fourteen pieces of view
/// state between them — three export URLs, the recap image and its share
/// sheet, the route-save sheet, and three in-flight flags. Every one travels
/// back through a binding rather than being duplicated here.
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
}
