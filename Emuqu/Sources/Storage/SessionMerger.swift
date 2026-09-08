import Foundation

// MARK: - Session Merging
//
// Structured per the refactor spec's "pure functions first"
// principle: every merge DECISION (which RR series wins, whose analysis is
// adopted, which metadata fills in) is computed up front as a pure
// `MergeOutcome` value from immutable snapshots of both sessions, and a
// separate apply step performs the mutations. Decisions and effects cannot
// interleave — which is exactly the bug class this file shipped
// twice (a score clobber, then a post-merge count read; see
// the notes inside `rrOutcome`).

/// The session-merge decision and its application: how an imported session is
/// folded into one already in the archive.
///
/// Split out of `SessionArchive`. It needs nothing from the
/// archive at all, because the decision core is pure: it
/// takes two immutable session snapshots and returns what to change.
enum SessionMerger {
    /// Pure description of everything a merge would change on the existing
    /// session. Computed before any mutation so the decision logic is
    /// testable in isolation (see ArchivePolicyTests).
    struct MergeOutcome {
        enum RRChange {
            /// Both sessions had RR points — replace existing's series with
            /// the composite and install a "composite" data-source summary.
            /// `adoptImportedSleepBounds` fills sleep bounds from the
            /// imported (device) session when existing was the streaming
            /// side; `adoptImportedAnalysis` swaps in imported's
            /// analysisResult + recoveryScore.
            case composite(
                mergedPoints: [RRPoint],
                summary: HRVSession.DataSourceSummary,
                adoptImportedSleepBounds: Bool,
                adoptImportedAnalysis: Bool
            )
            /// Existing had no RR series — adopt imported's series and its
            /// RR-adjacent fields wholesale.
            case adoptImportedSeries(adoptImportedAnalysis: Bool)
        }

        var rrChange: RRChange?
        /// Fill existing's nil analysisResult from imported (no-RR-merge path).
        var adoptAnalysisResult = false
        /// Fill existing's nil recoveryScore from imported (no-RR-merge path).
        var adoptRecoveryScore = false
        var tagsToAppend: [ReadingTag] = []
        var adoptNotes = false
        var adoptImportedMetrics = false

        /// Mirrors the historical `changed` return contract: any RR change
        /// counts (both RR branches always returned true), otherwise any
        /// fill-in counts.
        var hasChanges: Bool {
            rrChange != nil || adoptAnalysisResult || adoptRecoveryScore
                || !tagsToAppend.isEmpty || adoptNotes || adoptImportedMetrics
        }
    }

    /// Merge data from an imported session into an existing session.
    /// When both sessions have RR data, uses DataSourceSelector to create a
    /// composite that preserves beats from both sources instead of discarding one.
    /// Returns true if any changes were made.
    static func mergeSessionData(from imported: HRVSession, into existing: inout HRVSession) -> Bool {
        let outcome = Self.mergeOutcome(imported: imported, existing: existing)
        Self.apply(outcome, from: imported, to: &existing)
        return outcome.hasChanges
    }

    // MARK: Pure decision core

    /// Compute the full merge decision from immutable snapshots. Pure:
    /// no mutation, no I/O, deterministic for the same pair of sessions.
    static func mergeOutcome(imported: HRVSession, existing: HRVSession) -> MergeOutcome {
        var outcome = rrOutcome(imported: imported, existing: existing)

        // Metadata fills. RR decisions never touch tags/notes/importedMetrics,
        // so deciding from the pre-merge snapshot is safe.
        let existingTagIds = Set(existing.tags.map(\.id))
        outcome.tagsToAppend = imported.tags.filter { !existingTagIds.contains($0.id) }
        if let importedNotes = imported.notes, !importedNotes.isEmpty, (existing.notes ?? "").isEmpty {
            outcome.adoptNotes = true
        }
        if existing.importedMetrics == nil, imported.importedMetrics != nil {
            outcome.adoptImportedMetrics = true
        }
        return outcome
    }

    /// One side has no beats: adopt the imported series wholesale when the
    /// existing session has none, otherwise fill in only what's missing.
    private static func singleSeriesOutcome(imported: HRVSession, existing: HRVSession) -> MergeOutcome {
        var outcome = MergeOutcome()
        if existing.rrSeries == nil, imported.rrSeries != nil {
            outcome.rrChange = .adoptImportedSeries(adoptImportedAnalysis: imported.analysisResult != nil)
        } else {
            outcome.adoptAnalysisResult = existing.analysisResult == nil && imported.analysisResult != nil
            outcome.adoptRecoveryScore = existing.recoveryScore == nil && imported.recoveryScore != nil
        }
        return outcome
    }

    /// RR-data decision (historically `mergeRRData` + `mergeOverlappingRRData`).
    private static func rrOutcome(imported: HRVSession, existing: HRVSession) -> MergeOutcome {
        guard let importedPoints = imported.rrSeries?.points, !importedPoints.isEmpty,
              let existingPoints = existing.rrSeries?.points, !existingPoints.isEmpty else {
            return singleSeriesOutcome(imported: imported, existing: existing)
        }
        var outcome = MergeOutcome()
        outcome.rrChange = compositeChange(
            imported: imported, existing: existing,
            importedPoints: importedPoints, existingPoints: existingPoints
        )
        return outcome
    }

    /// Both sessions carry beats: interleave them and describe the result.
    private static func compositeChange(
        imported: HRVSession, existing: HRVSession,
        importedPoints: [RRPoint], existingPoints: [RRPoint]
    ) -> MergeOutcome.RRChange {
        let existingIsStreaming = (existing.dataSourceSummary?.selectedSource ?? "") == "streaming"
        let importedIsStreaming = (imported.dataSourceSummary?.selectedSource ?? "") == "streaming"
        let mergedPoints = mergePoints(
            importedPoints: importedPoints, existingPoints: existingPoints,
            existingIsStreaming: existingIsStreaming, importedIsStreaming: importedIsStreaming
        )
        let summary = compositeSummary(
            imported: imported, existing: existing, importedPoints: importedPoints,
            existingPoints: existingPoints, mergedPoints: mergedPoints
        )
        let adoptAnalysis = shouldAdoptImportedAnalysis(
            imported: imported, existing: existing,
            importedPoints: importedPoints, existingPoints: existingPoints
        )
        return .composite(
            mergedPoints: mergedPoints, summary: summary,
            adoptImportedSleepBounds: existingIsStreaming && !importedIsStreaming,
            adoptImportedAnalysis: adoptAnalysis
        )
    }

    /// Whichever series is streaming plays the streaming role in the merge;
    /// with both or neither streaming, the larger series is treated as the
    /// internal one.
    private static func mergePoints(
        importedPoints: [RRPoint], existingPoints: [RRPoint],
        existingIsStreaming: Bool, importedIsStreaming: Bool
    ) -> [RRPoint] {
        if existingIsStreaming, !importedIsStreaming {
            return DataSourceSelector.mergePoints(internal: importedPoints, streaming: existingPoints)
        }
        if importedIsStreaming, !existingIsStreaming {
            return DataSourceSelector.mergePoints(internal: existingPoints, streaming: importedPoints)
        }
        if importedPoints.count >= existingPoints.count {
            return DataSourceSelector.mergePoints(internal: importedPoints, streaming: existingPoints)
        }
        return DataSourceSelector.mergePoints(internal: existingPoints, streaming: importedPoints)
    }

    private static func compositeSummary(
        imported: HRVSession, existing: HRVSession,
        importedPoints: [RRPoint], existingPoints: [RRPoint], mergedPoints: [RRPoint]
    ) -> HRVSession.DataSourceSummary {
        let baseSummary = imported.dataSourceSummary ?? existing.dataSourceSummary
        let diffPct: Double? = existingPoints.count > 0
            ? Double(mergedPoints.count - existingPoints.count) / Double(existingPoints.count) * 100.0
            : baseSummary?.beatDifferencePercent
        return HRVSession.DataSourceSummary(
            selectedSource: "composite",
            streamingBeats: baseSummary?.streamingBeats ?? existingPoints.count,
            deviceBeats: baseSummary?.deviceBeats ?? importedPoints.count,
            totalBeats: mergedPoints.count,
            beatDifferencePercent: diffPct,
            reconnectCount: baseSummary?.reconnectCount ?? 0,
            deviceModel: baseSummary?.deviceModel
        )
    }

    /// Don't overwrite a good existing `analysisResult`
    /// with a worse incoming one. A merge that unconditionally
    /// copies imported's `analysisResult` + `recoveryScore` over the
    /// existing values produced this symptom (beta tester):
    /// a 22-min partial-backup recovery merged into Monday's real
    /// overnight session and clobbered Monday's recoveryScore = 70+
    /// with the 22-min reading's 25.
    ///
    /// Not gated on `cleanBeatCount`: that's the
    /// analysis-WINDOW size, ~400 beats for any session that finds
    /// a usable window. It doesn't distinguish a 22-min recovery
    /// from an 8-hour overnight. Gated on total RR points in
    /// the imported vs existing series — the actual amount of
    /// raw data behind each analysis.
    ///
    /// Compares the PRE-merge series sizes. Reading
    /// `existing.rrSeries` AFTER it has been
    /// replaced with the merged composite makes the existing total
    /// ≥ the imported total always — the imported analysis can NEVER
    /// win once `existing.analysisResult` is non-nil. That's the exact
    /// inverse of the intent: a fresh 8-hour overnight
    /// folded into an existing 22-min partial keeps the partial's
    /// recovery score and silently discards the full-night
    /// analysis. Taking the point arrays as parameters makes a
    /// post-merge read structurally impossible.
    ///
    /// When this is false we keep the existing analysis — it was computed on
    /// at least as much raw data, and swapping in a smaller-session analysis
    /// would be a regression.
    private static func shouldAdoptImportedAnalysis(
        imported: HRVSession, existing: HRVSession,
        importedPoints: [RRPoint], existingPoints: [RRPoint]
    ) -> Bool {
        imported.analysisResult != nil
            && (existing.analysisResult == nil || importedPoints.count > existingPoints.count)
    }

    // MARK: Imperative shell

    /// Apply a computed outcome to the existing session. The only place in
    /// the merge path that mutates.
    static func apply(_ outcome: MergeOutcome, from imported: HRVSession, to existing: inout HRVSession) {
        applyRRChange(outcome, from: imported, to: &existing)
        existing.tags.append(contentsOf: outcome.tagsToAppend)
        if outcome.adoptNotes {
            existing.notes = imported.notes
        }
        if outcome.adoptImportedMetrics {
            existing.importedMetrics = imported.importedMetrics
        }
    }

    private static func applyRRChange(
        _ outcome: MergeOutcome, from imported: HRVSession, to existing: inout HRVSession
    ) {
        switch outcome.rrChange {
        case let .composite(mergedPoints, summary, adoptImportedSleepBounds, adoptImportedAnalysis):
            applyComposite(
                mergedPoints: mergedPoints, summary: summary,
                adoptImportedSleepBounds: adoptImportedSleepBounds,
                adoptImportedAnalysis: adoptImportedAnalysis,
                from: imported, to: &existing
            )
        case let .adoptImportedSeries(adoptImportedAnalysis):
            applyImportedSeries(adoptImportedAnalysis, from: imported, to: &existing)
        case nil:
            if outcome.adoptAnalysisResult {
                existing.analysisResult = imported.analysisResult
            }
            if outcome.adoptRecoveryScore {
                adoptFrozenScore(from: imported, to: &existing)
            }
        }
    }

    /// The existing session had no beats of its own — take the imported
    /// series and everything derived from it.
    private static func applyImportedSeries(
        _ adoptImportedAnalysis: Bool, from imported: HRVSession, to existing: inout HRVSession
    ) {
        existing.rrSeries = imported.rrSeries
        existing.artifactFlags = imported.artifactFlags
        existing.dataSourceSummary = imported.dataSourceSummary
        existing.sleepStartMs = imported.sleepStartMs
        existing.sleepEndMs = imported.sleepEndMs
        adoptAnalysis(adoptImportedAnalysis, from: imported, to: &existing)
    }

    /// Artifact flags are cleared: they index the pre-merge series and would
    /// mislabel beats in the composite one.
    private static func applyComposite(
        mergedPoints: [RRPoint],
        summary: HRVSession.DataSourceSummary,
        adoptImportedSleepBounds: Bool,
        adoptImportedAnalysis: Bool,
        from imported: HRVSession,
        to existing: inout HRVSession
    ) {
        existing.rrSeries = RRSeries(points: mergedPoints, sessionId: existing.id, startDate: existing.startDate)
        existing.dataSourceSummary = summary
        if adoptImportedSleepBounds {
            existing.sleepStartMs = imported.sleepStartMs ?? existing.sleepStartMs
            existing.sleepEndMs = imported.sleepEndMs ?? existing.sleepEndMs
        }
        existing.artifactFlags = nil
        adoptAnalysis(adoptImportedAnalysis, from: imported, to: &existing)
    }

    /// The analysis result and the frozen score triple move together.
    private static func adoptAnalysis(
        _ shouldAdopt: Bool, from imported: HRVSession, to existing: inout HRVSession
    ) {
        guard shouldAdopt else { return }
        existing.analysisResult = imported.analysisResult
        adoptFrozenScore(from: imported, to: &existing)
    }

    /// Adopt the imported session's frozen SCORE TRIPLE as a unit.
    /// `recoveryScore`, `scoreBreakdown`, and `frozenReadiness` are written
    /// together at freeze time (§13.3 integrity contract) and must move
    /// together — copying the headline `recoveryScore` alone leaves the detail
    /// card's breakdown and the training-readiness number contradicting the
    /// new headline. Additive: only invoked where the merge already decided
    /// to adopt the imported score.
    private static func adoptFrozenScore(from imported: HRVSession, to existing: inout HRVSession) {
        existing.recoveryScore = imported.recoveryScore
        existing.scoreBreakdown = imported.scoreBreakdown
        existing.frozenReadiness = imported.frozenReadiness
    }
}
