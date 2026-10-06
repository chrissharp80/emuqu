import CryptoKit
import Foundation

// When the training-load cache rebuilds: what its result depends on, and the
// rule that decides whether that can have changed.

extension TrainingMetricsCache {
    /// The settings training load depends on: the resting- and max-HR
    /// settings and biological sex (Banister TRIMP for workouts without a
    /// precomputed load) and the FTPs (read-time power TSS). A change to any
    /// of them changes every day's load, so it rebuilds the cache at once.
    struct LoadSettings: Equatable, Codable, Sendable {
        let restingHR: Int
        let maxHR: Int
        let isFemale: Bool
        let ftp: TrainingLoadPrecedence.FTPAnchors

        init(_ settings: UserSettings) {
            restingHR = settings.effectiveRestingHR
            maxHR = settings.effectiveMaxHR
            isFemale = settings.biologicalSex == .female
            ftp = .current(settings)
        }
    }

    /// Everything a day-by-day series build reflects. A build is kept only
    /// while all of it still holds.
    struct HistoricalKey: Equatable, Sendable {
        /// Fingerprint of the archived workouts (`workoutFingerprint`).
        let archive: String
        /// Fingerprint of the HealthKit workouts (`healthKitFingerprint`),
        /// which is how a workout logged in another app reaches the series.
        let healthKit: String
        let day: Date
        let settings: LoadSettings
        let anchors: TrainingLoadSeries.HeartRateAnchors
    }

    /// Bursts of refresh calls within this many seconds of a compute share it.
    nonisolated static let burstThrottleSec: TimeInterval = 300

    /// How long a result is reused when nothing the cache can see has
    /// changed (same archived workouts, same day, same settings). Training
    /// load also depends on things the cache cannot see without asking
    /// HealthKit: a workout logged in another app, a new Apple resting HR.
    /// After this long the cache asks again.
    nonisolated static let unchangedMaxAgeSec: TimeInterval = 1800

    /// Whether a refresh must recompute.
    ///
    /// - No result yet, or `invalidate()` cleared `lastUpdated`: yes.
    /// - The load settings changed: yes, at once.
    /// - The archived workouts or the day changed: yes, once the burst
    ///   throttle has passed.
    /// - Nothing observable changed: only once the result is older than
    ///   `unchangedMaxAgeSec`, so other apps' workouts and Apple's resting
    ///   HR are picked up within half an hour.
    nonisolated static func needsRebuild(
        lastUpdated: Date?,
        hasResult: Bool,
        observedChange: Bool,
        settingsChanged: Bool,
        reference: Date
    ) -> Bool {
        guard let lastUpdated, hasResult else { return true }
        if settingsChanged { return true }
        let age = reference.timeIntervalSince(lastUpdated)
        return age > (observedChange ? burstThrottleSec : unchangedMaxAgeSec)
    }

    /// Fingerprint of a HealthKit workout list: each workout's start,
    /// duration, type, average HR and precomputed load, in start order.
    nonisolated static func healthKitFingerprint(_ workouts: [HealthKitManager.WorkoutSummary]) -> String {
        var digest = SHA256()
        for workout in workouts.sorted(by: { $0.date < $1.date }) {
            let line = [
                "\(workout.date.timeIntervalSince1970)", "\(workout.durationMinutes)",
                workout.workoutType, "\(workout.averageHR ?? -1)", "\(workout.precomputedLoad ?? -1)"
            ].joined(separator: ":")
            digest.update(data: Data((line + "\n").utf8))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
