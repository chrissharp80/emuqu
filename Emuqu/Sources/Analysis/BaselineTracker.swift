import Foundation

/// Personal baseline tracking for multi-night HRV trends
/// Per design spec v8.1: Rolling 7-day baseline with deviation tracking
///
/// # Concurrency contract
///
/// **All current callers are `@MainActor`-isolated** (RRCollector and its
/// extensions, the dashboard). The class is NOT marked `@MainActor`
/// so it can be future-proofed for background callers (e.g. session
/// rebuild from a detached migration task). The `NSRecursiveLock` below
/// is what protects mutable state for that future-cross-thread scenario
/// — every public accessor that reads or writes `currentBaseline` /
/// `historicalData` MUST acquire `lock` first.
///
/// **`@unchecked Sendable`** acknowledges the lock-protected design.
/// Without it, Swift 6 strict-concurrency would refuse to pass a
/// BaselineTracker instance across actor boundaries. The "unchecked"
/// label is honest: the compiler isn't verifying the lock discipline;
/// the maintainer is.
///
/// If you add a new mutating method, follow the pattern of `update(with:)`
/// — acquire `lock`, mutate, release. If you add a new reader, follow
/// `baseline` — `lock.lock(); defer { lock.unlock() }`.
/// Do NOT release the lock and then re-touch the protected state.
final class BaselineTracker: @unchecked Sendable {
    // MARK: - Types

    /// Personal baseline snapshot
    struct Baseline: Codable {
        let date: Date
        let rmssd: Double
        let sdnn: Double
        let meanHR: Double
        let hf: Double?
        let lf: Double?
        let lfHfRatio: Double?
        let dfaAlpha1: Double?
        let stressIndex: Double?
        let readinessScore: Double?
        let sampleCount: Int

        /// Minimum samples required for valid baseline
        static let minimumSamples = 3
    }

    /// Deviation from baseline for a single session
    struct BaselineDeviation: Codable {
        let rmssdDeviation: Double? // Percentage deviation
        let sdnnDeviation: Double?
        let meanHRDeviation: Double?
        let hfDeviation: Double?
        let lfHfDeviation: Double?
        let stressDeviation: Double?
        let readinessDeviation: Double?
    }

    /// Statistics for z-score based recovery scoring (Plews et al., Buchheit 2014)
    /// Uses ln(RMSSD) for normalization as per evidence base
    struct RecoveryBaselineStats {
        /// Mean of ln(RMSSD) over the rolling window (up to the last 60 stored
        /// nights — a count of nights, not a 60-day date window)
        let lnRmssdMean: Double
        /// Standard deviation of ln(RMSSD) over the rolling window
        let lnRmssdSD: Double
        /// Coefficient of variation of 7-day ln(RMSSD) (reduced CV signals overreaching)
        let lnRmssdCV7Day: Double?
        /// Mean resting HR over the rolling window (for RHR z-score adjustment)
        let meanHRBaseline: Double
        /// SD of resting HR over the rolling window
        let meanHRSD: Double
        /// Number of days in the rolling window
        let daysInWindow: Int
        /// Date of the most recent data point in the baseline window.
        /// Used to detect stale baselines (no sessions for 7+ days).
        var lastDataPointDate: Date?

        /// Minimum number of days required for valid z-score computation.
        /// Aligned with the trend analysis baseline (which also needs 3 sessions)
        /// so users see consistent baseline status across the app.
        /// Z-scores are less precise with few data points but improve as data accumulates.
        static let minimumDays = 3
    }

    /// Callback invoked when baseline changes — wired by the boundary layer
    /// to sync back to SettingsManager (or whatever display layer needs it).
    typealias BaselineUpdater = (_ rmssd: Double, _ hr: Double) -> Void

    // MARK: - Storage

    private let baselineFile: URL
    private var currentBaseline: Baseline?
    private var historicalData: [BaselineDataPoint] = []
    private let fileManager = FileManager.default
    private let lock = NSRecursiveLock()
    private let onBaselineUpdated: BaselineUpdater?

    /// Data point for baseline calculation
    private struct BaselineDataPoint: Codable {
        /// Session start. The night slot is derived from it.
        let date: Date
        /// Session end, for the morning-reading rule. Nil on points saved
        /// before it was recorded; those fall back to `date`.
        let endDate: Date?
        let rmssd: Double
        let sdnn: Double
        let meanHR: Double
        let hf: Double?
        let lf: Double?
        let lfHfRatio: Double?
        let dfaAlpha1: Double?
        let stressIndex: Double?
        let readinessScore: Double?

        // Window quality metrics (for replacement decisions)
        let isConsolidated: Bool?
        let isOrganizedRecovery: Bool?
        let windowHRStability: Double?
        let artifactPercentage: Double?
    }

    private struct StoredData: Codable {
        var baseline: Baseline?
        var historicalData: [BaselineDataPoint]
    }

    // MARK: - Configuration

    /// Rolling window for baseline calculation (days)
    /// 7-day rolling ln(RMSSD) baseline; collapsing CV = non-functional
    /// overreaching — Plews, Laursen, Buchheit et al., Sports Med 2013;43:773-781;
    /// Eur J Appl Physiol 2012;112:3729.
    static let baselineWindowDays = 7

    /// Maximum historical points to store (limit storage growth)
    static let maxHistoricalPoints = 90

    // MARK: - Initialization

    /// - Parameter onBaselineUpdated: Callback invoked with (rmssd, hr) whenever the
    ///   baseline changes. The caller wires this to SettingsManager or any display layer.
    ///   Passing nil disables sync (useful in tests).
    init(onBaselineUpdated: BaselineUpdater? = nil) {
        self.onBaselineUpdated = onBaselineUpdated
        // Try App Group container first, fall back to Documents
        let container = AppConfig.sharedContainerURL()
        baselineFile = container.appendingPathComponent("HRVBaseline.json")
        debugLog("[Baseline] Using container: \(container.path)")
        load()
        // Sync loaded baseline on startup
        notifyBaselineChanged()
        debugLog("[Baseline] Loaded \(historicalData.count) data points, baseline: \(currentBaseline != nil ? "available" : "not yet established")")
    }

    // MARK: - Public API

    /// Get current baseline
    var baseline: Baseline? {
        lock.lock()
        defer { lock.unlock() }
        return currentBaseline
    }

    /// Check if baseline is established (minimum samples collected)
    var hasValidBaseline: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let baseline = currentBaseline else { return false }
        return baseline.sampleCount >= Baseline.minimumSamples
    }

    /// Days of data collected
    var daysCollected: Int {
        lock.lock()
        defer { lock.unlock() }
        return historicalData.count
    }

    /// Compute recovery baseline stats for z-score scoring
    /// Uses ln(RMSSD) from up to the last 60 stored nights (by count, not a
    /// date window) per Plews/Buchheit methodology.
    /// Every stored night is included, so this is the baseline to SHOW. To
    /// SCORE a night, use `recoveryBaselineStats(excludingNightOf:sleepSchedule:)`,
    /// which reads only the nights before it.
    var recoveryBaselineStats: RecoveryBaselineStats? {
        lock.lock()
        defer { lock.unlock() }
        return stats(from: historicalData)
    }

    /// Baseline stats to score `session` against: the stored nights BEFORE
    /// the one the session belongs to. Once a night is accepted its reading
    /// sits in the baseline, and scoring it against itself pulls the z-score
    /// toward zero. The cited method compares a day's value with a reference
    /// built from earlier days only (Kiviniemi 2007: "ten earlier
    /// measurements"; Plews 2013 / Buchheit 2014: SWC from the preceding
    /// baseline), so re-scoring an old night must not read the nights after
    /// it either. On the live morning path there are no later nights, so this
    /// is every stored night except tonight.
    func recoveryBaselineStats(
        excludingNightOf session: HRVSession,
        sleepSchedule: SleepSchedule
    ) -> RecoveryBaselineStats? {
        lock.lock()
        defer { lock.unlock() }
        let night = sleepSchedule.nightKey(for: session.startDate)
        return stats(from: historicalData.filter { sleepSchedule.nightKey(for: $0.date) < night })
    }

    /// The 60 most recent points, or nil below `minimumDays`.
    private func stats(from points: [BaselineDataPoint]) -> RecoveryBaselineStats? {
        guard points.count >= RecoveryBaselineStats.minimumDays else { return nil }
        let recentData = Array(points.suffix(60))
        let lnValues = lnRmssdValues(recentData)
        guard lnValues.count >= RecoveryBaselineStats.minimumDays else { return nil }
        return baselineStats(recentData: recentData, lnValues: lnValues)
    }

    /// ln(RMSSD) values — zero/negative RMSSD is invalid and dropped.
    private func lnRmssdValues(_ points: [BaselineDataPoint]) -> [Double] {
        points.compactMap { point -> Double? in
            guard point.rmssd > 0 else { return nil }
            return log(point.rmssd)
        }
    }

    private func baselineStats(
        recentData: [BaselineDataPoint],
        lnValues: [Double]
    ) -> RecoveryBaselineStats {
        let lnMean = lnValues.mean
        let hrValues = recentData.map(\.meanHR)
        return RecoveryBaselineStats(
            lnRmssdMean: lnMean,
            lnRmssdSD: max(Self.widenedLnSD(lnValues), BaselineConstants.lnRmssdSDFloor), // Floor SD to prevent division by zero
            lnRmssdCV7Day: sevenDayCV(recentData),
            meanHRBaseline: hrValues.mean,
            meanHRSD: max(hrValues.sampleSD, BaselineConstants.meanHRSDFloor), // Floor SD
            daysInWindow: lnValues.count,
            lastDataPointDate: recentData.last?.date
        )
    }

    /// Sample variance (N-1) is appropriate here: we're estimating an
    /// individual's true day-to-day variability from a finite sample of 3–60
    /// nightly values. With fewer data points the estimate is noisier but improves
    /// as data accumulates.
    ///
    /// Small-sample confidence widening. z-scores
    /// become valid at `minimumDays` = 3, but with only 3–4 similar nights the
    /// sample SD can collapse toward the 0.10 floor (`lnRmssdSDFloor`), and dividing a real
    /// ln(RMSSD) deviation by a near-zero SD yields a huge |z| → bang-bang 0/100
    /// scores that swing wildly night to night before the baseline has
    /// stabilised. Rather than raise `minimumDays` toward 7 (which would
    /// withhold ANY score for the first week and regress the cold-start
    /// experience), we keep the score available but WIDEN the effective SD when
    /// the window is short — inflating the denominator shrinks |z| toward 0,
    /// pulling early scores toward the neutral middle until enough nights
    /// accumulate to trust the spread. The factor is 1.0 once the window reaches
    /// the 7-day baseline length and grows as the count drops below it (≈1.53× at
    /// 3 days), decaying smoothly. This is the standard "shrink toward the prior
    /// under low confidence" treatment and is cheaper and less disruptive than
    /// gating the score.
    /// `static` and `internal` so `DailyLoopAnalysis` can use the SAME
    /// estimator rather than its own un-widened SD. With three nights of
    /// data the two differ by a factor of 1.53, which is enough to push a
    /// morning the score treats as z = -0.33 — inside the Smallest
    /// Worthwhile Change band — across the daily-loop analysis's -0.5 boundary
    /// and print "below baseline" next to a score that says otherwise.
    static func widenedLnSD(_ lnValues: [Double]) -> Double {
        let confidenceFloor = Self.baselineWindowDays // 7
        let widening = lnValues.count >= confidenceFloor
            ? 1.0
            : sqrt(Double(confidenceFloor) / Double(lnValues.count))
        return lnValues.sampleSD * widening
    }

    /// 7-day CV of ln(RMSSD) — Plews: reduced CV signals overreaching.
    private func sevenDayCV(_ points: [BaselineDataPoint]) -> Double? {
        guard points.count >= 7 else { return nil }
        let ln7 = lnRmssdValues(Array(points.suffix(7)))
        guard ln7.count >= 3 else { return nil }
        return Statistics.coefficientOfVariation(ln7).map { $0 * 100.0 }
    }

    /// Rebuild baseline from archived sessions when historical data is missing
    /// (e.g. after app reinstall where sessions were restored from CloudKit but
    /// the local HRVBaseline.json was lost).
    /// - Parameters:
    ///   - sessions: Completed sessions with analysis results, sorted oldest-first
    ///   - sleepSchedule: User's sleep schedule for morning reading detection
    func rebuildFromSessions(_ sessions: [HRVSession], sleepSchedule: SleepSchedule) {
        // Mirror the reliability gate enforced in `update(with:)` so the logged
        // rebuild count reflects what actually contributes, and restored
        // archives (post-CloudKit reinstall) don't silently re-admit the same
        // bad partials the live path rejects.
        let validSessions = sessions.filter(Self.isRebuildCandidate).sorted { $0.startDate < $1.startDate }

        guard !validSessions.isEmpty else {
            debugLog("[Baseline] Rebuild: No valid sessions to rebuild from")
            return
        }

        debugLog("[Baseline] Rebuilding from \(validSessions.count) archived sessions")

        for session in validSessions {
            update(with: session, sleepSchedule: sleepSchedule)
        }

        debugLog("[Baseline] Rebuild complete: \(historicalData.count) data points, baseline: \(currentBaseline != nil ? "available" : "not yet established")")
    }

    /// Finished, analyzed, HRV-reliable overnight sessions.
    private static func isRebuildCandidate(_ session: HRVSession) -> Bool {
        session.state == .complete && session.sessionType == .overnight
            && session.analysisResult != nil && session.isReliableForHRVAggregates
    }

    /// Update baseline with new session data.
    /// Whether a session has enough structural signal to be admitted to the
    /// rolling baseline — a *different* question from whether it is worth
    /// showing the user, and deliberately answered differently.
    ///
    /// `isReliableForHRVAggregates` is derived from
    /// `hrvDataQuality`, and that classification is intentionally asymmetric:
    /// a short window whose RMSSD lands at or above baseline is still shown as
    /// a real reading (`SessionAcceptanceQualityTests` pins this deliberately,
    /// and for display it is the right call — the measurement is clean, just
    /// brief).
    ///
    /// For baseline admission that same asymmetry is actively harmful, because
    /// it is one-directional. Short windows carry the largest **positive**
    /// RMSSD sampling error, so admitting the above-baseline ones while
    /// rejecting the below-baseline ones lets in only the samples that raise
    /// `lnRmssdMean` and filters out the ones that would pull it back down.
    /// That mean anchors every future z-score, so the bias compounds: the
    /// baseline drifts upward, every later night scores lower against it, and
    /// the app reports declining recovery for a user whose physiology has not
    /// changed. It also could not self-correct, because the correcting samples
    /// are exactly the ones being excluded.
    ///
    /// Hence the split: **display stays asymmetric, aggregation is
    /// structural.** A four-minute window is not a baseline-quality
    /// measurement whichever side of the mean it happens to land on.
    static func isStructurallySoundForBaseline(
        session: HRVSession,
        result: HRVAnalysisResult
    ) -> Bool {
        if let wsMs = result.windowStartMs, let weMs = result.windowEndMs,
           (weMs - wsMs) < HRVConstants.MinimumDuration.forReliableWindowMs {
            return false
        }
        let sessionEnd = session.endDate ?? session.startDate
        let sessionDuration = sessionEnd.timeIntervalSince(session.startDate)
        if result.isOrganizedRecovery != true,
           sessionDuration < HRVConstants.MinimumDuration.forOvernightSessionSeconds {
            return false
        }
        return true
    }

    /// - Parameters:
    ///   - session: Completed session with analysis results
    ///   - sleepSchedule: User's sleep schedule (provided by caller from SettingsManager)
    /// Only overnight readings contribute, one per night.
    func update(with session: HRVSession, sleepSchedule: SleepSchedule) {
        lock.lock()
        defer { lock.unlock() }
        guard let result = session.analysisResult, admitsToBaseline(session, result: result) else { return }
        mergeIntoNight(dataPoint(session: session, result: result), sleepSchedule: sleepSchedule)
        historicalData.sort { $0.date < $1.date }
        if historicalData.count > Self.maxHistoricalPoints {
            historicalData = Array(historicalData.suffix(Self.maxHistoricalPoints))
        }
        recalculateBaseline()
        notifyBaselineChanged()
        save()
    }

    /// Three gates a session must pass to reach the baseline.
    ///
    /// Overnight only. A quick or nap reading carries no `hrvDataQuality`, so
    /// it passes the quality gate, and a daytime reading is not the resting
    /// state the baseline describes: it would lower `lnRmssdMean` and raise
    /// `meanHRBaseline`. Every cause detector already reads overnight only.
    ///
    /// Untrustworthy-HRV sessions must NEVER enter the baseline.
    /// `.insufficient` (awake / too-short partials, e.g. a pre-sleep recording
    /// paused while still up) and `.preSleep` (recording ended before sleep → the
    /// RMSSD is an awake value) both carry HRV the analyzer itself won't trust
    /// (it forces useBaselineHRV for both). Their RMSSD would be folded into
    /// `historicalData` and drag the rolling baseline down, corrupting the NEXT
    /// morning's score. This is the authoritative gate: every update path —
    /// including `rebuildFromSessions` — routes through here. See
    /// `HRVSession.isReliableForHRVAggregates`.
    ///
    /// The STRUCTURAL gate is separate from the quality flag; see
    /// `isStructurallySoundForBaseline` for why.
    private func admitsToBaseline(_ session: HRVSession, result: HRVAnalysisResult) -> Bool {
        guard session.sessionType == .overnight else {
            debugLog("[Baseline] Skipping \(session.sessionType.rawValue) session \(session.id.uuidString.prefix(8)) — only overnight readings form the baseline")
            return false
        }
        guard session.isReliableForHRVAggregates else {
            debugLog("[Baseline] Skipping \(session.hrvDataQuality.map { "\($0)" } ?? "unrated") session \(session.id.uuidString.prefix(8)) — not reliable for HRV aggregates")
            return false
        }
        guard Self.isStructurallySoundForBaseline(session: session, result: result) else {
            debugLog("[Baseline] Skipping session \(session.id.uuidString.prefix(8)) — window too short or no organized recovery")
            return false
        }
        return true
    }

    private func dataPoint(session: HRVSession, result: HRVAnalysisResult) -> BaselineDataPoint {
        BaselineDataPoint(
            date: session.startDate,
            endDate: session.endDate,
            rmssd: result.timeDomain.rmssd,
            sdnn: result.timeDomain.sdnn,
            meanHR: result.timeDomain.meanHR,
            hf: result.frequencyDomain?.hf,
            lf: result.frequencyDomain?.lf,
            lfHfRatio: result.frequencyDomain?.lfHfRatio,
            dfaAlpha1: result.nonlinear.dfaAlpha1,
            stressIndex: result.ansMetrics?.stressIndex,
            readinessScore: result.ansMetrics?.readinessScore,
            isConsolidated: result.isConsolidated,
            isOrganizedRecovery: result.isOrganizedRecovery,
            windowHRStability: result.windowHRStability,
            artifactPercentage: result.artifactPercentage
        )
    }

    /// One reading per night, keyed by the night's wake date
    /// (`SleepSchedule.nightKey`), not the calendar day: a night started at
    /// 23:30 and its 00:30 continuation share a slot, and two different
    /// nights never do. A morning reading always beats a non-morning one;
    /// otherwise the newcomer has to have earned the slot outright.
    private func mergeIntoNight(_ dataPoint: BaselineDataPoint, sleepSchedule: SleepSchedule) {
        let night = sleepSchedule.nightKey(for: dataPoint.date)
        guard let existingIndex = historicalData.firstIndex(
            where: { sleepSchedule.nightKey(for: $0.date) == night }
        ) else {
            historicalData.append(dataPoint)
            return
        }
        if shouldReplace(historicalData[existingIndex], with: dataPoint, sleepSchedule: sleepSchedule) {
            historicalData[existingIndex] = dataPoint
        }
    }

    private func shouldReplace(
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

    /// Notify the caller that the baseline changed (via injected callback).
    private func notifyBaselineChanged() {
        guard let baseline = currentBaseline, baseline.sampleCount >= Baseline.minimumSamples else {
            return
        }
        onBaselineUpdated?(baseline.rmssd, baseline.meanHR)
    }

    /// Calculate deviation from baseline for a session
    /// - Parameter session: Session to compare against baseline
    /// - Returns: Deviation metrics, or nil if no baseline
    func deviation(for session: HRVSession) -> BaselineDeviation? {
        lock.lock()
        defer { lock.unlock() }
        guard let baseline = currentBaseline,
              baseline.sampleCount >= Baseline.minimumSamples,
              let result = session.analysisResult
        else {
            return nil
        }

        return BaselineDeviation(
            rmssdDeviation: percentDeviation(current: result.timeDomain.rmssd, baseline: baseline.rmssd),
            sdnnDeviation: percentDeviation(current: result.timeDomain.sdnn, baseline: baseline.sdnn),
            meanHRDeviation: percentDeviation(current: result.timeDomain.meanHR, baseline: baseline.meanHR),
            hfDeviation: optionalPercentDeviation(current: result.frequencyDomain?.hf, baseline: baseline.hf),
            lfHfDeviation: optionalPercentDeviation(current: result.frequencyDomain?.lfHfRatio, baseline: baseline.lfHfRatio),
            stressDeviation: optionalPercentDeviation(current: result.ansMetrics?.stressIndex, baseline: baseline.stressIndex),
            readinessDeviation: optionalPercentDeviation(current: result.ansMetrics?.readinessScore, baseline: baseline.readinessScore)
        )
    }

    /// Reset baseline (start fresh)
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        currentBaseline = nil
        historicalData = []
        save()
    }

    // MARK: - Private Methods

    /// Compute the mean of values, returning nil if the array is empty.
    private func optionalMean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.mean
    }

    /// Determine if new window is objectively better than existing window
    /// New window must have "earned the right" to replace - would have won window selection
    /// - Parameters:
    ///   - new: New data point candidate
    ///   - existing: Existing data point currently in baseline
    /// - Returns: True if new window is objectively superior and should replace existing
    private func newWindowIsObjectivelyBetter(new: BaselineDataPoint, existing: BaselineDataPoint) -> Bool {
        if let verdict = consolidationVerdict(new: new, existing: existing) { return verdict }
        if let verdict = organizedRecoveryVerdict(new: new, existing: existing) { return verdict }
        if !passesQualityGates(new: new, existing: existing) { return false }
        return isMeaningfullyBetterScore(new: new, existing: existing)
    }

    /// 1. Consolidated windows take priority over non-consolidated: a true
    /// consolidated recovery (sustained plateau + stable HR) beats a spike.
    /// Nil means consolidation didn't decide it.
    private func consolidationVerdict(new: BaselineDataPoint, existing: BaselineDataPoint) -> Bool? {
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
    private func organizedRecoveryVerdict(new: BaselineDataPoint, existing: BaselineDataPoint) -> Bool? {
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
    private func passesQualityGates(new: BaselineDataPoint, existing: BaselineDataPoint) -> Bool {
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
    private func hrStabilityAcceptable(new: BaselineDataPoint, existing: BaselineDataPoint) -> Bool {
        guard let newStability = new.windowHRStability,
              let existingStability = existing.windowHRStability else { return true }
        guard newStability > existingStability * BaselineConstants.hrStabilityRejectMultiplier else { return true }
        debugLog("[Baseline] New window has poor HR stability (CV \(String(format: "%.3f", newStability)) vs \(String(format: "%.3f", existingStability))) - rejecting")
        return false
    }

    /// 5. Both windows have similar quality characteristics by now, so the new
    /// one must be meaningfully better (>5% improvement minimum).
    private func isMeaningfullyBetterScore(new: BaselineDataPoint, existing: BaselineDataPoint) -> Bool {
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

    private func recalculateBaseline() {
        guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -Self.baselineWindowDays, to: Date()) else {
            currentBaseline = nil
            return
        }
        let recentData = historicalData.filter { $0.date >= cutoffDate }
        guard !recentData.isEmpty else { return currentBaseline = nil }
        currentBaseline = Baseline(
            date: Date(),
            rmssd: Self.geometricMeanRMSSD(of: recentData),
            sdnn: recentData.map(\.sdnn).mean, meanHR: recentData.map(\.meanHR).mean,
            hf: optionalMean(recentData.compactMap(\.hf)),
            lf: optionalMean(recentData.compactMap(\.lf)),
            lfHfRatio: optionalMean(recentData.compactMap(\.lfHfRatio)),
            dfaAlpha1: optionalMean(recentData.compactMap(\.dfaAlpha1)),
            stressIndex: optionalMean(recentData.compactMap(\.stressIndex)),
            readinessScore: optionalMean(recentData.compactMap(\.readinessScore)),
            sampleCount: recentData.count
        )
    }

    /// The RMSSD display baseline uses the GEOMETRIC mean
    /// (exp(mean(ln(rmssd)))), not the arithmetic mean. RMSSD is
    /// log-normally distributed, which is exactly why the z-score scoring path
    /// normalises on ln(RMSSD) (lnRmssdMean → exp() to recover the baseline).
    /// Showing the arithmetic mean here makes the "baseline RMSSD" the user sees
    /// systematically higher than the baseline the score is actually
    /// computed against (Jensen's inequality: arithmetic ≥ geometric for
    /// positive values), so a reading could read "below your baseline" on the
    /// card yet score as at/above baseline. Computing both from ln(RMSSD) makes
    /// the displayed number and the scored number agree.
    private static func geometricMeanRMSSD(of recentData: [BaselineDataPoint]) -> Double {
        let lnRmssd = recentData.map(\.rmssd).filter { $0 > 0 }.map { log($0) }
        return lnRmssd.isEmpty ? recentData.map(\.rmssd).mean : exp(lnRmssd.mean)
    }

    private func percentDeviation(current: Double, baseline: Double) -> Double? {
        guard baseline > 0 else { return nil }
        return ((current - baseline) / baseline) * 100
    }

    private func optionalPercentDeviation(current: Double?, baseline: Double?) -> Double? {
        guard let c = current, let b = baseline, b > 0 else { return nil }
        return ((c - b) / b) * 100
    }

    // MARK: - Persistence

    private func load() {
        guard fileManager.fileExists(atPath: baselineFile.path) else { return }

        do {
            let data = try Data(contentsOf: baselineFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let stored = try decoder.decode(StoredData.self, from: data)
            currentBaseline = stored.baseline
            historicalData = stored.historicalData
        } catch {
            // A corrupt/undecodable file that fails load() silently AND
            // survives on disk means every launch re-reads the same garbage
            // and save() can later clobber it. Quarantine the
            // bad file aside so we start clean and never overwrite evidence.
            debugLog("Failed to load baseline: \(error) — quarantining file")
            quarantineCorruptFile()
        }
    }

    /// Move a corrupt baseline file aside (once) so the next launch starts
    /// from a clean slate instead of re-reading the same undecodable bytes.
    private func quarantineCorruptFile() {
        guard fileManager.fileExists(atPath: baselineFile.path) else { return }
        let quarantined = baselineFile.appendingPathExtension("corrupt")
        _ = attempt("BaselineTracker.remove") { try fileManager.removeItem(at: quarantined) } // clear any prior quarantine
        do {
            try fileManager.moveItem(at: baselineFile, to: quarantined)
        } catch {
            debugLog("Failed to quarantine corrupt baseline: \(error)")
        }
    }

    private func save() {
        do {
            let stored = StoredData(baseline: currentBaseline, historicalData: historicalData)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(stored)
            // Protect the baseline file at rest. HRV
            // history is health data; without a protection class it's readable
            // whenever the device filesystem is mounted.
            try data.write(to: baselineFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            debugLog("Failed to save baseline: \(error)")
        }
    }
}
