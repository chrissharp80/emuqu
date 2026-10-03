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
        case .everyDistanceUnit: return String(localized: "Every mile (or km)", bundle: LanguageManager.appBundle)
        case .everyMile: return String(localized: "Every mile", bundle: LanguageManager.appBundle)
        case .everyKilometer: return String(localized: "Every km", bundle: LanguageManager.appBundle)
        case .everyTwoKilometers: return String(localized: "Every 2 km", bundle: LanguageManager.appBundle)
        case .everyFiveKilometers: return String(localized: "Every 5 km", bundle: LanguageManager.appBundle)
        case .everyTenMinutes: return String(localized: "Every 10 min", bundle: LanguageManager.appBundle)
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
    /// HR zone label in the app language ("Zone 2") from the app's shared
    /// `HRZone` model. Nil when HR or max HR is unknown, or HR is below
    /// Zone 1.
    let hrZoneLabel: String?
    /// Total distance covered so far (meters at engine level).
    let totalDistanceMeters: Double
    /// Total elapsed seconds at this marker.
    let totalElapsedSec: Int
    /// Running cadence (steps per minute) — only set on running sports,
    /// and only when OUTSIDE the healthy 165–190 spm band so the
    /// announcement skips it on normal runs.
    let cadenceSpm: Double?
    /// Elevation gained THIS SPLIT (meters) — only set when ≥15 m
    /// (~50 ft) so a flat split skips it entirely.
    let splitElevationGainMeters: Double?
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
            splitElevationGainMeters: splitElevation(context: context, state: state)
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

    /// HR zone label from `HRZone`, the app's one zone model (% of max HR,
    /// the same zone the AI fact sheet and the recording screen show), with
    /// its plain "Zone N" label: no "VO2max" claim without lab calibration.
    private static func hrZoneLabel(context: WorkoutAIContext) -> String? {
        guard let hr = context.heartRate else { return nil }
        return HRZone.classify(hr: hr, userMaxHR: context.userMaxHR)?.localizedLabel
    }

    /// Cadence is surfaced only on running sports (on a row it is stroke
    /// rate, on a bike crank RPM, and walking cadence sits well under the
    /// band) and only when OUTSIDE the healthy 165–190 spm band. A stable
    /// in-band cadence is irrelevant noise; an out-of-band one tells the
    /// user to lengthen / shorten stride. Returns nil otherwise.
    private static func filteredCadence(context: WorkoutAIContext) -> Double? {
        guard [Sport.run, .trailRun, .treadmill].contains(context.sport),
              let spm = context.cadenceStepsPerMin else { return nil }
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
    /// Render a payload as a single short utterance in the app language
    /// (the coach speaks it with the app-language voice).
    ///
    /// Total distance is included only for non-time intervals, where the user
    /// might not know how far they've gone — a time-based interval already
    /// implies duration as the headline.
    static func render(payload: MileMarkerPayload, unitsImperial: Bool) -> String {
        let bundle = LanguageManager.appBundle
        // "Mile 3 in 8:45" / "Kilometer 5 in 5:42".
        var parts = [headline(payload)]
        if let paceSecPerKm = payload.splitPaceSecPerKm {
            parts.append(paceLabel(secPerKm: paceSecPerKm, imperial: unitsImperial))
        }
        // HR zone is already labelled, so no unit work is needed.
        if let zone = payload.hrZoneLabel { parts.append(zone) }
        if payload.markerUnit != .tenMinutes {
            let total = formatDistance(meters: payload.totalDistanceMeters, imperial: unitsImperial)
            parts.append(String(localized: "total \(total)", bundle: bundle))
        }
        parts += optionalCueParts(payload, unitsImperial: unitsImperial)
        return parts.joined(separator: ", ") + "."
    }

    /// The skip-when-normal fields: cadence outside the healthy band and a
    /// material climb.
    private static func optionalCueParts(_ payload: MileMarkerPayload, unitsImperial: Bool) -> [String] {
        let bundle = LanguageManager.appBundle
        var parts: [String] = []
        if let cadence = payload.cadenceSpm {
            parts.append(String(localized: "cadence \(Int(cadence)) — outside the healthy 165–190 band", bundle: bundle))
        }
        if let elev = payload.splitElevationGainMeters {
            let climb = formatElevation(meters: elev, imperial: unitsImperial)
            parts.append(String(localized: "\(climb) of climbing this split", bundle: bundle))
        }
        return parts
    }

    /// The marker and the split time as one phrase, so each language can
    /// order them its own way.
    private static func headline(_ payload: MileMarkerPayload) -> String {
        let bundle = LanguageManager.appBundle
        let index = payload.markerIndex
        let time = formatDuration(seconds: payload.splitDurationSec)
        switch payload.markerUnit {
        case .mile: return String(localized: "Mile \(index) in \(time)", bundle: bundle)
        case .kilometer: return String(localized: "Kilometer \(index) in \(time)", bundle: bundle)
        case .twoKilometers: return String(localized: "\(index * 2) km in \(time)", bundle: bundle)
        case .fiveKilometers: return String(localized: "\(index * 5) km in \(time)", bundle: bundle)
        case .tenMinutes: return String(localized: "\(index * 10) minutes in \(time)", bundle: bundle)
        }
    }

    private static func formatDuration(seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// "pace 8:03 min/mi" — the pace converted into the user's units.
    private static func paceLabel(secPerKm: Double, imperial: Bool) -> String {
        // Convert km → mi if imperial: pace_per_mi = pace_per_km × 1.60934
        let total = Int((imperial ? secPerKm * 1.609_344 : secPerKm).rounded())
        let clock = String(format: "%d:%02d", total / 60, total % 60)
        return imperial
            ? String(localized: "pace \(clock) min/mi", bundle: LanguageManager.appBundle)
            : String(localized: "pace \(clock) min/km", bundle: LanguageManager.appBundle)
    }

    /// Spoken distance in full words ("3.1 miles"), in the app language.
    private static func formatDistance(meters: Double, imperial: Bool) -> String {
        let length = Measurement(value: meters, unit: UnitLength.meters)
            .converted(to: imperial ? .miles : .kilometers)
        return length.formatted(.measurement(
            width: .wide, usage: .asProvided,
            numberFormatStyle: FloatingPointFormatStyle<Double>.number.precision(.fractionLength(imperial ? 1 : 2))
        ).locale(LanguageManager.appLocale))
    }

    /// Spoken climb ("120 feet"), in the app language.
    private static func formatElevation(meters: Double, imperial: Bool) -> String {
        let height = Measurement(value: meters, unit: UnitLength.meters)
            .converted(to: imperial ? .feet : .meters)
        return height.formatted(.measurement(
            width: .wide, usage: .asProvided,
            numberFormatStyle: FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0))
        ).locale(LanguageManager.appLocale))
    }
}
