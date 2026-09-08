import CoreLocation
import SwiftUI

// The α1 report card lives in `Alpha1ReportCards`, cut out of
// FitnessPostSummaryView like `ThresholdCards`.
//
// The forwarders return the same view trees an inline extension would, so
// nothing about the rendered hierarchy or its identity differs. `Alpha1Stats`
// and `AT1CrossDetector` are re-exported as typealiases because other files
// name them through the view.

extension FitnessPostSummaryView {
    typealias Alpha1Stats = Alpha1ReportCards.Alpha1Stats
    typealias AT1CrossDetector = Alpha1ReportCards.AT1CrossDetector

    /// The α1 report builders for the session currently rendered.
    var alpha1Report: Alpha1ReportCards { Alpha1ReportCards(session: session) }

    var alpha1ReportCard: some View { alpha1Report.alpha1ReportCard }

    func alpha1RouteColoredCard(track: [CLLocation]) -> some View {
        alpha1Report.alpha1RouteColoredCard(track: track)
    }
}
