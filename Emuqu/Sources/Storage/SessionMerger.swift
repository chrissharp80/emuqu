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
        /// The start of the clock both sessions are moved onto before an RR
        /// change is applied: the earlier of the two starts. Nil when no RR
        /// change is made, and the existing session keeps its own clock.
        var clockStart: Date?
        /// The two series are separate recordings of one sleep, not copies of
        /// one recording: the merged sleep runs from the earlier sleep start
        /// to the later sleep end.
        var spansBothSleeps = false
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
    ///
    /// Both sessions are first moved onto one clock, starting at the earlier
    /// start, so a beat keeps its real time whichever recording it came from.
    /// Whether two recordings should be merged at all is the caller's
    /// decision (`relation(of:to:mergeGap:)`): this combines whatever it is
    /// given.
    static func mergeSessionData(from imported: HRVSession, into existing: inout HRVSession) -> Bool {
        let outcome = Self.mergeOutcome(imported: imported, existing: existing)
        Self.apply(outcome, from: imported, to: &existing)
        return outcome.hasChanges
    }

    // MARK: Pure decision core

    /// Compute the full merge decision from immutable snapshots. Pure:
    /// no mutation, no I/O, deterministic for the same pair of sessions.
    static func mergeOutcome(imported: HRVSession, existing: HRVSession) -> MergeOutcome {
        let clockStart = commonClockStart(of: imported, and: existing)
        var outcome = rrOutcome(
            imported: onClock(imported, startingAt: clockStart),
            existing: onClock(existing, startingAt: clockStart)
        )
        if outcome.rrChange != nil {
            outcome.clockStart = clockStart
            outcome.spansBothSleeps = !overlaps(span(of: imported), span(of: existing))
        }
        decideMetadataFills(imported: imported, existing: existing, into: &outcome)
        return outcome
    }

    /// Metadata fills. RR decisions never touch tags/notes/importedMetrics,
    /// so deciding from the pre-merge snapshot is safe.
    private static func decideMetadataFills(
        imported: HRVSession, existing: HRVSession, into outcome: inout MergeOutcome
    ) {
        let existingTagIds = Set(existing.tags.map(\.id))
        outcome.tagsToAppend = imported.tags.filter { !existingTagIds.contains($0.id) }
        if let importedNotes = imported.notes, !importedNotes.isEmpty, (existing.notes ?? "").isEmpty {
            outcome.adoptNotes = true
        }
        if existing.importedMetrics == nil, imported.importedMetrics != nil {
            outcome.adoptImportedMetrics = true
        }
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

    /// Whichever series is streaming plays the streaming role in the merge and
    /// adds only the beats the device recording lacks; with both or neither
    /// streaming, the larger series is treated as the internal one.
    private static func mergePoints(
        importedPoints: [RRPoint], existingPoints: [RRPoint],
        existingIsStreaming: Bool, importedIsStreaming: Bool
    ) -> [RRPoint] {
        if existingIsStreaming, !importedIsStreaming {
            return DataSourceSelector.mergeAddingOnlyUncoveredBeats(internal: importedPoints, streaming: existingPoints)
        }
        if importedIsStreaming, !existingIsStreaming {
            return DataSourceSelector.mergeAddingOnlyUncoveredBeats(internal: existingPoints, streaming: importedPoints)
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
        if let clockStart = outcome.clockStart {
            existing = onClock(existing, startingAt: clockStart)
            let importedOnClock = onClock(imported, startingAt: clockStart)
            existing.endDate = [existing.endDate, importedOnClock.endDate].compactMap { $0 }.max()
            applyRRChange(outcome, from: importedOnClock, to: &existing)
        } else {
            applyRRChange(outcome, from: imported, to: &existing)
        }
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
            applySleepBounds(
                adoptImported: adoptImportedSleepBounds, spanBoth: outcome.spansBothSleeps,
                from: imported, to: &existing
            )
            applyComposite(
                mergedPoints: mergedPoints, summary: summary,
                adoptImportedAnalysis: adoptImportedAnalysis,
                from: imported, to: &existing
            )
        case let .adoptImportedSeries(adoptImportedAnalysis):
            applyImportedSeries(adoptImportedAnalysis, from: imported, to: &existing)
        case nil:
            applyFills(outcome, from: imported, to: &existing)
        }
    }

    /// No RR change: fill the analysis and score the existing session lacks.
    /// The imported analysis's times are re-counted from the existing start.
    private static func applyFills(
        _ outcome: MergeOutcome, from imported: HRVSession, to existing: inout HRVSession
    ) {
        if outcome.adoptAnalysisResult {
            let offsetMs = MillisecondOffset.between(imported.startDate, and: existing.startDate, fallback: 0)
            existing.analysisResult = imported.analysisResult.map { shifted($0, by: offsetMs) }
        }
        if outcome.adoptRecoveryScore {
            adoptFrozenScore(from: imported, to: &existing)
        }
    }

    /// The existing session had no beats of its own — take the imported
    /// series and everything derived from it. The series is filed under the
    /// existing session's id; both are already on one clock.
    private static func applyImportedSeries(
        _ adoptImportedAnalysis: Bool, from imported: HRVSession, to existing: inout HRVSession
    ) {
        existing.rrSeries = imported.rrSeries.map {
            RRSeries(points: $0.points, sessionId: existing.id, startDate: existing.startDate)
        }
        existing.artifactFlags = imported.artifactFlags
        existing.dataSourceSummary = imported.dataSourceSummary
        existing.sleepStartMs = imported.sleepStartMs
        existing.sleepEndMs = imported.sleepEndMs
        adoptAnalysis(adoptImportedAnalysis, from: imported, to: &existing)
    }

    /// Sleep bounds after a composite. A streamed copy takes the strap
    /// file's bounds; two segments of one sleep run from the earlier sleep
    /// start to the later sleep end. Both sessions are on one clock.
    private static func applySleepBounds(
        adoptImported: Bool, spanBoth: Bool, from imported: HRVSession, to existing: inout HRVSession
    ) {
        if spanBoth {
            existing.sleepStartMs = [existing.sleepStartMs, imported.sleepStartMs].compactMap { $0 }.min()
            existing.sleepEndMs = [existing.sleepEndMs, imported.sleepEndMs].compactMap { $0 }.max()
        } else if adoptImported {
            existing.sleepStartMs = imported.sleepStartMs ?? existing.sleepStartMs
            existing.sleepEndMs = imported.sleepEndMs ?? existing.sleepEndMs
        }
    }

    /// Artifact flags are cleared: they index the pre-merge series and would
    /// mislabel beats in the composite one. The analysis kept, whichever side
    /// it came from, has its window re-pointed at the same beats in the
    /// composite.
    private static func applyComposite(
        mergedPoints: [RRPoint],
        summary: HRVSession.DataSourceSummary,
        adoptImportedAnalysis: Bool,
        from imported: HRVSession,
        to existing: inout HRVSession
    ) {
        let existingPoints = existing.rrSeries?.points ?? []
        let importedPoints = imported.rrSeries?.points ?? []
        existing.rrSeries = RRSeries(points: mergedPoints, sessionId: existing.id, startDate: existing.startDate)
        existing.dataSourceSummary = summary
        existing.artifactFlags = nil
        existing.autoWindowResult = existing.autoWindowResult.map {
            reindexed($0, from: existingPoints, onto: mergedPoints)
        }
        adoptAnalysis(adoptImportedAnalysis, from: imported, to: &existing)
        let analysisSource = adoptImportedAnalysis ? importedPoints : existingPoints
        existing.analysisResult = existing.analysisResult.map {
            reindexed($0, from: analysisSource, onto: mergedPoints)
        }
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
