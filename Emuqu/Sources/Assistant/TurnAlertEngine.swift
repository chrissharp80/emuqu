import CoreLocation
import Foundation

// MARK: - Turn-by-turn alert engine
//
// Proactive "turn right onto Oak St in 200 feet"
// alerts for the AI's `directions.routeTo` route. Sibling of
// `WorkoutMileMarkerEngine`:
//
//   • Tier 1 = ALERTS (WorkoutTriggerEngine) — emergency / safety.
//   • Tier 2 = MILE MARKERS (WorkoutMileMarkerEngine) — periodic
//     split check-ins, distance-driven.
//   • Tier 3 = TURN ALERTS (this file) — route-driven turn
//     announcements, off by default. Only fires when an
//     `ActiveRouteSession` is engaged AND the user opts in via
//     `UserSettings.enableTurnByTurnAlerts`.
//
// User framing: "i want it to load a route and be
// proactive, if i want, about turns." The "if i want" is the
// per-user toggle.
//
// **Pure evaluator.** Like the other tier engines, this file holds
// no state — caller (WorkoutVoiceCoach) tracks `TurnAlertState`
// across ticks. Engine takes a snapshot + state, returns a payload
// (or nil) + the updated state. The dispatch side (voice / haptic)
// is the caller's job.
//
// **Threshold pattern.** For each upcoming step, fire ONCE at each
// of three distance thresholds, in order:
//   1. Far (~500 ft / 150 m): "in 500 feet, turn right onto Elm"
//   2. Near (~200 ft / 60 m): "in 200 feet, turn right onto Elm"
//   3. At-turn (~75 ft / 25 m): "turn right onto Elm"
// Once a threshold fires for a given step, it doesn't fire again
// even if GPS noise pushes the distance back above the threshold.
// When the user advances to the next step, the threshold counter
// resets so the new step's "far" alert fires.
//
// **Globally appropriate distances.** US users get feet; everyone
// else gets meters. The engine works in meters internally; the
// formatter converts based on the units preference at render time.

/// Per-workout / per-route state held by the caller across ticks.
struct TurnAlertState {
    /// Step index of the most recently announced step. Engine
    /// resets the threshold sequence whenever the route's
    /// `currentStepIndex` advances past this value.
    var lastStepIndex: Int = -1
    /// Highest threshold (1 = far, 2 = near, 3 = at-turn) already
    /// announced for `lastStepIndex`. 0 = none yet. Threshold
    /// firing is monotonic: once threshold 2 fired we never fire
    /// threshold 1 again for the same step.
    var lastThresholdLevel: Int = 0
}

/// Pure-data payload describing one turn-alert utterance. Caller
/// renders + dispatches.
struct TurnAlertPayload {
    /// The MapKit step instruction ("Turn right onto Oak
    /// Ave"). Already includes the action verb + street name.
    let stepInstruction: String
    /// Distance to the upcoming turn in meters. Can be 0 for the
    /// at-turn alert.
    let distanceMeters: Double
    /// Threshold level for telemetry / debugging — 1, 2, or 3.
    let thresholdLevel: Int
    /// Destination label. Used by the formatter when the user is
    /// approaching the FINAL step (arrival).
    let destinationLabel: String
    /// True when this is the at-arrival announcement (within ~25 m
    /// of destination). Formatter renders it as "you've arrived
    /// at <label>" rather than a turn instruction.
    let isArrival: Bool
}

enum TurnAlertEngine {
    // MARK: - Tunables

    /// Distance bands in meters. Each band has a center distance
    /// and an acceptance window — when the user's distance to the
    /// upcoming step is INSIDE the window, we fire the announcement.
    /// The window is sized so a user walking at 1.5 m/s passes
    /// through it in ~3-5 seconds — long enough to catch a tick
    /// without being so wide that two adjacent bands fire from one
    /// position.
    ///
    /// Approximate imperial equivalents in the comments:
    ///   farMeters     — 150 m  ≈  500 ft
    ///   nearMeters    — 60 m   ≈  200 ft
    ///   atTurnMeters  — 25 m   ≈  75 ft  (fires at the turn itself)
    static let farMeters: Double = 150
    static let farWindowMeters: Double = 30  // 135–165 m
    static let nearMeters: Double = 60
    static let nearWindowMeters: Double = 15 // 52.5–67.5 m
    static let atTurnMeters: Double = 25     // anything <= this
    /// Arrival distance — when the user is within this many meters
    /// of the destination, fire the arrival alert and stop.
    static let arrivalMeters: Double = 25

    // MARK: - Public

    /// Evaluate the active route against the user's snapshot.
    /// Returns a payload to speak (and the updated state) when a
    /// new threshold has just been crossed; otherwise nil + same
    /// state.
    ///
    /// `step` is the result of `ActiveRouteSession.currentStep(...)` —
    /// the engine doesn't query the session itself so it stays
    /// pure / testable.
    static func evaluate(
        step: ActiveRouteSession.StepResult,
        state: TurnAlertState
    ) -> (payload: TurnAlertPayload?, nextState: TurnAlertState) {
        // Step advanced — reset the threshold counter so the new
        // step's "far" alert can fire.
        var working = state
        if step.currentStepIndex != state.lastStepIndex {
            working = TurnAlertState(lastStepIndex: step.currentStepIndex, lastThresholdLevel: 0)
        }
        if step.arrived || step.remainingDistanceMeters <= arrivalMeters {
            return arrivalAlert(step: step, working: &working)
        }
        guard let level = crossedThreshold(
            distance: step.distanceToUpcomingStepMeters, alreadyFired: working.lastThresholdLevel
        ) else { return (nil, working) }
        working.lastThresholdLevel = level
        return (payload(step: step, distance: step.distanceToUpcomingStepMeters, level: level), working)
    }

    /// Arrival short-circuit. Once we're within `arrivalMeters`
    /// of the destination, fire the arrival alert (level 4 to
    /// distinguish it in the state machine — anything > 3 means
    /// "we're done with this step").
    private static func arrivalAlert(
        step: ActiveRouteSession.StepResult,
        working: inout TurnAlertState
    ) -> (payload: TurnAlertPayload?, nextState: TurnAlertState) {
        guard working.lastThresholdLevel < 4 else { return (nil, working) }
        working.lastThresholdLevel = 4
        let payload = TurnAlertPayload(
            stepInstruction: step.upcomingInstruction,
            distanceMeters: 0,
            thresholdLevel: 4,
            destinationLabel: step.destinationLabel,
            isArrival: true
        )
        return (payload, working)
    }

    /// Which threshold the user's distance currently falls into, or nil when
    /// none has newly been crossed. Fires the lowest threshold we haven't
    /// already announced — but only if the user is INSIDE its window, so we
    /// don't fire a "far" alert for someone who was 500 m out and just
    /// suddenly came into range.
    ///
    /// Level 3 (at-turn) is the exception: it always fires once the user is
    /// inside `atTurnMeters` of the upcoming step.
    private static func crossedThreshold(distance dist: Double, alreadyFired: Int) -> Int? {
        if dist <= atTurnMeters, alreadyFired < 3 { return 3 }
        if alreadyFired < 2, inWindow(dist, center: nearMeters, width: nearWindowMeters) { return 2 }
        if alreadyFired < 1, inWindow(dist, center: farMeters, width: farWindowMeters) { return 1 }
        return nil
    }

    /// True when `dist` sits inside a window of `width` centred on `center`.
    private static func inWindow(_ dist: Double, center: Double, width: Double) -> Bool {
        dist >= center - width / 2 && dist <= center + width / 2
    }

    private static func payload(
        step: ActiveRouteSession.StepResult,
        distance: Double,
        level: Int
    ) -> TurnAlertPayload {
        TurnAlertPayload(
            stepInstruction: step.upcomingInstruction,
            distanceMeters: distance,
            thresholdLevel: level,
            destinationLabel: step.destinationLabel,
            isArrival: false
        )
    }
}

// MARK: - Formatter

enum TurnAlertFormatter {
    /// Render a payload as a single short utterance suitable for
    /// the voice coach to speak, in the app language (the coach speaks
    /// with the app-language voice). Imperial vs metric flips at this
    /// surface; the engine works in meters.
    static func render(payload: TurnAlertPayload, unitsImperial: Bool) -> String {
        let bundle = LanguageManager.appBundle
        if payload.isArrival {
            return String(localized: "You've arrived at \(payload.destinationLabel).", bundle: bundle)
        }
        // The step instruction from MapKit already contains the
        // action ("Turn right onto Oak St"). We prefix with
        // distance and let the instruction speak for itself.
        let distLabel = formatDistance(meters: payload.distanceMeters, imperial: unitsImperial)
        let instruction = payload.stepInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if instruction.isEmpty {
            // Step instructions can be empty for the synthetic
            // "Proceed to <road>" first step. Skip the alert in
            // that case rather than say "in 500 feet, ."
            return ""
        }
        if payload.thresholdLevel == 3 {
            // At the turn — instruction alone, no leading distance.
            return instruction
        }
        return String(localized: "In \(distLabel), \(lowercaseFirst(instruction))", bundle: bundle)
    }

    /// Lower-case the first letter of an instruction so "Turn right"
    /// reads naturally after "In 500 feet, ". English only: other
    /// languages capitalise differently (German nouns, for one), so their
    /// instruction is left as written. Preserves proper-noun casing
    /// further into the string.
    private static func lowercaseFirst(_ s: String) -> String {
        guard LanguageManager.appLocale.language.languageCode == .english,
              let first = s.first else { return s }
        return first.lowercased() + s.dropFirst()
    }

    /// Compact human distance — feet for imperial, meters for metric.
    /// Engine inputs are meters; formatter is the unit boundary.
    static func formatDistance(meters: Double, imperial: Bool) -> String {
        if imperial {
            let feet = (meters * UnitConstants.feetPerMeter).rounded()
            // Round to nearest 50 ft for spoken output above 100 ft.
            // "in 217 feet" is awkward; "in 200 feet" is what real
            // navigation apps say.
            let spoken = feet >= 100 ? (feet / 50.0).rounded() * 50 : feet
            return String(localized: "\(Int(spoken)) feet", bundle: LanguageManager.appBundle)
        }
        // Metric: round to nearest 10 m above 50 m.
        let spoken = meters >= 50 ? (meters / 10.0).rounded() * 10 : meters.rounded()
        return String(localized: "\(Int(spoken)) meters", bundle: LanguageManager.appBundle)
    }
}
