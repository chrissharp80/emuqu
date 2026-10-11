// `@preconcurrency`: CLLocationManager and CLHeading predate Sendable.
@preconcurrency import CoreLocation
import Foundation

/// On-demand "where am I right now?" one-shot fix.
///
/// **Why this exists:** the app's `RoadGeocodingService` is fed location
/// updates by `WorkoutLocationManager`, which only runs while a workout is
/// recording, and `AmbientLocationService` only caches fixes in the
/// foreground. When neither has a fresh fix, the AI's routing tools and the
/// launch road-context prewarm need a first usable live fix, which this
/// provides; callers geocode it through `RoadGeocodingService` themselves.
///
/// **Permission posture.** Uses whatever authorization the user already
/// granted (When-In-Use suffices). When the user has never been asked, it
/// shows the system prompt and waits up to 10 s for an answer; a denial
/// returns `.permissionDenied` so the AI can point the user at Settings.
@MainActor
enum LocationFinder {
    // MARK: - Detached one-shot path
    //
    // The fix itself is taken off the main actor:
    // `CLLocationUpdate.liveUpdates()` (iOS 17+) is an async sequence that
    // needs no runloop on the caller. The authorization probe and prompt are
    // NOT main-actor free: `CLLocationManager` must be created on the main
    // thread, so they hop to the main actor (`locationAuthorizationStatus()`,
    // `requestAuthorizationOnMainActor()`). That is safe for today's callers,
    // which all `await` from a task, and would deadlock a caller that blocked
    // the main thread on a semaphore waiting for this.

    /// A raw one-shot `CLLocation`, for callers that feed it into their own
    /// geocoding (the launch prewarm of `RoadGeocodingService`, the
    /// assistant's cold routing fix).
    nonisolated static func detachedFirstUsableLocation(timeoutSec: TimeInterval = 30) async throws -> CLLocation {
        try await ensureAuthorization()
        return try await firstUsableLocation(timeoutSec: timeoutSec)
    }

    nonisolated private static func ensureAuthorization() async throws {
        switch await locationAuthorizationStatus() {
        case .authorizedWhenInUse, .authorizedAlways:
            break
        case .denied, .restricted:
            throw LookupError.permissionDenied
        case .notDetermined:
            try await promptForAuthorization()
        @unknown default:
            throw LookupError.permissionDenied
        }
        guard CLLocationManager.locationServicesEnabled() else {
            throw LookupError.locationServicesDisabled
        }
    }

    /// Trigger the iOS prompt. The user sees the dialog; we wait up to 10 s
    /// for a response. Allow → proceed. Don't Allow or dismiss →
    /// permissionDenied.
    nonisolated private static func promptForAuthorization() async throws {
        await requestAuthorizationOnMainActor()
        for _ in 0 ..< 40 { // 40 × 250ms = 10s
            await sleepQuietly(250_000_000, context: "promptForAuthorization")
            let status = await locationAuthorizationStatus()
            if status == .authorizedWhenInUse || status == .authorizedAlways { return }
            if status == .denied || status == .restricted {
                throw LookupError.permissionDenied
            }
        }
        throw LookupError.permissionDenied
    }

    /// The manager that asked for permission. Kept for the life of the
    /// process: releasing the manager that raised the system prompt dismisses
    /// the prompt. Also the one the status is read from.
    private static var authorizationManager: CLLocationManager?

    /// The retained manager, created on first use. Apple's docs:
    /// CLLocationManager init + requestWhenInUseAuthorization must happen on
    /// the main thread.
    private static func mainThreadManager() -> CLLocationManager {
        let manager = authorizationManager ?? CLLocationManager()
        authorizationManager = manager
        return manager
    }

    private static func locationAuthorizationStatus() -> CLAuthorizationStatus {
        mainThreadManager().authorizationStatus
    }

    private static func requestAuthorizationOnMainActor() {
        mainThreadManager().requestWhenInUseAuthorization()
    }

    /// First-fix latency. The 30 s budget is long enough
    /// that a "took 18 s" cold-start can hide behind "didn't time out, must be
    /// fine." Time-stamping the entry + return makes the actual
    /// fix-acquisition cost visible.
    nonisolated private static func firstUsableLocation(timeoutSec: TimeInterval) async throws -> CLLocation {
        let fixStartedAt = Date()
        let result: CLLocation
        do {
            result = try await raceFirstFix(timeoutSec: timeoutSec)
        } catch {
            debugLog("[GeocodingLatency] firstUsableLocation FAILED in \(String(format: "%.3f", Date().timeIntervalSince(fixStartedAt)))s: \(error)", level: .warning)
            throw error
        }
        debugLog("[GeocodingLatency] firstUsableLocation in \(String(format: "%.3f", Date().timeIntervalSince(fixStartedAt)))s — accuracy=\(String(format: "%.1f", result.horizontalAccuracy))m", level: .info)
        return result
    }

    /// The live-updates stream against a timeout sleeper; first child to
    /// finish wins and the rest are cancelled.
    ///
    /// The richer `authorizationDenied` / `locationUnavailable` diagnostic
    /// flags are iOS 18+. We rely on the pre-flight authorization probe to
    /// catch denial up front; if the user revokes permission mid-stream the
    /// underlying API will either error or stop yielding, hitting our
    /// timeout — adequate without a hot-loop `#available` guard.
    nonisolated private static func raceFirstFix(timeoutSec: TimeInterval) async throws -> CLLocation {
        try await withThrowingTaskGroup(of: CLLocation.self) { group in
            group.addTask { try await firstUsableLiveFix() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
                throw LookupError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw LookupError.noFix
            }
            return first
        }
    }

    /// Accuracy (m) above which a live update is too coarse to call a fix:
    /// a cell-tower estimate, not a position on a street.
    nonisolated static let maxUsableAccuracyMeters: CLLocationAccuracy = 200
    /// Age (s) above which a live update is a cached fix, not where the user
    /// is now.
    nonisolated static let maxUsableAgeSeconds: TimeInterval = 60

    /// The first live update with a valid accuracy no coarser than
    /// `maxUsableAccuracyMeters` that is no older than `maxUsableAgeSeconds`.
    /// A negative accuracy means CoreLocation has no real fix yet.
    nonisolated private static func firstUsableLiveFix() async throws -> CLLocation {
        for try await update in CLLocationUpdate.liveUpdates() {
            try Task.checkCancellation()
            guard let loc = update.location, isUsable(loc) else { continue }
            return loc
        }
        throw LookupError.noFix
    }

    nonisolated private static func isUsable(_ loc: CLLocation) -> Bool {
        loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy <= maxUsableAccuracyMeters
            && -loc.timestamp.timeIntervalSinceNow <= maxUsableAgeSeconds
    }

    enum LookupError: Error, Sendable {
        case permissionDenied
        case locationServicesDisabled
        case timeout
        case noFix
    }
}
