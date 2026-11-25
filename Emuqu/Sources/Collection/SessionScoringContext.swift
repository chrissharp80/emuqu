import Foundation

/// What a session is analysed and scored against besides its own beats: the
/// user's settings, the stored-nights baseline, and the training load as of
/// the session's day.
///
/// The composition root builds one and hands it to both the collector (live
/// recording, morning processing, acceptance) and the saved-session
/// reanalysis, so a night scored at acceptance and the same night rescored
/// later read one training-load cache and one baseline.
@MainActor
final class SessionScoringContext {
    let settingsManager: SettingsManager
    let healthKit: any HealthKitServiceProtocol
    let baselineTracker: BaselineTracker

    /// The current load, stamped with the day it was cached.
    private var cachedTrainingLoadOfDay: (day: Date, load: HealthKitManager.TrainingLoad)?
    /// Loads fetched as of a past day, keyed by that day's start, for the
    /// duration of a reanalysis of a session from that day.
    private var pastDayTrainingLoads: [Date: HealthKitManager.TrainingLoad] = [:]
    /// How many running reanalyses hold each past day's load.
    private var pastDayTrainingLoadHolders: [Date: Int] = [:]

    init(settingsManager: SettingsManager, healthKit: any HealthKitServiceProtocol, baselineTracker: BaselineTracker) {
        self.settingsManager = settingsManager
        self.healthKit = healthKit
        self.baselineTracker = baselineTracker
    }

    // MARK: - Training load

    /// The current (as-of-today) training load. Never holds a past day's:
    /// it is stamped with the day it was cached, and reads as nil once that
    /// day is over (an overnight recording outlives midnight).
    var cachedTrainingLoad: HealthKitManager.TrainingLoad? {
        get {
            guard let cached = cachedTrainingLoadOfDay, Calendar.current.isDateInToday(cached.day) else { return nil }
            return cached.load
        }
        set { cachedTrainingLoadOfDay = newValue.map { (day: Date(), load: $0) } }
    }

    /// Create a TrainingContext snapshot from the training load as of
    /// `referenceDate`. Nil for a past day whose load has not been fetched:
    /// today's load must never stand in for an earlier day's.
    func createTrainingContext(relativeTo referenceDate: Date = Date()) -> TrainingContext? {
        guard let load = trainingLoad(asOf: referenceDate) else { return nil }
        return trainingContext(from: load, relativeTo: referenceDate)
    }

    /// Today reads the shared current-load cache; a past day reads only a
    /// load fetched for that day.
    func trainingLoad(asOf date: Date) -> HealthKitManager.TrainingLoad? {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return cachedTrainingLoad }
        return pastDayTrainingLoads[calendar.startOfDay(for: date)]
    }

    private func trainingContext(from load: HealthKitManager.TrainingLoad, relativeTo referenceDate: Date) -> TrainingContext? {
        guard var context = TrainingContext(from: load, relativeTo: referenceDate) else { return nil }
        // TrainingContext.init copies the HealthKit value; the user's override
        // and opt-in decide, exactly as for the ANS configuration.
        context.vo2Max = configuredVO2Max(load)
        return context
    }

    /// Async sibling of `createTrainingContext` that guarantees a fresh
    /// fetch when the cache is empty, so a recovery score is never frozen at
    /// Tier 2 only because `cachedTrainingLoad` had not been filled yet
    /// (cold launch right after waking).
    ///
    /// Behaviour:
    ///   • If a load as of `referenceDate` is held (the shared cache for
    ///     today, a fetched past-day load otherwise) → use it.
    ///   • Else, with training-load integration enabled → fetch via HealthKit
    ///     as of that date and build the context. The fetch fills the shared
    ///     cache only when it is as of today: the cache is the current load,
    ///     and a past day's load left there would be read as today's.
    ///   • If integration is disabled → return nil (Tier 2 scoring is
    ///     intentional in that mode).
    func createTrainingContextEnsuringFresh(relativeTo referenceDate: Date = Date()) async -> TrainingContext? {
        guard settingsManager.settings.enableTrainingLoadIntegration else {
            return nil
        }
        if let context = createTrainingContext(relativeTo: referenceDate) {
            return context
        }
        debugLog("[SessionScoring] createTrainingContext returned nil with training-load integration ON — fetching live HealthKit training load to ensure Tier 3 freeze (relativeTo \(referenceDate))", level: .info)
        let load = await healthKit.calculateTrainingLoad(relativeTo: referenceDate)
        if Calendar.current.isDateInToday(referenceDate) { cachedTrainingLoad = load }
        return trainingContext(from: load, relativeTo: referenceDate)
    }

    /// A reanalysis reads the load as of the session's date. A past day's load
    /// goes into the per-day store, never the shared current-load cache, so a
    /// live read made meanwhile cannot pick up a past day's numbers. Returns
    /// the day key to release afterwards; nil for today, whose load is the
    /// cache, and when training-load integration is off. Each reanalysis of
    /// that day holds the load until it releases it, so two sessions of one
    /// day (a nap and the night) do not clear it for each other.
    func holdPastDayTrainingLoad(asOf sessionDate: Date) async -> Date? {
        let calendar = Calendar.current
        guard settingsManager.settings.enableTrainingLoadIntegration,
              !calendar.isDateInToday(sessionDate) else { return nil }
        let day = calendar.startOfDay(for: sessionDate)
        pastDayTrainingLoadHolders[day, default: 0] += 1
        pastDayTrainingLoads[day] = await healthKit.calculateTrainingLoad(relativeTo: sessionDate)
        return day
    }

    /// The last reanalysis of a day to finish drops its load.
    func releasePastDayTrainingLoad(_ day: Date) {
        let holders = (pastDayTrainingLoadHolders[day] ?? 1) - 1
        guard holders <= 0 else {
            pastDayTrainingLoadHolders[day] = holders
            return
        }
        pastDayTrainingLoadHolders[day] = nil
        pastDayTrainingLoads[day] = nil
    }

    // MARK: - Baseline and configuration

    /// Baseline to score `session` against: the stored nights before the
    /// session's own, so a reading is never compared with itself or with
    /// nights recorded after it.
    func scoringBaselineStats(for session: HRVSession) -> BaselineTracker.RecoveryBaselineStats? {
        baselineTracker.recoveryBaselineStats(
            excludingNightOf: session, sleepSchedule: settingsManager.settings.sleepSchedule
        )
    }

    /// Current scoring configuration for RecoveryScoreCalculator, built from
    /// the user's settings.
    var currentScoringConfig: RecoveryScoreCalculator.ScoringConfiguration {
        RecoveryScoreCalculator.ScoringConfiguration(from: settingsManager.settings)
    }

    /// Current ANS configuration for the analysis pipeline: today's training
    /// load and every stored night as the baseline.
    var currentANSConfig: HRVAnalysisPipeline.ANSConfiguration {
        ansConfig(asOf: Date())
    }

    /// ANS configuration with the training load as of `date` — a past
    /// session's analysis reads that day's load, not today's. The baseline is
    /// every stored night; scoring a specific session uses
    /// `ansConfig(for:)` instead.
    func ansConfig(asOf date: Date) -> HRVAnalysisPipeline.ANSConfiguration {
        ansConfig(asOf: date, baseline: baselineTracker.recoveryBaselineStats)
    }

    /// ANS configuration for analysing `session`: the training load as of its
    /// end (now, for a session still being recorded) and the same prior-nights
    /// baseline its recovery score uses (`scoringBaselineStats(for:)`), so
    /// re-analysing an old night never normalises readiness against nights
    /// recorded after it.
    func ansConfig(for session: HRVSession) -> HRVAnalysisPipeline.ANSConfiguration {
        ansConfig(asOf: session.endDate ?? Date(), baseline: scoringBaselineStats(for: session))
    }

    private func ansConfig(
        asOf date: Date,
        baseline: BaselineTracker.RecoveryBaselineStats?
    ) -> HRVAnalysisPipeline.ANSConfiguration {
        let settings = settingsManager.settings
        let load = trainingLoad(asOf: date)
        // Readiness starts from the same geometric baseline the recovery score
        // uses (exp(lnRmssdMean), last 60 stored nights), so both read ONE "your typical
        // RMSSD" value; each still transforms it differently (age-norm/DFA for
        // readiness, personal-delta for recovery). Falls back to the
        // settings baseline, then population, until BaselineTracker has
        // accumulated enough data.
        let baselineRMSSD = baseline.map { exp($0.lnRmssdMean) }
            ?? settings.baselineRMSSD ?? settings.populationBaselineRMSSD

        return HRVAnalysisPipeline.ANSConfiguration(
            baselineRMSSD: baselineRMSSD,
            vo2Max: configuredVO2Max(load),
            trainingLoadAdjustment: configuredTrainingLoadAdjustment(load)
        )
    }

    /// Explicit override wins, then the HealthKit-derived value when the user
    /// opted into it, else nothing.
    private func configuredVO2Max(_ load: HealthKitManager.TrainingLoad?) -> Double? {
        let settings = settingsManager.settings
        if let override = settings.vo2MaxOverride {
            return override
        }
        return settings.useHealthKitVO2Max ? load?.vo2Max : nil
    }

    private func configuredTrainingLoadAdjustment(_ load: HealthKitManager.TrainingLoad?) -> Double {
        guard settingsManager.settings.enableTrainingLoadIntegration, let load else { return 0 }
        return load.readinessAdjustment
    }

    // MARK: - Analysis

    /// Analyse `session` over `window` with the training context as of the
    /// session's end (fetched when not held) and its own ANS configuration.
    func analyze(
        _ session: HRVSession, window: WindowSelector.RecoveryWindow, flags: [ArtifactFlags],
        peakCapacity: PeakCapacity?, pipeline: HRVAnalysisPipeline
    ) async -> HRVAnalysisResult? {
        let sessionDate = session.endDate ?? session.startDate
        return await pipeline.analyzeWithWindow(
            session: session,
            window: window,
            flags: flags,
            peakCapacity: peakCapacity,
            trainingContext: await createTrainingContextEnsuringFresh(relativeTo: sessionDate),
            ansConfig: ansConfig(for: session)
        )
    }

    /// Analyse the whole session, for one with no organised recovery window,
    /// with the same training context and ANS configuration as `analyze(_:window:…)`.
    func analyze(
        _ session: HRVSession, peakCapacity: PeakCapacity?, pipeline: HRVAnalysisPipeline
    ) async -> HRVAnalysisResult? {
        let sessionDate = session.endDate ?? session.startDate
        return await pipeline.analyzeFullSession(
            session: session,
            peakCapacity: peakCapacity,
            trainingContext: await createTrainingContextEnsuringFresh(relativeTo: sessionDate),
            ansConfig: ansConfig(for: session)
        )
    }
}
