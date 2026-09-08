import SwiftUI

// Reanalysis, manual-window, strap-merge and report-export controls live in
// `MorningReanalysisControls`, keeping ~930 lines out of
// MorningResultsView.
//
// `reanalysis` is rebuilt on each access from the view's live state, and every
// mutation travels back through a binding, so behaviour is unchanged.

extension MorningResultsView {
    var reanalysis: MorningReanalysisControls {
        MorningReanalysisControls(
            vm: vm,
            session: session,
            result: result,
            recentSessions: recentSessions,
            collector: collector,
            onReanalyze: onReanalyze,
            onReanalyzeAt: onReanalyzeAt,
            onApplyManualResult: onApplyManualResult,
            exportURL: $exportURL,
            emailURL: $emailURL,
            isManualWindowMode: $isManualWindowMode,
            manualResult: $manualResult,
            manualPickMessage: $manualPickMessage,
            strapMergeWorking: $strapMergeWorking,
            strapMergeMessage: $strapMergeMessage
        )
    }

    var windowSelectionMethodSection: some View { reanalysis.windowSelectionMethodSection }

    var overnightStrapMergeCard: some View { reanalysis.overnightStrapMergeCard }

    func persistentWindowComparisonBanner() -> some View {
        reanalysis.persistentWindowComparisonBanner()
    }

    var pdfLoadingOverlay: some View { reanalysis.pdfLoadingOverlay }

    var provenanceView: some View { reanalysis.provenanceView }

    var availableReportSections: PDFReportGenerator.ReportSections {
        reanalysis.availableReportSections
    }

    func exportPDF(
        style: PDFReportGenerator.ReportStyle = .comprehensive,
        sections: PDFReportGenerator.ReportSections = .all
    ) {
        reanalysis.exportPDF(style: style, sections: sections)
    }

    func emailReport(
        style: PDFReportGenerator.ReportStyle = .comprehensive,
        sections: PDFReportGenerator.ReportSections = .all
    ) {
        reanalysis.emailReport(style: style, sections: sections)
    }

    func performReanalysis() { reanalysis.performReanalysis() }

    func reanalyzeWithMethod(_ method: WindowSelectionMethod) {
        reanalysis.reanalyzeWithMethod(method)
    }

    func handleManualReanalysis(timestampMs: Int64) {
        reanalysis.handleManualReanalysis(timestampMs: timestampMs)
    }

    func exportRRData() { reanalysis.exportRRData() }
}
