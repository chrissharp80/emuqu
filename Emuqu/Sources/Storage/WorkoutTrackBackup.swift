import CoreLocation
import Foundation

/// Append-only persistence of a workout's GPS fixes, per-tick `WorkoutSample`
/// rows, and barometric-altitude samples. Writes incrementally during the
/// recording so a crash mid-workout doesn't lose the minutes of motion
/// already captured.
///
/// Companion to `RawRRBackup`: that one keeps the heart-rate stream;
/// this one keeps everything else `WorkoutAnalyzer.analyze` needs to
/// reconstitute a workout (track for distance + polyline + splits,
/// samples for charts, barometer for elevation).
///
/// File layout (per session, in the App Group's `WorkoutBackup/`
/// directory):
///   • `<uuid>_workout_header.json` — sport + start date, written once.
///   • `<uuid>_workout_track.jsonl` — one `PersistedFix` per line.
///   • `<uuid>_workout_samples.jsonl` — one `WorkoutSample` per line.
///   • `<uuid>_workout_baro.jsonl` — one `PersistedBaro` per line.
///
/// Discovery scans the directory for `*_workout_header.json` files —
/// no separate index file. Crash-safe: each stream is independent
/// append-only, a torn write only loses the trailing line.
final class WorkoutTrackBackup: @unchecked Sendable {
    // `@unchecked Sendable`: mutable in-memory cursors are protected by
    // `lock`; all on-disk writes go through a single-threaded code path.
    // Same justification as `RawRRBackup`. Lets us call from a background
    // detached task off the main-actor recorder tick.

    static let shared = WorkoutTrackBackup()

    // MARK: - Public types

    /// Compact, Codable, `Sendable` form of a `CLLocation`. Only the
    /// fields `WorkoutAnalyzer` actually consumes survive the round-trip.
    /// Speed and course are kept so auto-pause / GPS-derived pace can
    /// be re-derived during recovery. The Sendable conformance lets the
    /// caller hand a `[PersistedFix]` to a detached background task —
    /// `CLLocation` itself is non-Sendable in Swift 6.
    struct PersistedFix: Codable, Sendable {
        let timestamp: Date
        let latitude: Double
        let longitude: Double
        let altitude: Double
        let horizontalAccuracy: Double
        let verticalAccuracy: Double
        let speed: Double
        let course: Double

        init(_ loc: CLLocation) {
            timestamp = loc.timestamp
            latitude = loc.coordinate.latitude
            longitude = loc.coordinate.longitude
            altitude = loc.altitude
            horizontalAccuracy = loc.horizontalAccuracy
            verticalAccuracy = loc.verticalAccuracy
            speed = loc.speed
            course = loc.course
        }

        var asCLLocation: CLLocation {
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                altitude: altitude,
                horizontalAccuracy: horizontalAccuracy,
                verticalAccuracy: verticalAccuracy,
                course: course,
                speed: speed,
                timestamp: timestamp
            )
        }
    }

    struct PersistedBaro: Codable, Sendable {
        let timestamp: Date
        let altitudeMeters: Double
    }

    /// Header written once per session. Contains the bits not derivable
    /// from the JSONL streams.
    struct Header: Codable {
        let sessionId: UUID
        let sport: Sport
        let startDate: Date
        let createdAt: Date
    }

    /// Hydrated payload returned to a recovery caller. Track is
    /// rehydrated to `CLLocation` so consumers (`WorkoutAnalyzer`,
    /// `RouteLibrary`) get the same type they'd see live; the rest
    /// stays in its persisted form.
    struct Recovered {
        let header: Header
        let track: [CLLocation]
        let samples: [WorkoutSample]
        let barometricSamples: [PersistedBaro]
    }

    // MARK: - Internal state

    private let directory: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()

    /// Serializes an entire incremental append, and reads against it.
    ///
    /// One lock for the whole append: taking and releasing `lock` several
    /// times across `appendIncremental`, with file I/O in between each pair,
    /// leaves the read-modify-write non-atomic. `WorkoutRecorder+Ticker` drives it
    /// from `Task.detached` on every 1 Hz tick, and detached tasks are
    /// unordered relative to each other, so two overlapping calls interleave.
    ///
    /// `retrieve` took no lock at all, so a recovery read concurrent with an
    /// append could observe a half-written JSONL line — which is exactly the
    /// moment this file exists to be readable.
    ///
    /// Both now run on this queue, which makes append atomic against append
    /// AND against read. Same shape as `RawRRBackup.appendQueue`.
    private let appendQueue = DispatchQueue(label: "com.emuqu.workouttrackbackup.append", qos: .utility)
    /// Running cursors: number of items already flushed for each stream
    /// of each session. Avoids re-encoding everything on each tick.
    private var trackCursor: [UUID: Int] = [:]
    private var sampleCursor: [UUID: Int] = [:]
    private var baroCursor: [UUID: Int] = [:]
    /// Set of sessions whose header has been written this app launch.
    /// Header is written exactly once per session — additional calls are
    /// a fast set-membership check, no disk I/O.
    private var headerWritten: Set<UUID> = []

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Initialization

    init() {
        let containerURL = AppConfig.sharedContainerURL()
        directory = containerURL.appendingPathComponent("WorkoutBackup", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
                )
            } catch {
                debugLog("[WorkoutTrackBackup] Failed to create directory: \(error)")
            }
        }
    }

    // MARK: - File paths

    private func headerURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString)_workout_header.json")
    }

    private func trackURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString)_workout_track.jsonl")
    }

    private func samplesURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString)_workout_samples.jsonl")
    }

    private func baroURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString)_workout_baro.jsonl")
    }

    // MARK: - Append API
    //
    // Each call passes the FULL stream so far. The backup tracks how many
    // items it has already written and appends only the new tail. This
    // matches `RawRRBackup.incrementalBackup`'s semantics exactly so the
    // caller doesn't have to maintain a parallel cursor.

    /// Persist any new track/sample/baro records since the last call.
    /// Safe to call from any thread — internally synchronizes via `lock`.
    /// All inputs are value types of `Sendable` kinds so this is safe to
    /// invoke from a `Task.detached` off the main-actor recorder tick.
    /// - Returns: `true` if any bytes were written, `false` if everything
    ///   was already persisted (used by the caller to skip downstream
    ///   work).
    @discardableResult
    func appendIncremental(
        sessionId: UUID,
        sport: Sport,
        startDate: Date,
        track: [PersistedFix],
        samples: [WorkoutSample],
        barometricSamples: [PersistedBaro]
    ) -> Bool {
        appendQueue.sync {
            appendIncrementalSerialized(
                sessionId: sessionId, sport: sport, startDate: startDate,
                track: track, samples: samples, barometricSamples: barometricSamples
            )
        }
    }

    /// Body of `appendIncremental`, always run on `appendQueue`.
    private func appendIncrementalSerialized(
        sessionId: UUID,
        sport: Sport,
        startDate: Date,
        track: [PersistedFix],
        samples: [WorkoutSample],
        barometricSamples: [PersistedBaro]
    ) -> Bool {
        lock.lock()
        let needHeader = !headerWritten.contains(sessionId)
        let trackOffset = trackCursor[sessionId] ?? 0
        let sampleOffset = sampleCursor[sessionId] ?? 0
        let baroOffset = baroCursor[sessionId] ?? 0
        lock.unlock()
        var wroteAnything = needHeader && writeHeader(sessionId: sessionId, sport: sport, startDate: startDate)
        // Each append runs unconditionally — `||` is left-biased, so putting
        // the call first keeps every stream from being short-circuited away.
        wroteAnything = appendStream(track, from: trackOffset, url: trackURL(sessionId), sessionId: sessionId, streamName: "track", cursor: \.trackCursor) || wroteAnything
        wroteAnything = appendStream(samples, from: sampleOffset, url: samplesURL(sessionId), sessionId: sessionId, streamName: "samples", cursor: \.sampleCursor) || wroteAnything
        wroteAnything = appendStream(barometricSamples, from: baroOffset, url: baroURL(sessionId), sessionId: sessionId, streamName: "baro", cursor: \.baroCursor) || wroteAnything
        return wroteAnything
    }

    /// Record how far into a stream we have persisted. Held under `lock`
    /// because the cursors are read from other queues.
    private func advanceCursor(
        _ cursor: ReferenceWritableKeyPath<WorkoutTrackBackup, [UUID: Int]>, sessionId: UUID, to count: Int
    ) {
        lock.lock()
        self[keyPath: cursor][sessionId] = count
        lock.unlock()
    }

    /// Everything past `offset`, appended as JSONL, advancing `cursor` on
    /// success. False when there is nothing new or the write failed — in
    /// either case the cursor stays put so the next tick retries.
    private func appendStream(
        _ items: [some Encodable],
        from offset: Int,
        url: URL,
        sessionId: UUID,
        streamName: String,
        cursor: ReferenceWritableKeyPath<WorkoutTrackBackup, [UUID: Int]>
    ) -> Bool {
        guard items.count > offset else { return false }
        guard appendJSONL(
            url: url, items: Array(items[offset...]), sessionId: sessionId, streamName: streamName
        ) else { return false }
        advanceCursor(cursor, sessionId: sessionId, to: items.count)
        return true
    }

    /// Protect at rest + allow writes while the device is locked mid-workout
    /// (screen off). Matches RawRRBackup; a bare write defaults to
    /// `.complete` and FAILS when locked.
    private func writeHeader(sessionId: UUID, sport: Sport, startDate: Date) -> Bool {
        do {
            let header = Header(
                sessionId: sessionId,
                sport: sport,
                startDate: startDate,
                createdAt: Date()
            )
            try encoder.encode(header).write(
                to: headerURL(sessionId),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            lock.lock()
            headerWritten.insert(sessionId)
            lock.unlock()
            return true
        } catch {
            debugLog("[WorkoutTrackBackup] Header write failed for \(sessionId.uuidString.prefix(8)): \(error)")
            return false
        }
    }

    /// Append one slice of JSON-encoded items as line-delimited JSON.
    /// Centralised so all three streams use the same FileHandle pattern,
    /// the same fall-back-on-corruption logic, and the same logging.
    private func appendJSONL(
        url: URL,
        items: [some Encodable],
        sessionId: UUID,
        streamName: String
    ) -> Bool {
        guard !items.isEmpty else { return false }
        let blob = encodeLines(items, sessionId: sessionId, streamName: streamName)
        guard !blob.isEmpty else { return false }
        guard fileManager.fileExists(atPath: url.path) else {
            return write(blob, to: url, sessionId: sessionId, streamName: streamName, label: "initial write")
        }
        if appendToExisting(blob, at: url) { return true }
        preserveCorruptedFile(at: url)
        return write(blob, to: url, sessionId: sessionId, streamName: streamName, label: "fresh-write fallback")
    }

    /// False when the FileHandle couldn't be opened (rare — usually a
    /// permissions or quota issue), which routes the caller to the
    /// preserve-and-rewrite fallback.
    private func appendToExisting(_ blob: Data, at url: URL) -> Bool {
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        handle.write(blob)
        return true
    }

    /// Keep whatever was already on disk under a `.corrupted` name rather than
    /// overwriting it, so a partially-recoverable stream isn't lost.
    private func preserveCorruptedFile(at url: URL) {
        let preserved = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".corrupted_\(Int(Date().timeIntervalSince1970))")
        _ = attempt("WorkoutTrackBackup.move") { try fileManager.moveItem(at: url, to: preserved) }
    }

    /// Encode each item on its own line. An item that fails to encode is
    /// logged and skipped rather than losing the whole slice.
    private func encodeLines(_ items: [some Encodable], sessionId: UUID, streamName: String) -> Data {
        var blob = Data()
        for item in items {
            do {
                blob.append(try encoder.encode(item))
                blob.append(0x0A) // newline
            } catch {
                debugLog("[WorkoutTrackBackup] \(streamName) encode failed for \(sessionId.uuidString.prefix(8)): \(error)")
            }
        }
        return blob
    }

    private func write(
        _ blob: Data, to url: URL, sessionId: UUID, streamName: String, label: String
    ) -> Bool {
        do {
            try blob.write(to: url, options: [.completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            debugLog("[WorkoutTrackBackup] \(streamName) \(label) failed for \(sessionId.uuidString.prefix(8)): \(error)")
            return false
        }
    }

    // MARK: - Discovery + retrieval

    /// All sessions with a header on disk. Used at app launch to find
    /// crash-orphaned workouts.
    func allSessionIds() -> [UUID] {
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.compactMap { url -> UUID? in
            let name = url.lastPathComponent
            guard name.hasSuffix("_workout_header.json") else { return nil }
            let prefix = String(name.dropLast("_workout_header.json".count))
            return UUID(uuidString: prefix)
        }
    }

    /// Read the persisted streams for a session. Missing streams come
    /// back empty rather than throwing — recovery should still attempt
    /// with whatever's available (e.g. indoor sessions have no track,
    /// pre-iPhone-6 devices have no baro).
    func retrieve(_ sessionId: UUID) -> Recovered? {
        // On `appendQueue` so a recovery read can never observe a
        // half-written JSONL line mid-append.
        appendQueue.sync { retrieveSerialized(sessionId) }
    }

    private func retrieveSerialized(_ sessionId: UUID) -> Recovered? {
        let headerPath = headerURL(sessionId)
        guard fileManager.fileExists(atPath: headerPath.path),
              let headerData = try? Data(contentsOf: headerPath),
              let header = try? decoder.decode(Header.self, from: headerData) else {
            return nil
        }

        let track = decodeJSONL(url: trackURL(sessionId), as: PersistedFix.self).map(\.asCLLocation)
        let samples = decodeJSONL(url: samplesURL(sessionId), as: WorkoutSample.self)
        let baro = decodeJSONL(url: baroURL(sessionId), as: PersistedBaro.self)

        return Recovered(
            header: header,
            track: track,
            samples: samples,
            barometricSamples: baro
        )
    }

    private func decodeJSONL<T: Decodable>(url: URL, as: T.Type) -> [T] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [T] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8) else { continue }
            if let item = try? decoder.decode(T.self, from: data) {
                out.append(item)
            }
            // Silently skip torn lines — better to recover what we can
            // than refuse the whole stream because of one truncated row.
        }
        return out
    }

    // MARK: - Cleanup

    /// Remove all four files for a session. Called once the recorder has
    /// successfully archived the finalized session — the backup has done
    /// its job and the archive is the source of truth.
    func discard(_ sessionId: UUID) {
        for url in [headerURL(sessionId), trackURL(sessionId), samplesURL(sessionId), baroURL(sessionId)] {
            _ = attempt("WorkoutTrackBackup.remove") { try fileManager.removeItem(at: url) }
        }
        lock.lock()
        trackCursor.removeValue(forKey: sessionId)
        sampleCursor.removeValue(forKey: sessionId)
        baroCursor.removeValue(forKey: sessionId)
        headerWritten.remove(sessionId)
        lock.unlock()
    }

    /// Erase EVERY workout backup (all sessions, all four file kinds) and reset
    /// the in-memory cursors. Used by "Delete All My Data" — these files hold
    /// raw GPS tracks (precise location), so right-to-erasure requires them to
    /// go regardless of age, unlike the age-based `purgeOldBackups`.
    func purgeAll() {
        for id in allSessionIds() {
            discard(id)
        }
    }

    /// Drop on-disk backups that haven't been touched in `keepDays`.
    /// Invoked at app launch alongside `RawRRBackup.purgeOldBackups`.
    func purgeOldBackups(keepDays: Int = 30) {
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86_400)
        for id in allSessionIds() {
            let header = headerURL(id)
            guard let attrs = try? fileManager.attributesOfItem(atPath: header.path),
                  let modified = attrs[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            discard(id)
        }
    }
}
