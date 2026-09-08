import CoreLocation
import Foundation

// MARK: - TCX Exporter
//
// Training Center XML — Garmin's original fitness-specific format.
// Richer than GPX because every trackpoint can carry HR, cadence,
// distance, altitude. TrainingPeaks, Strava, Final Surge, SportTracks,
// Runalyze, Garmin Connect all accept TCX.
//
// Schema: Activities > Activity > Lap > Track > Trackpoint.
// Activity type is keyed from the sport ("Running" / "Biking" / "Other").
enum TCXExporter {
    static func export(session: HRVSession, track: [CLLocation]) -> String {
        let sport = session.workoutMetadata?.sport ?? .walk
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var xml = header(
            session: session, activityType: tcxActivityType(for: sport),
            summary: humanSummary(session: session), iso: iso
        )
        xml += lapHeader(session: session, iso: iso)
        xml += trackpoints(session: session, track: track, iso: iso)
        xml += """
                </Track>
              </Lap>
              <Creator xsi:type="Device_t">
                <Name>Emuqu</Name>
              </Creator>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """
        return xml
    }

    /// TCX v2 schema mandates metric values (`<AltitudeMeters>`,
    /// `<DistanceMeters>`, m/s for speed). Putting feet / miles values in those
    /// tags would break TrainingPeaks / Garmin Connect imports. The machine
    /// payload stays metric, and this human-readable line goes into an XML
    /// comment at the top — plus a `<Notes>` block, so Garmin Connect surfaces
    /// it in the activity UI.
    private static func humanSummary(session: HRVSession) -> String {
        let metadata = session.workoutMetadata
        let distMetersRaw = metadata?.distanceMeters ?? 0
        let elevMetersRaw = metadata?.elevationGainMeters ?? 0
        let durationSecRaw = session.duration ?? 0
        let imperial = UnitsPreferenceStore.current.resolved == .imperial
        let distLabel: String = {
            if imperial { return String(format: "%.2f mi", distMetersRaw / 1609.344) }
            return String(format: "%.2f km", distMetersRaw / 1000.0)
        }()
        let elevLabel: String = {
            if imperial { return String(format: "%.0f ft", elevMetersRaw * UnitConstants.feetPerMeter) }
            return String(format: "%.0f m", elevMetersRaw)
        }()
        let durLabel: String = {
            let mins = Int(durationSecRaw) / 60
            let secs = Int(durationSecRaw) % 60
            return String(format: "%d:%02d", mins, secs)
        }()
        let humanSummary = "Emuqu export (preferred units: \(imperial ? "imperial" : "metric")). Distance \(distLabel), elevation gain \(elevLabel), duration \(durLabel). Values below are metric per TCX v2 schema."
        return humanSummary
    }

    private static func header(
        session: HRVSession,
        activityType: String,
        summary humanSummary: String,
        iso: ISO8601DateFormatter
    ) -> String {
        #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- \#(humanSummary) -->
        <TrainingCenterDatabase
            xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
            xsi:schemaLocation="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2 http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd">
          <Activities>
            <Activity Sport="\#(activityType)">
              <Id>\#(iso.string(from: session.startDate))</Id>
              <Notes>\#(humanSummary)</Notes>

        """#
    }

    private static func lapHeader(session: HRVSession, iso: ISO8601DateFormatter) -> String {
        let metadata = session.workoutMetadata
        let durationSecRaw = session.duration ?? 0
        let distMetersRaw = metadata?.distanceMeters ?? 0
        var xml = ""
        let durationSec = durationSecRaw
        let distance = distMetersRaw
        let meanHR = session.meanHR.map { Int($0) } ?? 0

        xml += "      <Lap StartTime=\"\(iso.string(from: session.startDate))\">\n"
        xml += "        <TotalTimeSeconds>\(durationSec)</TotalTimeSeconds>\n"
        xml += "        <DistanceMeters>\(distance)</DistanceMeters>\n"
        if meanHR > 0 {
            xml += "        <AverageHeartRateBpm><Value>\(meanHR)</Value></AverageHeartRateBpm>\n"
        }
        xml += "        <Intensity>Active</Intensity>\n"
        xml += "        <TriggerMethod>Manual</TriggerMethod>\n"
        xml += "        <Track>\n"
        return xml
    }

    private static func trackpoints(session: HRVSession, track: [CLLocation], iso: ISO8601DateFormatter) -> String {
        // Pair RR-derived HR samples with each GPS fix by nearest timestamp.
        let hrSamples = WorkoutAnalyzer.hrSamplesWithWallClock(
            rrPoints: session.rrSeries?.points ?? [],
            startDate: session.startDate
        )
        var xml = ""
        var cumulative = 0.0
        for (idx, fix) in track.enumerated() {
            if idx > 0 { cumulative += fix.distance(from: track[idx - 1]) }
            xml += trackpoint(fix, cumulative: cumulative, hrSamples: hrSamples, iso: iso)
        }
        return xml
    }

    private static func trackpoint(
        _ fix: CLLocation,
        cumulative: Double,
        hrSamples: [WorkoutAnalyzer.HRWallClockSample],
        iso: ISO8601DateFormatter
    ) -> String {
        var xml = ""
            xml += "          <Trackpoint>\n"
            xml += "            <Time>\(iso.string(from: fix.timestamp))</Time>\n"
            xml += "            <Position>\n"
            xml += "              <LatitudeDegrees>\(String(format: "%.6f", fix.coordinate.latitude))</LatitudeDegrees>\n"
            xml += "              <LongitudeDegrees>\(String(format: "%.6f", fix.coordinate.longitude))</LongitudeDegrees>\n"
            xml += "            </Position>\n"
            xml += "            <AltitudeMeters>\(String(format: "%.1f", fix.altitude))</AltitudeMeters>\n"
            xml += "            <DistanceMeters>\(String(format: "%.1f", cumulative))</DistanceMeters>\n"

            // HR at this fix — nearest beat.
            if let nearestHR = nearestHR(to: fix.timestamp, in: hrSamples) {
                xml += "            <HeartRateBpm><Value>\(Int(nearestHR))</Value></HeartRateBpm>\n"
            }
        xml += "          </Trackpoint>\n"
        return xml
    }

    static func writeToTempFile(session: HRVSession, track: [CLLocation]) throws -> URL {
        let tcx = export(session: session, track: track)
        let sport = session.workoutMetadata?.sport.rawValue ?? "workout"
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        let filename = "\(sport)-\(fmt.string(from: session.startDate)).tcx"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        guard let data = tcx.data(using: .utf8) else {
            throw NSError(domain: "TCXExporter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Couldn't encode TCX as UTF-8"])
        }
        try data.write(to: url, options: .atomic)
        debugLog("[TCXExporter] wrote \(data.count) bytes to \(url.path) (\(track.count) trackpoints)")
        return url
    }

    // MARK: - Helpers

    private static func tcxActivityType(for sport: Sport) -> String {
        switch sport {
        case .run, .trailRun, .treadmill: "Running"
        case .bike, .indoorBike, .airBike: "Biking"
        case .walk, .hike: "Other"
        case .row: "Other"  // TCX schema lacks a rowing primary type
        case .crossFit: "Other"  // no functional-fitness primary type in TCX
        }
    }

    private static func nearestHR(to target: Date, in samples: [WorkoutAnalyzer.HRWallClockSample]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let nearest = samples.min(by: {
            abs($0.timestamp.timeIntervalSince(target)) < abs($1.timestamp.timeIntervalSince(target))
        })
        guard let n = nearest,
              abs(n.timestamp.timeIntervalSince(target)) <= 5 else { return nil }
        return n.hr
    }
}
