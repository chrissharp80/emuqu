import CoreLocation
import Foundation

// MARK: - GPX Importer
//
// Reads a standard GPX 1.1 file — the format Strava, Garmin Connect, Runkeeper,
// and almost every other running app export — and rebuilds it into an Emuqu
// `HRVSession` of type `.workout`. Lets users bring in historical
// workouts from other apps without losing their data.
//
// What we extract:
//   - trkpt/lat/lon/ele                    → GPS track
//   - trkpt/time                           → trackpoint timestamps
//   - trkpt/extensions/gpxtpx:hr           → per-point heart rate (Garmin/Strava extension)
//   - trkpt/extensions/gpxtpx:cad          → per-point cadence
//   - first trkpt time (or metadata/time)  → session start
//
// Not extracted (doesn't exist in GPX):
//   - RR intervals (so no HRV metrics are computed — we flag the session
//     as having been imported and omit HRV/DFA analysis)
//   - Power (rarely in GPX)
//   - Lap markers
//
// Parser is a tiny XMLParser — we don't need a full GPX type system, just the
// three tags we consume.

@MainActor
enum GPXImporter {
    enum ImportError: LocalizedError {
        case invalidXML
        case noTrackpoints
        case noTimestamps

        var errorDescription: String? {
            switch self {
            case .noTimestamps:
                return String(localized: "This GPX file has no timestamps, so it can't be imported as a workout.", bundle: LanguageManager.appBundle)
            case .invalidXML:
                return String(localized: "This file isn't valid GPX, so it couldn't be read.", bundle: LanguageManager.appBundle)
            case .noTrackpoints:
                return String(localized: "This GPX file has no trackpoints.", bundle: LanguageManager.appBundle)
            }
        }
    }

    /// Parse a GPX file for its track, e.g. a planned route. A file with no
    /// time anywhere (a route drawn in a planner) is accepted and stamped now;
    /// to import a recorded workout use `parseWorkout`, which refuses one.
    static func parse(data: Data, defaultSport: Sport = .run) throws -> ImportedWorkoutTrack {
        let delegate = try parsedPoints(from: data)
        return track(from: delegate, times: resolvedTimes(delegate), defaultSport: defaultSport)
    }

    /// Parse a GPX file as a recorded workout. Its date comes from the file,
    /// never from the moment of import, so a file with no timestamps throws.
    static func parseWorkout(data: Data, defaultSport: Sport = .run) throws -> ImportedWorkoutTrack {
        let delegate = try parsedPoints(from: data)
        guard let times = resolvedTimes(delegate) else { throw ImportError.noTimestamps }
        return track(from: delegate, times: times, defaultSport: defaultSport)
    }

    private static func track(
        from delegate: GPXParserDelegate,
        times: [Date]?,
        defaultSport: Sport
    ) -> ImportedWorkoutTrack {
        let pointTimes = times ?? Array(repeating: Date(), count: delegate.points.count)
        let start = pointTimes.first ?? Date()
        return ImportedWorkoutTrack(
            startDate: start,
            endDate: pointTimes.last ?? start,
            track: locations(from: delegate.points, times: pointTimes),
            heartRateSamples: delegate.points.compactMap { p in
                guard let t = p.time, let hr = p.hr else { return nil }
                return (t, hr)
            },
            cadenceSamples: delegate.points.compactMap { p in
                guard let t = p.time, let cad = p.cad else { return nil }
                return (t, cad)
            },
            // GPX files often set <trk><type>Running</type>; fall back to the
            // caller's default when they don't.
            sport: sportFromType(delegate.trkType) ?? defaultSport
        )
    }

    /// Each point's time: its own, else the previous point's, else (for points
    /// before the first timed one) the first point time or the file's
    /// `metadata/time`. Nil when the file carries no time at all.
    private static func resolvedTimes(_ delegate: GPXParserDelegate) -> [Date]? {
        guard let anchor = delegate.points.lazy.compactMap(\.time).first ?? delegate.metadataTime else { return nil }
        var last = anchor
        return delegate.points.map { point in
            if let time = point.time { last = time }
            return last
        }
    }

    /// Runs the XML parse and rejects anything with no usable trackpoints.
    ///
    /// XXE hardening: iOS `XMLParser` defaults `shouldResolveExternalEntities`
    /// to `false`, but it is set explicitly so the intent is visible to anyone
    /// auditing the import path — GPX files come from arbitrary user sources
    /// (Garmin Connect exports, manual edits, etc.).
    private static func parsedPoints(from data: Data) throws -> GPXParserDelegate {
        let delegate = GPXParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false // GPX extensions use namespaces; we accept the raw element names
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw ImportError.invalidXML }
        guard !delegate.points.isEmpty else { throw ImportError.noTrackpoints }
        return delegate
    }

    private static func locations(from points: [GPXParserDelegate.Point], times: [Date]) -> [CLLocation] {
        zip(points, times).map { p, time in
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon),
                altitude: p.ele ?? 0,
                horizontalAccuracy: 5, // conservative — GPX files don't carry accuracy
                verticalAccuracy: 5,
                timestamp: time
            )
        }
    }
    /// Build a finished `HRVSession` from a parsed GPX.
    ///
    /// The reconstruction itself is `ImportedWorkoutBuilder`'s — the same code
    /// that rebuilds a workout read out of Apple Health, because a GPX file and
    /// an HKWorkout carry the same two signals (a timestamped track and
    /// timestamped heart rates) in different wrappers.
    static func buildSession(from parsed: ImportedWorkoutTrack) -> HRVSession {
        ImportedWorkoutBuilder.buildSession(from: parsed, source: .gpxFile)
    }

    private static func sportFromType(_ type: String?) -> Sport? {
        guard let type = type?.lowercased() else { return nil }
        // Check "trail" before "run": Strava/Garmin export "trail running" /
        // "TrailRun", which contain "run" — testing run first made .trailRun
        // unreachable for the common labels.
        if type.contains("trail") { return .trailRun }
        if type.contains("run") { return .run }
        if type.contains("walk") { return .walk }
        // Stems, not words: Garmin and Strava write "hiking" and "cycling",
        // which contain neither "hike" nor "cycle".
        if type.contains("hik") { return .hike }
        // Check air-bike and crossfit before the generic "bike" test:
        // "air_bike"/"airbike" contain "bike" and would otherwise resolve
        // to plain .bike.
        if type.contains("crossfit") || type.contains("cross_fit") { return .crossFit }
        if type.contains("air_bike") || type.contains("airbike") { return .airBike }
        if ["bike", "biking", "cycl", "ride", "riding"].contains(where: { type.contains($0) }) { return .bike }
        return nil
    }

    // MARK: - Numeric validation

    // Parsing a Double is not validating one. `Double(_:)` accepts "nan",
    // "inf", "-inf" and overflowing literals like "1e400", and every one of
    // those reaches an `Int(...)` conversion downstream that traps rather than
    // throwing. These bounds are the WGS 84 coordinate domain and a generous
    // physical elevation range — from the Dead Sea shore to above Everest —
    // wide enough that no real recording is rejected.

    nonisolated static func isValidLatitude(_ value: Double) -> Bool {
        value.isFinite && (-90.0 ... 90.0).contains(value)
    }

    nonisolated static func isValidLongitude(_ value: Double) -> Bool {
        value.isFinite && (-180.0 ... 180.0).contains(value)
    }

    /// Finite and physical only: `inf` passes a `> 0` filter and traps later
    /// in `Int(round(...))`.
    nonisolated static func validCadence(_ value: Double) -> Double? {
        value.isFinite && (0 ... 300).contains(value) ? value : nil
    }

    nonisolated static func isValidElevation(_ value: Double) -> Bool {
        value.isFinite && (-500.0 ... 10000.0).contains(value)
    }

    /// A heart rate a person can have; 0 or 400 bpm from a malformed file is
    /// dropped rather than imported.
    nonisolated static func validHeartRate(_ value: Int) -> Int? {
        (25 ... 250).contains(value) ? value : nil
    }

}

// MARK: - XMLParser delegate (tiny, focused)

private final class GPXParserDelegate: NSObject, XMLParserDelegate {
    struct Point {
        var lat: Double = 0
        var lon: Double = 0
        var ele: Double?
        var time: Date?
        var hr: Int?
        var cad: Double?
    }

    var points: [Point] = []
    var trkType: String?
    /// `<metadata><time>`, the file's own creation time.
    var metadataTime: Date?
    private var inMetadata = false

    private var current: Point?
    private var currentElement = ""
    private var textBuffer = ""

    /// `Date.ISO8601FormatStyle` is a `Sendable` value, unlike the class-based
    /// `ISO8601DateFormatter`, so the parser can be shared across isolation
    /// domains without an unchecked escape.
    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// GPX timestamps come with or without fractional seconds; a value that
    /// parses as neither is dropped rather than guessed.
    private static func parseTimestamp(_ text: String) -> Date? {
        for style in [isoFractional, iso] {
            do { return try style.parse(text) } catch { continue }
        }
        return nil
    }
    private static let iso = Date.ISO8601FormatStyle()

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName.lowercased()
        textBuffer = ""
        if currentElement == "metadata" { inMetadata = true }
        guard currentElement == "trkpt" else { return }
        // Only start a point when both coordinates parse. A malformed trkpt
        // (missing/unparseable lat or lon) would otherwise append a phantom
        // (0,0) Null-Island fix that corrupts distance/polyline.
        // Parsing is not validation — see `isValidLatitude`.
        guard let latStr = attributeDict["lat"], let lat = Double(latStr),
              let lonStr = attributeDict["lon"], let lon = Double(lonStr),
              GPXImporter.isValidLatitude(lat), GPXImporter.isValidLongitude(lon) else {
            current = nil
            return
        }
        var p = Point()
        p.lat = lat
        p.lon = lon
        current = p
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let tag = elementName.lowercased()
        if tag == "metadata" { inMetadata = false }
        apply(tag: tag, text: textBuffer.trimmingCharacters(in: .whitespacesAndNewlines))
        if tag == "trkpt", let p = current {
            points.append(p)
            current = nil
        }
        textBuffer = ""
    }

    /// A trackpoint's own time, or the file's `<metadata><time>`.
    private func applyTime(_ text: String) {
        if current != nil {
            current?.time = Self.parseTimestamp(text)
        } else if inMetadata {
            metadataTime = Self.parseTimestamp(text)
        }
    }

    /// Route one closed element's text onto the point being built. Namespaced
    /// extension tags (`gpxtpx:hr`, `ns3:cad`, …) are matched by suffix.
    private func apply(tag: String, text: String) {
        switch tag {
        case "ele":
            // Same reasoning as the coordinates above: a non-finite or absurd
            // elevation traps in the altitude encoder. An out-of-range
            // elevation drops the ELEVATION rather than the point — a good
            // track with one bad `<ele>` is still a good track.
            current?.ele = Double(text).flatMap { GPXImporter.isValidElevation($0) ? $0 : nil }
        case "time":
            applyTime(text)
        default:
            if tag.hasSuffix(":hr") || tag == "hr" || tag == "heartrate" {
                current?.hr = Int(text).flatMap(GPXImporter.validHeartRate)
            } else if tag.hasSuffix(":cad") || tag == "cad" || tag == "cadence" {
                current?.cad = Double(text).flatMap(GPXImporter.validCadence)
            } else if tag == "type" {
                trkType = text
            }
        }
    }
}
