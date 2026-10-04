import Foundation

/// The decision layer behind automatic sleep refresh, lifted out of
/// `RRCollector`.
///
/// Every function here is pure — a session and a `SleepData` in, a verdict or
/// a mutated copy out — and lives here rather than as `private static`
/// members of the collector so tests can reach them. They encode the
/// answers to three questions that have each been the subject of a production
/// bug:
///
///  * may this session's sleep be refreshed at all (user edits);
///  * is the fresh HealthKit data actually an improvement, and does it move
///    the scoring window enough to justify a rescore (onset move
///    and source upgrade);
///  * when applying it, what has to change besides the display snapshot
///    (the ms boundaries WindowSelection actually scores from).
enum SleepRefreshPolicy {
    /// Honor user timeline edits (FLOWCHART §13.2/§14:
    /// user edits are the source of truth). Every other automatic
    /// sleep path has this guard (`ReanalysisService.reanalyzeSession`
    /// and the `updateSessionSleepBoundaries` non-user branch);
    /// without it here, the next HK sleep sample arrival after
    /// a manual edit silently rewrites the snapshot — the user's corrected
    /// boundary reverts to the bogus 8 PM iPhone-guess start same-day,
    /// every day. Worse, when the edit had saved a smaller total than
    /// HK's interpretation, the `newMinutes > priorMinutes` improvement
    /// gate was trivially satisfied, making the overwrite guaranteed.
    ///
    /// The `sleepSnapshot != nil` clause: CloudKit uploads strip
    /// HK-derived snapshots (Guideline 5.1.3), so a user-adjusted
    /// session pulled onto a second device arrives flag=true,
    /// snapshot=nil. First-fill of the snapshot from that device's own
    /// HealthKit is allowed (`applyAutoRefresh` keeps the user's synced
    /// boundaries and the verdict asks for no rescore); OVERWRITING an
    /// existing user-edited snapshot is blocked.
    static func autoSleepRefreshAllowed(for session: HRVSession) -> Bool {
        guard session.sleepUserAdjusted != true || session.sleepSnapshot == nil else {
            debugLog("[AutoRescore.sleep] skipped — session \(session.id.uuidString.prefix(8)) has user-adjusted sleep")
            return false
        }
        return true
    }

    /// What the improvement / rescore gates decided, plus the numbers the log
    /// lines quote.
    struct SleepRefreshVerdict {
        let shouldUpdate: Bool
        let needsRescore: Bool
        let priorMinutes: Int
        let newMinutes: Int
        let delta: Int
        let endMovedLater: Bool
        let firstSnapshot: Bool
        let onsetMovedMin: Int
        let onsetMovedMaterially: Bool
        let sourceUpgradedToWatch: Bool
    }

    /// ONSET-MOVE + SOURCE-UPGRADE gating (per Chris: once Apple
    /// Watch sleep syncs it should always win). Gates keyed ONLY on
    /// total sleep MINUTES (delta ≥ 20) and a later end are not enough: an HR-estimated
    /// onset is systematically MIS-TIMED — HR reaches its nadir ~an hour after
    /// true sleep onset, so an HR-drop threshold fires late — and Apple's data
    /// often lands with a similar TOTAL but a very different ONSET (e.g. HR
    /// guessed onset 117 min in; Apple: 5 min). Same total → both the update
    /// gate and the rescore gate skipped, so the recovery SCORE stayed computed
    /// from the bogus HR window even after the sleep card corrected. Since
    /// WindowSelection places the 30–70% HRV band inside [sleepStart, sleepEnd],
    /// a moved onset changes the score. So we also act on a material onset move,
    /// and ALWAYS act when the boundary source upgrades from an HR estimate to
    /// an Apple/HealthKit-based source.
    ///
    /// The improvement gate (inherited from the dashboard's old sleep-refresh) passes
    /// on a material onset move or a source upgrade too, not just more/later
    /// sleep, so Apple's corrected window isn't discarded when the total matches.
    /// Rescore fires when the scoring WINDOW moved enough to change the score:
    /// total delta ≥ 20 min, a material onset shift, OR a source upgrade from an
    /// HR guess to Apple (the last always rescores — Apple's authoritative window
    /// must replace the estimate's, regardless of total minutes).
    static func sleepRefreshVerdict(
        session: HRVSession,
        fresh: SleepData
    ) -> SleepRefreshVerdict {
        let priorMinutes = session.sleepSnapshot?.nightSleepMinutes ?? 0
        let newMinutes = fresh.nightSleepMinutes
        let priorEnd = session.sleepSnapshot?.sleepEnd ?? .distantPast
        let endMovedLater = (fresh.sleepEnd ?? .distantPast).timeIntervalSince(priorEnd) > 60
        let firstSnapshot = priorMinutes == 0
        let onsetMovedMin = onsetMoveMinutes(session: session, fresh: fresh)
        let onsetMovedMaterially = onsetMovedMin >= 15 // beyond typical SOL; shifts the HRV band
        let sourceUpgradedToWatch = isSourceUpgradeToWatch(session: session, fresh: fresh)
        let delta = abs(newMinutes - priorMinutes)
        return SleepRefreshVerdict(
            shouldUpdate: firstSnapshot || endMovedLater || newMinutes > priorMinutes
                || onsetMovedMaterially || sourceUpgradedToWatch,
            needsRescore: firstSnapshot || delta >= 20 || onsetMovedMaterially || sourceUpgradedToWatch,
            priorMinutes: priorMinutes, newMinutes: newMinutes, delta: delta,
            endMovedLater: endMovedLater, firstSnapshot: firstSnapshot,
            onsetMovedMin: onsetMovedMin, onsetMovedMaterially: onsetMovedMaterially,
            sourceUpgradedToWatch: sourceUpgradedToWatch
        )
    }

    static func onsetMoveMinutes(session: HRVSession, fresh: SleepData) -> Int {
        guard let prior = session.sleepStartMs,
              let freshStart = fresh.sleepStart
        else { return 0 }
        let newStartMs = max(0, MillisecondOffset.between(freshStart, and: session.startDate, fallback: 0))
        return Int(abs(newStartMs - prior) / 60_000)
    }

    static func isSourceUpgradeToWatch(session: HRVSession, fresh: SleepData) -> Bool {
        let priorSource = session.sleepSnapshot?.boundarySource
        let priorWasEstimate = priorSource == nil
            || priorSource == .hrEstimated
            || priorSource == .healthKitHREstimated
            || priorSource == .recordingBounds
        let newIsWatchBased = fresh.boundarySource == .healthKit || fresh.boundarySource == .hrValidated
        return newIsWatchBased && priorWasEstimate
    }

    /// Apply an automatic refresh. A user-adjusted night (reaching here only
    /// with no snapshot, on a second device) gets the snapshot filled but
    /// keeps the boundaries and segments the user edited, which sync — so
    /// the caller does not rescore it: its scoring window did not move.
    static func applyAutoRefresh(_ fresh: SleepData, to session: inout HRVSession) {
        if session.sleepUserAdjusted == true {
            applyPulledSleep(fresh, to: &session)
        } else {
            applyFreshSleep(fresh, to: &session)
        }
    }

    /// The snapshot is always updated when the new data is an improvement —
    /// even if the rescore threshold isn't met, the displayed sleep should
    /// reflect what HK actually has.
    ///
    /// CRITICAL: also update the ms boundaries + segments, not
    /// just the snapshot. `sleepStartMs`/`sleepEndMs` are what WindowSelection
    /// reads to pick the 30-70% HRV band and score the night; the snapshot is
    /// display-only. Updating just the snapshot leaves the
    /// rescore scoring against the STALE HR-estimated window while the sleep
    /// card shows the corrected Apple data — when Apple Watch sleep synced
    /// ~90s LATE and this auto-rescore fired, the display corrected to 343 min
    /// but the score was still computed from a bogus "117 min awake" onset.
    /// Mirrors `ReanalysisService.updateSessionSleepBoundaries`.
    static func applyFreshSleep(_ fresh: SleepData, to session: inout HRVSession) {
        session.sleepSnapshot = fresh
        if let freshStart = fresh.sleepStart {
            session.sleepStartMs = max(0, MillisecondOffset.between(freshStart, and: session.startDate, fallback: 0))
        }
        if let freshEnd = fresh.sleepEnd {
            session.sleepEndMs = MillisecondOffset.between(freshEnd, and: session.startDate, fallback: 0)
        }
        // A single-segment night drops any older multi-segment array so it
        // can't disagree with the snapshot just written.
        guard fresh.segments.count > 1 else {
            session.sleepSegments = nil
            return
        }
        session.sleepSegments = fresh.segments.map { seg in
            HRVSession.SleepSegmentMs(
                startMs: MillisecondOffset.between(seg.sleepStart, and: session.startDate, fallback: 0),
                endMs: MillisecondOffset.between(seg.sleepEnd, and: session.startDate, fallback: 0)
            )
        }
    }

    /// Keep the scoring boundaries consistent with the snapshot we
    /// just wrote, but ONLY fill them when currently nil — never
    /// overwrite real boundaries and never recompute the frozen score.
    /// Prevents the "display snapshot present, scoring window
    /// nil/stale" divergence on CloudKit-pulled sessions.
    static func applyPulledSleep(_ resolvedSleep: SleepData, to session: inout HRVSession) {
        session.sleepSnapshot = resolvedSleep
        if session.sleepStartMs == nil, let s = resolvedSleep.sleepStart {
            session.sleepStartMs = max(0, MillisecondOffset.between(s, and: session.startDate, fallback: 0))
        }
        if session.sleepEndMs == nil, let e = resolvedSleep.sleepEnd {
            session.sleepEndMs = MillisecondOffset.between(e, and: session.startDate, fallback: 0)
        }
    }
}
