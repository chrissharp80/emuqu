import CoreLocation
import Foundation

// MARK: - TCX Exporter
//
// Training Center XML — Garmin's original fitness-specific format.
// Richer than GPX because every trackpoint can carry HR, cadence,
// distance, altitude. TrainingPeaks, Strava, Final Surge, SportTracks,
// Runalyze, Garmin Connect all accept TCX.
//
// Schema: Activities > Activity > Lap > Track > Trackpoint, elements in the
// order TrainingCenterDatabasev2.xsd requires (Activity: Id, Lap, Notes; Lap:
// TotalTimeSeconds, DistanceMeters, Calories, AverageHeartRateBpm, Intensity,
// TriggerMethod, Track). No <Creator>: Device_t needs a Garmin unit and
// product id that this app doesn't have.
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
        xml += track.isEmpty
            ? timeOnlyTrackpoints(session: session, iso: iso)
            : trackpoints(session: session, track: track, iso: iso)
        xml += """
                </Track>
              </Lap>
              <Notes>\(humanSummary(session: session))</Notes>
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
    /// it in the activity UI. The totals are the GPX export's
    /// (`GPXExporter.summaryTotals`), so both files describe a workout alike
    /// and a total the session did not record is left out, not written as 0.
    private static func humanSummary(session: HRVSession) -> String {
        let imperial = UnitsPreferenceStore.current.resolved == .imperial
        let totals = GPXExporter.summaryTotals(session: session, imperial: imperial).map { " \($0)." } ?? ""
        return "Emuqu export (preferred units: \(imperial ? "imperial" : "metric")).\(totals) Values below are metric per TCX v2 schema."
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
        // Required by the schema; the app records no energy figure.
        xml += "        <Calories>0</Calories>\n"
        if meanHR > 0 {
            xml += "        <AverageHeartRateBpm><Value>\(meanHR)</Value></AverageHeartRateBpm>\n"
        }
        xml += "        <Intensity>Active</Intensity>\n"
        xml += "        <TriggerMethod>Manual</TriggerMethod>\n"
        xml += "        <Track>\n"
        return xml
    }

    private static func trackpoints(session: HRVSession, track: [CLLocation], iso: ISO8601DateFormatter) -> String {
        var hrTrack = HRTrack(session: session)
        var xml = ""
        var cumulative = 0.0
        for (idx, fix) in track.enumerated() {
            if idx > 0 { cumulative += fix.distance(from: track[idx - 1]) }
            let hr = hrTrack.median(near: fix.timestamp.timeIntervalSince(session.startDate))
            xml += trackpoint(fix, cumulative: cumulative, heartRate: hr, iso: iso)
        }
        return xml
    }

    /// Seconds between trackpoints when there is no GPS track.
    private static let indoorStepSec: TimeInterval = 5

    /// Trackpoints for a workout with no GPS (treadmill, indoor bike, rower,
    /// CrossFit): time and heart rate only, which the schema allows, every
    /// `indoorStepSec` seconds where a heart rate exists. The schema's
    /// `Track_t` needs at least one `Trackpoint`, so the start is always
    /// written, and an indoor export still carries its HR stream.
    private static func timeOnlyTrackpoints(session: HRVSession, iso: ISO8601DateFormatter) -> String {
        var hrTrack = HRTrack(session: session)
        let duration = max(0, session.duration ?? 0)
        var xml = ""
        for offset in stride(from: 0, through: duration, by: indoorStepSec) {
            let hr = hrTrack.median(near: offset)
            guard hr != nil || offset == 0 else { continue }
            xml += timeOnlyTrackpoint(at: session.startDate.addingTimeInterval(offset), heartRate: hr, iso: iso)
        }
        return xml
    }

    private static func timeOnlyTrackpoint(at time: Date, heartRate: Double?, iso: ISO8601DateFormatter) -> String {
        var xml = "          <Trackpoint>\n"
        xml += "            <Time>\(iso.string(from: time))</Time>\n"
        if let heartRate {
            xml += "            <HeartRateBpm><Value>\(Int(heartRate.rounded()))</Value></HeartRateBpm>\n"
        }
        xml += "          </Trackpoint>\n"
        return xml
    }

    private static func trackpoint(
        _ fix: CLLocation,
        cumulative: Double,
        heartRate: Double?,
        iso: ISO8601DateFormatter
    ) -> String {
        var xml = ""
            xml += "          <Trackpoint>\n"
            xml += "            <Time>\(iso.string(from: fix.timestamp))</Time>\n"
            xml += "            <Position>\n"
            xml += "              <LatitudeDegrees>\(String(format: "%.6f", fix.coordinate.latitude))</LatitudeDegrees>\n"
            xml += "              <LongitudeDegrees>\(String(format: "%.6f", fix.coordinate.longitude))</LongitudeDegrees>\n"
            xml += "            </Position>\n"
            // A fix without a stored altitude carries a negative vertical
            // accuracy (`GPXExporter.decode`); its element is left out, as
            // the GPX writer leaves out <ele>, rather than written as 0 m.
            if fix.altitude != 0 || fix.verticalAccuracy >= 0 {
                xml += "            <AltitudeMeters>\(String(format: "%.1f", fix.altitude))</AltitudeMeters>\n"
            }
            xml += "            <DistanceMeters>\(String(format: "%.1f", cumulative))</DistanceMeters>\n"

            if let heartRate {
                xml += "            <HeartRateBpm><Value>\(Int(heartRate.rounded()))</Value></HeartRateBpm>\n"
            }
        xml += "          </Trackpoint>\n"
        return xml
    }

    static func writeToTempFile(session: HRVSession, track: [CLLocation]) throws -> URL {
        let tcx = export(session: session, track: track)
        let sport = session.workoutMetadata?.sport.rawValue ?? "workout"
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        let filename = "\(sport)-\(fmt.string(from: session.startDate)).tcx"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        guard let data = tcx.data(using: .utf8) else {
            throw NSError(domain: "TCXExporter", code: -1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Couldn't create the TCX file.", bundle: LanguageManager.appBundle)
            ])
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

}

/// Heart rate by wall-clock offset for the trackpoints. Prefers per-beat HR
/// from the RR series, whose times are on the wall clock (gap-corrected), so
/// it lines up with trackpoint times after a pause. Falls back to the
/// recorder's 1 Hz samples, whose `offsetSec` stops while paused; each is
/// moved onto the wall clock by the pauses recorded before it
/// (`WorkoutMetadata.wallClockSeconds(forActiveOffset:)`), or after a pause
/// it would sit early by the pause's length. Either way each trackpoint gets
/// the median of the readings within ±`halfWindow` seconds, so one missed or
/// extra beat can't export as a 30 or 250 bpm spike. Readings are sorted by
/// offset, and queries normally arrive in time order, so a moving start
/// index keeps the pass linear; a query earlier than the last moves it back.
private struct HRTrack {
    private let offsets: [TimeInterval]
    private let values: [Double]
    private var start = 0
    private let halfWindow: TimeInterval = 3

    private typealias Reading = (offset: TimeInterval, value: Double)

    init(session: HRVSession) {
        let beats: [Reading] = WorkoutAnalyzer.hrSamplesWithWallClock(
            rrPoints: session.rrSeries?.points ?? [], startDate: session.startDate
        ).map { ($0.timestamp.timeIntervalSince(session.startDate), $0.hr) }
        let metadata = session.workoutMetadata
        let samples: [Reading] = (metadata?.samples ?? []).compactMap { sample -> Reading? in
            guard let heartRate = sample.heartRate, heartRate > 0, let metadata else { return nil }
            return (metadata.wallClockSeconds(forActiveOffset: sample.offsetSec), Double(heartRate))
        }
        let readings = (beats.isEmpty ? samples : beats).sorted { $0.offset < $1.offset }
        offsets = readings.map { $0.offset }
        values = readings.map { $0.value }
    }

    mutating func median(near offset: TimeInterval) -> Double? {
        while start > 0, offsets[start - 1] >= offset - halfWindow { start -= 1 }
        while start < offsets.count, offsets[start] < offset - halfWindow { start += 1 }
        var window: [Double] = []
        var i = start
        while i < offsets.count, offsets[i] <= offset + halfWindow {
            window.append(values[i])
            i += 1
        }
        guard !window.isEmpty else { return nil }
        let sorted = window.sorted()
        return sorted[sorted.count / 2]
    }
}
