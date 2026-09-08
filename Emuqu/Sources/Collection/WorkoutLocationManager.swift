import Combine
import CoreLocation
import CoreMotion
import Foundation

// MARK: - Workout Location Manager
//
// CoreLocation wrapper for workout GPS capture. Uses "While Using" permission
// only — the app is active during a workout, so there's no need for Always
// authorization and no backgrounding trickery. This is deliberately separate
// from BackgroundLocationManager (the historical overnight stub) because they
// have different permission, different lifecycle, and different purpose.
//
// Responsibilities:
//   - Request While-Using authorization on demand
//   - Stream CLLocation fixes while a workout is active
//   - Track cumulative distance across the session
//   - Provide a polyline suitable for map rendering and persistence
//
// What this does NOT do:
//   - Request Always authorization
//   - Attempt background execution beyond iOS's natural while-using lifetime
//   - Process routing, geofencing, or significant-change monitoring
@Observable
@MainActor
final class WorkoutLocationManager: NSObject {
    // MARK: Published live state

    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var currentLocation: CLLocation?
    private(set) var isTracking = false
    private(set) var distanceMeters: Double = 0
    private(set) var elevationGainMeters: Double = 0
    private(set) var elevationLossMeters: Double = 0
    /// Ordered sequence of captured fixes. Consumers can transform this into
    /// a compact polyline or persist verbatim.
    private(set) var track: [CLLocation] = []

    // MARK: Private

    private let manager = CLLocationManager()
    /// Fixes with horizontal accuracy worse than this threshold are dropped.
    /// Relaxed from 25m to 65m so we still collect SOMETHING indoors / in
    /// urban canyons — production running apps use ~50–100m for this gate.
    /// Individual bad fixes still get filtered; the track just isn't purist.
    private let accuracyThresholdMeters: Double = 65
    /// Movement below this threshold between consecutive fixes is ignored to
    /// prevent jitter-inflated distance while stationary. Raised from 1.5m
    /// to 3.5m after field reports of "distance grew while I sat in my
    /// chair" — stationary GPS easily produces 2–3 m of apparent movement
    /// per fix. 3.5 m (~2 casual steps) is the floor where "you're actually
    /// walking" becomes statistically distinguishable from "you're still".
    /// True slow walks (0.5 m/s) register once every ~7 s at this threshold —
    /// coarser cadence but the integrated distance comes out the same.
    private let minimumMovementMeters: Double = 3.5
    /// Movement below 1.5× the worst of the two fixes' horizontal-accuracy
    /// uncertainties is treated as noise. If your GPS says you're accurate
    /// to 10 m and you "moved" 3 m, that's within the measurement noise —
    /// accept the fix but don't credit the distance. This is the gate that
    /// actually kills chair-sitting drift: indoor accuracy is typically
    /// 8–15 m, so any apparent movement under ~20 m gets filtered out.
    private let accuracyNoiseMultiplier: Double = 1.5
    /// Elevation changes smaller than this between consecutive fixes are
    /// ignored. Sized for **barometric altitude** (CMAltimeter →
    /// `relativeAltitude`, typically ±0.5 m accurate), which is why 1 m
    /// holds without inflating gain. Raw GPS altitude (±5-10 m noise
    /// standard deviation) needs a far larger gate — even 2 m accumulates
    /// drift and walks report ~2× the real elevation gain.
    /// GPS altitude is still used as a starting-altitude reference for
    /// CLLocation compatibility; all gain/loss math runs against the
    /// barometer.
    private let minimumElevationChangeMeters: Double = 1.0

    /// Threshold (m) the live sustained-run accumulator commits a run at.
    /// Smaller than the post-hoc processor's threshold (which operates on
    /// SMOOTHED data with much lower noise) — the raw signal needs more
    /// margin so brief HVAC / pressure-front blips don't cross before
    /// reversing. 3 m matches what the field-test data converged on.
    private let liveSustainedClimbThresholdMeters: Double = 3.0
    private var liveAltitudeRunSum: Double = 0
    /// Most recent horizontal accuracy from CoreLocation. Surfaced so the UI
    /// can warn the user when GPS is degraded.
    private(set) var lastHorizontalAccuracy: Double?

    // MARK: - Barometric altitude
    //
    // CMAltimeter gives us *relative* pressure-based altitude changes at
    // ±0.5 m accuracy on all iPhones with a barometer (every iPhone 6+).
    // That's an order of magnitude better than raw GPS altitude (±5-10 m)
    // and matches what Strava / Garmin Connect actually use for their
    // elevation numbers. The CMAltimeter callback delivers a cumulative
    // `relativeAltitude` measured from the moment we called `startRelativeAltitudeUpdates`.
    private let altimeter = CMAltimeter()
    /// Whether the device supports relative-altitude updates.
    private(set) var barometerAvailable = false
    /// Wall-clock of the previous barometric sample, for delta-based
    /// live-accumulator display (NOT the source of truth — see buffer below).
    private var lastBarometricAltitude: Double?
    /// Starting reference altitude so we can annotate track fixes with
    /// barometrically-corrected elevations when GPS altitude drifts.
    private var barometricStartOffset: Double?

    /// Every barometric sample during the session, verbatim. The live
    /// `elevationGainMeters` value is a rough running estimate for the UI
    /// ticker; the AUTHORITATIVE elevation comes from post-processing
    /// this buffer on finalize via `BarometricAltitudeProcessor`, which
    /// applies sports-engineering best-practice smoothing (Savitzky-
    /// Golay style moving-average) + a 1 m sensor-noise-matched
    /// threshold on the smoothed signal. This replaces the old
    /// threshold-at-collect-time approach that was sensitive to noise
    /// spikes and couldn't be re-processed later.
    private(set) var barometricSamples: [(timestamp: Date, altitudeMeters: Double)] = []

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        // distanceFilter=kCLDistanceFilterNone — let every fix through; the
        // internal ingest filter decides whether to commit it.
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
        // Prevents iOS from auto-pausing long runs when the user stops briefly.
        manager.pausesLocationUpdatesAutomatically = false
    }

    // MARK: - Public control

    /// Requests While-Using authorization. Safe to call repeatedly; iOS will
    /// no-op on subsequent calls once a decision is made.
    func requestAuthorization() {
        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
    }

    /// Begin a fresh tracking session. Resets distance, elevation, and track.
    /// Enables background location so GPS keeps flowing when the screen
    /// locks — the whole point of "don't lose my 4-mile walk". Paired
    /// with the `location` UIBackgroundMode in Info.plist.
    ///
    /// Fine-grained logging inside this function so an
    /// app-watchdog kill (one logged `step=location.startTracking`
    /// and then 17 s of silence until iOS SIGKILLed at the 20 s watchdog
    /// threshold) tells us EXACTLY which sub-step hung. Each step is cheap to
    /// log and gives a deterministic breadcrumb when the iOS APIs misbehave
    /// under whatever race actually caused the freeze.
    func startTracking() {
        debugLog("[WorkoutLocation] startTracking step=1 entry authStatus=\(authorizationStatus.rawValue)")
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            requestAuthorization()
            return
        }
        debugLog("[WorkoutLocation] startTracking step=2 resetState")
        resetState()
        isTracking = true
        configureManagerForBackgroundTracking()
        debugLog("[WorkoutLocation] startTracking step=6 startUpdatingLocation")
        manager.startUpdatingLocation()
        debugLog("[WorkoutLocation] startTracking step=7 startBarometricAltitudeUpdates")
        // Start the barometer's relative-altitude stream. Drives the
        // elevation-gain/loss accumulators instead of the raw GPS altitude
        // that produced ~2× inflation.
        startBarometricAltitudeUpdates()
        debugLog("[WorkoutLocation] startTracking step=8 done")
    }

    /// Enabling background updates requires the `location` background mode in
    /// Info.plist (present). When set, iOS shows the blue status bar / Dynamic
    /// Island "App is using your location" pill — expected behaviour for a live
    /// fitness tracker.
    ///
    /// `allowsBackgroundLocationUpdates` is the most likely
    /// culprit for the iOS-26 watchdog kill. Its setter makes a synchronous XPC
    /// round-trip to locationd to verify entitlements + background modes; under
    /// BLE-radio contention (the user's session started ~4 s after a BLE
    /// power-cycle), iOS 26 has been observed to stall there for tens of
    /// seconds — hence the per-step logging.
    private func configureManagerForBackgroundTracking() {
        debugLog("[WorkoutLocation] startTracking step=3 allowsBackgroundLocationUpdates=true")
        manager.allowsBackgroundLocationUpdates = true
        debugLog("[WorkoutLocation] startTracking step=4 pausesLocationUpdatesAutomatically=false")
        // Pause on its own decision = BAD for long workouts (e.g. it'll
        // pause during stops at crosswalks). We decide when to pause.
        manager.pausesLocationUpdatesAutomatically = false
        debugLog("[WorkoutLocation] startTracking step=5 showsBackgroundLocationIndicator=true")
        // Hint to the system that we're in an active workout so it keeps
        // the accelerometer + GPS stack warm.
        manager.showsBackgroundLocationIndicator = true
    }

    /// End the current tracking session. Keeps the accumulated track so the
    /// caller can persist it before calling `reset()` or starting fresh.
    func stopTracking() {
        manager.stopUpdatingLocation()
        altimeter.stopRelativeAltitudeUpdates()
        isTracking = false
    }

    /// Buffers every raw barometric sample AND advances the live display
    /// accumulator.
    ///
    /// 1) The buffer is authoritative: `BarometricAltitudeProcessor` runs over
    ///    it at finalize time. The live accumulator below is just for the
    ///    ticker display.
    /// 2) The live estimate uses a sustained-run accumulator, NOT a
    ///    per-delta 1 m gate — that overcounts by ~2× from environmental
    ///    pressure noise (HVAC, weather fronts), the same bug the post-hoc
    ///    processor's per-delta gate had. This value is what the
    ///    live UI shows AND the fallback persisted value when
    ///    `barometricSamples` is somehow empty at finalize, so it has to be
    ///    honest.
    private func startBarometricAltitudeUpdates() {
        debugLog("[WorkoutLocation] barometer step=a checkAvailability")
        barometerAvailable = CMAltimeter.isRelativeAltitudeAvailable()
        guard barometerAvailable else {
            debugLog("[WorkoutLocation] barometer unavailable — falling back to GPS altitude (less accurate)")
            return
        }
        debugLog("[WorkoutLocation] barometer step=b startRelativeAltitudeUpdates")
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            let current = data.relativeAltitude.doubleValue
            self.barometricSamples.append((Date(), current))
            self.advanceLiveAltitudeRun(current: current)
        }
    }

    /// Single-step the live sustained-run elevation accumulator with the most
    /// recent altitude sample. See the comment in
    /// `startBarometricAltitudeUpdates` for why we don't just sum per-sample
    /// deltas with a fixed gate.
    ///
    /// Algorithm: accumulate same-sign deltas into `liveAltitudeRunSum`; when
    /// the next delta flips direction, commit the run to gain or loss IF its
    /// magnitude cleared `liveSustainedClimbThresholdMeters`, then start a
    /// fresh run with the new delta.
    private func advanceLiveAltitudeRun(current: Double) {
        defer { lastBarometricAltitude = current }
        guard let previous = lastBarometricAltitude else {
            // First sample seeds the anchor; nothing to accumulate yet.
            barometricStartOffset = current
            return
        }
        let delta = current - previous
        if delta == 0 { return }  // ties don't extend the run
        let sign = delta > 0 ? 1 : -1
        let runSign = liveAltitudeRunSum > 0 ? 1 : (liveAltitudeRunSum < 0 ? -1 : 0)
        if runSign == 0 || sign == runSign {
            liveAltitudeRunSum += delta  // same direction — extend the run
        } else {
            commitAltitudeRun()
            liveAltitudeRunSum = delta
        }
    }

    /// Direction flipped: bank the finished run if it cleared the threshold (a
    /// real climb / descent) rather than pressure noise.
    private func commitAltitudeRun() {
        guard abs(liveAltitudeRunSum) >= liveSustainedClimbThresholdMeters else { return }
        if liveAltitudeRunSum > 0 {
            elevationGainMeters += liveAltitudeRunSum
        } else {
            elevationLossMeters += -liveAltitudeRunSum
        }
    }

    /// Wipe the accumulated state — call after persisting the track.
    func reset() {
        resetState()
    }

    // MARK: - Internal

    private func resetState() {
        currentLocation = nil
        distanceMeters = 0
        elevationGainMeters = 0
        elevationLossMeters = 0
        lastBarometricAltitude = nil
        barometricStartOffset = nil
        liveAltitudeRunSum = 0
        barometricSamples.removeAll()
        track.removeAll()
    }

    private func ingest(location: CLLocation) {
        lastHorizontalAccuracy = location.horizontalAccuracy
        guard Self.isUsableFix(location, threshold: accuracyThresholdMeters) else {
            seedTrackIfEmpty(with: location)
            return
        }
        if let previous = track.last {
            creditMovement(from: previous, to: location)
        } else {
            track.append(location)
        }
        currentLocation = location
    }

    /// Drop obviously bad fixes. CoreLocation occasionally emits -1 accuracy
    /// shortly after startup. The accuracy-threshold gate is intentionally
    /// generous — production running apps commonly use 50–100 m so that
    /// urban-canyon and early-fix samples still contribute.
    private static func isUsableFix(_ location: CLLocation, threshold: Double) -> Bool {
        guard location.horizontalAccuracy > 0, location.horizontalAccuracy <= threshold else {
            debugLog("[WorkoutLocation] dropped fix — accuracy=\(String(format: "%.0f", location.horizontalAccuracy))m (threshold=\(Int(threshold))m)")
            return false
        }
        return true
    }

    /// Still append a rejected fix to the track when it's the first one, so the
    /// UI can show "searching…" with at least one point; callers use
    /// `distanceMeters` (which we didn't increment) as the measured value.
    private func seedTrackIfEmpty(with location: CLLocation) {
        guard track.isEmpty else { return }
        track.append(location)
        currentLocation = location
    }

    /// Two gates have to both pass before we credit the delta:
    ///   1. Apparent movement exceeds our fixed minimum (kills tiny sub-step
    ///      drift).
    ///   2. Apparent movement exceeds the measurement uncertainty of the worse
    ///      of the two fixes, times a safety factor. Indoor accuracy is
    ///      typically 8–15 m — a 3 m "step" when your fix is accurate to ±10 m
    ///      is noise, not motion.
    private func creditMovement(from previous: CLLocation, to location: CLLocation) {
        let distanceDelta = location.distance(from: previous)
        let noiseFloor = Self.noiseFloor(previous: previous, current: location, multiplier: accuracyNoiseMultiplier)
        let passesMinStep = distanceDelta >= minimumMovementMeters
        let passesNoiseFloor = distanceDelta >= noiseFloor
        guard passesMinStep, passesNoiseFloor else {
            logJitterReject(previous: previous, current: location, delta: distanceDelta, minStep: passesMinStep, noiseFloor: noiseFloor)
            return
        }
        distanceMeters += distanceDelta
        accumulateGPSElevationFallback(from: previous, to: location)
        track.append(location)
    }

    /// Cap the noise floor at 20 m. The accuracy×1.5 multiplier exists to kill
    /// chair-drift — indoors, accuracy is 8–15 m so the floor is 12–22 m, far
    /// above the 2–5 m of stationary GPS wander, so a sitting user never
    /// accumulates phantom distance. But with DEGRADED outdoor accuracy (cold
    /// GPS at the start of a walk, urban canyon, tree cover — anything up to
    /// the 65 m accept threshold) the uncapped floor demanded 30–97 m of
    /// movement before crediting ANY distance, so a real walk read as "frozen"
    /// until the fix sharpened. User report: "the location is acting
    /// weird — it wants you to be moving." Capping at 20 m preserves the
    /// stationary-drift rejection (drift never reaches 20 m) while letting
    /// genuine walking accumulate even when GPS is momentarily rough. The 3.5 m
    /// minimum-step gate still independently filters sub-step jitter.
    private static func noiseFloor(previous: CLLocation, current: CLLocation, multiplier: Double) -> Double {
        let worstAccuracy = max(current.horizontalAccuracy, previous.horizontalAccuracy)
        return min(worstAccuracy * multiplier, 20.0)
    }

    /// Elevation-gain / loss is accumulated by the CMAltimeter callback, NOT
    /// from GPS altitude. Raw GPS altitude carries ±5-10 m noise that
    /// accumulated into ~2× the real gain before the barometer swap. We still
    /// append the fix to the track (so the map + polyline encode correctly) —
    /// just don't read altitude from it for gain math. When the barometer is
    /// unavailable (rare — pre-iPhone-6), this keeps a GPS-altitude fallback
    /// inside a much higher noise gate.
    private func accumulateGPSElevationFallback(from previous: CLLocation, to location: CLLocation) {
        guard !barometerAvailable else { return }
        let elevationDelta = location.altitude - previous.altitude
        guard abs(elevationDelta) >= 5.0 else { return }  // GPS fallback: tighter gate
        if elevationDelta > 0 {
            elevationGainMeters += elevationDelta
        } else {
            elevationLossMeters += -elevationDelta
        }
    }

    /// Jitter — the fix isn't appended, but `currentLocation` still updates so
    /// the map marker refreshes. Logged once per minute so a debug session can
    /// confirm which gate rejected.
    private func logJitterReject(previous: CLLocation, current: CLLocation, delta: Double, minStep: Bool, noiseFloor: Double) {
        guard Int(elapsedSecondsSinceTrackStart(previous: previous, current: current)) % 60 == 0 else { return }
        debugLog(
            "[WorkoutLocation] jitter reject dd=\(String(format: "%.1f", delta))m " +
                "minStep=\(minStep) noiseFloor=\(String(format: "%.1f", noiseFloor))m " +
                "acc=\(String(format: "%.0f", current.horizontalAccuracy))m"
        )
    }

    /// Helper used only to rate-limit jitter-reject logs. Returns the number
    /// of seconds between the two fixes' timestamps.
    private func elapsedSecondsSinceTrackStart(previous: CLLocation, current: CLLocation) -> Double {
        current.timestamp.timeIntervalSince(previous.timestamp)
    }
}

// MARK: - CLLocationManagerDelegate

extension WorkoutLocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations
        Task { @MainActor in
            for fix in fixes {
                self.ingest(location: fix)
            }
            // Forward the freshest fix to the ambient
            // service so the AI's location tools can fast-path.
            // Workout-while-backgrounded is the user's primary case
            // ("phone locked, audiobook, workout running"); the
            // ambient service itself is stopped in that state, so
            // without this push the cache would stay empty and the
            // AI would cold-fetch + time out.
            if let last = fixes.last {
                AppDependencies.current.location.ambientLocationService.record(last)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Silent — CoreLocation can transiently emit errors during bad signal.
        // The app remains usable without GPS (distance just stops advancing).
    }
}
