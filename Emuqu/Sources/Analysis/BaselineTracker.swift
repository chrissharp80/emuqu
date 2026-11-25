import Foundation
import UIKit

/// Personal baseline tracking for multi-night HRV trends
/// Per design spec v8.1: one reading per night, with the 7 most recent
/// nights for display and up to 60 for the recovery score's baseline.
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
    /// Seals `baselineFile` and opens it: the app's key for the app, a seal
    /// a test controls otherwise.
    private let seal: JSONFileSeal
    private var currentBaseline: Baseline?
    private var historicalData: [BaselineDataPoint] = []
    private let fileManager = FileManager.default
    private let lock = NSRecursiveLock()
    private let onBaselineUpdated: BaselineUpdater?
    /// Why `save()` must not write over `baselineFile` yet, or nil when it may.
    /// Set by `load()`; read and cleared under `lock`.
    private var saveHold: SaveHold?

    /// Why the file at `baselineFile` must not be written over.
    private enum SaveHold {
        /// The file could not be read but may be intact: iOS file protection
        /// kept it unreadable (a background launch before the first unlock),
        /// or the read failed for a reason that can pass (out of file
        /// descriptors, an I/O error; `FileReadFailure.transient`). It is read
        /// again when protected data is available, the app becomes active or
        /// goes to the background, or before the next change, and the nights
        /// taken in meanwhile are merged onto it (`reloadAfterUnlock()`).
        case fileNotRead
        /// The file did not decode and the copy of its bytes could not be
        /// written aside, so the file is the only copy of what it held. Each
        /// save writes the copy again from `undecodableBytes`.
        case unreadableNotSetAside
    }

    /// The bytes of a file that did not decode, kept while their copy aside
    /// has not been written (`.unreadableNotSetAside`). Under `lock`.
    private var undecodableBytes: Data?

    /// Set when a save could not seal the nights (no key reachable), so the
    /// file still holds the previous save; the unlock observers save again.
    /// Under `lock`.
    private var unsavedChanges = false

    /// Whether the unlock observers are installed. Under `lock`, or in `init`.
    private var observingUnlock = false

    /// The sleep schedule of the last `update` or `rebuildFromSessions`, which
    /// merging the nights held in memory onto a file read after unlock needs.
    /// Under `lock`.
    private var lastSleepSchedule: SleepSchedule?

    /// Protected-data, become-active and background observers, installed
    /// when the file could not be read at load or a save could not be sealed.
    private let unlockObservers = NotificationTokens()

    /// Set under `lock` when a change was committed; `notifyIfChanged()`
    /// runs the callback for it once the lock is released, so the callback
    /// (which syncs the settings) never runs while this tracker's lock is
    /// held and cannot deadlock against a thread waiting for it.
    private var changedSinceNotify = false

    /// Data point for baseline calculation. Internal rather than `private`
    /// so `BaselineTracker+NightReplacement.swift` can name it.
    struct BaselineDataPoint: Codable {
        /// Session start. The night slot is derived from it.
        let date: Date
        /// Session end, for the morning-reading rule. Nil on points saved
        /// before it was recorded; those fall back to `date`.
        let endDate: Date?
        /// The session the reading came from, so a re-analysis of that
        /// session replaces or removes it (`isReading(_:of:)`). Nil on points
        /// saved before it was recorded; those are matched by `date`.
        let sessionId: UUID?
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

    /// Rolling window of the display baseline and the 7-day CV: the 7 most
    /// recent stored nights (a count of nights, not a date window, so a gap
    /// in recording does not empty it).
    /// 7-day rolling ln(RMSSD) baseline; collapsing CV = non-functional
    /// overreaching — Plews, Laursen, Buchheit et al., Sports Med 2013;43:773-781;
    /// Eur J Appl Physiol 2012;112:3729.
    static let baselineWindowDays = 7

    /// Maximum historical points to store (limit storage growth)
    static let maxHistoricalPoints = 90

    /// Nights the recovery score's baseline reads: the most recent 60 stored
    /// nights (`stats(from:)`, `baselineRMSSDs(rebuiltFrom:beforeNightOf:sleepSchedule:)`).
    static let recoveryWindowNights = 60

    // MARK: - Initialization

    /// The app's tracker, on `HRVBaseline.json` in the App Group container
    /// (Documents when the group is unavailable).
    /// - Parameter onBaselineUpdated: Callback invoked with (rmssd, hr) whenever the
    ///   baseline changes. The caller wires this to SettingsManager or any display layer.
    ///   Passing nil disables sync (useful in tests).
    convenience init(onBaselineUpdated: BaselineUpdater? = nil) {
        let container = AppConfig.sharedContainerURL()
        debugLog("[Baseline] Using container: \(container.path)")
        self.init(baselineFile: container.appendingPathComponent("HRVBaseline.json"), onBaselineUpdated: onBaselineUpdated)
    }

    /// A tracker persisted at `baselineFile`, sealed with the app's key.
    /// Tests pass a temporary file so they never read or overwrite the app's
    /// own baseline.
    convenience init(baselineFile: URL, onBaselineUpdated: BaselineUpdater? = nil) {
        self.init(baselineFile: baselineFile, seal: .app, onBaselineUpdated: onBaselineUpdated)
    }

    /// A tracker persisted at `baselineFile` and sealed with `seal`.
    ///
    /// The stored display baseline is recomputed from the stored nights on
    /// load rather than trusted as saved, so it always follows the current
    /// window rule before it is pushed to the callback.
    init(baselineFile: URL, seal: JSONFileSeal, onBaselineUpdated: BaselineUpdater?) {
        self.onBaselineUpdated = onBaselineUpdated
        self.baselineFile = baselineFile
        self.seal = seal
        load()
        if saveHold == .fileNotRead { observeUnlock() }
        recalculateBaseline()
        // Sync loaded baseline on startup
        notify(currentBaseline)
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
        let recentData = Array(points.suffix(Self.recoveryWindowNights))
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
            // Widened like the ln(RMSSD) SD: three similar nights give a
            // sample SD near the floor, and a 2 bpm rise would read as a
            // several-SD elevation in both the Tier-1 resting-HR adjustment
            // and the vitals sleep-HR sub-score.
            meanHRSD: max(hrValues.sampleSD * Self.smallSampleWidening(count: hrValues.count), BaselineConstants.meanHRSDFloor),
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
        lnValues.sampleSD * smallSampleWidening(count: lnValues.count)
    }

    /// The factor a baseline SD over `count` nights is widened by: 1 from the
    /// 7-night baseline length up, √(7/n) below it (≈1.53 at 3 nights). The
    /// ln(RMSSD) SD (`widenedLnSD`) and the resting-HR SD both use it, so the
    /// two z-scores shrink toward 0 alike while the baseline is short.
    static func smallSampleWidening(count: Int) -> Double {
        let confidenceFloor = Self.baselineWindowDays // 7
        return count >= confidenceFloor ? 1.0 : sqrt(Double(confidenceFloor) / Double(count))
    }

    /// 7-day CV of ln(RMSSD) — Plews: reduced CV signals overreaching. The
    /// window is the 7 most recent stored nights, as for the display
    /// baseline (`baselineWindowDays`).
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
    ///
    /// Every session is merged under one hold of the lock, then the baseline
    /// is recalculated, published and written once, not once per session.
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
        defer { notifyIfChanged() }
        lock.lock()
        defer { lock.unlock() }
        lastSleepSchedule = sleepSchedule
        reloadAfterUnlock()
        let admitted = validSessions.map { merge($0, sleepSchedule: sleepSchedule) }
        if admitted.contains(true) { commitChanges() }
        debugLog("[Baseline] Rebuild complete: \(historicalData.count) data points, baseline: \(currentBaseline != nil ? "available" : "not yet established")")
    }

    /// Finished, analyzed, HRV-reliable overnight sessions.
    private static func isRebuildCandidate(_ session: HRVSession) -> Bool {
        session.state == .complete && session.sessionType == .overnight
            && session.analysisResult != nil && session.isReliableForHRVAggregates
    }

    /// Whether `session` can hold a night of the baseline: a rebuild
    /// candidate that also passes the structural gate and carries a measured
    /// SDNN, i.e. what `rebuildFromSessions` admits (`admitsToBaseline`).
    static func isBaselineCandidate(_ session: HRVSession) -> Bool {
        guard isRebuildCandidate(session), let result = session.analysisResult else { return false }
        return isStructurallySoundForBaseline(session: session, result: result) && !result.isEstimated(.sdnn)
    }

    /// RMSSD of the nights the recovery score's baseline holds for the night
    /// of `session`, rebuilt from `sessions`, oldest first: the sessions
    /// `rebuildFromSessions` admits (`isBaselineCandidate`), merged in start
    /// order one per night (`SleepSchedule.nightKey`) by the same replacement
    /// rule, from nights before `session`'s only, the most recent
    /// `recoveryWindowNights` of them — what
    /// `recoveryBaselineStats(excludingNightOf:sleepSchedule:)` reads. The
    /// daily report's baseline comes from here, so it counts the nights the
    /// score counts: a short window is left out, a split night counts once,
    /// and an earlier segment of the reported night is not a night before it.
    static func baselineRMSSDs(
        rebuiltFrom sessions: [HRVSession], beforeNightOf session: HRVSession, sleepSchedule: SleepSchedule
    ) -> [Double] {
        let night = sleepSchedule.nightKey(for: session.startDate)
        let points = sessions
            .filter { isBaselineCandidate($0) && sleepSchedule.nightKey(for: $0.startDate) < night }
            .sorted { $0.startDate < $1.startDate }
            .compactMap { candidate in candidate.analysisResult.map { dataPoint(session: candidate, result: $0) } }
        var nights: [BaselineDataPoint] = []
        for point in points {
            mergeIntoNight(point, into: &nights, sleepSchedule: sleepSchedule)
        }
        return nights.sorted { $0.date < $1.date }.suffix(recoveryWindowNights).map(\.rmssd)
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
        let sessionEnd = session.endDate ?? session.startDate
        return isStructurallySound(result: result, sessionDuration: sessionEnd.timeIntervalSince(session.startDate))
    }

    /// The two structural tests of the insufficient-data rule
    /// (`SessionAcceptanceService.isInsufficientData`), read the same way: the
    /// analysed span — the window, or the whole session when the analysis
    /// had none — must reach `forReliableWindowMs`, and a session without
    /// organized recovery must reach overnight length.
    static func isStructurallySound(result: HRVAnalysisResult, sessionDuration: TimeInterval) -> Bool {
        let windowSeconds = result.windowStartMs.flatMap { start in
            result.windowEndMs.map { Double($0 - start) / 1000 }
        }
        let minimumSpanSeconds = Double(HRVConstants.MinimumDuration.forReliableWindowMs) / 1000
        guard (windowSeconds ?? sessionDuration) >= minimumSpanSeconds else { return false }
        return result.isOrganizedRecovery == true
            || sessionDuration >= HRVConstants.MinimumDuration.forOvernightSessionSeconds
    }

    /// - Parameters:
    ///   - session: Completed session with analysis results
    ///   - sleepSchedule: User's sleep schedule (provided by caller from SettingsManager)
    /// Only overnight readings contribute, one per night. A session already
    /// in the baseline (re-analysed, or its window re-picked by hand) takes
    /// its own reading's place whatever the replacement rule would say, and
    /// leaves the baseline when it no longer passes the gates (`merge`).
    /// The callback runs after the lock is released (`notifyIfChanged()`).
    func update(with session: HRVSession, sleepSchedule: SleepSchedule) {
        defer { notifyIfChanged() }
        lock.lock()
        defer { lock.unlock() }
        lastSleepSchedule = sleepSchedule
        reloadAfterUnlock()
        guard merge(session, sleepSchedule: sleepSchedule) else { return }
        commitChanges()
    }

    /// Drops the reading `session` put in the baseline before, then admits
    /// the session into its night's slot when it passes the gates. A newer
    /// analysis of the same session is not a rival for its night: it
    /// replaces the old reading outright, and one the gates now turn away
    /// (`.preSleep`, `.insufficient`, a window too short) takes the old
    /// reading out rather than leave a value the session no longer supports.
    /// False when nothing changed. Caller holds `lock`.
    private func merge(_ session: HRVSession, sleepSchedule: SleepSchedule) -> Bool {
        let storedBefore = historicalData.count
        historicalData.removeAll { Self.isReading($0, of: session) }
        let removedOwnReading = historicalData.count != storedBefore
        guard let result = session.analysisResult, admitsToBaseline(session, result: result) else {
            if removedOwnReading {
                debugLog("[Baseline] Removed the earlier reading of session \(session.id.uuidString.prefix(8)) — it no longer passes the baseline gates")
            }
            return removedOwnReading
        }
        Self.mergeIntoNight(Self.dataPoint(session: session, result: result), into: &historicalData, sleepSchedule: sleepSchedule)
        return true
    }

    /// Whether `point` is a reading of `session`: by session id, or, for a
    /// point saved before ids were recorded, by the session's start.
    private static func isReading(_ point: BaselineDataPoint, of session: HRVSession) -> Bool {
        guard let id = point.sessionId else { return point.date == session.startDate }
        return id == session.id
    }

    /// Sorts and trims the stored nights, then recalculates and writes the
    /// baseline and marks it for the callback (`notifyIfChanged()`). Caller
    /// holds `lock`.
    private func commitChanges() {
        historicalData.sort { $0.date < $1.date }
        if historicalData.count > Self.maxHistoricalPoints {
            historicalData = Array(historicalData.suffix(Self.maxHistoricalPoints))
        }
        recalculateBaseline()
        changedSinceNotify = true
        save()
    }

    /// Four gates a session must pass to reach the baseline.
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
    ///
    /// A reading whose SDNN is an estimate (an Elite HRV summary import,
    /// `HRVAnalysisResult.estimatedMetrics`) stays out: a data point's SDNN
    /// is a stored number the SDNN baseline averages.
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
        return !result.isEstimated(.sdnn)
    }

    private static func dataPoint(session: HRVSession, result: HRVAnalysisResult) -> BaselineDataPoint {
        BaselineDataPoint(
            date: session.startDate,
            endDate: session.endDate,
            sessionId: session.id,
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

    /// Runs the callback for a change committed since the last call, with
    /// the baseline as it stands. Takes `lock` only to read and clear the
    /// pending-change mark; the callback itself runs with the lock released.
    /// Caller must not hold `lock`.
    private func notifyIfChanged() {
        lock.lock()
        let changed = changedSinceNotify
        changedSinceNotify = false
        let baseline = currentBaseline
        lock.unlock()
        guard changed else { return }
        notify(baseline)
    }

    /// Hands `baseline` to the injected callback once it has enough nights.
    private func notify(_ baseline: Baseline?) {
        guard let baseline, baseline.sampleCount >= Baseline.minimumSamples else {
            return
        }
        onBaselineUpdated?(baseline.rmssd, baseline.meanHR)
    }

    /// Whether a reading of the session `id` is among the stored nights.
    func holdsReading(of id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return historicalData.contains { $0.sessionId == id }
    }

    /// Calculate deviation from baseline for a session
    /// - Parameter session: Session to compare against baseline
    /// - Returns: Deviation metrics, or nil if no baseline
    func deviation(for session: HRVSession) -> BaselineDeviation? {
        lock.lock()
        defer { lock.unlock() }
        guard let baseline = currentBaseline, let result = session.analysisResult else { return nil }
        return deviation(of: result, against: baseline)
    }

    /// Deviation of `session` from the display baseline of the nights BEFORE
    /// its own (the 7 most recent of them), for a night already admitted:
    /// `deviation(for:)` reads the current baseline, which then contains the
    /// night itself and pulls every deviation toward zero.
    func deviation(for session: HRVSession, sleepSchedule: SleepSchedule) -> BaselineDeviation? {
        lock.lock()
        defer { lock.unlock() }
        let night = sleepSchedule.nightKey(for: session.startDate)
        let earlier = historicalData.filter { sleepSchedule.nightKey(for: $0.date) < night }
        guard let baseline = Self.makeBaseline(from: Array(earlier.suffix(Self.baselineWindowDays))),
              let result = session.analysisResult else { return nil }
        return deviation(of: result, against: baseline)
    }

    /// Percent deviations of `result` from `baseline`; nil when the baseline
    /// has fewer than `Baseline.minimumSamples` nights.
    private func deviation(of result: HRVAnalysisResult, against baseline: Baseline) -> BaselineDeviation? {
        guard baseline.sampleCount >= Baseline.minimumSamples else { return nil }
        return BaselineDeviation(
            rmssdDeviation: percentDeviation(current: result.timeDomain.rmssd, baseline: baseline.rmssd),
            sdnnDeviation: result.measuredSDNN.flatMap { percentDeviation(current: $0, baseline: baseline.sdnn) },
            meanHRDeviation: percentDeviation(current: result.timeDomain.meanHR, baseline: baseline.meanHR),
            hfDeviation: optionalPercentDeviation(current: result.frequencyDomain?.hf, baseline: baseline.hf),
            lfHfDeviation: optionalPercentDeviation(current: result.frequencyDomain?.lfHfRatio, baseline: baseline.lfHfRatio),
            stressDeviation: optionalPercentDeviation(current: result.ansMetrics?.stressIndex, baseline: baseline.stressIndex),
            readinessDeviation: optionalPercentDeviation(current: result.ansMetrics?.readinessScore, baseline: baseline.readinessScore)
        )
    }

    /// Reset baseline (start fresh): forgets every stored night and saves the
    /// empty baseline. A file that could not be read at load is written over
    /// without being read first, as its nights are the ones being discarded; a file
    /// that did not decode and whose copy could not be written aside stays
    /// protected (`mayWriteFile()`).
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        currentBaseline = nil
        historicalData = []
        if saveHold == .fileNotRead { saveHold = nil }
        save()
    }

    deinit { unlockObservers.removeAll() }

    // MARK: - Private Methods

    /// Compute the mean of values, returning nil if the array is empty.
    private static func optionalMean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.mean
    }

    /// The display baseline over the 7 most recent stored nights. The score
    /// reads a longer window (`stats(from:)`, up to 60 nights), so the two
    /// share the ln(RMSSD) scale (see `geometricMeanRMSSD`) but not their
    /// nights.
    private func recalculateBaseline() {
        currentBaseline = Self.makeBaseline(from: Array(historicalData.suffix(Self.baselineWindowDays)))
    }

    /// A baseline over `recentData`; nil when it is empty.
    private static func makeBaseline(from recentData: [BaselineDataPoint]) -> Baseline? {
        guard !recentData.isEmpty else { return nil }
        return Baseline(
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
    /// card yet score as at/above baseline. Computing both from ln(RMSSD) puts
    /// the displayed number and the scored number on the same scale; they still
    /// differ by window (the display's 7 most recent nights, the score's up to
    /// 60).
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

    /// Reads the stored nights (`readFile()`); a file that cannot be read or
    /// decoded leaves the tracker empty with the hold `readFile` sets.
    private func load() {
        guard fileManager.fileExists(atPath: baselineFile.path), let stored = readFile() else { return }
        currentBaseline = stored.baseline
        historicalData = stored.historicalData
    }

    /// The stored baseline and nights, or nil with `saveHold` set for why not.
    /// A failed read is classified as `SettingsManager.load(from:)` does
    /// (`Self.hold(forReadError:)`): a file that may be intact is left in place
    /// and holds saves until it reads; only a file that is gone or can never
    /// give its bytes back lets saves go ahead. Bytes that do not decode are
    /// written aside first (`setAsideUndecodable`), and saves are held only
    /// while that write fails.
    private func readFile() -> StoredData? {
        let data: Data
        do {
            data = try Data(contentsOf: baselineFile)
        } catch let nsError as NSError {
            saveHold = Self.hold(forReadError: nsError)
            if saveHold == nil {
                debugLog("[Baseline] baseline file is gone or can never be read — nothing to keep, starting empty: \(nsError)", level: .warning)
            } else {
                debugLog("[Baseline] baseline file could not be read — saves wait until it reads: \(nsError)", level: .warning)
            }
            return nil
        }
        return decodeOrSetAside(data)
    }

    /// Whether a failed read of the baseline file holds saves; the decision
    /// `readFile()` makes, for tests.
    static func holdsSaves(afterReadError error: NSError) -> Bool {
        hold(forReadError: error) != nil
    }

    /// The save hold a failed read of the baseline file leaves: `.fileNotRead`
    /// while the file may be intact (protection-locked or a read that can
    /// pass), none when it is gone or can never give its bytes back.
    private static func hold(forReadError error: NSError) -> SaveHold? {
        switch FileReadFailure(error) {
        case .locked, .transient: .fileNotRead
        case .gone, .nothingToKeep: nil
        }
    }

    /// The second half of `readFile()`: `data` opened with `seal` (sealed, or
    /// plain JSON from a build that did not seal the file) and decoded. While
    /// the keychain refuses the key, nil with `.fileNotRead`: the file is
    /// left as it is and read again after unlock. Bytes that do not open or
    /// decode for any other reason: nil once they are written aside (no
    /// hold), or with `.unreadableNotSetAside` when that write fails.
    private func decodeOrSetAside(_ data: Data) -> StoredData? {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try seal.openJSON(StoredData.self, from: data, with: decoder)
        } catch let error where JSONFileSeal.isKeyLocked(error) {
            debugLog("[Baseline] baseline file is sealed and the key is locked — saves wait until it opens: \(error)", level: .warning)
            saveHold = .fileNotRead
            return nil
        } catch {
            // A corrupt/undecodable file that fails load() silently AND
            // survives on disk means every launch re-reads the same garbage
            // and save() can later clobber it. Keep its bytes aside first.
            let keptAside = setAsideUndecodable(data)
            debugLog(keptAside
                ? "Failed to load baseline: \(error) — kept a copy aside"
                : "Failed to load baseline: \(error) — its copy could not be written aside, so saves are held", level: .error)
            saveHold = keptAside ? nil : .unreadableNotSetAside
            return nil
        }
    }

    /// Watches for protected data becoming available, the app becoming active
    /// (which a suspended app sees instead) and the app going to the
    /// background once the file could not be read or a save could not be
    /// written, so it is read again and the nights held in memory are saved
    /// without waiting for the next change. Installed once.
    private func observeUnlock() {
        guard !observingUnlock else { return }
        observingUnlock = true
        unlockObservers.observeProtectedDataMayBeAvailable(also: [UIApplication.didEnterBackgroundNotification]) { [weak self] in
            self?.retryAfterUnlock()
        }
    }

    /// Notification entry: `reloadAfterUnlock()` (a no-op once the hold is
    /// gone), then a save of nights a sealed save could not write yet. A
    /// merge the reload committed reaches the callback once the lock is
    /// released.
    private func retryAfterUnlock() {
        defer { notifyIfChanged() }
        lock.lock()
        defer { lock.unlock() }
        reloadAfterUnlock()
        if unsavedChanges { save() }
    }

    /// While the file could not be read at load, reads it again. Once it is
    /// readable, the nights held in memory are merged onto the file's nights
    /// (one per night, with the last sleep schedule an update or rebuild
    /// passed), the hold lifts and the result is committed. Still unreadable:
    /// nothing changes. Gone, or unable ever to give its bytes back: the hold
    /// is what `readFile()` leaves, and the held nights are saved with the
    /// next change. Caller holds `lock`.
    private func reloadAfterUnlock() {
        guard saveHold == .fileNotRead else { return }
        guard fileManager.fileExists(atPath: baselineFile.path) else {
            saveHold = nil
            return
        }
        guard var nights = readFile()?.historicalData else { return }
        if let schedule = lastSleepSchedule {
            for point in historicalData {
                Self.mergeIntoNight(point, into: &nights, sleepSchedule: schedule)
            }
        }
        historicalData = nights
        saveHold = nil
        debugLog("[Baseline] baseline file readable again — merged into \(historicalData.count) nights")
        commitChanges()
    }

    /// Writes the bytes of a file that did not decode to `<name>.corrupt`
    /// (atomically, so an earlier copy is replaced only once the new one is
    /// complete). On failure the bytes are kept in `undecodableBytes` for the
    /// next save to try again. True once the copy is on disk.
    private func setAsideUndecodable(_ data: Data) -> Bool {
        do {
            try data.write(to: baselineFile.appendingPathExtension("corrupt"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            undecodableBytes = nil
            return true
        } catch {
            undecodableBytes = data
            return false
        }
    }

    /// Whether `save()` may write `baselineFile`: always without a hold, and
    /// once the held file is gone (Delete All My Data removed it). The copy of
    /// an undecodable file is written again here; an unread file waits for
    /// `reloadAfterUnlock()`. A save that stays held is not logged again: the
    /// hold was logged when it was set. Caller holds `lock`.
    private func mayWriteFile() -> Bool {
        guard let hold = saveHold else { return true }
        let fileGone = !fileManager.fileExists(atPath: baselineFile.path)
        let setAside = hold == .unreadableNotSetAside && (undecodableBytes.map { setAsideUndecodable($0) } ?? true)
        guard fileGone || setAside else { return false }
        if setAside { debugLog("[Baseline] copy of the undecodable baseline written aside — saves resume") }
        saveHold = nil
        undecodableBytes = nil
        return true
    }

    /// Seals the baseline and nights with `seal` and writes them atomically
    /// under `.completeFileProtectionUntilFirstUserAuthentication`, so a
    /// night archived while the phone is locked (after the first unlock of
    /// the boot) is saved. Nothing is written while `mayWriteFile()` says no.
    /// A save that fails (no key reachable, or the write) writes nothing: the
    /// file keeps the previous save, never the nights in the clear; the
    /// nights stay in memory and are saved by the next change or the unlock
    /// observers. Caller holds `lock`.
    private func save() {
        guard mayWriteFile() else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted]
            let sealed = try seal.sealJSON(StoredData(baseline: currentBaseline, historicalData: historicalData), with: encoder)
            try sealed.write(to: baselineFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            unsavedChanges = false
        } catch {
            debugLog("[Baseline] baseline not saved — the file keeps the previous save and the save is retried: \(error)", level: .error)
            unsavedChanges = true
            observeUnlock()
        }
    }
}

// MARK: - Replacing rebuild

extension BaselineTracker {
    /// The start of a replacing rebuild: forgets every stored night except
    /// the readings of `unreadable`, archived sessions the rebuild could not
    /// read this time, and saves the result. With none, a plain `reset()`.
    func reset(keepingReadingsOf unreadable: Set<UUID>) {
        guard !unreadable.isEmpty else { return reset() }
        debugLog("[Baseline] rebuild keeps the stored readings of \(unreadable.count) sessions it could not read", level: .warning)
        defer { notifyIfChanged() }
        lock.lock()
        defer { lock.unlock() }
        historicalData = historicalData.filter { point in point.sessionId.map(unreadable.contains) ?? false }
        if saveHold == .fileNotRead { saveHold = nil }
        commitChanges()
    }
}
