import SwiftUI

/// The reanalysis, manual-window, strap-merge and report-export controls on the
/// morning results screen.
///
/// Wide initialiser for the same reason as the cards: this is genuinely
/// stateful work. Reanalysis mutates seven pieces of view state (which window
/// is selected, the manual result, the export URLs, the in-flight flags), so
/// the bindings are threaded rather than hidden. A facade that concealed them
/// would hide the coupling without removing it.
///
/// Deliberately NOT a `View`: it returns view trees into the host view's
/// body, so SwiftUI identity, animation and `@State` stay the host's; the
/// snapshot suite pins that.
@MainActor
struct MorningReanalysisControls {
    let vm: MorningResultsViewModel
    let session: HRVSession
    let result: HRVAnalysisResult
    let recentSessions: [HRVSession]
    let collector: RRCollector
    /// Saved-session reanalysis, which rescores a night after a strap merge.
    let sessionReanalysis: SessionReanalysisCoordinator
    let trainingMetricsCache: TrainingMetricsCache
    let settingsManager: SettingsManager

    let onReanalyze: ((HRVSession, WindowSelectionMethod) async -> HRVSession?)?
    let onReanalyzeAt: ((Int64) async -> HRVAnalysisResult?)?
    let onApplyManualResult: ((HRVAnalysisResult) async -> HRVSession?)?

    @Binding var exportURL: IdentifiableURL?
    @Binding var emailURL: IdentifiableURL?
    @Binding var isManualWindowMode: Bool
    @Binding var manualResult: HRVAnalysisResult?
    @Binding var manualPickMessage: String?
    @Binding var strapMergeWorking: Bool
    @Binding var strapMergeMessage: String?
    /// A method picked from the Analysis Window menu, awaiting confirmation.
    @Binding var pendingWindowMethod: WindowSelectionMethod?
    /// Set when a re-analysis returned no session; the view alerts.
    @Binding var reanalysisDeclined: Bool
}
