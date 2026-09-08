import Combine
// `@preconcurrency`: CLLocationManager and CLHeading predate Sendable.
@preconcurrency import CoreLocation
import Foundation

// MARK: - BreadcrumbRecorder
//
// Engaged-only background-tolerant location recorder for "Get Me Back"
// mode. Distinct from `WorkoutLocationManager` (which is high-accuracy,
// every-fix-forwarded, used only during an active workout) because:
//
//  - This runs while NO workout is active.
//  - It uses lower accuracy + larger distance filter to save battery
//    over hours of background recording.
//  - Every fix is persisted via `BreadcrumbStore.save(_:)` so a crash
//    or a kill-then-relaunch days later doesn't lose the trail.
//
// **Throttling.** A new fix is committed to the trail when EITHER:
//   - 30 s have elapsed since the last commit, OR
//   - the user has moved 25 m from the last commit.
// Whichever fires first. Below those thresholds, fixes are dropped to
// keep the trail file small and the radio quiet.
//
// **Heading.** Subscribes to `startUpdatingHeading()` so the
// `GetMeBackView` compass arrow can rotate based on the user's actual
// device orientation (magnetic compass) — distinct from GPS course,
// which is meaningless when stationary. The published heading is the
// raw `CLHeading` value; the view does the bearing math.
//
// **Authorization.** Requests "When In Use" only. The app does NOT
// request "Always" — the breadcrumb mode is engaged when the user is
// actively using the phone OR has it in their pocket with the screen
// off (iOS allows continued background updates with `When In Use` IFF
// `allowsBackgroundLocationUpdates = true` AND a `location` background
// mode is declared, both of which are already in place for the workout
// recorder).

@Observable

@MainActor
final class BreadcrumbRecorder: NSObject {
    // MARK: Singleton

    static let shared = BreadcrumbRecorder()

    // MARK: Published state

    /// Latest CLLocation fix from the recorder. Used by `GetMeBackView`
    /// to compute distance + bearing in real time.
    private(set) var latestLocation: CLLocation?
    /// Latest CLHeading from the magnetic compass. Drives the arrow
    /// rotation in the UI. Updates ~10 Hz when active, much faster than
    /// the throttled location commits.
    private(set) var latestHeading: CLHeading?
    /// Current trail (mirror of `AppDependencies.current.location.breadcrumbStore` content with
    /// every committed fix). nil when no mode is engaged.
    private(set) var activeTrail: BreadcrumbTrail?
    /// Whether `engage()` has been called and recording is running.
    private(set) var isEngaged: Bool = false
    /// Authorization status surfaced for UI gating ("you need to allow
    /// location for this to work").
    private(set) var authorizationStatus: CLAuthorizationStatus

    // MARK: Private

    private let manager = CLLocationManager()
    /// Movement threshold below which a new fix is NOT committed (the
    /// time gate may still commit).
    private static let movementCommitMeters: Double = 25
    /// Time threshold above which a fix IS committed even with little
    /// movement. Keeps the trail "alive" while the user takes a
    /// breather.
    private static let timeCommitSeconds: TimeInterval = 30
    /// Last fix we actually wrote to the trail. Distinct from the most
    /// recent CLLocation we received, because most fixes get dropped
    /// by the throttle.
    private var lastCommittedFix: BreadcrumbFix?

    override private init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        // Lower accuracy than the workout recorder — we don't need
        // 5m precision for "lead me back", and the battery savings on
        // a 6-hour hike are real (~30% less radio time).
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        // distanceFilter set in addition to the time-based throttle.
        // 10m below our 25m commit threshold gives the throttle some
        // breathing room while still rate-limiting the delegate noise.
        manager.distanceFilter = 10
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        // Restore prior trail (if any) so the user can pick up where
        // they left off across an app kill / day rollover.
        activeTrail = AppDependencies.current.location.breadcrumbStore.load()
    }

    // MARK: - Public control

    func engage(label: String? = nil) {
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            return
        }
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        // Fresh trail — origin will be set when the first fix arrives.
        let trail = BreadcrumbTrail(
            startedAt: Date(), origin: nil, fixes: [],
            label: label, resolvedOriginLabel: nil
        )
        activeTrail = trail
        AppDependencies.current.location.breadcrumbStore.save(trail)
        lastCommittedFix = nil
        startStreaming()
        isEngaged = true
    }

    /// Turn the location manager on for background trail recording. Heading is
    /// optional — simulators and some iPads have no magnetometer.
    private func startStreaming() {
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    /// Stop recording. Trail stays on disk so the user can re-engage or
    /// clear later. Battery returns to baseline immediately.
    func disengage() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
        isEngaged = false
    }

    /// User-confirmed delete. Stops recording AND clears the trail
    /// from disk. Always-confirm semantics enforced by the caller.
    func clearTrail() {
        disengage()
        AppDependencies.current.location.breadcrumbStore.clear()
        activeTrail = nil
        lastCommittedFix = nil
    }

    /// Annotate the active trail with a user-typed label or a resolved
    /// origin address. Persists immediately.
    func updateLabel(_ label: String?) {
        guard var trail = activeTrail else { return }
        trail.label = label
        activeTrail = trail
        AppDependencies.current.location.breadcrumbStore.save(trail)
    }

    func updateResolvedOriginLabel(_ resolved: String?) {
        guard var trail = activeTrail else { return }
        trail.resolvedOriginLabel = resolved
        activeTrail = trail
        AppDependencies.current.location.breadcrumbStore.save(trail)
    }

    // MARK: - Throttle gate

    private func shouldCommit(_ candidate: CLLocation) -> Bool {
        // Drop garbage fixes outright — a horizontalAccuracy <= 0
        // indicates an invalid CLLocation per Apple docs. Don't pollute
        // the trail with those.
        guard candidate.horizontalAccuracy > 0 else { return false }
        // Cap accepted accuracy at 100 m — anything looser is more
        // likely to lead the user astray than help them. The UI also
        // signals "wait for a better fix" at this threshold.
        guard candidate.horizontalAccuracy <= 100 else { return false }

        guard let last = lastCommittedFix else { return true }
        let elapsed = candidate.timestamp.timeIntervalSince(last.timestamp)
        if elapsed >= Self.timeCommitSeconds { return true }
        let dist = candidate.distance(from: last.asCLLocation)
        if dist >= Self.movementCommitMeters { return true }
        return false
    }

    private func commit(_ loc: CLLocation) {
        let fix = BreadcrumbFix(from: loc)
        guard var trail = activeTrail else { return }
        // First fix becomes the origin.
        if trail.origin == nil { trail.origin = fix }
        trail.fixes.append(fix)
        activeTrail = trail
        lastCommittedFix = fix
        AppDependencies.current.location.breadcrumbStore.save(trail)
    }
}

// MARK: - CLLocationManagerDelegate

extension BreadcrumbRecorder: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.applyAuthorization(status, manager: manager) }
    }

    /// A grant that arrives while a trail is already engaged starts the streams
    /// that couldn't run before.
    @MainActor
    private func applyAuthorization(_ status: CLAuthorizationStatus, manager: CLLocationManager) {
        authorizationStatus = status
        let granted = status == .authorizedWhenInUse || status == .authorizedAlways
        guard isEngaged, granted else { return }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    nonisolated func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.latestLocation = loc
            if self.shouldCommit(loc) {
                self.commit(loc)
            }
            // Forward to the ambient service so the AI's
            // cache fast-path works during a Get-Me-Back session too.
            AppDependencies.current.location.ambientLocationService.record(loc)
        }
    }

    nonisolated func locationManager(_: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        Task { @MainActor in
            self.latestHeading = newHeading
        }
    }

    nonisolated func locationManager(_: CLLocationManager, didFailWithError _: Error) {
        // Common during a poor-fix interlude; not actionable here.
        // The UI's accuracy ribbon handles user-visible feedback.
    }
}
