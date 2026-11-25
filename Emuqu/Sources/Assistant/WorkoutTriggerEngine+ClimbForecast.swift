import Foundation

// The hill heart-rate forecast cue: a climb is coming, and what it did to the
// user's heart rate on past passes would take them over their limit from
// where they are now (`ClimbHeartRateForecast`). Spoken before the climb,
// while easing off still keeps them under, which no breach alert can do:
// those fire once the line is crossed. Spoken, not silent like the other
// routine cues, because it is the one that is only useful heard in time.
extension WorkoutTriggerEngine {
    /// The cue is spoken about this long before the climb at the current
    /// speed, and never nearer or farther than these distances.
    static let climbForecastLeadSec = 120.0
    static let climbForecastNearestMeters = 50.0
    static let climbForecastFarthestMeters = 500.0
    /// The lead distance when speed is unknown or slower than a walk.
    static let climbForecastMinimumLeadMeters = 150.0

    static func climbHeartRateForecastRule() -> Rule {
        Rule(
            id: "climb.heartRateForecast",
            tier: .spoken,
            cooldown: 8 * 60,
            condition: { climbForecastToSpeak($0) != nil },
            message: { ctx in
                guard let forecast = climbForecastToSpeak(ctx) else {
                    return String(localized: "Climb ahead.", bundle: LanguageManager.appBundle)
                }
                return ClimbHeartRateForecast.warning(forecast, imperial: ctx.userUnits.resolved == .imperial)
            }
        )
    }

    /// The forecast, when its climb is in the speaking window.
    static func climbForecastToSpeak(_ ctx: WorkoutAIContext) -> ClimbHeartRateForecast.Forecast? {
        guard let climb = ctx.historyClimbAhead, inSpeakingWindow(climb.distanceMeters, speed: ctx.currentSpeedMS) else { return nil }
        let limit = ClimbHeartRateForecast.limit(
            ceilings: ctx.activeThresholds.map(ClimbHeartRateForecast.Ceiling.init), maxHR: ctx.userMaxHR,
            thresholdHeartRate: ctx.thresholdHeartRate, thresholdIsUserSet: ctx.thresholdHeartRateIsUserSet
        )
        return ClimbHeartRateForecast.forecast(climb: climb, heartRate: ctx.heartRate, limit: limit)
    }

    static func inSpeakingWindow(_ meters: Double, speed: Double?) -> Bool {
        let lead = min(climbForecastFarthestMeters, max(climbForecastMinimumLeadMeters, (speed ?? 0) * climbForecastLeadSec))
        return meters >= climbForecastNearestMeters && meters <= lead
    }
}
