import CoreLocation
import Foundation

/// The live speed of a workout in progress, and the pace shown from it.
///
/// One value for every consumer: the phone's pace tile, the Watch, the AI
/// coach's live context and its pace rules, pace thresholds, the per-second
/// samples (and so the METs, Apple Health energy, training load, post-workout
/// pace chart, CSV and PDF built from them).
///
/// Workout distance does not arrive smoothly. `WorkoutLocationManager` credits
/// a GPS step only once it clears a 3.5 m floor and 1.5 × the fixes'
/// accuracy, so a walker's distance grows in chunks of about 8 m every few
/// seconds; the pedometer delivers in batches too. Dividing one tick's change
/// by one second reads N times too fast on the tick a chunk lands and nothing
/// on the others. Speed is therefore measured the way sports watches measure
/// it, in this order:
///
///   1. Foot pod (or trainer) speed, when it reports one: a direct measurement.
///   2. GNSS Doppler speed (`CLLocation.speed`) for an outdoor sport, when the
///      fix is fresh and both its position and its speed are accurate. Doppler
///      speed comes from the satellite signal's frequency shift, not from
///      differencing noisy positions, so it is the most accurate speed a phone
///      has. It is averaged over the last few seconds of fixes.
///   3. Otherwise distance over a trailing window, measured between the
///      ticks on which that distance actually advanced. Distance credited at
///      those ticks covers exactly the time between them, so chunked arrival
///      does not bias the result. The window reaches back at least
///      `distanceTargetSpanSec` when the data allows. Each distance source has
///      its own window, used in this order: GPS while its fixes are accurate
///      to `dopplerMaxHorizontalAccuracyM`, the pedometer (on-foot sports),
///      then the workout distance the screen shows (the rower's odometer on
///      the erg). One source at a time: the screen's distance is the larger of
///      GPS and pedometer, and the lead passing between two staircases that
///      disagree by a few percent would read as surges and stalls.
///
/// Between chunks the last estimate is held. Once no distance has arrived for
/// longer than `holdIntervals` typical gaps, the estimate decays as if the
/// next chunk is still to come, and below `minimumPaceSpeedMS` there is no
/// pace: a stopped user reads "—", not a stale number.
struct LivePaceEstimator: Equatable {
    /// One GNSS fix's speed and how much to trust it.
    struct GPSSpeed: Equatable {
        let speedMS: Double
        let speedAccuracyMS: Double
        let horizontalAccuracyM: Double
        let timestamp: Date
    }

    /// What one 1 Hz tick knows. Distances are this workout's so far, with
    /// paused stretches already taken out.
    struct Reading {
        let now: Date
        /// The distance the live screen shows.
        let distanceMeters: Double
        /// GPS-credited distance; nil for an indoor sport.
        var gpsMeters: Double?
        /// Pedometer distance; nil for a sport not done on foot.
        var pedometerMeters: Double?
        var footPodSpeedMS: Double?
        /// The newest fix; nil for an indoor sport.
        var gps: GPSSpeed?
    }

    /// Where the current estimate came from.
    enum Source: String, Equatable {
        case footPod, gpsDoppler, gpsDistance, pedometer, distance
    }

    /// Slower than this (1.8 km/h, below a stroll) is not a pace.
    static let minimumPaceSpeedMS = 0.5
    /// A fix counts as accurate when it is this recent, its position is good
    /// to `dopplerMaxHorizontalAccuracyM` and (for Doppler) its speed to
    /// `dopplerMaxSpeedAccuracyMS`.
    static let dopplerMaxFixAgeSec: TimeInterval = 3
    static let dopplerMaxHorizontalAccuracyM = 20.0
    static let dopplerMaxSpeedAccuracyMS = 0.5
    /// Doppler readings averaged together.
    static let dopplerWindowSec: TimeInterval = 5
    /// Distance steps older than this are dropped.
    static let distanceWindowSec: TimeInterval = 30
    /// The distance estimate spans at least this long when the window has it.
    static let distanceTargetSpanSec: TimeInterval = 10
    /// Two steps closer together than this give no estimate.
    static let distanceMinimumSpanSec: TimeInterval = 4
    /// The estimate holds for this many typical step gaps (at least
    /// `minimumHoldSec`) after the last step before it starts to decay.
    static let holdIntervals = 1.5
    static let minimumHoldSec: TimeInterval = 3

    /// Speed in m/s, nil when nothing can be measured yet.
    private(set) var speedMS: Double?
    private(set) var source: Source?
    private var gpsWindow = DistanceWindow()
    private var pedometerWindow = DistanceWindow()
    private var totalWindow = DistanceWindow()
    private var dopplerReadings: [GPSSpeed] = []
    private var latestFix: GPSSpeed?

    /// Seconds per kilometre, nil when there is no speed or the user is
    /// slower than `minimumPaceSpeedMS`.
    var paceSecPerKm: Double? {
        guard let speedMS, speedMS >= Self.minimumPaceSpeedMS else { return nil }
        return 1000 / speedMS
    }

    /// Whether the pedometer measures this sport's distance.
    static func countsSteps(_ sport: Sport) -> Bool {
        switch sport {
        case .run, .trailRun, .walk, .hike, .treadmill: true
        case .bike, .indoorBike, .row, .airBike, .crossFit: false
        }
    }

    /// Forget everything: a new workout, or a pause (time paused is not time
    /// moving, and the distance does not advance through it).
    mutating func reset() {
        self = LivePaceEstimator()
    }

    mutating func update(_ reading: Reading) {
        let now = reading.now
        gpsWindow.record(reading.gpsMeters, at: now)
        pedometerWindow.record(reading.pedometerMeters, at: now)
        totalWindow.record(reading.distanceMeters, at: now)
        recordDoppler(reading)
        let (speed, origin) = estimate(reading)
        speedMS = speed
        source = speed == nil ? nil : origin
    }

    /// The first source in the precedence order that has a value.
    private func estimate(_ reading: Reading) -> (Double?, Source) {
        let now = reading.now
        if let footPod = reading.footPodSpeedMS, footPod.isFinite, footPod > 0 { return (footPod, .footPod) }
        if let doppler = dopplerSpeed(now: now) { return (doppler, .gpsDoppler) }
        if gpsIsAccurate(now: now), let gps = gpsWindow.speed(now: now) { return (gps, .gpsDistance) }
        if let steps = pedometerWindow.speed(now: now) { return (steps, .pedometer) }
        return (totalWindow.speed(now: now), .distance)
    }

    /// The newest fix is recent and its position good enough that GPS
    /// distance steps are small and frequent.
    private func gpsIsAccurate(now: Date) -> Bool {
        guard let fix = latestFix else { return false }
        return fix.horizontalAccuracyM > 0 && fix.horizontalAccuracyM <= Self.dopplerMaxHorizontalAccuracyM
            && now.timeIntervalSince(fix.timestamp) <= Self.dopplerMaxFixAgeSec
    }

    // MARK: - Doppler

    /// Keeps the trustworthy fixes of the last few seconds, one entry per fix.
    private mutating func recordDoppler(_ reading: Reading) {
        latestFix = reading.gps ?? latestFix
        let cutoff = reading.now.addingTimeInterval(-Self.dopplerWindowSec)
        dopplerReadings.removeAll { $0.timestamp < cutoff }
        guard let fix = reading.gps, Self.isTrustworthy(fix, now: reading.now),
              fix.timestamp > (dopplerReadings.last?.timestamp ?? .distantPast) else { return }
        dopplerReadings.append(fix)
    }

    /// The mean Doppler speed of the recent fixes, provided the newest fix is
    /// itself trustworthy; otherwise nil, and a distance window is used.
    private func dopplerSpeed(now: Date) -> Double? {
        guard let fix = latestFix, Self.isTrustworthy(fix, now: now),
              !dopplerReadings.isEmpty else { return nil }
        return dopplerReadings.reduce(0) { $0 + $1.speedMS } / Double(dopplerReadings.count)
    }

    /// CoreLocation reports a negative speed or accuracy when it has none.
    static func isTrustworthy(_ fix: GPSSpeed, now: Date) -> Bool {
        fix.speedMS.isFinite && fix.speedMS >= 0
            && fix.speedAccuracyMS > 0 && fix.speedAccuracyMS <= dopplerMaxSpeedAccuracyMS
            && fix.horizontalAccuracyM > 0 && fix.horizontalAccuracyM <= dopplerMaxHorizontalAccuracyM
            && now.timeIntervalSince(fix.timestamp) <= dopplerMaxFixAgeSec
    }
}

// MARK: - Distance window

extension LivePaceEstimator {
    /// One cumulative distance's recent history: the ticks on which it
    /// advanced, and how far it stood at each.
    struct DistanceWindow: Equatable {
        private struct Step: Equatable {
            let at: Date
            let meters: Double
        }

        private var steps: [Step] = []

        /// A distance that went backwards (a source reset) starts over.
        mutating func record(_ meters: Double?, at now: Date) {
            if let meters, meters.isFinite {
                if let last = steps.last, meters < last.meters { steps.removeAll() }
                if meters > (steps.last?.meters ?? 0) { steps.append(Step(at: now, meters: meters)) }
            }
            let cutoff = now.addingTimeInterval(-LivePaceEstimator.distanceWindowSec)
            steps.removeAll { $0.at < cutoff }
        }

        /// Distance between the anchor step and the newest one, over the time
        /// between them, stretched by however long the next step is overdue.
        func speed(now: Date) -> Double? {
            guard let newest = steps.last, let anchorIndex = anchorIndex(newest: newest) else { return nil }
            let anchor = steps[anchorIndex]
            let span = newest.at.timeIntervalSince(anchor.at)
            guard span >= LivePaceEstimator.distanceMinimumSpanSec else { return nil }
            let typicalGap = span / Double(steps.count - 1 - anchorIndex)
            let hold = max(LivePaceEstimator.minimumHoldSec, LivePaceEstimator.holdIntervals * typicalGap)
            let overdue = max(0, now.timeIntervalSince(newest.at) - hold)
            return (newest.meters - anchor.meters) / (span + overdue)
        }

        /// The newest step at least `distanceTargetSpanSec` before `newest`,
        /// else the oldest step. Nil when there is only one step.
        private func anchorIndex(newest: Step) -> Int? {
            guard steps.count >= 2 else { return nil }
            let reach = newest.at.addingTimeInterval(-LivePaceEstimator.distanceTargetSpanSec)
            return steps.lastIndex { $0.at <= reach } ?? 0
        }
    }
}

extension LivePaceEstimator.GPSSpeed {
    init(_ location: CLLocation) {
        self.init(
            speedMS: location.speed,
            speedAccuracyMS: location.speedAccuracy,
            horizontalAccuracyM: location.horizontalAccuracy,
            timestamp: location.timestamp
        )
    }
}
