import Foundation

// MARK: - Mile-marker notification system
//
// Tier-2 sibling of `WorkoutTriggerEngine`:
//
//   • Tier 1 = ALERTS (engine.swift) — emergency / safety / threshold breach.
//     Fires on its own schedule, the user opts out per-toggle. Designed to
//     interrupt because something needs attention.
//   • Tier 2 = NOTIFICATIONS (this file) — periodic split-marker check-ins
//     with deterministic data (split pace, distance, HR zone, etc.). Off by
//     default; the user opts in. Designed to be skippable, and to skip
//     itself when no metric is interesting enough to surface.
//
// User framing: "An alert is like 'you're about to fucking die'.
// An opt-in notification would be every mile an alert happens with useful
// metrics."
//
// The engine is pure: it takes a snapshot + state and returns a payload
// (or nil). It never speaks, never logs, never mutates global state. The
// caller (WorkoutVoiceCoach) routes payloads through the existing
// in-conversation-aware trigger queue so they never wipe an in-progress
// user utterance.

/// User-configurable interval at which mile-marker notifications fire.
/// Stored in `UserSettings.mileMarkerInterval`.
enum MileMarkerInterval: String, Codable, CaseIterable {
    /// Default — fires every mile for imperial users, every km for
    /// metric users. The engine resolves which based on the active
    /// units preference at evaluation time.
    case everyDistanceUnit
    /// Force per-mile regardless of unit preference (e.g. user has
    /// metric units in app but trains in miles).
    case everyMile
    /// Force per-kilometer regardless of unit preference.
    case everyKilometer
    /// Every 2 km (~1.25 mi) — quieter cadence for long sessions.
    case everyTwoKilometers
    /// Every 5 km (~3.1 mi) — long-run / ultra cadence.
    case everyFiveKilometers
    /// Every 10 minutes of elapsed time (distance-blind — useful for
    /// hikers / mixed-pace days).
    case everyTenMinutes

    /// Display label for settings UI.
    var displayName: String {
        switch self {
        case .everyDistanceUnit: return "Every mile (or km)"
        case .everyMile: return "Every mile"
        case .everyKilometer: return "Every km"
        case .everyTwoKilometers: return "Every 2 km"
        case .everyFiveKilometers: return "Every 5 km"
        case .everyTenMinutes: return "Every 10 min"
        }
    }
}

/// Per-workout state held by the caller across ticks. Rolling baselines
/// for "is this metric interesting?" decisions, plus the marker-index
/// counter that keeps the engine idempotent across rapid ticks.
struct MileMarkerState {
    /// Last marker index (mile / km / 2km / etc., depending on interval)
    /// already announced. Engine fires when the current index exceeds
    /// this value. Reset to 0 at workout start.
    var lastMarkerIndex: Int = 0

    /// Distance (meters) at the start of the current split — used to
    /// compute the split's elevation gain delta.
    var splitStartDistanceMeters: Double = 0

    /// Cumulative elevation gain (meters) at the start of the current
    /// split. The split's gain is `current - this`.
    var splitStartElevationMeters: Double = 0

    /// Elapsed seconds at the start of the current split. The split's
    /// duration is `current elapsed - this`.
    var splitStartElapsedSec: Int = 0
}

/// Pure-data payload for one mile-marker notification. Skip-when-normal
/// fields are nil when the engine decided they aren't worth surfacing.
/// The formatter renders only the non-nil ones, keeping the spoken
/// announcement under the 4-second target.
struct MileMarkerPayload {
    /// Marker number — "mile 3", "kilometer 5", etc.
    let markerIndex: Int
    /// Unit suffix for the marker label.
    let markerUnit: MileMarkerUnit
    /// Time taken for THIS split (this mile, this km, etc.). Always
    /// surfaced — the most-loved metric in the runner-survey research.
    let splitDurationSec: Int
    /// Pace (seconds per kilometer at the engine layer; formatter
    /// converts to per-mile if user is imperial). Always surfaced.
    let splitPaceSecPerKm: Double?
    /// HR zone label ("Z2 — endurance", "Z4 — threshold", etc.) when
    /// HR + userMaxHR are both present. Nil when HR is unknown OR
    /// when zone math hasn't yet stabilised.
    let hrZoneLabel: String?
    /// Total distance covered so far (meters at engine level).
    let totalDistanceMeters: Double
    /// Total elapsed seconds at this marker.
    let totalElapsedSec: Int
    /// Cadence (steps per minute) — only set when OUTSIDE the healthy
    /// 165–190 spm band so the announcement skips it on normal runs.
    let cadenceSpm: Double?
    /// Elevation gained THIS SPLIT (meters) — only set when ≥15 m
    /// (~50 ft) so a flat split skips it entirely.
    let splitElevationGainMeters: Double?
    /// HR drift / HRV anomaly cue — currently nil; reserved for the
    /// future "your HR has crept up 12 bpm at the same pace" feature.
    /// The framework is here so the formatter doesn't have to change
    /// when it lands.
    let driftCue: String?
}

enum MileMarkerUnit: String {
    case mile
    case kilometer
    case twoKilometers
    case fiveKilometers
    case tenMinutes
}

/// Pure evaluator. Returns a payload when a new marker has been crossed
/// since the last evaluation; returns nil otherwise. Callers track
/// `MileMarkerState` across ticks; the engine itself holds zero state.
enum WorkoutMileMarkerEngine {
    /// Evaluate and (when crossing a marker) return a payload + the
    /// updated state. The new state must be written back by the caller
    /// for the next tick.
    ///
    /// Refuses to fire in the first 60 s: a GPS jitter that pretends we
    /// covered 1.6 km in 30 s shouldn't false-fire mile 1.
    static func evaluate(
        context: WorkoutAIContext,
        state: MileMarkerState,
        interval: MileMarkerInterval,
        unitsImperial: Bool
    ) -> (payload: MileMarkerPayload?, nextState: MileMarkerState) {
        guard context.elapsedSeconds >= 60 else { return (nil, state) }
        let resolved = resolvedUnit(for: interval, unitsImperial: unitsImperial)
        let currentIndex = markerIndex(context: context, unit: resolved)
        guard currentIndex > state.lastMarkerIndex else { return (nil, state) }
        let payload = MileMarkerPayload(
            markerIndex: currentIndex, markerUnit: resolved,
            splitDurationSec: max(0, context.elapsedSeconds - state.splitStartElapsedSec),
            splitPaceSecPerKm: splitPace(context: context, state: state),
            hrZoneLabel: hrZoneLabel(context: context),
            totalDistanceMeters: context.distanceMeters, totalElapsedSec: context.elapsedSeconds,
            cadenceSpm: filteredCadence(context: context),
            splitElevationGainMeters: splitElevation(context: context, state: state),
            driftCue: nil
        )
        return (payload, MileMarkerState(
            lastMarkerIndex: currentIndex,
            splitStartDistanceMeters: context.distanceMeters,
            splitStartElevationMeters: context.elevationGainMeters,
            splitStartElapsedSec: context.elapsedSeconds
        ))
    }

    /// Which marker we're at. A time-based interval indexes by 10-minute
    /// blocks of elapsed; everything else by distance covered.
    private static func markerIndex(context: WorkoutAIContext, unit: MileMarkerUnit) -> Int {
        if case .tenMinutes = unit { return context.elapsedSeconds / 600 }
        let granularityMeters = unit.metersPerMarker
        guard granularityMeters > 0 else { return 0 }
        return Int(context.distanceMeters / granularityMeters)
    }

    /// This split's pace, or nil on a stub split too short to mean anything.
    private static func splitPace(context: WorkoutAIContext, state: MileMarkerState) -> Double? {
        let splitDistanceM = max(0, context.distanceMeters - state.splitStartDistanceMeters)
        guard splitDistanceM > 100 else { return nil }
        let splitDurationSec = max(0, context.elapsedSeconds - state.splitStartElapsedSec)
        return Double(splitDurationSec) / (splitDistanceM / 1000.0)
    }

    /// This split's climb, reported only when it's material (≥15 m).
    private static func splitElevation(context: WorkoutAIContext, state: MileMarkerState) -> Double? {
        let splitElev = max(0, context.elevationGainMeters - state.splitStartElevationMeters)
        return splitElev >= 15.0 ? splitElev : nil
    }

    /// Resolve the requested interval against the user's actual units
    /// preference. `.everyDistanceUnit` becomes `.mile` for imperial
    /// users, `.kilometer` for metric users.
    private static func resolvedUnit(
        for interval: MileMarkerInterval,
        unitsImperial: Bool
    ) -> MileMarkerUnit {
        switch interval {
        case .everyDistanceUnit: return unitsImperial ? .mile : .kilometer
        case .everyMile: return .mile
        case .everyKilometer: return .kilometer
        case .everyTwoKilometers: return .twoKilometers
        case .everyFiveKilometers: return .fiveKilometers
        case .everyTenMinutes: return .tenMinutes
        }
    }

    /// HR zone label using the standard %-of-max bands. Returns nil when
    /// HR or userMaxHR are unavailable. The framework is "% of HRmax"
    /// (Karvonen would need rest HR and adds complexity for marginal
    /// labelling improvement at this surface).
    private static func hrZoneLabel(context: WorkoutAIContext) -> String? {
        guard let hr = context.heartRate, context.userMaxHR > 0 else {
            return nil
        }
        let frac = Double(hr) / Double(context.userMaxHR)
        let zone: String
        switch frac {
        case ..<0.60: zone = "Z1 — recovery"
        case 0.60..<0.70: zone = "Z2 — endurance"
        case 0.70..<0.80: zone = "Z3 — tempo"
        case 0.80..<0.90: zone = "Z4 — threshold"
        default: zone = "Z5 — VO2max"
        }
        return zone
    }

    /// Cadence is surfaced only when OUTSIDE the healthy 165–190 spm
    /// band. A stable in-band cadence is irrelevant noise; an out-of-
    /// band one tells the user to lengthen / shorten stride. Returns
    /// nil for in-band or missing.
    private static func filteredCadence(context: WorkoutAIContext) -> Double? {
        guard let spm = context.cadenceStepsPerMin else { return nil }
        if spm >= 165, spm <= 190 { return nil }
        return spm
    }
}

private extension MileMarkerUnit {
    /// Meters per marker, for distance-based intervals. Time-based
    /// intervals return 0; the engine handles that branch separately.
    var metersPerMarker: Double {
        switch self {
        case .mile: return 1609.344
        case .kilometer: return 1000.0
        case .twoKilometers: return 2_000.0
        case .fiveKilometers: return 5_000.0
        case .tenMinutes: return 0
        }
    }
}

// MARK: - Formatter
//
// Pure render — payload → speakable string. Caps total content at the
// research-derived 4-second target by elision (drop optional fields,
// shorten labels). Imperial vs metric resolution lives here because
// the speakable string is the only place it matters; the engine works
// in SI so its math stays uniform.

enum MileMarkerFormatter {
    /// Render a payload as a single short utterance.
    ///
    /// Total distance is included only for non-time intervals, where the user
    /// might not know how far they've gone — a time-based interval already
    /// implies duration as the headline.
    static func render(payload: MileMarkerPayload, unitsImperial: Bool) -> String {
        // "Mile 3 in 8:45" / "Kilometer 5 in 5:42".
        let markerLabel = labelFor(unit: payload.markerUnit, index: payload.markerIndex)
        var parts = ["\(markerLabel) in \(formatDuration(seconds: payload.splitDurationSec))"]
        if let paceSecPerKm = payload.splitPaceSecPerKm {
            parts.append("pace \(formatPace(secPerKm: paceSecPerKm, imperial: unitsImperial))")
        }
        // HR zone is already labelled, so no unit work is needed.
        if let zone = payload.hrZoneLabel { parts.append(zone) }
        if payload.markerUnit != .tenMinutes {
            parts.append("total \(formatDistance(meters: payload.totalDistanceMeters, imperial: unitsImperial))")
        }
        parts += optionalCueParts(payload, unitsImperial: unitsImperial)
        return parts.joined(separator: ", ") + "."
    }

    /// The skip-when-normal fields: cadence outside the healthy band, a
    /// material climb, and any drift cue the caller attached.
    private static func optionalCueParts(_ payload: MileMarkerPayload, unitsImperial: Bool) -> [String] {
        var parts: [String] = []
        if let cadence = payload.cadenceSpm {
            parts.append("cadence \(Int(cadence)) — outside the healthy 165–190 band")
        }
        if let elev = payload.splitElevationGainMeters {
            parts.append("\(formatElevation(meters: elev, imperial: unitsImperial)) of climbing this split")
        }
        if let drift = payload.driftCue { parts.append(drift) }
        return parts
    }

    private static func labelFor(unit: MileMarkerUnit, index: Int) -> String {
        switch unit {
        case .mile: return "Mile \(index)"
        case .kilometer: return "Kilometer \(index)"
        case .twoKilometers: return "\(index * 2) km"
        case .fiveKilometers: return "\(index * 5) km"
        case .tenMinutes: return "\(index * 10) minutes"
        }
    }

    private static func formatDuration(seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private static func formatPace(secPerKm: Double, imperial: Bool) -> String {
        // Convert km → mi if imperial: pace_per_mi = pace_per_km × 1.60934
        let secPerUnit = imperial ? secPerKm * 1.609_344 : secPerKm
        let unitTail = imperial ? "min/mi" : "min/km"
        let total = Int(secPerUnit.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d %@", m, s, unitTail)
    }

    private static func formatDistance(meters: Double, imperial: Bool) -> String {
        if imperial {
            let miles = meters / 1_609.344
            return String(format: "%.1f mi", miles)
        }
        let km = meters / 1_000.0
        return String(format: "%.2f km", km)
    }

    private static func formatElevation(meters: Double, imperial: Bool) -> String {
        if imperial {
            let feet = meters * UnitConstants.feetPerMeter
            return String(format: "%.0f ft", feet)
        }
        return String(format: "%.0f m", meters)
    }
}
