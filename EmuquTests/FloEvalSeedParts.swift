@testable import Emuqu
import Foundation

/// A night's beats, so the clock-time lookups (the nadir's time, the night's
/// heart-rate curve) have a series to read. One beat every six seconds of
/// the recording: heart rate falls in a straight line to the dataset's nadir
/// at its nadir time and rises after it, steep enough that the curve's mean
/// is the night's mean heart rate; successive intervals alternate by the
/// night's RMSSD, so each stretch's RMSSD is the night's.
enum FloEvalBeats {
    static let stepMs: Int64 = 6000

    struct Shape {
        let durationMs: Int64
        let nadirMs: Int64
        let nadirHR: Double
        let peakHR: Double
        let halfSwingMs: Int
    }

    static func series(for night: FloEvalDataset.Overnight, start: Date, end: Date, sessionId: UUID) throws -> RRSeries {
        let shape = try self.shape(for: night, start: start, end: end)
        let points = stride(from: Int64(0), to: shape.durationMs, by: Int(stepMs)).enumerated().map { index, tMs in
            RRPoint(t_ms: tMs, rr_ms: interval(at: tMs, index: index, shape: shape))
        }
        return RRSeries(points: points, sessionId: sessionId, startDate: start)
    }

    /// The peak that makes the V's mean the night's mean: over a recording of
    /// length L with the nadir a from its start and b from its end, the V's
    /// mean sits (a² + b²) / (2 L max(a, b)) of the way from nadir to peak.
    private static func shape(for night: FloEvalDataset.Overnight, start: Date, end: Date) throws -> Shape {
        let durationMs = MillisecondOffset.between(end, and: start, fallback: 0)
        let nadirAt = try FloEvalSeeder.instant(night.nadirTimeLocal)
        let nadirMs = MillisecondOffset.between(nadirAt, and: start, fallback: 0)
        let before = Double(max(nadirMs, 1))
        let after = Double(max(durationMs - nadirMs, 1))
        let fraction = (before * before + after * after) / (2 * Double(max(durationMs, 1)) * max(before, after))
        let peak = night.nadirHrBpm + (night.meanHrBpm - night.nadirHrBpm) / max(fraction, 0.01)
        return Shape(durationMs: durationMs, nadirMs: nadirMs, nadirHR: night.nadirHrBpm, peakHR: peak, halfSwingMs: Int((night.rmssdMs / 2).rounded()))
    }

    private static func interval(at tMs: Int64, index: Int, shape: Shape) -> Int {
        let reach = Double(max(shape.nadirMs, shape.durationMs - shape.nadirMs, 1))
        let distance = Double(abs(tMs - shape.nadirMs))
        let heartRate = distance < 150_000 ? shape.nadirHR : shape.nadirHR + (shape.peakHR - shape.nadirHR) * distance / reach
        let base = Int((60000 / heartRate).rounded())
        return base + (index.isMultiple(of: 2) ? -shape.halfSwingMs : shape.halfSwingMs)
    }
}

/// The dataset's recovery factors as the app's stored breakdown. The
/// dataset scores a night as 72 base points plus each factor's points; the
/// app stores weighted 0-100 sub-scores. Each factor keeps its points in its
/// detail line and its sign as its impact; its sub-score is 50 plus twice
/// its points, so the factors rank as their points do.
enum FloEvalBreakdown {
    static func breakdown(_ night: FloEvalDataset.Overnight) -> RecoveryScoreCalculator.ScoreBreakdown {
        let factors = factorLines(night).map { key, label, detail in
            factor(label: label, detail: detail, points: night.recoveryFactors[key] ?? 0)
        }
        return RecoveryScoreCalculator.ScoreBreakdown(
            compositeScore: Double(night.recoveryScore0100), tier: 3, factors: factors,
            penalties: [], spo2PenaltyApplied: false
        )
    }

    private static func factorLines(_ night: FloEvalDataset.Overnight) -> [(key: String, label: String, detail: String)] {
        let base = night.recoveryFactors["base_points"] ?? 72
        return [
            ("hrv_vs_baseline_points", "HRV vs baseline", "RMSSD \(night.rmssdMs) ms against a baseline of \(night.baselineRmssdMs) ms"),
            ("resting_hr_vs_baseline_points", "Resting HR vs baseline", "resting heart rate \(Int(night.restingHrBpm)) bpm against a baseline of \(night.baselineRestingHrBpm) bpm"),
            ("sleep_duration_points", "Sleep duration", "\(night.totalSleepMinutes) minutes asleep"),
            ("prior_day_training_load_points", "Prior-day training load", "the previous day's training load")
        ].map { key, label, detail in (key, label, "\(detail): \(signed(night.recoveryFactors[key] ?? 0)) points on a base of \(base)") }
    }

    private static func factor(label: String, detail: String, points: Int) -> RecoveryScoreCalculator.ScoreFactor {
        let impact: RecoveryScoreCalculator.ScoreFactor.Impact = points < 0 ? .negative : points > 0 ? .positive : .neutral
        let score = min(100, max(0, 50 + 2 * Double(points)))
        return RecoveryScoreCalculator.ScoreFactor(label: label, detail: detail, score: score, weight: 0.25, impact: impact)
    }

    private static func signed(_ points: Int) -> String {
        points > 0 ? "+\(points)" : "\(points)"
    }
}

/// A dataset workout as an archived workout session.
@MainActor
enum FloEvalWorkoutSeeder {
    static func workout(_ workout: FloEvalDataset.Workout) throws -> FloEvalSeeder.Item {
        let start = try FloEvalSeeder.instant(workout.startLocal)
        let duration = Double(workout.durationS)
        var session = HRVSession(startDate: start, tags: [], sessionType: .workout)
        session.endDate = start.addingTimeInterval(duration)
        session.state = .complete
        session.notes = workout.notes
        session.analysisResult = FloEvalSeeder.analysis(rmssd: 0, sdnn: 0, meanHR: workout.avgHrBpm, at: start)
        session.workoutMetadata = try metadata(workout, start: start)
        return FloEvalSeeder.Item(availableAt: start.addingTimeInterval(duration), session: session)
    }

    private static func metadata(_ workout: FloEvalDataset.Workout, start: Date) throws -> WorkoutMetadata {
        var meta = WorkoutMetadata(sport: sport(workout))
        meta.distanceMeters = workout.distanceKm.map { $0 * 1000 }
        meta.elevationGainMeters = workout.elevationGainM
        meta.activeSeconds = Double(workout.durationS)
        meta.splits = workout.splits.isEmpty ? nil : workout.splits.map(split)
        meta.samples = samples(workout)
        meta.hrrSamples = recovery(workout)
        meta.weatherSnapshot = workout.weather.map { weather($0, at: start) }
        meta.workoutFeeling = workout.feeling15
        meta.luciaTRIMP = workout.trainingLoad
        meta.averageSplitSecPer500m = workout.avgPaceSPer500m
        return meta
    }

    private static func sport(_ workout: FloEvalDataset.Workout) -> Sport {
        switch workout.type {
        case "walk": .walk
        case "ride": workout.indoor ? .indoorBike : .bike
        case "row": .row
        default: workout.indoor ? .treadmill : .run
        }
    }

    private static func split(_ split: FloEvalDataset.WorkoutSplit) -> Split {
        Split(
            index: split.split, distanceMeters: split.distanceKm * 1000, durationSeconds: split.durationS,
            averageHR: split.avgHrBpm, averagePaceSecPerKm: split.paceSPerKm, elevationGainMeters: nil
        )
    }

    /// One sample every ten seconds at the average heart rate, distance
    /// growing evenly, with the workout's maximum at two thirds of the way.
    private static func samples(_ workout: FloEvalDataset.Workout) -> [WorkoutSample] {
        let offsets = Array(stride(from: 0, through: workout.durationS, by: 10))
        let peakAt = offsets.isEmpty ? 0 : offsets[offsets.count * 2 / 3]
        let metres = (workout.distanceKm ?? 0) * 1000
        return offsets.map { offset in
            let heartRate = offset == peakAt ? workout.maxHrBpm : workout.avgHrBpm
            let covered = metres * Double(offset) / Double(max(workout.durationS, 1))
            return WorkoutSample(offsetSec: offset, heartRate: Int(heartRate.rounded()), distanceMeters: metres > 0 ? covered : nil)
        }
    }

    private static func recovery(_ workout: FloEvalDataset.Workout) -> [HRRSample]? {
        guard let stop = workout.hrAtStopBpm, let drop = workout.hrr60sBpm else { return nil }
        return [HRRSample(offsetSec: 60, hr: stop - drop, drop: drop, peakHR: stop, provenance: .strap)]
    }

    private static func weather(_ weather: FloEvalDataset.Weather, at date: Date) -> WorkoutWeatherSnapshot {
        WorkoutWeatherSnapshot(
            temperatureC: weather.tempC, apparentTemperatureC: nil, relativeHumidityPercent: 50,
            windKMH: weather.windKmh, conditions: weather.conditions, observedAt: date, backfilled: false
        )
    }
}
