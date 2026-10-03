import SwiftUI

// Detail cards live in `MorningDetailCards` — 667 lines out of
// MorningResultsView.
//
// `cards` is rebuilt on each access from the view's current state, so every
// forwarder below renders from live values. The forwarders return the same view
// trees from the same positions, so SwiftUI view identity is unchanged; the
// snapshot suite pins that.

extension MorningResultsView {
    /// Only needs the view model, so it stays with the view rather than
    /// travelling with the reanalysis controls.
    func toggleTag(_ tag: ReadingTag) {
        if vm.selectedTags.contains(tag) {
            vm.selectedTags.remove(tag)
        } else {
            vm.selectedTags.insert(tag)
        }
    }

    var cards: MorningDetailCards {
        MorningDetailCards(
            vm: vm,
            session: session,
            result: result,
            recentSessions: recentSessions,
            translator: translator,
            collector: collector,
            morningCoordination: morningCoordination,
            linkedSegments: linkedSegments,
            onUnlinkSegment: onUnlinkSegment,
            onToggleTag: { toggleTag($0) },
            scoreRingSize: scoreRingSize,
            heroScoreFontSize: heroScoreFontSize,
            metricValueFontSize: metricValueFontSize,
            notes: $vm.notes,
            showingScoreExplainer: $showingScoreExplainer,
            showingUnlinkConfirmation: $showingUnlinkConfirmation,
            pendingUnlinkSegmentId: $pendingUnlinkSegmentId,
            removedSegmentIds: $removedSegmentIds
        )
    }

    func recoveryScoreCard(breakdownMessage: String) -> some View {
        cards.recoveryScoreCard(breakdownMessage: breakdownMessage)
    }

    var trainingReadinessCard: some View { cards.trainingReadinessCard }

    func scoreBreakdownSection(breakdown: RecoveryScoreCalculator.ScoreBreakdown) -> some View {
        cards.scoreBreakdownSection(breakdown: breakdown)
    }

    func sectionHeader(_ title: String, icon: String) -> some View {
        cards.sectionHeader(title, icon: icon)
    }

    var tagsAndNotesSection: some View { cards.tagsAndNotesSection }

    func trainingLoadCard(_ training: TrainingContext) -> some View {
        cards.trainingLoadCard(training)
    }

    var sleepWasActuallySplit: Bool { cards.sleepWasActuallySplit }

    func splitNightCard(segments: [LinkedSegmentInfo]) -> some View {
        cards.splitNightCard(segments: segments)
    }

    func formatGapDuration(_ interval: TimeInterval) -> String {
        cards.formatGapDuration(interval)
    }

    var hrvMetricCard: some View { cards.hrvMetricCard }

    var sleepMetricCardCompact: some View { cards.sleepMetricCardCompact }

    func sleepCard(_ sleep: SleepData) -> some View { cards.sleepCard(sleep) }

    func sleepQualityBand(_ sleep: SleepData) -> MorningDetailCards.SleepQualityBand {
        cards.sleepQualityBand(sleep)
    }

    func sleepScoreForLabel(_ sleep: SleepData) -> Int { cards.sleepScoreForLabel(sleep) }

    func dataSourceSummaryCard(_ summary: HRVSession.DataSourceSummary) -> some View {
        cards.dataSourceSummaryCard(summary)
    }

    var technicalDetailsSectionContent: some View { cards.technicalDetailsSectionContent }

    var trendComparisonSection: some View { cards.trendComparisonSection }
}
