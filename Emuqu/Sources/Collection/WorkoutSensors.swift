import Foundation

/// The motion sensors a workout reads (GPS and barometer, pedometer, foot
/// pod) and this workout's running readings of them.
@Observable
@MainActor
final class WorkoutSensors {
    // The location stack is NOT constructed eagerly: that pulls in
    // `CLLocationManager` + `CMAltimeter` synchronously on the main thread.
    // The recorder is bound at Fitness-tab appear (so the Watch's "Start"
    // command can route through it on a cold tab), but the user often hasn't
    // tapped the in-app Start button for many seconds — they're picking
    // sport / target / strap. Eagerly building the location stack adds 1–3 s
    // of main-thread work to the tab swap, so it is lazy: constructed on first
    // access (start() for a GPS sport, or any view that reads `location`). By
    // that point the user has explicitly committed to a workout.
    private let injectedLocation: WorkoutLocationManager?
    private var lazyLocation: WorkoutLocationManager?

    let pedometer = WorkoutPedometer()
    /// Optional foot pod / running power meter. Shared singleton so the
    /// Settings screen can pair it outside a workout and have the pairing
    /// still be there when a workout starts. When connected, foot-pod
    /// readings take priority over GPS + pedometer.
    let footPod: FootPodManager

    /// This workout's foot-pod distance, kept across pod resets. The pod
    /// reports cumulative distance from power-on (not from workout start),
    /// so its first reading is the baseline subtracted to get
    /// session-relative distance. Replaced with a fresh odometer at workout
    /// start, which also drops any distance banked across a pod reset.
    var footPodOdometer = FootPodOdometer()
    /// The pedometer step count as of the last tick that saw it change, and
    /// when. Lets the indoor auto-pause tell a stopped treadmill from the
    /// last walking cadence the pedometer leaves standing.
    @ObservationIgnored var lastPedometerStepAdvance: (count: Int, at: Date?) = (0, nil)

    /// `location` keeps the test-injection seam but defers the production
    /// allocation: an injected manager is used as is, otherwise the getter
    /// constructs one on first access.
    init(location: WorkoutLocationManager?, footPod: FootPodManager) {
        self.injectedLocation = location
        self.footPod = footPod
    }

    /// The location stack if something has built it (start() for a GPS
    /// sport, or a view that read `location`); nil otherwise. Pause, stop and
    /// finalize read it through this, so an indoor workout never builds the
    /// stack (the 1–3 s of main-thread work above) only to find it empty.
    var startedLocation: WorkoutLocationManager? { injectedLocation ?? lazyLocation }

    var location: WorkoutLocationManager {
        if let injectedLocation { return injectedLocation }
        if let lazyLocation { return lazyLocation }
        let fresh = WorkoutLocationManager()
        lazyLocation = fresh
        return fresh
    }

    /// Foot-pod odometers report lifetime distance, so the workout's share is
    /// the delta from whatever the pod read when this workout first saw it.
    /// A reading lower than the last one is a pod reset (power cycle or
    /// reconnect): the distance covered so far is banked and the new reading
    /// becomes the baseline, so the workout's distance never goes backwards.
    /// With no reading (pod disconnected) the distance so far is returned.
    func footPodDistanceMeters() -> Double {
        guard let reported = footPod.podReportedDistanceMeters else { return footPodOdometer.distanceMeters }
        return footPodOdometer.record(reported)
    }
}

/// One workout's foot-pod distance from the pod's lifetime odometer readings.
/// The pod's counter restarts when it is power-cycled or reconnects, so a
/// reading below the previous one banks the distance covered so far and
/// starts a new baseline from that reading.
struct FootPodOdometer {
    /// The pod reading this stretch of the workout is measured from.
    private(set) var baselineMeters: Double?
    private var lastReadingMeters: Double?
    private var bankedMeters: Double = 0

    init(baselineMeters: Double? = nil) {
        self.baselineMeters = baselineMeters
    }

    /// Distance covered this workout as of the last reading.
    var distanceMeters: Double {
        guard let baselineMeters, let lastReadingMeters else { return bankedMeters }
        return bankedMeters + max(0, lastReadingMeters - baselineMeters)
    }

    /// Takes a new pod reading and returns the workout's distance.
    mutating func record(_ reading: Double) -> Double {
        if let lastReadingMeters, reading < lastReadingMeters {
            bankedMeters = distanceMeters
            baselineMeters = reading
        }
        if baselineMeters == nil { baselineMeters = reading }
        lastReadingMeters = reading
        return distanceMeters
    }
}
