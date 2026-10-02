import Foundation
import HealthKit
import UIKit

/// Extracted processing logic from `RRCollector+MorningProcessing`.
///
/// Owns the heavy analysis pipeline (artifact detection, sleep polling,
/// window selection, HRV analysis, recovery scoring) without mutating
/// any observable UI state. The caller (`RRCollector`) performs the
/// final state updates after the service returns a `ProcessingResult`.
@MainActor
final class MorningProcessingService {
    // MARK: - Result Type

    /// Everything produced by `processOvernightData` that the caller
    /// needs to apply to its own state.
    struct ProcessingResult {
        var session: HRVSession
        var verificationResult: Verification.Result?
        var recoveryWindow: WindowSelector.RecoveryWindow?
        var baselineDeviation: BaselineTracker.BaselineDeviation?
        /// Session IDs from same-night sessions that were superseded.
        var sameNightLinks: [UUID]
    }

    // MARK: - Settings Parameters

    /// Snapshot of settings values needed during processing.
    /// Passed in by the caller so the service never reads `SettingsManager.shared`.
    struct SettingsSnapshot {
        let sleepSchedule: SleepSchedule
        let enableTrainingLoadIntegration: Bool
        let typicalSleepHours: Double
        let scoringConfig: RecoveryScoreCalculator.ScoringConfiguration
        let ansConfig: HRVAnalysisPipeline.ANSConfiguration
        var sessionMergeMode: SessionMergeMode = .defaultGap
    }

    // MARK: - Status Callback

    /// The caller provides this closure to receive `morningStatus` updates
    /// during processing (e.g., sleep polling progress).
    typealias StatusCallback = @MainActor (RRCollector.MorningProcessingStatus) -> Void

    /// Injected clock for deterministic tests.
    typealias NowProvider = () -> Date
    /// Injected sleep function for deterministic polling tests.
    typealias SleepProvider = (_ nanoseconds: UInt64) async -> Void

    // MARK: - Dependencies

    let archive: SessionArchive
    // Internal rather than private: the sleep-poll half of this service lives
    // in `MorningProcessingService+Sleep.swift`, and `private` is file-scoped.
    // Still module-internal — nothing here escapes the app target.
    let healthKit: any HealthKitServiceProtocol
    let analysisPipeline: HRVAnalysisPipeline
    private let windowSelector: WindowSelector
    private let artifactDetector: ArtifactDetector
    private let verification: Verification
    private let baselineTracker: BaselineTracker
    let rawBackup: RawRRBackup
    let now: NowProvider
    let sleep: SleepProvider

    /// Set to `true` to break out of the sleep-data polling loop early.
    var skipSleepWait = false

    // MARK: - Initialization

    init(
        archive: SessionArchive,
        healthKit: any HealthKitServiceProtocol,
        analysisPipeline: HRVAnalysisPipeline,
        windowSelector: WindowSelector,
        artifactDetector: ArtifactDetector,
        verification: Verification,
        baselineTracker: BaselineTracker,
        rawBackup: RawRRBackup,
        now: @escaping NowProvider = Date.init,
        sleep: @escaping SleepProvider = { nanoseconds in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                // swallow-ok: `Task.sleep` throws only on cancellation, and a cancelled
                // polling loop is the caller shutting it down.
            }
        }
    ) {
        self.archive = archive
        self.healthKit = healthKit
        self.analysisPipeline = analysisPipeline
        self.windowSelector = windowSelector
        self.artifactDetector = artifactDetector
        self.verification = verification
        self.baselineTracker = baselineTracker
        self.rawBackup = rawBackup
        self.now = now
        self.sleep = sleep
    }

    // MARK: - Main Entry Point

    /// Output of the analysis phase — steps 5 through 7 of the morning
    /// pipeline, which run as a unit: each stage feeds the next, and all
    /// five results are needed downstream to build the final session.
    struct AnalysisPhaseResult {
        let flags: [ArtifactFlags]
        let verifyResult: Verification.Result
        let sleepResult: SleepPollResult
        let windowResult: WindowSelector.WindowSelectionResult?
        let analysisResult: HRVAnalysisResult?
    }

    /// Runs artifact detection, the sleep-boundary poll, window selection and
    /// the HRV analysis, with the per-step timing instrumentation intact.
    ///
    /// Kept out of `processOvernightData` as its largest contiguous,
    /// self-contained stretch. The
    /// concurrency notes below are load-bearing and travel with the code.
    /// Per-step timing instrumentation lets us attribute
    /// the user's "still ~5 min for 10 sec of work" complaint. Each
    /// line in the log gives a wall-clock delta for one step — the
    /// sum should bound the user-visible wait.
    ///
    /// Artifact detection + verification run OFF the main actor.
    /// This service is @MainActor and these are pure value-in/value-out CPU
    /// passes over the whole night (~20k beats) that would otherwise freeze the UI
    /// behind the processing spinner. The detectors are stateless (immutable
    /// default config — production AND the tests both use
    /// ArtifactDetector()/Verification() defaults), so fresh instances inside
    /// the task are behavior-identical.
    ///
    /// Window selection also runs off the main actor: it's the single heaviest
    /// synchronous pass (two full sliding-window sweeps over the night). The
    /// inputs are captured on the main actor, then scanned on a background
    /// task. WindowSelector is stateless (default config). The baseline is
    /// passed so window ranking matches the scorer; otherwise auto picks a
    /// high-RMSSD window while a user-picked one scores higher.
    private func runAnalysisPhase(
        series: RRSeries,
        analyzingSession: HRVSession,
        effectiveStartDate: Date,
        totalBeats: Int,
        isBackgroundRefinement: Bool,
        settings: SettingsSnapshot,
        trainingContext: TrainingContext?,
        // Both default so the parameter count stays inside budget; both are
        // genuinely optional — a background refinement has no status
        // callback, and the prefetch is a best-effort optimisation.
        prefetchedSleepData: SleepData? = nil,
        statusCallback: StatusCallback? = nil
    ) async -> AnalysisPhaseResult {
        // Step 5: Detect artifacts and verify quality
        let (flags, verifyResult) = await Self.detectArtifacts(in: series)
        // Step 6: Poll HealthKit for sleep boundaries; pre-fetched sleep data
        // from the parallel device fetch passes straight through.
        let sleepResult = await timedSleepPoll(
            series: series, effectiveStartDate: effectiveStartDate, totalBeats: totalBeats, isBackgroundRefinement: isBackgroundRefinement, sleepSchedule: settings.sleepSchedule, prefetchedSleepData: prefetchedSleepData, statusCallback: statusCallback
        )
        // Step 7: Select recovery window and run analysis.
        let windowResult = await Self.selectWindow(
            in: series, flags: flags, sleepResult: sleepResult, baselineStats: baselineTracker.recoveryBaselineStats
        )
        let analysisResult = await timedAnalysis(
            analyzingSession: analyzingSession, series: series, flags: flags,
            windowResult: windowResult, trainingContext: trainingContext, ansConfig: settings.ansConfig
        )
        return AnalysisPhaseResult(
            flags: flags, verifyResult: verifyResult, sleepResult: sleepResult,
            windowResult: windowResult, analysisResult: analysisResult
        )
    }

    /// Process overnight data and return a result struct.
    ///
    /// This is the heavy lifting extracted from `RRCollector.processOvernightData`.
    /// The caller is responsible for updating observable state, archiving,
    /// and CloudKit sync based on the returned result.
    ///
    /// - Parameter request: Everything the pass works from — see `OvernightRequest`.
    func processOvernightData(_ request: OvernightRequest) async -> ProcessingResult {
        // On expiry the optional wait for Apple Health sleep is cut short so
        // the pass can finish with what it has, and the assertion is ended.
        let bgTask = BackgroundTaskAssertion(name: "MorningProcessing") { [weak self] in
            self?.skipSleepWait = true
        }
        defer { bgTask.end() }
        skipSleepWait = false
        return await run(request)
    }

    /// Everything one morning pass works from, grouped so the pipeline stages
    /// pass it along as a single value.
    struct OvernightRequest {
        /// Raw RR data points to process.
        let points: [RRPoint]
        /// The session template (carries ID, start date, type, provenance, linked IDs).
        let baseSession: HRVSession
        /// Human-readable label for logging ("streaming", "device", etc.).
        let dataSource: String
        /// Number of BLE reconnects during collection.
        let reconnectCount: Int
        /// Number of beats received via BLE streaming.
        let streamingBeats: Int
        /// Number of beats from device internal recording (nil if unavailable).
        let deviceBeats: Int?
        /// Polar device identifier for raw backup.
        let deviceId: String?
        /// When true, skips sleep polling and UI callbacks.
        let isBackgroundRefinement: Bool
        /// Snapshot of user settings needed for analysis.
        let settings: SettingsSnapshot
        /// Pre-built training context (nil if training load disabled).
        let trainingContext: TrainingContext?
        /// Cached training load data (for recovery score calculation).
        let cachedTrainingLoad: HealthKitManager.TrainingLoad?
        let prefetchedSleepData: SleepData?
        /// Called on MainActor to update `morningStatus` during processing.
        let statusCallback: StatusCallback?

        init(
            points: [RRPoint],
            baseSession: HRVSession,
            dataSource: String,
            reconnectCount: Int,
            streamingBeats: Int = 0,
            deviceBeats: Int? = nil,
            deviceId: String?,
            isBackgroundRefinement: Bool = false,
            settings: SettingsSnapshot,
            trainingContext: TrainingContext?,
            cachedTrainingLoad: HealthKitManager.TrainingLoad?,
            prefetchedSleepData: SleepData? = nil,
            statusCallback: StatusCallback? = nil
        ) {
            self.points = points
            self.baseSession = baseSession
            self.dataSource = dataSource
            self.reconnectCount = reconnectCount
            self.streamingBeats = streamingBeats
            self.deviceBeats = deviceBeats
            self.deviceId = deviceId
            self.isBackgroundRefinement = isBackgroundRefinement
            self.settings = settings
            self.trainingContext = trainingContext
            self.cachedTrainingLoad = cachedTrainingLoad
            self.prefetchedSleepData = prefetchedSleepData
            self.statusCallback = statusCallback
        }
    }

    /// Steps 1–7: back up the raw beats, merge same-night sessions, then run
    /// artifact detection, sleep boundaries, window selection and analysis.
    ///
    /// Step 1's backup runs off the main thread: overnight sessions can hold
    /// ~20K+ RR points that serialize to 1.5MB+ JSON and produce a
    /// main-thread stall when backed up inline.
    private func run(_ request: OvernightRequest) async -> ProcessingResult {
        await backupRawDataAsync(
            points: request.points, sessionId: request.baseSession.id,
            deviceId: request.deviceId, dataSource: request.dataSource
        )
        // Step 2: Build series, merge same-night sessions
        let merged = buildMergedSeries(
            points: request.points, baseSession: request.baseSession,
            sleepSchedule: request.settings.sleepSchedule,
            sessionMergeMode: request.settings.sessionMergeMode
        )
        // Step 3: Log gap detection
        logGapDetection(series: merged.series)
        // Step 4: Build analyzing session
        let analyzingSession = makeAnalyzingSession(request: request, merged: merged)
        // Steps 5–7: artifacts, sleep boundaries, window selection, analysis.
        let phase = await analysisPhase(request: request, merged: merged, analyzingSession: analyzingSession)
        return await assembleResult(request: request, merged: merged, analyzingSession: analyzingSession, phase: phase)
    }

    private func analysisPhase(
        request: OvernightRequest, merged: MergeResult, analyzingSession: HRVSession
    ) async -> AnalysisPhaseResult {
        await runAnalysisPhase(
            series: merged.series,
            analyzingSession: analyzingSession,
            effectiveStartDate: merged.effectiveStartDate,
            totalBeats: request.points.count,
            isBackgroundRefinement: request.isBackgroundRefinement,
            settings: request.settings,
            trainingContext: request.trainingContext,
            prefetchedSleepData: request.prefetchedSleepData,
            statusCallback: request.statusCallback
        )
    }

    private func makeAnalyzingSession(request: OvernightRequest, merged: MergeResult) -> HRVSession {
        HRVSession(
            id: request.baseSession.id,
            startDate: merged.effectiveStartDate,
            endDate: now(),
            state: .analyzing,
            sessionType: request.baseSession.sessionType,
            rrSeries: merged.series,
            analysisResult: nil,
            artifactFlags: nil
        )
    }

    /// Steps 8–12: build the final session, finish it, and report.
    private func assembleResult(
        request: OvernightRequest,
        merged: MergeResult,
        analyzingSession: HRVSession,
        phase: AnalysisPhaseResult
    ) async -> ProcessingResult {
        var finalSession = buildFinalSession(
            analyzingSession: analyzingSession, request: request, merged: merged, phase: phase
        )
        await finishSession(
            &finalSession, phase: phase, settings: request.settings,
            trainingContext: request.trainingContext, cachedTrainingLoad: request.cachedTrainingLoad,
            isBackgroundRefinement: request.isBackgroundRefinement
        )
        return ProcessingResult(
            session: finalSession,
            verificationResult: phase.verifyResult,
            recoveryWindow: phase.windowResult?.recoveryWindow,
            baselineDeviation: baselineTracker.deviation(for: finalSession),
            sameNightLinks: merged.sameNightLinks
        )
    }

    /// Steps 9–12: vitals snapshot, the insufficient-data gate, the recovery
    /// score, and the same-night supersede.
    private func finishSession(
        _ finalSession: inout HRVSession,
        phase: AnalysisPhaseResult,
        settings: SettingsSnapshot,
        trainingContext: TrainingContext?,
        cachedTrainingLoad: HealthKitManager.TrainingLoad?,
        isBackgroundRefinement: Bool
    ) async {
        if !isBackgroundRefinement {
            await attachVitalsSnapshot(to: &finalSession)
        }
        applyInsufficientDataGate(to: &finalSession, analysisResult: phase.analysisResult)
        let scored = await computeRecoveryScore(
            for: finalSession, analysisResult: phase.analysisResult,
            trainingContext: trainingContext, baselineTracker: baselineTracker,
            settings: settings, cachedTrainingLoad: cachedTrainingLoad
        )
        if let scored {
            finalSession.recoveryScore = scored.score
            finalSession.scoreBreakdown = scored.breakdown
            finalSession.frozenReadiness = ReanalysisService.computeFrozenReadiness(
                compositeScore: scored.breakdown.compositeScore, trainingContext: trainingContext
            )
        }
        // Only for complete, non-background sessions.
        if finalSession.state == .complete, !isBackgroundRefinement {
            supersedeSameNightSession(newSession: &finalSession, sleepSchedule: settings.sleepSchedule, sessionMergeMode: settings.sessionMergeMode)
        }
    }

    /// Strap-RHR override: when the session has an analysisResult, the
    /// analysis-window mean HR (already nocturnal, already what
    /// BaselineTracker.meanHRBaseline is built from) replaces Apple's
    /// daytime-rest RHR sample. Keeps the comparison physiologically
    /// self-consistent. Falls back to HealthKit RHR when no analysis
    /// exists yet.
    private func attachVitalsSnapshot(to session: inout HRVSession) async {
        let vitals = await healthKit.fetchRecoveryVitals(relativeTo: session.endDate ?? now())
        session.vitalsSnapshot = vitals.withStrapNocturnalRHR(session.analysisResult?.timeDomain.meanHR)
    }

    /// Applied BEFORE scoring so the score computation uses the baseline-HRV
    /// fallback when the session doesn't have enough signal. Reanalysis
    /// applies the identical check, so both paths converge on the same
    /// `.insufficient` marker for the same session — no more "first-run looks
    /// fine, reanalysis flips it to insufficient" surprise.
    private func applyInsufficientDataGate(
        to session: inout HRVSession, analysisResult: HRVAnalysisResult?
    ) {
        guard let result = analysisResult else { return }
        let baselineRmssd = baselineTracker.recoveryBaselineStats.map { exp($0.lnRmssdMean) } ?? 0
        guard ReanalysisService.hasInsufficientData(
            session: session, analysisResult: result, baselineRmssd: baselineRmssd
        ) else { return }
        session.hrvDataQuality = .insufficient
        // RMSSD / baseline are PHI and debugLog is user-exportable —
        // log the transition without the numeric health values.
        debugLog("[MorningProcessingService] Marked initial session insufficient (window too short or no organized recovery)")
    }
}
