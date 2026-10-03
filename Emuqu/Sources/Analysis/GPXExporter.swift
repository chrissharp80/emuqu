import CoreLocation
import Foundation

// MARK: - GPX Exporter
//
// Minimal GPX 1.1 writer for workout sessions. Writes a single <trk> with
// one <trkseg> containing each CLLocation as a <trkpt>. Elevation lives in
// <ele>. Time is ISO-8601 UTC. Name + sport go in <metadata>.
//
// Every caller passes a track rebuilt by `decode`, whose fix times are spread
// evenly over the session because the stored polyline carries none. Importers
// need a <time> per point to treat the file as an activity, so the times stay,
// and the <desc> says they are spread evenly (pauses don't show as stops).
//
// This is what iSmoothRun / Strava / Garmin Connect / WorkOutDoors all
// consume natively — the lowest-common-denominator workout format. If the
// user wants TCX (training-specific: HR/cadence/power per point) or FIT
// (binary, Garmin-native), those are follow-up writers.
enum GPXExporter {
    static func export(session: HRVSession, track: [CLLocation]) -> String {
        let metadata = session.workoutMetadata
        let sport = metadata?.sport.displayName ?? "Workout"
        let started = session.startDate
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var xml = header(sport: sport, started: started, summary: summaryDesc(session: session), iso: iso)
        xml += trackSegment(track, iso: iso)
        xml += """
            </trkseg>
          </trk>
        </gpx>
        """
        return xml
    }

    /// GPX spec (topografix 1.1) mandates metric units: `<ele>` in metres,
    /// coordinates in decimal degrees. Putting feet values in `<ele>` would
    /// break Strava / Garmin Connect / WorkOutDoors imports — those readers
    /// expect metres per schema and would silently misinterpret. So the
    /// machine-readable payload stays metric, and this human-readable summary
    /// goes in the metadata `<desc>` instead: anyone opening the file in a text
    /// editor sees their preferred units at the top, while any downstream
    /// fitness app continues to parse correctly.
    private static func summaryDesc(session: HRVSession) -> String {
        let metadata = session.workoutMetadata
        let imperial = UnitsPreferenceStore.current.resolved == .imperial
        let distLabel = distanceLabel(metadata?.distanceMeters ?? 0, imperial: imperial)
        let elevLabel = elevationLabel(metadata?.elevationGainMeters ?? 0, imperial: imperial)
        let durLabel = durationLabel(session.duration ?? 0)
        let summaryDesc = "Emuqu export (preferred units: \(imperial ? "imperial" : "metric")). Distance \(distLabel), elevation gain \(elevLabel), duration \(durLabel). Machine-readable payload below is metric per GPX 1.1 spec. Point times are spread evenly across the session, so pauses don't appear as stops."
        return summaryDesc
    }

    static func distanceLabel(_ distMeters: Double, imperial: Bool) -> String {
        imperial
            ? String(format: "%.2f mi", distMeters / 1_609.344)
            : String(format: "%.2f km", distMeters / 1_000.0)
    }

    static func elevationLabel(_ elevMeters: Double, imperial: Bool) -> String {
        imperial
            ? String(format: "%.0f ft", elevMeters * UnitConstants.feetPerMeter)
            : String(format: "%.0f m", elevMeters)
    }

    static func durationLabel(_ durationSec: TimeInterval) -> String {
        String(format: "%d:%02d", Int(durationSec) / 60, Int(durationSec) % 60)
    }

    private static func header(sport: String, started: Date, summary summaryDesc: String, iso: ISO8601DateFormatter) -> String {
        #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1"
             creator="Emuqu"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
             xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
          <metadata>
            <name>\#(escape(sport)) — \#(iso.string(from: started))</name>
            <desc>\#(escape(summaryDesc))</desc>
            <time>\#(iso.string(from: started))</time>
          </metadata>
          <trk>
            <name>\#(escape(sport))</name>
            <type>\#(escape(sport))</type>
            <trkseg>

        """#
    }

    private static func trackSegment(_ track: [CLLocation], iso: ISO8601DateFormatter) -> String {
        var xml = ""
        for fix in track {
            let lat = String(format: "%.6f", fix.coordinate.latitude)
            let lon = String(format: "%.6f", fix.coordinate.longitude)
            xml += "      <trkpt lat=\"\(lat)\" lon=\"\(lon)\">\n"
            if fix.altitude != 0 || fix.verticalAccuracy >= 0 {
                xml += "        <ele>\(String(format: "%.1f", fix.altitude))</ele>\n"
            }
            xml += "        <time>\(iso.string(from: fix.timestamp))</time>\n"
            xml += "      </trkpt>\n"
        }
        return xml
    }

    /// Write a GPX export to the app's temporary directory and return the
    /// resulting file URL. Caller is responsible for presenting a share sheet.
    static func writeToTempFile(session: HRVSession, track: [CLLocation]) throws -> URL {
        let gpx = export(session: session, track: track)
        let sport = session.workoutMetadata?.sport.rawValue ?? "workout"
        // Safe filename: YYYYMMDD-HHMMSS, no colons (share-sheet quirks), in
        // POSIX/Gregorian so every calendar gets the same digits.
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        let filename = "\(sport)-\(fmt.string(from: session.startDate)).gpx"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        guard let data = gpx.data(using: .utf8) else {
            throw NSError(domain: "GPXExporter", code: -1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Couldn't create the GPX file.", bundle: LanguageManager.appBundle)
            ])
        }
        try data.write(to: url, options: .atomic)
        debugLog("[GPXExporter] wrote \(data.count) bytes to \(url.path) (track=\(track.count) points)")
        return url
    }

    // MARK: - Polyline decode
    //
    // Reverse of WorkoutAnalyzer.encodePolyline — used by the summary view to
    // reconstruct [CLLocation] from the compressed form we persist on the
    // session. Format: "<coords>\n<altitudes>" (two Google-style polylines).
    /// - Parameters:
    ///   - polyline: Encoded polyline as stored on WorkoutMetadata.
    ///   - startDate: Session start — decoded fixes begin here.
    ///   - duration: Session duration in seconds. Fixes are spread
    ///     proportionally across this window. Passing nil falls back to
    ///     5 seconds per fix (but CSVs decoded that way
    ///     will report "session lasted 99 min" for a 63-min walk
    ///     because the polyline packs fixes at a non-uniform rate).
    static func decode(polyline: Data, startDate: Date, duration: TimeInterval? = nil) -> [CLLocation] {
        guard let combined = String(data: polyline, encoding: .utf8) else { return [] }
        let parts = combined.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let coords = decodeCoordinates(String(parts.first ?? ""))
        let altitudes = decodeAltitudes(parts.count > 1 ? String(parts[1]) : "")
        let interval = fixInterval(coordCount: coords.count, duration: duration)
        return coords.enumerated().map { idx, coord in
            CLLocation(
                coordinate: coord,
                altitude: idx < altitudes.count ? altitudes[idx] : 0,
                horizontalAccuracy: 10,
                verticalAccuracy: 10,
                timestamp: startDate.addingTimeInterval(Double(idx) * interval)
            )
        }
    }

    /// The original timestamps aren't stored, so they're reconstructed by
    /// spreading fixes proportionally across the session's duration.
    ///
    /// A hardcoded 5-second interval only works by accident when the GPS fix
    /// rate happens to be ~1 fix / 5 s; when the rate diverges a walk with
    /// 1 196 coords reads as 99 min (1196 × 5 s) regardless of the true session
    /// duration — visible in exported CSVs as "session ended at 14:51, samples
    /// go to 16:31". The interval adapts instead: for a 63-min session with
    /// 1 196 coords it is 3.16 s per fix, and the last fix sits at t=endDate.
    private static func fixInterval(coordCount: Int, duration: TimeInterval?) -> TimeInterval {
        guard let d = duration, d > 0, coordCount > 1 else { return 5 }
        return d / Double(coordCount - 1)
    }

    private static func decodeCoordinates(_ s: String) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        var index = s.startIndex
        var lat = 0
        var lon = 0
        while index < s.endIndex {
            guard let dLat = decodeValue(s, &index) else { break }
            guard let dLon = decodeValue(s, &index) else { break }
            lat += dLat
            lon += dLon
            result.append(CLLocationCoordinate2D(
                latitude: Double(lat) / 1e5,
                longitude: Double(lon) / 1e5
            ))
        }
        return result
    }

    private static func decodeAltitudes(_ s: String) -> [Double] {
        var result: [Double] = []
        var index = s.startIndex
        var prev = 0
        while index < s.endIndex {
            guard let d = decodeValue(s, &index) else { break }
            prev += d
            result.append(Double(prev) / 10)
        }
        return result
    }

    private static func decodeValue(_ s: String, _ index: inout String.Index) -> Int? {
        var result = 0
        var shift = 0
        while index < s.endIndex {
            let c = s[index]
            guard let ascii = c.asciiValue else { return nil }
            let byte = Int(ascii) - 63
            index = s.index(after: index)
            result |= (byte & 0x1f) << shift
            shift += 5
            if byte < 0x20 { break }
        }
        let negative = (result & 1) == 1
        let value = result >> 1
        return negative ? ~value : value
    }

    // MARK: - Escape

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
