import SwiftUI

// The results screen's two builders, `MorningDetailCards` and
// `MorningReanalysisControls`. Both are rebuilt on every access from the
// view's current state and write back through bindings, so they always render
// from live values and the view keeps all the state.

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

    /// The detail cards below the score.
    var cards: MorningDetailCards {
        MorningDetailCards(
            vm: vm,
            settingsManager: dependencies.app.settingsManager,
            session: session,
            result: result,
            recentSessions: recentSessions,
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

    /// Reanalysis, manual-window, strap-merge and report-export controls.
    var reanalysis: MorningReanalysisControls {
        MorningReanalysisControls(
            vm: vm, session: session, result: result, recentSessions: recentSessions, collector: collector,
            sessionReanalysis: dependencies.collection.sessionReanalysis,
            trainingMetricsCache: dependencies.analysis.trainingMetricsCache, settingsManager: dependencies.app.settingsManager,
            onReanalyze: onReanalyze,
            onReanalyzeAt: onReanalyzeAt,
            onApplyManualResult: onApplyManualResult,
            exportURL: $exportURL,
            emailURL: $emailURL,
            isManualWindowMode: $isManualWindowMode,
            manualResult: $manualResult,
            manualPickMessage: $manualPickMessage,
            strapMergeWorking: $strapMergeWorking,
            strapMergeMessage: $strapMergeMessage,
            pendingWindowMethod: $pendingWindowMethod,
            reanalysisDeclined: $reanalysisDeclined
        )
    }
}
