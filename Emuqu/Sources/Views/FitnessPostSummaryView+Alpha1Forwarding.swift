import CoreLocation
import SwiftUI

// The α1 report card lives in `Alpha1ReportCards`, cut out of
// FitnessPostSummaryView like `ThresholdCards`.
//
// The forwarders return the same view trees an inline extension would, so
// nothing about the rendered hierarchy or its identity differs. `Alpha1Stats`
// is re-exported as a typealias because other files name it through the view.

extension FitnessPostSummaryView {
    typealias Alpha1Stats = Alpha1ReportCards.Alpha1Stats

    /// The α1 report builders for the session currently rendered.
    var alpha1Report: Alpha1ReportCards { Alpha1ReportCards(session: session) }

    var alpha1ReportCard: some View { alpha1Report.alpha1ReportCard }

    func alpha1RouteColoredCard(track: [CLLocation]) -> some View {
        alpha1Report.alpha1RouteColoredCard(track: track)
    }
}
