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
///   • `<uuid>_workout_hkhr.jsonl` — one sample `offsetSec` per line, for
///     each row whose heart rate is Apple Watch wrist HR from Apple Health.
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
        /// Offsets of the rows whose heart rate came from Apple Health.
        let healthKitHROffsets: [Int]
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
    private var healthKitHRCursor: [UUID: Int] = [:]
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

    private func healthKitHRURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString)_workout_hkhr.jsonl")
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
        healthKitHROffsets: [Int],
        barometricSamples: [PersistedBaro]
    ) -> Bool {
        appendQueue.sync {
            appendIncrementalSerialized(
                sessionId: sessionId, sport: sport, startDate: startDate,
                track: track, samples: samples, healthKitHROffsets: healthKitHROffsets,
                barometricSamples: barometricSamples
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
        healthKitHROffsets: [Int],
        barometricSamples: [PersistedBaro]
    ) -> Bool {
        lock.lock()
        let needHeader = !headerWritten.contains(sessionId)
        lock.unlock()
        let persisted = offsets(for: sessionId)
        var wroteAnything = needHeader && writeHeader(sessionId: sessionId, sport: sport, startDate: startDate)
        // Each append runs unconditionally — `||` is left-biased, so putting
        // the call first keeps every stream from being short-circuited away.
        wroteAnything = appendStream(track, from: persisted.track, url: trackURL(sessionId), sessionId: sessionId, streamName: "track", cursor: \.trackCursor) || wroteAnything
        wroteAnything = appendStream(samples, from: persisted.samples, url: samplesURL(sessionId), sessionId: sessionId, streamName: "samples", cursor: \.sampleCursor) || wroteAnything
        wroteAnything = appendStream(barometricSamples, from: persisted.baro, url: baroURL(sessionId), sessionId: sessionId, streamName: "baro", cursor: \.baroCursor) || wroteAnything
        wroteAnything = appendStream(healthKitHROffsets, from: persisted.healthKitHR, url: healthKitHRURL(sessionId), sessionId: sessionId, streamName: "hkhr", cursor: \.healthKitHRCursor) || wroteAnything
        return wroteAnything
    }

    /// Items already on disk per stream. The cursors live in memory, so after
    /// a relaunch they are empty; starting them at zero appended every stream
    /// again from the start, and the recovered track and samples held each
    /// row twice. A missing cursor is taken from the lines on disk.
    private func offsets(for sessionId: UUID) -> StreamOffsets<Int> {
        lock.lock()
        let cached = StreamOffsets<Int?>(
            track: trackCursor[sessionId], samples: sampleCursor[sessionId],
            baro: baroCursor[sessionId], healthKitHR: healthKitHRCursor[sessionId]
        )
        lock.unlock()
        return StreamOffsets(
            track: cached.track ?? persistedLineCount(trackURL(sessionId)),
            samples: cached.samples ?? persistedLineCount(samplesURL(sessionId)),
            baro: cached.baro ?? persistedLineCount(baroURL(sessionId)),
            healthKitHR: cached.healthKitHR ?? persistedLineCount(healthKitHRURL(sessionId))
        )
    }

    /// One count per stream of a session: the cached cursors (nil when not
    /// yet known this launch) or the items already on disk.
    private struct StreamOffsets<Count> {
        let track: Count
        let samples: Count
        let baro: Count
        let healthKitHR: Count
    }

    /// Rows in a stream's file and any set-aside copies of it.
    private func persistedLineCount(_ url: URL) -> Int {
        (setAsideFiles(for: url) + [url]).reduce(0) { total, file in
            guard fileManager.fileExists(atPath: file.path),
                  let data = attempt("WorkoutTrackBackup.countLines", { try Data(contentsOf: file) }) else { return total }
            return total + data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        }
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
        switch appendToExisting(blob, at: url) {
        case .appended:
            return true
        case .writeFailed:
            // Full disk or an I/O error. The cursor stays put and the next
            // tick retries; moving the file aside here would strand
            // everything already written.
            return false
        case .couldNotOpen:
            return rewriteUnopenable(url, adding: blob, sessionId: sessionId, streamName: streamName)
        }
    }

    /// The bytes may still read even though the handle would not open: rewrite
    /// them with the new slice rather than setting them aside. Only a file that
    /// won't read either is moved aside and started fresh.
    private func rewriteUnopenable(_ url: URL, adding blob: Data, sessionId: UUID, streamName: String) -> Bool {
        if let existing = attempt("WorkoutTrackBackup.readForRewrite", { try Data(contentsOf: url) }) {
            return write(existing + blob, to: url, sessionId: sessionId, streamName: streamName, label: "rewrite fallback")
        }
        preserveCorruptedFile(at: url)
        return write(blob, to: url, sessionId: sessionId, streamName: streamName, label: "fresh-write fallback")
    }

    private enum AppendOutcome {
        case appended
        /// Rare — usually a permissions or quota issue.
        case couldNotOpen
        case writeFailed
    }

    /// The throwing `FileHandle` calls: `seekToEndOfFile()` / `write(_:)`
    /// raise an Objective-C exception on a full disk, which Swift cannot
    /// catch, so a full disk mid-workout crashed the app.
    private func appendToExisting(_ blob: Data, at url: URL) -> AppendOutcome {
        guard let handle = try? FileHandle(forWritingTo: url) else { return .couldNotOpen }
        defer { _ = attempt("WorkoutTrackBackup.close") { try handle.close() } }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: blob)
            return .appended
        } catch {
            debugLog("[WorkoutTrackBackup] Append to \(url.lastPathComponent) failed: \(error)", level: .warning)
            return .writeFailed
        }
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

    /// Every session with any backup file on disk, header or not. Used by
    /// "Delete All My Data": a session whose header write failed still has
    /// its GPS streams.
    private func allSessionIdsOnDisk() -> Set<UUID> {
        let names = attempt("WorkoutTrackBackup.listAll") {
            try fileManager.contentsOfDirectory(atPath: directory.path)
        } ?? []
        return Set(names.compactMap { name in
            name.contains("_workout_") ? UUID(uuidString: String(name.prefix(36))) : nil
        })
    }

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
        let healthKitHROffsets = decodeJSONL(url: healthKitHRURL(sessionId), as: Int.self)

        return Recovered(
            header: header,
            track: track,
            samples: samples,
            healthKitHROffsets: healthKitHROffsets,
            barometricSamples: baro
        )
    }

    /// The live stream plus any `.corrupted_*` file an earlier append set
    /// aside, oldest first: those hold the rows from before that append.
    private func decodeJSONL<T: Decodable>(url: URL, as type: T.Type) -> [T] {
        let aside = setAsideFiles(for: url).sorted { $0.lastPathComponent < $1.lastPathComponent }
        return (aside + [url]).flatMap { decodeJSONLFile(url: $0, as: type) }
    }

    private func setAsideFiles(for url: URL) -> [URL] {
        let prefix = url.lastPathComponent + ".corrupted_"
        let names = attempt("WorkoutTrackBackup.listSiblings") {
            try fileManager.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        } ?? []
        return names.filter { $0.hasPrefix(prefix) }.map { url.deletingLastPathComponent().appendingPathComponent($0) }
    }

    private func decodeJSONLFile<T: Decodable>(url: URL, as: T.Type) -> [T] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
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

    /// Remove every file for a session. Called once the recorder has
    /// successfully archived the finalized session — the backup has done
    /// its job and the archive is the source of truth.
    func discard(_ sessionId: UUID) {
        let streams = [trackURL(sessionId), samplesURL(sessionId), baroURL(sessionId), healthKitHRURL(sessionId)]
        for url in [headerURL(sessionId)] + streams + streams.flatMap(setAsideFiles(for:)) {
            _ = attempt("WorkoutTrackBackup.remove") { try fileManager.removeItem(at: url) }
        }
        lock.lock()
        trackCursor.removeValue(forKey: sessionId)
        sampleCursor.removeValue(forKey: sessionId)
        baroCursor.removeValue(forKey: sessionId)
        healthKitHRCursor.removeValue(forKey: sessionId)
        headerWritten.remove(sessionId)
        lock.unlock()
    }

    /// Erase EVERY workout backup (all sessions, every file kind) and reset
    /// the in-memory cursors. Used by "Delete All My Data" — these files hold
    /// raw GPS tracks (precise location), so right-to-erasure requires them to
    /// go. Outside this, a backup is removed only by `discard` once its
    /// workout is archived; nothing removes them by age.
    func purgeAll() {
        for id in allSessionIdsOnDisk() {
            discard(id)
        }
    }
}
