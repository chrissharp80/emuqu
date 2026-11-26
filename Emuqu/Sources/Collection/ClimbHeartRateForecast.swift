import Foundation

/// Will the climb ahead take the user over their heart-rate limit? The
/// climb and its heart-rate rise come from the user's own past GPS workouts
/// that went this way (`PlaceHistory`); with no such history there is no
/// forecast rather than a guess. Read by the spoken hill cue
/// (`WorkoutTriggerEngine.climbHeartRateForecastRule`) and by the
/// "should I ease off?" answer (`DeterministicIntent`), so the two never
/// disagree.
enum ClimbHeartRateForecast {
    /// A rise smaller than this is within a few seconds' noise.
    static let minimumRise = 5

    /// The ceiling a forecast is measured against: the lowest heart-rate
    /// limit the user set for this workout, else their threshold heart rate.
    struct Limit: Equatable {
        enum Source: Equatable { case userLimit, threshold, estimatedThreshold }
        let bpm: Int
        let source: Source
    }

    /// One "warn me above" threshold the user set: a bpm, or a zone.
    struct Ceiling: Equatable {
        let metric: WorkoutThreshold.Metric
        let condition: WorkoutThreshold.Condition
        let value: Double
    }

    struct Forecast: Equatable {
        let climb: PlaceHistory.ClimbAhead
        let rise: Int
        let predictedHeartRate: Int
        let limit: Limit
    }

    /// A zone ceiling is the top of that zone on the band model the zone
    /// rules use: zone N tops out at (N × 0.10 + 0.50) × max.
    static func limit(ceilings: [Ceiling], maxHR: Int, thresholdHeartRate: Int?, thresholdIsUserSet: Bool) -> Limit? {
        let bpms = ceilings.filter { $0.condition == .greaterThan }.compactMap { ceiling -> Int? in
            switch ceiling.metric {
            case .heartRateBPM: return Int(ceiling.value.rounded())
            case .heartRateZone: return Int(((ceiling.value * 0.10 + 0.50) * Double(maxHR)).rounded())
            default: return nil
            }
        }
        if let lowest = bpms.min() { return Limit(bpm: lowest, source: .userLimit) }
        guard let thresholdHeartRate else { return nil }
        return Limit(bpm: thresholdHeartRate, source: thresholdIsUserSet ? .threshold : .estimatedThreshold)
    }

    /// The forecast when the climb's past rise, from the heart rate now,
    /// passes a limit the user is still under; nil otherwise.
    static func forecast(climb: PlaceHistory.ClimbAhead?, heartRate: Int?, limit: Limit?) -> Forecast? {
        guard let climb, let rise = climb.heartRateRise, rise >= minimumRise, let heartRate, let limit else { return nil }
        let predicted = heartRate + rise
        guard heartRate < limit.bpm, predicted > limit.bpm else { return nil }
        return Forecast(climb: climb, rise: rise, predictedHeartRate: predicted, limit: limit)
    }

    /// The spoken warning, one whole sentence per kind of limit so each
    /// translates as a unit.
    static func warning(_ forecast: Forecast, imperial: Bool) -> String {
        let distance = distancePhrase(forecast.climb.distanceMeters, imperial: imperial)
        let grade = Int(forecast.climb.gradePercent.rounded())
        let (rise, predicted, limit) = (forecast.rise, forecast.predictedHeartRate, forecast.limit.bpm)
        let bundle = LanguageManager.appBundle
        switch forecast.limit.source {
        case .userLimit:
            return String(localized: "Hill in \(distance), about \(grade) percent. It has taken your heart rate up \(rise) beats before, which would put you at \(predicted), over your \(limit) limit. Ease off now.", bundle: bundle)
        case .threshold:
            return String(localized: "Hill in \(distance), about \(grade) percent. It has taken your heart rate up \(rise) beats before, which would put you at \(predicted), over your threshold of \(limit). Ease off now.", bundle: bundle)
        case .estimatedThreshold:
            return String(localized: "Hill in \(distance), about \(grade) percent. It has taken your heart rate up \(rise) beats before, which would put you at \(predicted), over your estimated threshold of \(limit). Ease off now.", bundle: bundle)
        }
    }

    /// The distance to the climb, rounded to 50 yards or 50 meters.
    static func distancePhrase(_ meters: Double, imperial: Bool) -> String {
        let bundle = LanguageManager.appBundle
        if imperial {
            let yards = max(50, Int((meters * UnitConstants.yardsPerMeter / 50).rounded()) * 50)
            return String(localized: "\(yards) yards", bundle: bundle)
        }
        let rounded = max(50, Int((meters / 50).rounded()) * 50)
        return String(localized: "\(rounded) meters", bundle: bundle)
    }
}

extension ClimbHeartRateForecast.Ceiling {
    init(_ threshold: WorkoutThreshold) {
        self.init(metric: threshold.metric, condition: threshold.condition, value: threshold.value)
    }

    /// The live snapshot's copy of a threshold, which keeps the metric and
    /// condition as their raw values.
    init?(_ snapshot: AssistantContext.LiveWorkoutSnapshot.ThresholdSnapshot) {
        guard let metric = WorkoutThreshold.Metric(rawValue: snapshot.metric),
              let condition = WorkoutThreshold.Condition(rawValue: snapshot.condition) else { return nil }
        self.init(metric: metric, condition: condition, value: snapshot.value)
    }
}
