import Foundation

// MARK: - Turn-marker update engine
//
// Fires AFTER each completed turn on the active
// route, with a split-style breakdown of the leg the user just
// finished ("turned onto Maple. Last leg: 2:14, pace 8:45,
// HR 142"). User framing: "and even the ability to use those
// turns as markers to get updates."
//
// **Distinct from TurnAlertEngine.**
//   • TurnAlertEngine fires BEFORE a turn — "in 200 ft, turn right
//     onto Oak." Dictated by approach distance.
//   • TurnMarkerEngine fires AFTER a turn — "you turned onto
//     Maple. Last leg: 2:14." Dictated by step-index advance.
// Both can be on / off independently.
//
// **Pure evaluator** matching `WorkoutMileMarkerEngine`'s shape.
// Caller (WorkoutVoiceCoach) holds the per-workout state and
// hands a snapshot in per tick. Engine returns a payload (or nil)
// + the updated state.
//
// **Why mile-marker AND turn-marker?** They answer different
// questions:
//   • Mile markers = "how am I doing per the clock / distance
//     plan" — split pace, total distance, zone.
//   • Turn markers = "what was that LEG like" — same metrics but
//     bucketed by route-segment instead of distance grid. Useful
//     for users who care more about "how was the leg from the
//     park entrance to the bridge" than arbitrary mile boundaries.

/// Per-workout state held by the caller across ticks.
struct TurnMarkerState {
    /// Step index at the start of the current leg. -1 = no leg
    /// active (route just engaged, awaiting first advance).
    var legStartStepIndex: Int = -1
    /// Distance (meters) at the start of the current leg.
    var legStartDistanceMeters: Double = 0
    /// Elapsed seconds at the start of the current leg.
    var legStartElapsedSec: Int = 0
    /// Cumulative elevation gain (meters) at start of leg.
    var legStartElevationMeters: Double = 0
    /// Sum of HR samples during the current leg, for averaging.
    var legHRSum: Int = 0
    /// Number of HR samples summed (for the average).
    var legHRCount: Int = 0
}

/// Pure-data payload for one turn-marker notification.
struct TurnMarkerPayload {
    /// Instruction that just got completed — the AI's "you turned
    /// X" comes from this. e.g. "Turn right onto Maple Ave". Empty when
    /// MapKit gave the step no instruction.
    let completedInstruction: String
    /// Time taken for this leg (seconds).
    let legDurationSec: Int
    /// Distance covered during this leg (meters).
    let legDistanceMeters: Double
    /// Average pace during the leg (seconds per kilometer).
    /// Nil when the leg covered too little ground to call a pace
    /// (<50 m — usually a quick "turn left then right" combo).
    let legPaceSecPerKm: Double?
    /// Average HR during the leg. Nil when no HR samples were
    /// captured (no strap / watch unavailable).
    let legAvgHR: Int?
    /// Elevation gained during the leg (meters). Surfaced only
    /// when ≥10 m so flat legs skip it.
    let legElevationGainMeters: Double?
    /// Step index of the just-completed step — for telemetry.
    let completedStepIndex: Int
}

enum TurnMarkerEngine {
    /// Evaluate the current step result against the per-workout
    /// state. Returns a payload (and updated state) when the
    /// user has just COMPLETED a turn since the previous tick.
    /// Otherwise nil + same state (modulo HR-sum accumulation
    /// inside the leg).
    static func evaluate(
        step: ActiveRouteSession.StepResult,
        context: WorkoutAIContext,
        state: TurnMarkerState
    ) -> (payload: TurnMarkerPayload?, nextState: TurnMarkerState) {
        // First-tick init — capture leg-start metrics so the FIRST
        // completed turn has a baseline to subtract from.
        guard state.legStartStepIndex >= 0 else {
            return (nil, legStart(at: step.currentStepIndex, context: context))
        }
        var working = state
        // Accumulate HR samples for the in-flight leg.
        if let hr = context.heartRate, hr > 0 {
            working.legHRSum += hr
            working.legHRCount += 1
        }
        // No turn completion yet — same step.
        guard step.currentStepIndex > working.legStartStepIndex else { return (nil, working) }
        let payload = legPayload(step: step, context: context, working: working)
        return (payload, legStart(at: step.currentStepIndex, context: context))
    }

    /// A fresh leg's state, seeded from the current snapshot.
    private static func legStart(at stepIndex: Int, context: WorkoutAIContext) -> TurnMarkerState {
        let hr = context.heartRate.flatMap { $0 > 0 ? $0 : nil }
        return TurnMarkerState(
            legStartStepIndex: stepIndex,
            legStartDistanceMeters: context.distanceMeters,
            legStartElapsedSec: context.elapsedSeconds,
            legStartElevationMeters: context.elevationGainMeters,
            legHRSum: hr ?? 0,
            legHRCount: hr != nil ? 1 : 0
        )
    }

    /// A turn has just been completed — compute the leg deltas.
    ///
    /// The instruction we just completed is the one at the PREVIOUS step
    /// index; the route's `currentStep` has already advanced. We don't have
    /// the prior step's text in the StepResult, so we fall back to a generic
    /// "you turned" line when the route engine doesn't expose it. The
    /// ActiveRouteSession surfaces `currentInstruction` for the step we're on
    /// NOW — close enough for a confirmation line ("you turned, now on
    /// <currentInstruction>").
    private static func legPayload(
        step: ActiveRouteSession.StepResult,
        context: WorkoutAIContext,
        working: TurnMarkerState
    ) -> TurnMarkerPayload {
        let legDuration = max(0, context.elapsedSeconds - working.legStartElapsedSec)
        let legDistance = max(0, context.distanceMeters - working.legStartDistanceMeters)
        let legElev = max(0, context.elevationGainMeters - working.legStartElevationMeters)
        let legPaceSecPerKm = legDistance > 50 ? Double(legDuration) / (legDistance / 1000.0) : nil
        let legAvgHR = working.legHRCount > 0
            ? Int(Double(working.legHRSum) / Double(working.legHRCount))
            : nil
        return TurnMarkerPayload(
            completedInstruction: step.currentInstruction,
            legDurationSec: legDuration,
            legDistanceMeters: legDistance,
            legPaceSecPerKm: legPaceSecPerKm,
            legAvgHR: legAvgHR,
            legElevationGainMeters: legElev >= 10.0 ? legElev : nil,
            completedStepIndex: working.legStartStepIndex
        )
    }
}

// MARK: - Formatter

enum TurnMarkerFormatter {
    /// Render a payload as a single short utterance in the app language
    /// (the coach speaks with the app-language voice). Imperial vs metric
    /// flips at this surface.
    static func render(payload: TurnMarkerPayload, unitsImperial: Bool) -> String {
        let bundle = LanguageManager.appBundle
        // Lead with the new road we're on (the AI Coach's "now on"
        // confirmation line), then the last leg's duration.
        let now = payload.completedInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = now.isEmpty
            ? String(localized: "Turn completed", bundle: bundle)
            : String(localized: "Now \(lowercaseFirst(now))", bundle: bundle)
        let leg = String(format: "%d:%02d", payload.legDurationSec / 60, payload.legDurationSec % 60)
        var parts = [lead, String(localized: "last leg \(leg)", bundle: bundle)]
        if let pace = payload.legPaceSecPerKm {
            parts.append(paceLabel(secPerKm: pace, unitsImperial: unitsImperial))
        }
        if let hr = payload.legAvgHR { parts.append(String(localized: "HR \(hr)", bundle: bundle)) }
        if let elev = payload.legElevationGainMeters { parts.append(climbLabel(meters: elev, unitsImperial: unitsImperial)) }
        return parts.joined(separator: ", ") + "."
    }

    /// "pace 8:42 min/mi" — the pace converted into the user's units.
    private static func paceLabel(secPerKm: Double, unitsImperial: Bool) -> String {
        let perUnit = unitsImperial ? secPerKm * 1.609_344 : secPerKm
        let total = Int(perUnit.rounded())
        let clock = String(format: "%d:%02d", total / 60, total % 60)
        return unitsImperial
            ? String(localized: "pace \(clock) min/mi", bundle: LanguageManager.appBundle)
            : String(localized: "pace \(clock) min/km", bundle: LanguageManager.appBundle)
    }

    /// "120 ft up" — the leg's elevation gain in the user's units.
    private static func climbLabel(meters: Double, unitsImperial: Bool) -> String {
        unitsImperial
            ? String(localized: "\(Int((meters * UnitConstants.feetPerMeter).rounded())) ft up", bundle: LanguageManager.appBundle)
            : String(localized: "\(Int(meters.rounded())) m up", bundle: LanguageManager.appBundle)
    }

    /// English only, as in `TurnAlertFormatter`: other languages keep the
    /// instruction's own capitalisation.
    private static func lowercaseFirst(_ s: String) -> String {
        guard LanguageManager.appLocale.language.languageCode == .english,
              let first = s.first else { return s }
        return first.lowercased() + s.dropFirst()
    }
}
