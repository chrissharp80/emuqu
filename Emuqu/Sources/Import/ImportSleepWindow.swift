import Foundation

/// Converts HealthKit's absolute sleep boundaries into offsets into an
/// imported recording.
///
/// The conversion below must not be a bare `Int64(interval * 1000)`. That traps
/// on NaN, on infinity, and on anything outside Int64 — and its inputs are
/// dates parsed out of a user-supplied file, so a corrupt or absurd timestamp
/// would crash the import rather than fail it. Same defect class as the
/// `GPXImporter` and `WorkoutAnalyzer` conversions.
enum ImportSleepWindow {
    /// Offsets in milliseconds from `recordingStart`, or nil where the
    /// boundary is absent or cannot be represented.
    struct Offsets: Equatable {
        var startMs: Int64?
        var wakeMs: Int64?
    }

    /// Why an offset was rejected — surfaced so the import log can say what
    /// happened instead of silently dropping a boundary.
    enum Rejection: String, Error {
        case notFinite = "timestamp is not a finite date"
        case outOfRange = "timestamp is too far from the recording to represent"

        /// The reason in the app's language, for the user-visible import log.
        var localizedReason: String {
            switch self {
            case .notFinite: String(localized: "timestamp is not a finite date", bundle: LanguageManager.appBundle)
            case .outOfRange: String(localized: "timestamp is too far from the recording to represent", bundle: LanguageManager.appBundle)
            }
        }
    }

    /// Milliseconds are held in Int64. A recording offset beyond ±100 years is
    /// not a real boundary, it is corrupt input, and clamping it would invent
    /// a plausible-looking window rather than reporting bad data.
    static let maxOffsetMs: Double = 100 * 365.25 * 24 * 60 * 60 * 1000

    /// Convert one absolute boundary into an offset, or explain the rejection.
    static func offsetMs(
        of boundary: Date,
        from recordingStart: Date
    ) -> Result<Int64, Rejection> {
        let seconds = boundary.timeIntervalSince(recordingStart)
        guard seconds.isFinite else { return .failure(.notFinite) }
        guard let ms = MillisecondOffset.milliseconds(from: seconds) else {
            return .failure(.outOfRange)
        }
        return .success(ms)
    }

    /// Convert a sleep window into recording offsets.
    ///
    /// A boundary that cannot be represented is dropped rather than clamped,
    /// and reported through `note` so the import log records the reason.
    static func offsets(
        sleepStart: Date?,
        sleepEnd: Date?,
        recordingStart: Date,
        note: (String) -> Void = { _ in }
    ) -> Offsets {
        var result = Offsets()
        if let sleepStart {
            switch offsetMs(of: sleepStart, from: recordingStart) {
            case let .success(ms):
                result.startMs = ms
            case let .failure(why):
                note("  " + String(localized: "Apple Health sleep start ignored: \(why.localizedReason)", bundle: LanguageManager.appBundle))
            }
        }
        if let sleepEnd {
            switch offsetMs(of: sleepEnd, from: recordingStart) {
            case let .success(ms):
                result.wakeMs = ms
            case let .failure(why):
                note("  " + String(localized: "Apple Health wake time ignored: \(why.localizedReason)", bundle: LanguageManager.appBundle))
            }
        }
        return result
    }

    /// Share of beats flagged as artifacts, as a percentage.
    ///
    /// Returns nil for an empty series rather than 0: a Double `0/0`
    /// produces NaN, which formats as "nan%" in the user-visible import log.
    static func artifactPercent(artifactCount: Int, totalBeats: Int) -> Double? {
        guard totalBeats > 0 else { return nil }
        return Double(artifactCount) / Double(totalBeats) * 100
    }
}
