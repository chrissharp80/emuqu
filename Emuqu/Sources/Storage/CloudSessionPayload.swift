import Foundation

// What a session record carries to iCloud: the payload without its Apple
// Health readings, and the restore of this device's own copies of them.
// Moved out of `CloudKitSyncSupport.swift`, which holds the rest of the sync
// support types.

// MARK: - What a session carries to iCloud

/// Keeps every reading taken from Apple Health out of the session payloads
/// uploaded to iCloud.
///
/// Guideline 5.1.3(ii): apps "may not store personal health information in
/// iCloud." Every payload is already encrypted on the device before upload
/// (`CloudPayloadCodec`); on top of that, what Apple Health supplied stays
/// behind, not even uploaded as ciphertext. What the app measured itself (the
/// strap's RR series and its analysis) and the scores and figures it computed
/// travel; the readings it took from HealthKit do not:
///   • sessions read out of Apple Health whole (imported or rebuilt workouts,
///     Apple Watch Breathe readings) are not uploaded;
///   • the sleep snapshot, the sleep boundaries and segments, whether the
///     user adjusted them, and the analysis's sleep-segment label, which
///     quotes a segment's clock times;
///   • the vitals snapshot (respiratory rate, wrist temperature, SpO₂, sleep
///     heart-rate dip);
///   • VO2max and the list of recent workouts, in the session's training
///     snapshot and in the analysis result's copy of it;
///   • Apple Health's daytime resting heart rate the analysis compares the
///     night against (the nocturnal dip computed from it stays);
///   • the explanatory text of the score breakdown's Sleep and Vitals rows
///     and the numbers it quotes (`facts`), and the SpO₂ penalty line and
///     flag, which say that SpO₂ was below 95% (the sub-scores and the
///     composite stay);
///   • heart-rate-recovery samples computed from Apple Watch heart rate or
///     read from HealthKit;
///   • the heart rate on each per-second workout row filled from Apple Health
///     (`healthKitHROffsets`); for a workout recorded with Apple Watch heart
///     rate, also the per-split and per-lap heart rate and the AI snapshot's
///     current and peak heart rate, which are that wrist heart rate.
/// Load figures (ATL, CTL, TSB, TRIMP), zone times and the other scores
/// computed from these readings travel.
/// A device that pulls the session re-derives the sleep and vitals snapshots
/// from its own HealthKit store (`cloudKitSnapshotBackfillNeeded`) and shows
/// the rest as unavailable. A device that already holds the session keeps its
/// own copies of these fields when a newer iCloud copy replaces it
/// (`restoringLocalOnlyFields`).
enum CloudSessionPayload {
    /// The device ids `ImportedWorkoutBuilder.Source.appleHealth` and
    /// `.appleHealthSamples` stamp on a session built from Apple Health data.
    static let healthKitDeviceIds: Set<String> = ["healthkit-import", "healthkit-rebuild"]

    /// The device id `WorkoutRecorder` stamps on a workout whose heart rate
    /// came from Apple Watch (`makeStartProvenance`).
    static let appleWatchDeviceId = "apple-watch"

    /// Keys of a workout's AI snapshot (`HRVSession.aiContext`) that hold a
    /// heart-rate reading.
    static let heartRateContextKeys: Set<String> = ["hr", "peak_hr"]

    /// Score-breakdown rows whose explanatory text quotes HealthKit readings.
    static let healthKitFactorLabels: Set<String> = ["Sleep", "Vitals"]

    /// Whether the whole session came out of Apple Health, so none of it may
    /// be uploaded.
    static func isHealthKitSourced(_ session: HRVSession) -> Bool {
        if session.sessionType == .breathe { return true }
        guard let deviceId = session.deviceProvenance?.deviceId else { return false }
        return healthKitDeviceIds.contains(deviceId)
    }

    /// Whether the session's heart rate is Apple Watch wrist heart rate.
    static func hasAppleWatchHeartRate(_ session: HRVSession) -> Bool {
        session.deviceProvenance?.deviceId == appleWatchDeviceId
    }

    /// The session as it may be uploaded: every HealthKit reading removed,
    /// and the auto-window comparison, which only means something on the
    /// device where the window was picked.
    static func uploadable(_ session: HRVSession) -> HRVSession {
        let watchHR = hasAppleWatchHeartRate(session)
        var payload = session
        payload.sleepSnapshot = nil
        payload.vitalsSnapshot = nil
        payload.sleepStartMs = nil
        payload.sleepEndMs = nil
        payload.sleepSegments = nil
        payload.sleepUserAdjusted = nil
        payload.trainingSnapshot = session.trainingSnapshot.map(trainingWithoutHealthKitReadings)
        payload.analysisResult = session.analysisResult.map(analysisWithoutHealthKitReadings)
        payload.scoreBreakdown = session.scoreBreakdown.map(breakdownWithoutHealthKitReadings)
        payload.workoutMetadata = session.workoutMetadata.map { workoutWithoutHealthKitReadings($0, watchHR: watchHR) }
        if watchHR { payload.aiContext = session.aiContext?.filter { !heartRateContextKeys.contains($0.key) } }
        payload.autoWindowResult = nil
        payload.autoWindowScore = nil
        return payload
    }

    /// Put back into `merged`, a newer iCloud copy, the HealthKit readings this
    /// device holds and the upload left out. A field the iCloud copy does carry
    /// (a record written before these were stripped) is kept as it came.
    ///
    /// The vitals snapshot's sleep HR follows the iCloud copy's analysis and
    /// quality (`HRVSession.refreshSleepHeartRate`) when that gives another
    /// sleep HR than this device's copy: a reanalysis made on the other device
    /// moves the window, and the local snapshot holds the strap heart rate of
    /// the window it replaced. An edit that left the analysis as it was (notes,
    /// tags) keeps the local snapshot as it stands.
    static func restoringLocalOnlyFields(into merged: inout HRVSession, from local: HRVSession) {
        merged.vitalsSnapshot = merged.vitalsSnapshot ?? local.vitalsSnapshot
        if merged.strapSleepHeartRate != local.strapSleepHeartRate {
            merged.refreshSleepHeartRate(replacing: local)
        }
        merged.trainingSnapshot = restoring(merged.trainingSnapshot, from: local.trainingSnapshot)
        merged.analysisResult = merged.analysisResult.map { restoring($0, from: local.analysisResult) }
        merged.scoreBreakdown = restoring(merged.scoreBreakdown, from: local.scoreBreakdown)
        merged.aiContext = restoringHeartRateContext(merged.aiContext, from: local.aiContext)
        if let metadata = merged.workoutMetadata {
            merged.workoutMetadata = restoring(metadata, from: local.workoutMetadata)
        }
    }

    // MARK: Stripping

    /// The recorded load figures on their recorded scale: the copy is the
    /// snapshot without its Health readings, not a rescaled one.
    private static func trainingWithoutHealthKitReadings(_ context: TrainingContext) -> TrainingContext {
        context.withHealthReadings(vo2Max: nil, recentWorkouts: nil)
    }

    private static func analysisWithoutHealthKitReadings(_ result: HRVAnalysisResult) -> HRVAnalysisResult {
        var stripped = result
        if let metrics = result.ansMetrics, metrics.daytimeRestingHR != nil {
            stripped = result.withANSMetrics(metrics.withDaytimeRestingHR(nil))
        }
        stripped.trainingContext = result.trainingContext.map(trainingWithoutHealthKitReadings)
        stripped.analysisSegmentLabel = nil
        return stripped
    }

    private static func breakdownWithoutHealthKitReadings(
        _ breakdown: RecoveryScoreCalculator.ScoreBreakdown
    ) -> RecoveryScoreCalculator.ScoreBreakdown {
        let factors = breakdown.factors.map { factor in
            healthKitFactorLabels.contains(factor.label) ? withDetail("", facts: nil, on: factor) : factor
        }
        return RecoveryScoreCalculator.ScoreBreakdown(
            compositeScore: breakdown.compositeScore, tier: breakdown.tier, factors: factors,
            penalties: penaltiesWithoutSpO2(breakdown), spo2PenaltyApplied: false,
            scoringVersion: breakdown.scoringVersion
        )
    }

    /// The penalty lines without the SpO₂ one. Scoring lists it first
    /// (`computeBreakdown`); a record scored before the lines were localized
    /// is matched by its English text instead.
    private static func penaltiesWithoutSpO2(_ breakdown: RecoveryScoreCalculator.ScoreBreakdown) -> [String] {
        var lines = breakdown.penalties
        guard breakdown.spo2PenaltyApplied, !lines.isEmpty else { return lines }
        let english = lines.firstIndex { ScoreBreakdownCopy.listsEnglishSpO2Penalty([$0]) }
        lines.remove(at: english ?? lines.startIndex)
        return lines
    }

    private static func workoutWithoutHealthKitReadings(_ metadata: WorkoutMetadata, watchHR: Bool) -> WorkoutMetadata {
        var stripped = metadata
        stripped.hrrSamples = strapMeasured(metadata.hrrSamples)
        stripped.samples = withoutHealthKitHR(metadata)
        guard watchHR else { return stripped }
        stripped.splits = metadata.splits?.map { $0.withAverageHR(nil) }
        stripped.laps = metadata.laps?.map { $0.withHeartRate(average: nil, max: nil) }
        return stripped
    }

    /// Only the samples computed from the strap's own RR stream; nil when none.
    private static func strapMeasured(_ samples: [HRRSample]?) -> [HRRSample]? {
        let strap = (samples ?? []).filter { $0.provenance == .strap }
        return strap.isEmpty ? nil : strap
    }

    /// The per-second samples with the heart rate cleared on each row
    /// `healthKitHROffsets` lists: Apple Watch wrist HR read from Apple Health.
    private static func withoutHealthKitHR(_ metadata: WorkoutMetadata?) -> [WorkoutSample]? {
        guard let samples = metadata?.samples else { return nil }
        let offsets = Set(metadata?.healthKitHROffsets ?? [])
        guard !offsets.isEmpty else { return samples }
        return samples.map { offsets.contains($0.offsetSec) ? $0.withHeartRate(nil) : $0 }
    }

    /// The factor with its line and the numbers the line quotes replaced.
    private static func withDetail(
        _ detail: String, facts: ScoreFactorFacts?, on factor: RecoveryScoreCalculator.ScoreFactor
    ) -> RecoveryScoreCalculator.ScoreFactor {
        RecoveryScoreCalculator.ScoreFactor(
            label: factor.label, detail: detail, score: factor.score, weight: factor.weight, impact: factor.impact,
            facts: facts
        )
    }

    // MARK: Restoring

    /// The local VO2max and recent-workout list on the iCloud copy's load
    /// figures. The snapshot is frozen at waking, so a missing iCloud copy
    /// keeps the local one.
    private static func restoring(_ remote: TrainingContext?, from local: TrainingContext?) -> TrainingContext? {
        guard let remote else { return local }
        guard let local, remote.vo2Max == nil, remote.recentWorkouts == nil else { return remote }
        return remote.withHealthReadings(vo2Max: local.vo2Max, recentWorkouts: local.recentWorkouts)
    }

    /// The local training context, and, when both copies are the same
    /// analysis, the local daytime resting heart rate and sleep-segment label.
    private static func restoring(_ remote: HRVAnalysisResult, from local: HRVAnalysisResult?) -> HRVAnalysisResult {
        guard let local else { return remote }
        var merged = remote
        merged.trainingContext = restoring(remote.trainingContext, from: local.trainingContext)
        guard remote.analysisDate == local.analysisDate, remote.windowStart == local.windowStart else { return merged }
        merged.analysisSegmentLabel = remote.analysisSegmentLabel ?? local.analysisSegmentLabel
        if let metrics = remote.ansMetrics, metrics.daytimeRestingHR == nil,
           let held = local.ansMetrics?.daytimeRestingHR {
            merged = merged.withANSMetrics(metrics.withDaytimeRestingHR(held))
        }
        return merged
    }

    /// The local text of each row the upload emptied, with the numbers it
    /// quotes, when the row's sub-score is the one that text explains, and the
    /// local SpO₂ penalty line and flag when the composite is the one they
    /// explain.
    private static func restoring(
        _ remote: RecoveryScoreCalculator.ScoreBreakdown?, from local: RecoveryScoreCalculator.ScoreBreakdown?
    ) -> RecoveryScoreCalculator.ScoreBreakdown? {
        guard let remote, let local else { return remote }
        let factors = remote.factors.map { factor in
            guard factor.detail.isEmpty,
                  let held = local.factors.first(where: { $0.label == factor.label && $0.score == factor.score })
            else { return factor }
            return withDetail(held.detail, facts: held.facts, on: factor)
        }
        let heldSpO2 = local.spo2PenaltyApplied && !remote.spo2PenaltyApplied && local.compositeScore == remote.compositeScore
        return RecoveryScoreCalculator.ScoreBreakdown(
            compositeScore: remote.compositeScore, tier: remote.tier, factors: factors,
            penalties: heldSpO2 ? local.penalties : remote.penalties,
            spo2PenaltyApplied: heldSpO2 || remote.spo2PenaltyApplied,
            scoringVersion: remote.scoringVersion
        )
    }

    /// The local heart-rate entries of the AI snapshot the iCloud copy lacks.
    private static func restoringHeartRateContext(_ remote: [String: String]?, from local: [String: String]?) -> [String: String]? {
        guard var remote, let local else { return remote }
        for key in heartRateContextKeys where remote[key] == nil {
            remote[key] = local[key]
        }
        return remote
    }

    private static func restoring(_ remote: WorkoutMetadata, from local: WorkoutMetadata?) -> WorkoutMetadata {
        var metadata = remote
        metadata.hrrSamples = restoring(remote.hrrSamples, from: local?.hrrSamples)
        // A copy written before these rows were marked carries no list:
        // this device's list keeps the next upload from sending them.
        metadata.healthKitHROffsets = remote.healthKitHROffsets ?? local?.healthKitHROffsets
        metadata.samples = restoringHealthKitHR(metadata, from: local)
        metadata.splits = restoringHR(remote.splits, from: local?.splits)
        metadata.laps = restoringHR(remote.laps, from: local?.laps)
        return metadata
    }

    /// The iCloud copy's per-second samples with this device's heart rate put
    /// back on each row the upload cleared (listed in `healthKitHROffsets`).
    /// A row the iCloud copy still carries a heart rate for keeps it.
    private static func restoringHealthKitHR(_ remote: WorkoutMetadata, from local: WorkoutMetadata?) -> [WorkoutSample]? {
        guard let samples = remote.samples else { return nil }
        let offsets = Set(remote.healthKitHROffsets ?? [])
        guard !offsets.isEmpty, let localSamples = local?.samples else { return samples }
        let localHR = Dictionary(localSamples.map { ($0.offsetSec, $0.heartRate) }, uniquingKeysWith: { first, _ in first })
        return samples.map { row in
            guard row.heartRate == nil, offsets.contains(row.offsetSec), let held = localHR[row.offsetSec] ?? nil
            else { return row }
            return row.withHeartRate(held)
        }
    }

    /// The iCloud copy's splits with this device's heart rate on each split
    /// the upload cleared.
    private static func restoringHR(_ remote: [Split]?, from local: [Split]?) -> [Split]? {
        guard let remote, let local else { return remote }
        return remote.map { split in
            guard split.averageHR == nil,
                  let held = local.first(where: { $0.index == split.index && $0.durationSeconds == split.durationSeconds })
            else { return split }
            return split.withAverageHR(held.averageHR)
        }
    }

    /// The iCloud copy's laps with this device's heart rate on each lap the
    /// upload cleared.
    private static func restoringHR(_ remote: [Lap]?, from local: [Lap]?) -> [Lap]? {
        guard let remote, let local else { return remote }
        return remote.map { lap in
            guard lap.averageHR == nil, lap.maxHR == nil,
                  let held = local.first(where: { $0.index == lap.index && $0.startOffsetSec == lap.startOffsetSec })
            else { return lap }
            return lap.withHeartRate(average: held.averageHR, max: held.maxHR)
        }
    }

    /// The iCloud copy's strap samples plus the local Watch and HealthKit
    /// ones, unless the iCloud copy already carries those.
    private static func restoring(_ remote: [HRRSample]?, from local: [HRRSample]?) -> [HRRSample]? {
        let remoteSamples = remote ?? []
        guard remoteSamples.allSatisfy({ $0.provenance == .strap }) else { return remote }
        let combined = remoteSamples + (local ?? []).filter { $0.provenance != .strap }
        return combined.isEmpty ? nil : combined
    }
}

// MARK: - Copies with one reading replaced

extension HRVAnalysisResult {
    /// This result with `ansMetrics` replaced and every other field kept.
    func withANSMetrics(_ metrics: ANSMetrics?) -> HRVAnalysisResult {
        HRVAnalysisResult(
            windowStart: windowStart, windowEnd: windowEnd, timeDomain: timeDomain,
            frequencyDomain: frequencyDomain, nonlinear: nonlinear, ansMetrics: metrics,
            artifactPercentage: artifactPercentage, cleanBeatCount: cleanBeatCount, analysisDate: analysisDate,
            windowStartMs: windowStartMs, windowEndMs: windowEndMs, windowMeanHR: windowMeanHR,
            windowHRStability: windowHRStability, windowSelectionReason: windowSelectionReason,
            windowRelativePosition: windowRelativePosition, isConsolidated: isConsolidated,
            isOrganizedRecovery: isOrganizedRecovery, windowClassification: windowClassification,
            organizedRecoveryZones: organizedRecoveryZones, peakCapacity: peakCapacity,
            trainingContext: trainingContext, analysisSegmentLabel: analysisSegmentLabel, isReanalysis: isReanalysis,
            overnightNadirHR: overnightNadirHR, overnightNadirTimeMs: overnightNadirTimeMs,
            overnightMinHR: overnightMinHR, overnightMaxHR: overnightMaxHR, overnightMeanHR: overnightMeanHR,
            estimatedMetrics: estimatedMetrics
        )
    }
}

extension ANSMetrics {
    /// These metrics with the daytime resting heart rate replaced. The dip
    /// computed from it is kept.
    func withDaytimeRestingHR(_ heartRate: Double?) -> ANSMetrics {
        ANSMetrics(
            stressIndex: stressIndex, pnsIndex: pnsIndex, snsIndex: snsIndex, readinessScore: readinessScore,
            respirationRate: respirationRate, nocturnalHRDip: nocturnalHRDip,
            daytimeRestingHR: heartRate, nocturnalMedianHR: nocturnalMedianHR
        )
    }
}

extension Split {
    func withAverageHR(_ heartRate: Double?) -> Split {
        Split(
            index: index, distanceMeters: distanceMeters, durationSeconds: durationSeconds, averageHR: heartRate,
            averagePaceSecPerKm: averagePaceSecPerKm, elevationGainMeters: elevationGainMeters, averageAlpha1: averageAlpha1
        )
    }
}

extension Lap {
    func withHeartRate(average: Double?, max: Double?) -> Lap {
        Lap(
            index: index, startOffsetSec: startOffsetSec, endOffsetSec: endOffsetSec, distanceMeters: distanceMeters,
            averageHR: average, maxHR: max, averagePaceSecPerKm: averagePaceSecPerKm
        )
    }
}
