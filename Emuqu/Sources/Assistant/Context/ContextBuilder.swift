import CoreLocation
import Foundation

/// Builds an `AssistantContext` from the live app state.
///
/// Stateless. The caller (typically `AssistantViewModel` or a debug screen)
/// gathers the inputs from its existing data sources and hands them in.
/// This avoids any direct coupling to singletons (`AppDependencies.current.storage.sessionArchive`,
/// `HealthKitManager`) so the builder is straightforward to call from
/// any context and easy to test.
///
/// All inputs except `userSettings` are optional. Missing data degrades
/// gracefully — the resulting context simply omits the corresponding
/// snapshot fields.
enum ContextBuilder {
    static func build(
        latestSession: HRVSession?,
        yesterdaySession: HRVSession? = nil,
        recentSessions: [HRVSession],
        sleepInput: AnalysisSleepInput = .empty,
        sleepTrend: AnalysisSleepTrendInput? = nil,
        trainingContext: TrainingContext? = nil,
        userSettings: UserSettings,
        customTagNames: [String] = [],
        baseline: BaselineTracker.Baseline? = nil,
        baselineStats: BaselineTracker.RecoveryBaselineStats? = nil,
        trends7Day: TrendAnalyzer.TrendSummary? = nil,
        trends30Day: TrendAnalyzer.TrendSummary? = nil,
        // Pre-resolved on MainActor by the caller so the
        // downstream AnalysisSummaryGenerator doesn't have to hop back
        // via `MainActor.assumeIsolated` (which traps off-main).
        liveLoadSnapshot: TrainingLoadRegistry.TrainingLoad? = nil
    ) -> AssistantContext {
        AssistantContext(
            generatedAt: Date(),
            userProfile: buildUserProfile(
                settings: userSettings, customTagNames: customTagNames,
                effectiveVO2Max: effectiveVO2Max(settings: userSettings, training: trainingContext)),
            today: latestSession.flatMap { buildSessionSnapshot(session: $0, trainingFallback: trainingContext) },
            yesterday: yesterdaySession.flatMap { buildSessionSnapshot(session: $0, trainingFallback: nil) },
            yesterdayDiagnostic: yesterdayDiagnostic(
                session: yesterdaySession, recentSessions: recentSessions,
                userSettings: userSettings, liveLoadSnapshot: liveLoadSnapshot),
            recent: recentLiteSnapshots(recentSessions), baselines: buildBaselineSnapshot(baseline: baseline, stats: baselineStats),
            trends7Day: trends7Day.map { buildTrendSnapshot(summary: $0, periodLabel: "7 Days") }, trends30Day: trends30Day.map { buildTrendSnapshot(summary: $0, periodLabel: "30 Days") },
            analysisSummary: computeOrFetchSummary(
                session: latestSession, recentSessions: recentSessions, sleepInput: sleepInput,
                sleepTrend: sleepTrend, trainingContext: trainingContext,
                userSettings: userSettings, liveLoadSnapshot: liveLoadSnapshot),
            recentWorkouts: buildWorkoutHistory(sessions: recentSessions),
            liveWorkout: AppDependencies.current.assistant.liveWorkoutBroker.currentSnapshot(), liveHRVSession: AppDependencies.current.assistant.liveHRVBroker.currentSnapshot(),
            ambientLocation: buildAmbientLocationSnapshot()
        )
    }

    /// Yesterday's sleep/training data lives on the session itself — we don't
    /// have HK-derived inputs to pass, so this degrades to defaults.
    private static func yesterdayDiagnostic(
        session: HRVSession?,
        recentSessions: [HRVSession],
        userSettings: UserSettings,
        liveLoadSnapshot: TrainingLoadRegistry.TrainingLoad?
    ) -> AssistantContext.AnalysisSummarySnapshot? {
        computeOrFetchSummary(
            session: session,
            recentSessions: recentSessions,
            sleepInput: AnalysisSleepInput(from: session?.sleepSnapshot),
            sleepTrend: nil,
            trainingContext: session?.trainingSnapshot,
            userSettings: userSettings,
            liveLoadSnapshot: liveLoadSnapshot
        )
    }

    /// Mirrors the scoring path (RRCollector / WorkoutRecorder): a manual
    /// override wins, else the HealthKit estimate (carried on the
    /// already-resolved trainingContext, so no MainActor hop here) when the
    /// user opted in. Without this the passive context showed VO2max only when
    /// the user had typed a manual override.
    private static func effectiveVO2Max(settings: UserSettings, training: TrainingContext?) -> Double? {
        if let override = settings.vo2MaxOverride { return override }
        return settings.useHealthKitVO2Max ? training?.vo2Max : nil
    }

    /// Recent sessions in lite form — most recent first, capped at 14.
    private static func recentLiteSnapshots(
        _ sessions: [HRVSession]
    ) -> [AssistantContext.SessionSnapshotLite] {
        sessions
            .filter { $0.state == .complete || $0.state == .paused }
            .sorted { $0.startDate > $1.startDate }
            .prefix(14)
            .map { buildLiteSnapshot(session: $0) }
    }

    /// Snapshot the always-on resolved-address cache so it
    /// reaches every conversation's system prompt, workout or not. Both
    /// reads go through `AmbientLocationService`'s lock-protected
    /// state — `cachedLocation` for the raw fix, `cachedResolvedAddress`
    /// for the road / locality / cross-street mirror that
    /// `RoadGeocodingService.publishContext` pushes on every resolution.
    /// No MainActor hop, no `DispatchQueue.main.sync` — both readers
    /// are safe from any Swift Concurrency context (Tasks, detached
    /// work, cooperative pool workers).
    ///
    /// Reading `AppDependencies.current.location.roadGeocodingService.current`
    /// directly via `MainActor.assumeIsolated { ... }` would
    /// crash (EXC_BREAKPOINT) when the builder runs from a
    /// non-MainActor thread, which is most of the time when
    /// `AssistantContextSource.currentContext()` is awaited from a
    /// background Task.
    ///
    /// 600 s on the address mirror — the same generous window as the raw fix.
    /// The resolved address only ages by distance (handled inside
    /// RoadGeocodingService); a 5-minute-old name is still correct if the user
    /// hasn't moved a block.
    private static func buildAmbientLocationSnapshot() -> AssistantContext.AmbientLocationSnapshot? {
        let rawLoc = AppDependencies.current.location.ambientLocationService.cachedLocation(maxAgeSec: 600)
        let road = AppDependencies.current.location.ambientLocationService.cachedResolvedAddress(maxAgeSec: 600)
        guard rawLoc != nil || road != nil else { return nil }
        return AssistantContext.AmbientLocationSnapshot(
            road: road?.road,
            nearestCrossStreet: road?.nearestCrossStreet,
            locality: road?.locality,
            subdivision: road?.subdivision ?? road?.subLocality ?? road?.areaOfInterest,
            administrativeArea: road?.administrativeArea,
            country: road?.country,
            headingCardinal: cardinalDirection(courseDegrees: rawLoc?.course),
            headingDegrees: (rawLoc?.course ?? -1) >= 0 ? rawLoc?.course : nil,
            speedMS: (rawLoc?.speed ?? -1) >= 0 ? rawLoc?.speed : nil,
            altitudeMeters: rawLoc?.altitude,
            accuracyMeters: rawLoc?.horizontalAccuracy,
            ageSeconds: snapshotAgeSeconds(rawLoc: rawLoc, road: road)
        )
    }

    /// Eight-point compass label, or nil when the course is unknown (CoreLocation
    /// reports a negative course when it has no heading).
    private static func cardinalDirection(courseDegrees: Double?) -> String? {
        guard let course = courseDegrees, course >= 0 else { return nil }
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((course + 22.5).truncatingRemainder(dividingBy: 360) / 45)
        return dirs[max(0, min(7, index))]
    }

    /// How stale the snapshot is: prefer the raw fix's timestamp, fall back to
    /// when the address was resolved.
    private static func snapshotAgeSeconds(rawLoc: CLLocation?, road: RoadGeocodingService.RoadContext?) -> Int? {
        if let last = rawLoc?.timestamp { return Int(Date().timeIntervalSince(last)) }
        guard let observed = road?.observedAt else { return nil }
        return Int(Date().timeIntervalSince(observed))
    }

    /// Read an `AnalysisSummary` from the shared cache, or compute one if missing.
    /// Always writes back to the cache on compute so the next read is a hit.
    private static func computeOrFetchSummary(
        session: HRVSession?,
        recentSessions: [HRVSession],
        sleepInput: AnalysisSleepInput,
        sleepTrend: AnalysisSleepTrendInput?,
        trainingContext: TrainingContext?,
        userSettings: UserSettings,
        liveLoadSnapshot: TrainingLoadRegistry.TrainingLoad? = nil
    ) -> AssistantContext.AnalysisSummarySnapshot? {
        guard let session, let result = session.analysisResult else { return nil }
        if let cached = AppDependencies.current.assistant.analysisSummaryCache.get(forSessionId: session.id) {
            return mapSummary(cached)
        }
        let generator = AnalysisSummaryGenerator(
            result: result,
            session: session,
            recentSessions: recentSessions,
            selectedTags: Set(session.tags),
            sleep: sleepInput,
            sleepTrend: sleepTrend,
            trainingContext: trainingContext ?? session.trainingSnapshot,
            userAge: userSettings.age,
            biologicalSex: userSettings.biologicalSex,
            liveLoadSnapshot: liveLoadSnapshot
        )
        let summary = generator.generate()
        AppDependencies.current.assistant.analysisSummaryCache.set(summary, forSessionId: session.id)
        return mapSummary(summary)
    }

    private static func mapSummary(_ summary: AnalysisSummaryGenerator.AnalysisSummary) -> AssistantContext.AnalysisSummarySnapshot {
        AssistantContext.AnalysisSummarySnapshot(
            analysisTitle: summary.analysisTitle,
            diagnosticScore: summary.diagnosticScore,
            analysisExplanation: summary.analysisExplanation,
            probableCauses: summary.probableCauses.map {
                .init(cause: $0.cause, confidence: $0.confidence, explanation: $0.explanation)
            },
            keyFindings: summary.keyFindings,
            actionableSteps: summary.actionableSteps,
            trendInsight: summary.trendInsight
        )
    }

    // MARK: - Builders

    private static func buildUserProfile(
        settings: UserSettings,
        customTagNames: [String],
        effectiveVO2Max: Double?
    ) -> AssistantContext.UserProfileSnapshot {
        AssistantContext.UserProfileSnapshot(
            age: settings.age,
            biologicalSex: settings.biologicalSex?.rawValue,
            fitnessLevel: settings.fitnessLevel?.rawValue,
            vo2Max: effectiveVO2Max,
            typicalSleepHours: settings.typicalSleepHours,
            customTagNames: customTagNames,
            maxHR: settings.effectiveMaxHR,
            maxHRIsUserOverride: settings.maxHR != nil,
            unitsPreference: UnitsPreferenceStore.current.resolved.rawValue,
            onTrainingBreak: settings.isOnTrainingBreak,
            trainingBreakReason: settings.trainingBreakReason,
            sleepIntegrationEnabled: settings.enableSleepIntegration,
            trainingLoadIntegrationEnabled: settings.enableTrainingLoadIntegration,
            comebackModeActive: settings.isComebackModeActive,
            comebackModeDayInWindow: comebackDayInWindow(settings),
            scoreAlgorithmVersion: ScoringVersion.current, // HRV/Sleep/Vitals 60/25/15
            scoreHistoryRecomputed: settings.hasRunScoreHistoryRecompute
        )
    }

    /// Derive Comeback day-in-window from the start date so
    /// the AI can phrase "5 days into a 21-day comeback" instead of just
    /// "comeback is on".
    private static func comebackDayInWindow(_ settings: UserSettings) -> Int? {
        guard settings.isComebackModeActive,
              let start = settings.comebackModeStartDate else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return cal.dateComponents([.day], from: cal.startOfDay(for: start), to: today).day
    }

    /// Build the compact workout-history array fed into the Assistant so it
    /// can answer "what runs have I done this week?" without reloading the
    /// heavy HRVSession objects. Includes per-session avg pace / avg HR /
    /// TRIMP / METs — derived live from samples when available.
    ///
    /// Separate from `recent`, which is HRV-flavoured. Builds from the same
    /// sessions array so we don't re-query the archive.
    private static func buildWorkoutHistory(sessions: [HRVSession]) -> [AssistantContext.WorkoutHistoryEntry] {
        sessions
            .filter { $0.sessionType == .workout }
            .sorted { $0.startDate > $1.startDate }
            .prefix(30)
            .map { workoutHistoryEntry($0) }
    }

    /// One workout as a history entry.
    private static func workoutHistoryEntry(_ s: HRVSession) -> AssistantContext.WorkoutHistoryEntry {
        let meta = s.workoutMetadata
        let duration = s.duration.map { Int($0) }
        let derived = derivedSampleMetrics(samples: meta?.samples ?? [], durationSec: duration)
        return AssistantContext.WorkoutHistoryEntry(
            date: s.startDate, sport: meta?.sport.rawValue ?? "unknown", durationSec: duration,
            distanceMeters: meta?.distanceMeters, elevationGainMeters: meta?.elevationGainMeters,
            averageHR: s.meanHR ?? derived.avgHR, maxHRInSession: derived.maxHR,
            averagePaceSecPerKm: paceSecPerKm(distance: meta?.distanceMeters, durationSec: duration),
            trimp: meta?.luciaTRIMP, hrTSS: meta?.hrTSS, decouplingPercent: meta?.decouplingPercent,
            avgMETs: derived.avgMETs, estimatedCalories: derived.kcal,
            avgPowerWatts: meta?.averagePowerWatts, normalizedPowerWatts: meta?.normalizedPowerWatts,
            peakPowerWatts: meta?.peakPowerWatts, powerTSS: meta?.powerTSS,
            intensityFactor: meta?.intensityFactor,
            avgCadenceSpm: derived.avgCadenceSpm, alpha1Mean: derived.alpha1Mean,
            hrr1MinDrop: meta?.hrrSamples?.bestAtOneMinute?.drop,
            hrr2MinDrop: meta?.hrrSamples?.bestAtTwoMinutes?.drop,
            workoutFeeling: meta?.workoutFeeling, workoutFeelingNote: meta?.workoutFeelingNote
        )
    }

    /// Everything the per-tick sample series yields.
    private struct DerivedSampleMetrics {
        var avgHR: Double?
        var maxHR: Int?
        var avgMETs: Double?
        var kcal: Double?
        var avgCadenceSpm: Int?
        var alpha1Mean: Double?
    }

    /// `s.meanHR` is sourced from
    /// `analysisResult.timeDomain.meanHR`, which only exists
    /// when an HRV analysis ran. Workout sessions typically
    /// skip that pipeline (no RR stream → no time-domain
    /// result), so the AI never saw an avg HR. The caller falls back to
    /// `avgHR` here — the simple average of the HR sample series, which is
    /// present on every workout that captured HR.
    ///
    /// Average cadence and α1 mean come from the same per-tick
    /// samples. Nil when no samples were captured (legacy sessions) or none of
    /// the samples carried that value (no foot-pod / no bike sensor).
    private static func derivedSampleMetrics(
        samples: [WorkoutSample],
        durationSec: Int?
    ) -> DerivedSampleMetrics {
        var out = DerivedSampleMetrics()
        let hrs = samples.compactMap { $0.heartRate }
        out.maxHR = hrs.max()
        if !hrs.isEmpty { out.avgHR = Double(hrs.reduce(0, +)) / Double(hrs.count) }
        let mets = samples.compactMap { $0.mets }
        if !mets.isEmpty { out.avgMETs = mets.reduce(0, +) / Double(mets.count) }
        out.kcal = estimatedCalories(avgMETs: out.avgMETs, durationSec: durationSec)
        let cadences = samples.compactMap { $0.cadenceStepsPerMin }
        if !cadences.isEmpty {
            out.avgCadenceSpm = Int(round(Double(cadences.reduce(0, +)) / Double(cadences.count)))
        }
        let alphas = samples.compactMap { $0.alpha1 }
        if !alphas.isEmpty { out.alpha1Mean = alphas.reduce(0, +) / Double(alphas.count) }
        return out
    }

    /// Compendium kcal formula using the user's real weight from settings
    /// (else the 75 kg fallback `effectiveBodyWeightKg` exposes). Consistent
    /// with the post-summary card.
    private static func estimatedCalories(avgMETs: Double?, durationSec: Int?) -> Double? {
        guard let avg = avgMETs, let dur = durationSec, dur > 0 else { return nil }
        let weightKg = AppDependencies.current.app.settingsManager.settingsSnapshot.effectiveBodyWeightKg
        return (avg * 3.5 * weightKg * (Double(dur) / 60.0)) / 200.0
    }

    /// Seconds per kilometre, or nil when the workout is too short to make the
    /// figure meaningful.
    private static func paceSecPerKm(distance: Double?, durationSec: Int?) -> Double? {
        guard let dist = distance, dist > 100, let dur = durationSec, dur > 10 else { return nil }
        return Double(dur) * 1000.0 / dist
    }

    private static func buildSessionSnapshot(
        session: HRVSession,
        trainingFallback: TrainingContext?
    ) -> AssistantContext.SessionSnapshot {
        let result = session.analysisResult
        return AssistantContext.SessionSnapshot(
            id: session.id, startDate: session.startDate, endDate: session.endDate,
            sessionType: session.sessionType.rawValue,
            recoveryScore: session.recoveryScore, scoreTier: session.scoreBreakdown?.tier,
            scoreFactors: scoreFactorSnapshots(session),
            scorePenalties: session.scoreBreakdown?.penalties ?? [], scoreMessage: session.scoreBreakdown?.message,
            timeDomain: timeDomainSnapshot(result), frequencyDomain: frequencyDomainSnapshot(result),
            nonlinear: nonlinearSnapshot(result), ansMetrics: ansSnapshot(result),
            overnightHR: overnightHRSnapshot(session: session, result: result),
            sleep: sleepSnapshot(for: session), vitals: vitalsSnapshot(for: session),
            training: trainingSnapshot(session: session, fallback: trainingFallback),
            tags: session.tags.map(\.name), notes: session.notes,
            morningFeeling: session.morningFeeling,
            morningFeelingTags: (session.morningFeelingTags ?? []).map(\.rawValue),
            hrvDataQuality: session.hrvDataQuality?.rawValue,
            perceivedReadiness: session.perceivedReadiness, artifactPercentage: result?.artifactPercentage
        )
    }

    private static func timeDomainSnapshot(
        _ result: HRVAnalysisResult?
    ) -> AssistantContext.TimeDomainSnapshot? {
        result.map {
            AssistantContext.TimeDomainSnapshot(
                rmssd: $0.timeDomain.rmssd,
                sdnn: $0.timeDomain.sdnn,
                pnn50: $0.timeDomain.pnn50,
                meanRR: $0.timeDomain.meanRR,
                meanHR: $0.timeDomain.meanHR
            )
        }
    }

    private static func frequencyDomainSnapshot(
        _ result: HRVAnalysisResult?
    ) -> AssistantContext.FrequencyDomainSnapshot? {
        result?.frequencyDomain.map {
            AssistantContext.FrequencyDomainSnapshot(
                lf: $0.lf, hf: $0.hf, lfHfRatio: $0.lfHfRatio, totalPower: $0.totalPower
            )
        }
    }

    private static func nonlinearSnapshot(
        _ result: HRVAnalysisResult?
    ) -> AssistantContext.NonlinearSnapshot? {
        result.map {
            AssistantContext.NonlinearSnapshot(
                sd1: $0.nonlinear.sd1,
                sd2: $0.nonlinear.sd2,
                sd1Sd2Ratio: $0.nonlinear.sd1Sd2Ratio,
                dfaAlpha1: $0.nonlinear.dfaAlpha1,
                dfaAlpha2: $0.nonlinear.dfaAlpha2,
                sampleEntropy: $0.nonlinear.sampleEntropy
            )
        }
    }

    private static func ansSnapshot(
        _ result: HRVAnalysisResult?
    ) -> AssistantContext.ANSMetricsSnapshot? {
        result?.ansMetrics.map {
            AssistantContext.ANSMetricsSnapshot(
                stressIndex: $0.stressIndex,
                pnsIndex: $0.pnsIndex,
                snsIndex: $0.snsIndex,
                readinessScore: $0.readinessScore,
                respirationRate: $0.respirationRate,
                nocturnalHRDip: $0.nocturnalHRDip
            )
        }
    }

    /// The session's own frozen training snapshot, falling back to the live
    /// one when the session predates snapshot capture.
    private static func trainingSnapshot(
        session: HRVSession,
        fallback: TrainingContext?
    ) -> AssistantContext.TrainingSnapshot? {
        (session.trainingSnapshot ?? fallback).map { t in
            AssistantContext.TrainingSnapshot(
                atl: t.atl,
                ctl: t.ctl,
                tsb: t.tsb,
                acwr: t.acuteChronicRatio,
                yesterdayTrimp: t.yesterdayTrimp,
                daysSinceHardWorkout: t.daysSinceHardWorkout,
                vo2Max: t.vo2Max
            )
        }
    }

    private static func scoreFactorSnapshots(
        _ session: HRVSession
    ) -> [AssistantContext.ScoreFactorSnapshot] {
        session.scoreBreakdown?.factors.map { f in
            .init(
                label: f.label,
                detail: f.detail,
                score: f.score,
                weight: f.weight,
                impact: impactString(f.impact),
                contribution: f.contribution
            )
        } ?? []
    }

    private static func buildLiteSnapshot(session: HRVSession) -> AssistantContext.SessionSnapshotLite {
        let cachedSummary = AppDependencies.current.assistant.analysisSummaryCache.get(forSessionId: session.id)
        let snapshot = session.sleepSnapshot
        return AssistantContext.SessionSnapshotLite(
            date: session.startDate,
            sessionType: session.sessionType.rawValue,
            recoveryScore: session.recoveryScore,
            rmssd: session.analysisResult?.timeDomain.rmssd, meanHR: session.analysisResult?.timeDomain.meanHR,
            stressIndex: session.analysisResult?.ansMetrics?.stressIndex,
            sleepMinutes: snapshot?.nightSleepMinutes, morningFeeling: session.morningFeeling,
            tags: session.tags.map(\.name),
            atl: session.trainingSnapshot?.atl, ctl: session.trainingSnapshot?.ctl,
            tsb: session.trainingSnapshot?.tsb, acwr: session.trainingSnapshot?.acuteChronicRatio,
            yesterdayTrimp: session.trainingSnapshot?.yesterdayTrimp,
            analysisTitle: cachedSummary?.analysisTitle, scoreMessage: session.scoreBreakdown?.message,
            deepSleepMinutes: snapshot?.deepSleepMinutes, remSleepMinutes: snapshot?.remSleepMinutes,
            coreSleepMinutes: coreSleepMinutes(snapshot), awakeMinutes: snapshot?.awakeMinutes,
            nocturnalDipPercent: session.analysisResult?.ansMetrics?.nocturnalHRDip
        )
    }

    /// Core sleep derived the same way Archive does — sum per-segment when
    /// present, otherwise total − deep − REM.
    private static func coreSleepMinutes(_ snapshot: SleepData?) -> Int? {
        if let snap = snapshot {
            let summed = snap.effectiveSegments.compactMap(\.coreSleepMinutes).reduce(0, +)
            if summed > 0 { return summed }
        }
        guard let total = snapshot?.nightSleepMinutes,
              let deep = snapshot?.deepSleepMinutes,
              let rem = snapshot?.remSleepMinutes else { return nil }
        return max(0, total - deep - rem)
    }

    private static func buildBaselineSnapshot(
        baseline: BaselineTracker.Baseline?,
        stats: BaselineTracker.RecoveryBaselineStats?
    ) -> AssistantContext.BaselineSnapshot? {
        guard baseline != nil || stats != nil else { return nil }
        return AssistantContext.BaselineSnapshot(
            lnRmssdMean: stats?.lnRmssdMean,
            lnRmssdSD: stats?.lnRmssdSD,
            lnRmssdCV7Day: stats?.lnRmssdCV7Day,
            meanHRBaseline: stats?.meanHRBaseline,
            meanHRSD: stats?.meanHRSD,
            daysInWindow: stats?.daysInWindow ?? 0,
            lastDataPointDate: stats?.lastDataPointDate,
            rmssdBaseline: baseline?.rmssd,
            sdnnBaseline: baseline?.sdnn,
            dfaAlpha1Baseline: baseline?.dfaAlpha1,
            stressIndexBaseline: baseline?.stressIndex
        )
    }

    private static func buildTrendSnapshot(
        summary: TrendAnalyzer.TrendSummary,
        periodLabel: String
    ) -> AssistantContext.TrendSnapshot {
        var metrics: [AssistantContext.TrendSnapshot.MetricTrend] = [
            mapStat(summary.rmssdStats),
            mapStat(summary.sdnnStats),
            mapStat(summary.hrStats)
        ]
        if let s = summary.lfHfStats { metrics.append(mapStat(s)) }
        if let s = summary.dfaAlpha1Stats { metrics.append(mapStat(s)) }
        if let s = summary.stressStats { metrics.append(mapStat(s)) }
        if let s = summary.readinessStats { metrics.append(mapStat(s)) }

        return AssistantContext.TrendSnapshot(
            period: periodLabel,
            dataPointCount: summary.dataPoints.count,
            overallTrend: summary.overallTrend.rawValue,
            metrics: metrics,
            insights: summary.insights
        )
    }

    private static func mapStat(_ s: TrendAnalyzer.TrendStatistics) -> AssistantContext.TrendSnapshot.MetricTrend {
        AssistantContext.TrendSnapshot.MetricTrend(
            metric: s.metric,
            count: s.count,
            mean: s.mean,
            standardDeviation: s.standardDeviation,
            min: s.min,
            max: s.max,
            trend: s.trend.rawValue,
            trendSlope: s.trendSlope,
            coefficientOfVariation: s.coefficientOfVariation,
            baseline: s.baseline,
            deviationFromBaseline: s.deviationFromBaseline
        )
    }

    private static func impactString(_ impact: RecoveryScoreCalculator.ScoreFactor.Impact) -> String {
        switch impact {
        case .positive: "positive"
        case .neutral: "neutral"
        case .negative: "negative"
        }
    }
}

// MARK: - Session sub-snapshots
//
// Built separately so `buildSessionSnapshot` reads as the list of things a
// session snapshot contains, rather than as the arithmetic for each of them.

extension ContextBuilder {
    /// Recovery vitals. Wrist temperature is reported as a deviation from the
    /// user's own baseline where one exists, since the absolute number means
    /// nothing without it; with no baseline the raw reading passes through.
    private static func vitalsSnapshot(for session: HRVSession) -> AssistantContext.VitalsSnapshot? {
        session.vitalsSnapshot.map { v in
            AssistantContext.VitalsSnapshot(
                respiratoryRate: v.respiratoryRate,
                respiratoryRateBaseline: v.respiratoryRateBaseline,
                oxygenSaturation: v.oxygenSaturation,
                oxygenSaturationMin: v.oxygenSaturationMin,
                wristTemperatureDeviation: Self.temperatureDeviation(v),
                restingHeartRate: v.restingHeartRate
            )
        }
    }

    private static func temperatureDeviation(_ v: RecoveryVitals) -> Double? {
        guard let t = v.wristTemperature else { return nil }
        guard let baseline = v.wristTemperatureBaseline else { return t }
        return t - baseline
    }

    /// Whole-recording HR summary — nadir plus min/max/mean across the FULL
    /// session, not the analysis window. Persisted on the analysis result by
    /// `HRVAnalysisPipeline.attachOvernightHRStats`.
    ///
    /// Wall-clock time of the nadir comes from session start + offset, but when
    /// `rrSeries` is loaded its `wallClockTime(forTMs:)` mapping wins, because
    /// that one honours data gaps.
    private static func overnightHRSnapshot(
        session: HRVSession,
        result: HRVAnalysisResult?
    ) -> AssistantContext.OvernightHRSnapshot? {
        guard let r = result, let nadir = r.overnightNadirHR,
              let min = r.overnightMinHR, let max = r.overnightMaxHR,
              let mean = r.overnightMeanHR
        else { return nil }
        let nadirAt: Date? = {
            guard let offsetMs = r.overnightNadirTimeMs else { return nil }
            if let series = session.rrSeries {
                return series.wallClockTime(forTMs: offsetMs)
            }
            return session.startDate.addingTimeInterval(TimeInterval(offsetMs) / 1000.0)
        }()
        return AssistantContext.OvernightHRSnapshot(
            nadirBPM: nadir,
            nadirAt: nadirAt,
            minBPM: min,
            maxBPM: max,
            meanBPM: mean
        )
    }

    /// Sleep totals for the assistant context.
    ///
    /// `SleepData.sleepEfficiency` is stored as 0–100 (percent). The
    /// assistant-context field is documented 0–1 (fraction) and the renderers
    /// multiply by 100 before appending "%". Passing the raw percent through
    /// produced "9592%" in the prompt — which is how the AI came to surface
    /// that figure. The conversion belongs here, at the seam.
    private static func sleepSnapshot(for session: HRVSession) -> AssistantContext.SleepSnapshot? {
        session.sleepSnapshot.map { sleep in
            AssistantContext.SleepSnapshot(
                totalSleepMinutes: sleep.nightSleepMinutes,
                inBedMinutes: sleep.inBedMinutes,
                deepSleepMinutes: sleep.deepSleepMinutes,
                remSleepMinutes: sleep.remSleepMinutes,
                awakeMinutes: sleep.awakeMinutes,
                sleepEfficiency: sleep.sleepEfficiency / 100.0,
                isShortSleep: sleep.nightSleepMinutes > 0
                    && sleep.nightSleepMinutes < HRVThresholds.sleepShortMinutes,
                isFragmented: sleep.awakeMinutes > HRVThresholds.sleepFragmentedAwakeMinutes
            )
        }
    }
}
