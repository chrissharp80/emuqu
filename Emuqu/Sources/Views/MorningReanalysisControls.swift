import SwiftUI

/// The reanalysis, manual-window, strap-merge and report-export controls on the
/// morning results screen.
///
/// Split out of `MorningResultsView`, alongside [MorningDetailCards].
///
/// Wide initialiser for the same reason as the cards: this is genuinely
/// stateful work. Reanalysis mutates seven pieces of view state (which window
/// is selected, the manual result, the export URLs, the in-flight flags), so
/// the bindings are threaded rather than hidden. A facade that concealed them
/// would remove the line count without removing the coupling.
///
/// Deliberately NOT a `View`. It returns the same view trees from the same
/// positions, so SwiftUI identity, animation and `@State` behaviour are
/// unchanged; the snapshot suite pins that.
@MainActor
struct MorningReanalysisControls {
    let vm: MorningResultsViewModel
    let session: HRVSession
    let result: HRVAnalysisResult
    let recentSessions: [HRVSession]
    let collector: RRCollector

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
}
