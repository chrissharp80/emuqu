import CoreLocation
import Foundation

/// Low-power background keep-alive via a standing CLLocationManager.
///
/// **What it does.** When the user has already granted location permission
/// (When-In-Use or Always), starting this manager keeps the iOS app
/// eligible for background CPU time by holding an active location
/// manager. It does NOT record GPS tracks — the workout uses a separate
/// `WorkoutLocationManager` for that. This one is pure keep-alive.
///
/// **Why it exists.** An outdoor GPS workout cannot rely on
/// `BackgroundAudioManager` alone — silent audio playback as the iOS
/// "stay alive" mechanism. That path is fragile under real-world
/// conditions:
///
///   - A phone call or Siri trigger interrupts the audio session, and its
///     recovery (the 30 s health check in `BackgroundAudioManager`) can take
///     several cycles to re-establish playback.
///   - AirPlay / BT route changes can stop silent playback.
///
/// Location keep-alive is independent of the audio session — the two
/// subsystems can fail independently. Running both is belt-and-braces
/// (user's ask: "use location along with existing strategies") so a
/// failure of one doesn't silently suspend the app. Indoor workouts and
/// overnight recording never use it (see App Store posture below).
///
/// **Power budget.** Low. `kCLLocationAccuracyThreeKilometers` plus a
/// 1 km `distanceFilter` lets iOS use the cell-tower positioning path
/// rather than GPS, which in Apple's own disclosures costs roughly the
/// same as leaving Maps open to nothing. The app receives a location
/// callback every few minutes at most; we ignore the contents entirely.
///
/// **Permission posture.** This class NEVER requests elevated
/// authorisation. If the user only granted "While Using," we start in
/// that mode; iOS will suspend the app at next foreground-to-background
/// transition unless another mechanism (audio, UIBackgroundTask) is
/// also active — so the coordinator pairs us with audio rather than
/// replacing it.
///
/// **Redundancy, stated plainly.** `WorkoutLocationManager`
/// already sets `allowsBackgroundLocationUpdates = true` on its own manager for
/// the same session, so for background *eligibility* this class adds nothing
/// its sibling does not already provide. It is kept anyway, deliberately: the
/// two managers can fail independently, and the failure this exists to survive
/// — the app being suspended mid-recording — is one the project has already
/// been bitten by. Deleting a keep-alive added after a production incident, to
/// remove a redundancy, is the wrong trade.
///
/// **App Store posture (2.5.4).** The `UIBackgroundModes = location` entry
/// is declared in Info.plist and backed by a real, user-visible location
/// feature: outdoor route recording. This keep-alive is started from
/// exactly ONE place — `WorkoutRecorder+Start.startKeepAlives(sport:hasIntervalPlan:)`,
/// reached from `start()` — and *only* inside its `sport.usesGPS` gate, so it runs strictly
/// concurrently with `WorkoutLocationManager`, which IS recording the GPS
/// track for that same session. The empty `didUpdateLocations` below is
/// therefore not "location with no purpose" — the purpose is the route the
/// sibling manager is actively logging; this class just holds background
/// eligibility so a mid-run audio/BT hiccup can't suspend the recording.
///
/// Indoor sessions (no GPS feature) never start this — they ride on
/// `bluetooth-central` (strap/erg stream). Overnight likewise (there is
/// no `.overnightHRV` reason). Those are the only
/// paths that would be genuine 2.5.4 violations, and both are closed.
/// If a future call site is added, it MUST be behind a GPS-workout gate.
@Observable
@MainActor
final class BackgroundLocationManager: NSObject {
    static let shared = BackgroundLocationManager()

    /// Reason the keep-alive is active — must be one of these.
    /// Makes the active-session contract explicit so a
    /// future call site can't accidentally start background location
    /// without an enclosing user-visible session.
    enum ActivationReason: String, Sendable {
        case workoutRecording  // active GPS workout via WorkoutRecorder (route is being recorded)
        // No `.overnightHRV` case — overnight keep-alive via
        // background location violates App Store 2.5.4 (no location
        // feature); overnight rides on `bluetooth-central`.
        //
        // No `.pausedWorkout` case — it would have zero call sites. A
        // dead case in the type whose entire purpose is to enumerate the
        // legitimate reasons for holding background location is worse than
        // dead code elsewhere: it reads to a reviewer as a claim that the app
        // keeps location alive through a pause, which it does not.

        var description: String {
            switch self {
            case .workoutRecording: return "active workout"
            }
        }
    }

    private(set) var isRunning = false
    private(set) var lastError: String?
    private(set) var activeReason: ActivationReason?

    /// Mirror of `CLLocationManager.authorizationStatus`, kept observable
    /// so settings UI can react without the SwiftUI tree
    /// re-reading CoreLocation every frame.
    private(set) var authorizationStatus: CLAuthorizationStatus

    /// Cached result of `CLLocationManager.locationServicesEnabled()`.
    /// Updated off the main thread (Apple deprecated direct calls on
    /// main; the system call can block while contacting the location
    /// daemon — runtime warning at the call site, occasional hang in
    /// the wild). Refreshed at init and again whenever the delegate
    /// fires `locationManagerDidChangeAuthorization`.
    private(set) var locationServicesEnabled: Bool = true

    @ObservationIgnored private let manager: CLLocationManager

    override private init() {
        manager = CLLocationManager()
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 1000
        manager.pausesLocationUpdatesAutomatically = false
        // `allowsBackgroundLocationUpdates` requires `UIBackgroundModes`
        // to include `location` (it does — see Info.plist) AND for
        // authorisation to be granted; we flip this on in `start()` to
        // avoid the runtime assertion if the user is in denied state.
        refreshLocationServicesEnabled()
    }

    /// True when the user has granted any form of location authorisation
    /// that allows us to use the service. Denied / restricted / not-
    /// determined all return false. Reads only the cached
    /// `locationServicesEnabled` property — no main-thread CL call.
    var canUseLocationServices: Bool {
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return locationServicesEnabled
        default:
            return false
        }
    }

    /// Refresh the `locationServicesEnabled` cache off the main thread.
    /// `CLLocationManager.locationServicesEnabled()` is a synchronous
    /// system call that can block waiting on locationd; calling it on
    /// the main thread produces a runtime warning. Dispatching to a
    /// global queue keeps the UI responsive.
    nonisolated private func refreshLocationServicesEnabled() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let enabled = CLLocationManager.locationServicesEnabled()
            Task { @MainActor [weak self] in
                self?.locationServicesEnabled = enabled
            }
        }
    }

    // MARK: - Lifecycle

    /// Start the keep-alive manager. Safe to call multiple times (idempotent).
    /// No-op when the user has not granted location permission; callers
    /// don't have to check first. Caller MUST declare the user-visible
    /// session reason for compliance with the App Store background-location
    /// guideline.
    func startBackgroundLocation(reason: ActivationReason) {
        guard canUseLocationServices else {
            debugLog("[BgLocation] skip — no location authorization (status=\(authorizationStatus.rawValue))")
            return
        }
        guard !isRunning else {
            // Already running for some other reason; record the most recent one.
            activeReason = reason
            return
        }
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        isRunning = true
        activeReason = reason
        lastError = nil
        debugLog("[BgLocation] started (reason=\(reason.description), auth=\(authorizationStatus.rawValue))")
    }

    // There is deliberately no no-argument overload, not even a deprecated
    // one. It would default to `.workoutRecording`, so any future call site
    // that forgot the reason would silently claim to be a GPS workout and
    // re-open the exact 2.5.4 hole the `ActivationReason` enum exists to keep
    // shut — from an indoor or overnight path, the two closed
    // cases. A deprecation warning is not a gate when
    // the project builds with warnings-as-errors only for NEW warnings; a
    // missing overload is.

    /// Stop the keep-alive. Idempotent — safe to call when not running.
    func stopBackgroundLocation() {
        guard isRunning else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isRunning = false
        let reason = activeReason
        activeReason = nil
        debugLog("[BgLocation] stopped (was=\(reason?.description ?? "?"))")
    }

    /// Does NOT prompt; call sites should only invoke after the user has
    /// gone through the app's consent flow elsewhere. Kept for the old
    /// stub's API compatibility.
    func requestAuthorization() {}
}

// MARK: - CLLocationManagerDelegate

extension BackgroundLocationManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            // If the user revokes mid-workout, we can't keep pretending to
            // be running — surface the state so the coordinator can flip
            // to audio-only keep-alive.
            if self.isRunning, !self.canUseLocationServices {
                self.stopBackgroundLocation()
            }
        }
        // Apple's recommended pattern: re-check `locationServicesEnabled`
        // when the auth callback fires (toggles in iOS Settings, restoring
        // a backup, etc. all flow through this callback). Dispatch off
        // the main thread per the deprecation warning.
        refreshLocationServicesEnabled()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations _: [CLLocation]) {
        // Deliberately empty — and 2.5.4-safe: this manager only ever runs
        // during an outdoor `sport.usesGPS` workout (see the class doc), where
        // the sibling `WorkoutLocationManager` is the one recording the GPS
        // track the user sees. We don't double-consume samples here; the
        // callback merely existing is what keeps iOS scheduling background CPU
        // so the recording survives an audio/BT interruption.
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let description = error.localizedDescription
        Task { @MainActor in
            self.lastError = description
            debugLog("[BgLocation] error: \(description)", level: .warning)
        }
    }
}
