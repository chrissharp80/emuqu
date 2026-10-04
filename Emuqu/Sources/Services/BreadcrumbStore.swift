import CoreLocation
import Foundation

// MARK: - Model
//
// Get Me Back mode. The user engages this at the trailhead
// (or anywhere they want a "drop a pin and lead me back" anchor); the
// app then drops a fix every ~30 s OR ~25 m of movement. The full trail
// is persisted to disk on every fix so a crash, low battery shutoff, or
// a kill-then-relaunch days later doesn't lose where they came from.
//
// **Design intent.** This is offline-first by design. Nothing in the
// model or the store talks to the network. Reverse-geocoding the origin
// to a human-readable address is a *bonus* layer on top, not a
// dependency. If the user is in the woods with no signal, the
// breadcrumb data is enough to lead them back via the compass arrow in
// `GetMeBackView` — the AI commentary layer is purely optional.
//
// **Liability note.** Marketing this as a safety feature creates
// reliance, which is why the model carries `accuracyMeters` per fix and
// the UI is honest about when accuracy is poor (see `GetMeBackView`).
// Users should never see false confidence projected from a fuzzy fix.

/// One captured GPS fix in a `BreadcrumbTrail`.
struct BreadcrumbFix: Codable, Equatable, Sendable {
    /// Wall-clock time the fix was captured.
    let timestamp: Date
    /// Latitude in degrees, WGS84.
    let latitude: Double
    /// Longitude in degrees, WGS84.
    let longitude: Double
    /// Horizontal accuracy from CLLocation, in meters. Higher numbers
    /// mean less certain. Surfaced in the UI so we never project false
    /// confidence in the arrow direction.
    let horizontalAccuracyMeters: Double
    /// Altitude in meters above sea level, when the fix had one.
    let altitudeMeters: Double?
    /// True-north course in degrees at the moment of the fix, when
    /// moving. nil when stationary.
    let courseDegrees: Double?
    /// Speed in m/s at the moment of the fix.
    let speedMS: Double?

    /// Convenience initializer from a `CLLocation`.
    init(from loc: CLLocation) {
        timestamp = loc.timestamp
        latitude = loc.coordinate.latitude
        longitude = loc.coordinate.longitude
        horizontalAccuracyMeters = loc.horizontalAccuracy
        altitudeMeters = loc.verticalAccuracy >= 0 ? loc.altitude : nil
        courseDegrees = loc.course >= 0 ? loc.course : nil
        speedMS = loc.speed >= 0 ? loc.speed : nil
    }

    /// 2D coordinate convenience for distance / bearing math.
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// CLLocation reconstruction for distance math against another fix.
    var asCLLocation: CLLocation {
        CLLocation(
            coordinate: coordinate,
            altitude: altitudeMeters ?? 0,
            horizontalAccuracy: horizontalAccuracyMeters,
            verticalAccuracy: altitudeMeters == nil ? -1 : 5,
            course: courseDegrees ?? -1,
            speed: speedMS ?? -1,
            timestamp: timestamp
        )
    }
}

/// One Get-Me-Back trail. Contains the start time, the origin fix
/// (the "lead me back HERE" anchor), and the full ordered list of
/// subsequent fixes captured as the user moves away.
struct BreadcrumbTrail: Codable, Equatable, Sendable {
    /// When the user engaged the mode. Distinct from the first fix's
    /// timestamp — there can be 5–60 s of GPS warm-up before the first
    /// fix lands.
    let startedAt: Date
    /// Origin fix — the place we'll lead the user back to. Set when the
    /// first fix arrives after engagement. nil until then.
    var origin: BreadcrumbFix?
    /// Every fix captured since engagement, in chronological order.
    /// Origin is also the first element; we keep it duplicated on
    /// `origin` for cheap access without an array bounds check.
    var fixes: [BreadcrumbFix]
    /// Optional user label ("Cedar Falls hike", "Section A
    /// trailhead"). Helps the AI give a friendlier confirmation: "I'll
    /// lead you back to Cedar Falls trailhead."
    var label: String?
    /// Resolved street + locality of the origin, from
    /// `RoadGeocodingService` when connectivity allows. Cached so we
    /// don't re-geocode the same point. Optional — never blocking.
    var resolvedOriginLabel: String?

    /// Total straight-line distance from the most recent fix to the
    /// origin. Returns nil if either piece is missing.
    func crowFlyDistanceFromTipToOriginMeters() -> Double? {
        guard let origin, let last = fixes.last else { return nil }
        return last.asCLLocation.distance(from: origin.asCLLocation)
    }

    /// Distance accumulated walking the trail end-to-end (tip → origin
    /// reversed). Useful for "you walked 4.2 km out — same to come back
    /// if you retrace."
    func walkedTrailLengthMeters() -> Double {
        guard fixes.count >= 2 else { return 0 }
        var total: Double = 0
        for i in 1 ..< fixes.count {
            total += fixes[i].asCLLocation.distance(from: fixes[i - 1].asCLLocation)
        }
        return total
    }
}

// MARK: - Persistence
//
// Pattern mirrors `ConversationStore` — App Group container for
// availability across extensions, atomic write to dodge half-written
// files on crash, file-protection level set so the file is readable as
// long as the device has been unlocked once since boot (matches the
// "I want it to keep recording while my phone is in my pocket and
// locked" use case).
//
// Multi-trail history. There is:
//   - One **active** trail at `Breadcrumbs/active.json` (engaged via
//     Get Me Back mode). Written on every fix so a crash doesn't lose
//     it.
//   - A list of **archived** trails at `Breadcrumbs/archive.json`.
//     The "Clear" button on `GetMeBackView` archives the active trail
//     instead of deleting it (the user can browse / route back to
//     prior origins via the AI). The sleep-session prompt offers
//     true delete via `clear()`.
//   - Auto-imported **workout** trails are appended to the archive
//     when a workout finishes (see `WorkoutRecorder.finalizeSession`),
//     labeled "from <sport> on <date>" so the user can say "lead me
//     back to where I parked for yesterday's run" without having to
//     have engaged Get Me Back beforehand.

final class BreadcrumbStore: @unchecked Sendable {
    static let shared = BreadcrumbStore()

    private let activeURL: URL
    private let archiveURL: URL
    private let queue = DispatchQueue(
        label: "com.chrissharp.flowrecovery.breadcrumbstore",
        qos: .utility
    )
    /// Cap on archived trails kept on disk. Older ones are evicted on
    /// `archive(...)` calls. Tens of trails fit easily in ~5 MB; the
    /// cap prevents an indefinite-use device from accumulating
    /// hundreds of stale "Saturday hike" trails forever.
    static let archiveRetentionLimit = 50

    private init() {
        let fm = FileManager.default
        let baseURL = Self.storageDirectory(fm)
        _ = attempt("BreadcrumbStore.create") { try fm.createDirectory(at: baseURL, withIntermediateDirectories: true) }
        activeURL = baseURL.appendingPathComponent("active.json")
        archiveURL = baseURL.appendingPathComponent("archive.json")
        Self.migrateLegacyTrailIfNeeded(in: baseURL, to: activeURL)
    }

    /// App group if available (shared with the app's extensions; deleted with
    /// the app like the rest of its data), else Documents, else the temporary
    /// directory.
    private static func storageDirectory(_ fm: FileManager) -> URL {
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier) {
            return group.appendingPathComponent("Breadcrumbs", isDirectory: true)
        }
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            return docs.appendingPathComponent("Breadcrumbs", isDirectory: true)
        }
        return fm.temporaryDirectory.appendingPathComponent("Breadcrumbs", isDirectory: true)
    }

    /// One-shot migration from the v1 single-file layout
    /// (`trail.json`). If the legacy file is present and `active.json` isn't,
    /// move it. Guarantees existing users don't lose their engaged trail when
    /// this build lands.
    private static func migrateLegacyTrailIfNeeded(in baseURL: URL, to activeURL: URL) {
        let fm = FileManager.default
        let legacyURL = baseURL.appendingPathComponent("trail.json")
        if fm.fileExists(atPath: legacyURL.path), !fm.fileExists(atPath: activeURL.path) {
            _ = attempt("BreadcrumbStore.move") { try fm.moveItem(at: legacyURL, to: activeURL) }
        }
    }

    /// Test seam — single-file mode for tests written against v1.
    /// Tests can pass a custom URL; we use it for both active+archive
    /// (the archive then accumulates next to it).
    init(fileURL: URL) {
        self.activeURL = fileURL
        self.archiveURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("archive.json")
        let parent = fileURL.deletingLastPathComponent()
        _ = attempt("BreadcrumbStore.create") { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
    }

    // MARK: Active trail

    /// Read the active (in-progress) trail off disk. Returns nil when
    /// no Get-Me-Back session is currently engaged.
    func load() -> BreadcrumbTrail? {
        queue.sync {
            guard let data = try? Data(contentsOf: activeURL) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(BreadcrumbTrail.self, from: data)
        }
    }

    /// Atomic write of the active trail. Called on every fix because
    /// we promised the user the trail survives a crash mid-hike.
    /// File-protection level set to
    /// `.completeUntilFirstUserAuthentication` so the recorder can
    /// keep writing while the phone is locked and in the pocket.
    func save(_ trail: BreadcrumbTrail) {
        queue.async { [activeURL] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys] // stable diffs for tests
            guard let data = attempt("breadcrumbs.active.encode", { try encoder.encode(trail) }) else { return }
            Self.ensureParentDirectory(of: activeURL)
            attempt("breadcrumbs.active.write") {
                try data.write(
                    to: activeURL,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
            }
        }
    }

    /// "Clear" semantics from the GetMeBackView toolbar — moves the
    /// active trail into the archive (instead of throwing it away).
    /// User can still route back to its origin via the AI later.
    func archiveActive() {
        guard let active = load() else { return }
        archive(active)
        clear()
    }

    /// Permanent delete of the active trail. Used by the sleep-prompt
    /// "Discard" path where the user explicitly chooses to drop the
    /// data, not just file it away.
    func clear() {
        queue.async { [activeURL] in
            _ = attempt("BreadcrumbStore.remove") { try FileManager.default.removeItem(at: activeURL) }
        }
    }

    /// Cheap "is there an active trail" check without deserialising the
    /// whole thing. Used by the dashboard entry point to know whether
    /// to show "Engage Get Me Back" or "Trail active — open."
    func hasActiveTrail() -> Bool {
        queue.sync {
            FileManager.default.fileExists(atPath: activeURL.path)
        }
    }

    // MARK: Archive (history of completed trails)

    /// All archived trails, newest first. Cheap read — the file is
    /// JSON of at most a few hundred KB even with the retention cap.
    func loadArchive() -> [BreadcrumbTrail] {
        queue.sync {
            guard let data = try? Data(contentsOf: archiveURL) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                return try decoder.decode([BreadcrumbTrail].self, from: data)
            } catch {
                // Missing file is normal; an unreadable one is data loss the
                // user cannot see, so say so.
                debugLog("[BreadcrumbStore] archive decode failed, reporting no trails: \(error)", level: .error)
                return []
            }
        }
    }

    /// Existing trails, or nil when the file is present but unreadable.
    ///
    /// If the caller used `(try? decode) ?? []`, the consequence
    /// would not be a failed read: the empty array falls through to the
    /// insert-and-write below, so ONE unreadable byte silently replaces the
    /// user's entire trail archive with a single trail. `SavedRouteStore`
    /// already refuses to write over a file it could not parse; nil here makes
    /// the caller do the same, leaving the corrupt file intact for recovery.
    ///
    /// The same holds for a file that is present and cannot be read at all —
    /// before the first unlock, or an I/O error: it is not an empty archive.
    private static func decodeArchive(at url: URL, using decoder: JSONDecoder) -> [BreadcrumbTrail]? {
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path) ? nil : []
        }
        do {
            return try decoder.decode([BreadcrumbTrail].self, from: data)
        } catch {
            debugLog("[BreadcrumbStore] archive present but failed to decode — refusing to overwrite it: \(error)", level: .error)
            return nil
        }
    }

    func archive(_ trail: BreadcrumbTrail) {
        queue.async { [archiveURL] in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let existingOrNil = Self.decodeArchive(at: archiveURL, using: decoder) else { return }
            var existing = existingOrNil
            // Newest-first ordering so callers don't have to re-sort.
            existing.insert(trail, at: 0)
            if existing.count > Self.archiveRetentionLimit {
                existing = Array(existing.prefix(Self.archiveRetentionLimit))
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            guard let data = attempt("breadcrumbs.archive.encode", { try encoder.encode(existing) }) else { return }
            let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            Self.ensureParentDirectory(of: archiveURL)
            attempt("breadcrumbs.archive.write") { try data.write(to: archiveURL, options: options) }
        }
    }

    /// Delete All My Data sweeps the `Breadcrumbs` directory away while the
    /// app keeps running; without recreating it, every write after the purge
    /// failed until the next launch and an engaged trail was not crash-safe.
    private static func ensureParentDirectory(of url: URL) {
        let parent = url.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: parent.path) else { return }
        _ = attempt("BreadcrumbStore.create") { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
    }

    /// Erase the entire archive. Surfaced via Settings → Privacy
    /// (caller responsibility) — never auto-fires. Honours the user's
    /// "delete my history" intent. Does not touch the active trail.
    func eraseArchive() {
        queue.async { [archiveURL] in
            _ = attempt("BreadcrumbStore.remove") { try FileManager.default.removeItem(at: archiveURL) }
        }
    }
}
