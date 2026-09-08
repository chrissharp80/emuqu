import SwiftUI

// Threshold cards live in `ThresholdCards` — 715 lines out of
// FitnessPostSummaryView, which was the third largest type in the codebase.
//
// The forwarders return the same view trees the extension returned before, so
// nothing about the rendered hierarchy or its identity changes.

extension FitnessPostSummaryView {
    /// The threshold-card builders for the session currently rendered.
    var thresholds: ThresholdCards { ThresholdCards(session: session) }

    var alpha1LT1EstimateCard: some View { thresholds.alpha1LT1EstimateCard }

    var alpha1CrossingsCard: some View { thresholds.alpha1CrossingsCard }

    var derivedMetricsCard: some View { thresholds.derivedMetricsCard }

    var hrZoneDistributionCard: some View { thresholds.hrZoneDistributionCard }
}
