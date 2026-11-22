import Foundation

// Which reading holds a night's slot in the baseline: the one-per-night
// merge and the window-quality rules it replaces a stored reading by.
// `mergeIntoNight` (and the `BaselineDataPoint` it takes) is internal rather
// than `private` because Swift's `private` does not reach across files; the
// rules it calls stay `private` to this file.

extension BaselineTracker {
    /// One reading per night, keyed by the night's wake date
    /// (`SleepSchedule.nightKey`), not the calendar day: a night started at
    /// 23:30 and its 00:30 continuation share a slot, and two different
    /// nights never do. A newer reading of the session already in the slot
    /// takes it outright (`isSameSession`): it is that session's current
    /// analysis, not a rival. Otherwise a morning reading always beats a
    /// non-morning one, and the newcomer has to have earned the slot
    /// outright. Static, over the `nights` it is given, so the stored
    /// baseline and `baselineRMSSDs` apply the one rule.
    static func mergeIntoNight(
        _ dataPoint: BaselineDataPoint, into nights: inout [BaselineDataPoint], sleepSchedule: SleepSchedule
    ) {
        let night = sleepSchedule.nightKey(for: dataPoint.date)
        guard let existingIndex = nights.firstIndex(
            where: { sleepSchedule.nightKey(for: $0.date) == night }
        ) else {
            nights.append(dataPoint)
            return
        }
        if isSameSession(nights[existingIndex], dataPoint)
            || shouldReplace(nights[existingIndex], with: dataPoint, sleepSchedule: sleepSchedule) {
            nights[existingIndex] = dataPoint
        }
    }

    /// Whether two points are readings of one session: the same session id,
    /// or the same start when either was saved before ids were recorded.
    private static func isSameSession(_ stored: BaselineDataPoint, _ incoming: BaselineDataPoint) -> Bool {
        guard let storedId = stored.sessionId, let incomingId = incoming.sessionId else {
            return stored.date == incoming.date
        }
        return storedId == incomingId
    }

    private static func shouldReplace(
        _ existing: BaselineDataPoint,
        with dataPoint: BaselineDataPoint,
        sleepSchedule: SleepSchedule
    ) -> Bool {
        let isMorningReading = sleepSchedule.isMorningReading(endDate: dataPoint.endDate ?? dataPoint.date)
        let existingIsMorning = sleepSchedule.isMorningReading(endDate: existing.endDate ?? existing.date)
        // A morning reading always wins over a non-morning one, in either
        // direction. Like-for-like, the new window must be objectively better —
        // it has to have earned the right, i.e. would have won window selection.
        if isMorningReading != existingIsMorning { return isMorningReading }
        return newWindowIsObjectivelyBetter(new: dataPoint, existing: existing)
    }

    /// Determine if new window is objectively better than existing window
    /// New window must have "earned the right" to replace - would have won window selection
    /// - Parameters:
    ///   - new: New data point candidate
    ///   - existing: Existing data point currently in baseline
    /// - Returns: True if new window is objectively superior and should replace existing
    private static func newWindowIsObjectivelyBetter(new: BaselineDataPoint, existing: BaselineDataPoint) -> Bool {
        if let verdict = consolidationVerdict(new: new, existing: existing) { return verdict }
        if let verdict = organizedRecoveryVerdict(new: new, existing: existing) { return verdict }
        if !passesQualityGates(new: new, existing: existing) { return false }
        return isMeaningfullyBetterScore(new: new, existing: existing)
    }

    /// 1. Consolidated windows take priority over non-consolidated: a true
    /// consolidated recovery (sustained plateau + stable HR) beats a spike.
    /// Nil means consolidation didn't decide it.
    private static func consolidationVerdict(new: BaselineDataPoint, existing: BaselineDataPoint) -> Bool? {
        let newScore = new.readinessScore ?? 0
        let existingScore = existing.readinessScore ?? 0
        let newConsolidated = new.isConsolidated ?? false
        let existingConsolidated = existing.isConsolidated ?? false
        if existingConsolidated, !newConsolidated {
            // New must have SIGNIFICANTLY higher readiness to replace (>15% better).
            let threshold = existingScore * BaselineConstants.consolidatedReplacementFraction
            debugLog("[Baseline] New window not consolidated vs existing consolidated - requires >15% score improvement")
            return newScore - existingScore > threshold
        }
        // Consolidated wins if the score is close (within 10% or better).
        if newConsolidated, !existingConsolidated,
           newScore >= existingScore * BaselineConstants.consolidatedAdvantageFraction {
            debugLog("[Baseline] New window is consolidated vs existing non-consolidated - replacing")
            return true
        }
        return nil
    }

    /// 2. With consolidation equal, organized recovery (DFA α1 0.75-1.0) is the
    /// critical readiness signal. Nil means it didn't decide it.
    private static func organizedRecoveryVerdict(new: BaselineDataPoint, existing: BaselineDataPoint) -> Bool? {
        guard (new.isConsolidated ?? false) == (existing.isConsolidated ?? false) else { return nil }
        let newOrganized = new.isOrganizedRecovery ?? false
        let existingOrganized = existing.isOrganizedRecovery ?? false
        if existingOrganized, !newOrganized {
            debugLog("[Baseline] New window lacks organized recovery vs existing organized - rejecting")
            return false
        }
        // Strong advantage: within 5% or better is enough.
        if newOrganized, !existingOrganized,
           (new.readinessScore ?? 0) >= (existing.readinessScore ?? 0) * BaselineConstants.organizedRecoveryAdvantageFraction {
            debugLog("[Baseline] New window has organized recovery vs existing unorganized - replacing")
            return true
        }
        return nil
    }

    /// 3-4. Quality control: artifact rate and HR stability must not be
    /// meaningfully worse than what is already in the baseline.
    private static func passesQualityGates(new: BaselineDataPoint, existing: BaselineDataPoint) -> Bool {
        let newArtifacts = new.artifactPercentage ?? 100.0
        let existingArtifacts = existing.artifactPercentage ?? 100.0

        // Use a floor so that near-zero baselines don't reject excellent-quality windows.
        // Without this, an existing 0.0% baseline rejects any non-zero rate (e.g. 0.5%).
        let artifactCeiling = max(existingArtifacts * BaselineConstants.artifactCeilingMultiplier, BaselineConstants.artifactCeilingFloor)
        if newArtifacts > artifactCeiling {
            // New window has significantly more artifacts
            debugLog("[Baseline] New window has high artifact rate (\(String(format: "%.1f", newArtifacts))% vs \(String(format: "%.1f", existingArtifacts))%, ceiling \(String(format: "%.1f", artifactCeiling))%) - rejecting")
            return false
        }

        return hrStabilityAcceptable(new: new, existing: existing)
    }

    /// Lower CV is better. A window more than 30% less stable than the one it
    /// would replace is rejected.
    private static func hrStabilityAcceptable(new: BaselineDataPoint, existing: BaselineDataPoint) -> Bool {
        guard let newStability = new.windowHRStability,
              let existingStability = existing.windowHRStability else { return true }
        guard newStability > existingStability * BaselineConstants.hrStabilityRejectMultiplier else { return true }
        debugLog("[Baseline] New window has poor HR stability (CV \(String(format: "%.3f", newStability)) vs \(String(format: "%.3f", existingStability))) - rejecting")
        return false
    }

    /// 5. Both windows have similar quality characteristics by now, so the new
    /// one must be meaningfully better (>5% improvement minimum).
    private static func isMeaningfullyBetterScore(new: BaselineDataPoint, existing: BaselineDataPoint) -> Bool {
        let newScore = new.readinessScore ?? 0
        let existingScore = existing.readinessScore ?? 0
        let scoreDelta = newScore - existingScore
        let minImprovement = existingScore * BaselineConstants.minimumImprovementFraction // 5% minimum improvement

        if scoreDelta > minImprovement {
            debugLog("[Baseline] New window is objectively better - score improvement: \(String(format: "%.1f", scoreDelta)) (>\(String(format: "%.1f", minImprovement)) threshold)")
            return true
        } else {
            debugLog("[Baseline] New window does not meet improvement threshold - delta: \(String(format: "%.1f", scoreDelta)), need: >\(String(format: "%.1f", minImprovement))")
            return false
        }
    }
}
