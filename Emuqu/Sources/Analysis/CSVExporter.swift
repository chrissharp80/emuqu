import CoreLocation
import Foundation

// MARK: - CSV Exporter
//
// Spreadsheet-friendly flat export. Two sections:
//   1. A metadata header (summary row) — sport, duration, distance,
//      TRIMP, hrTSS, HRR, decoupling.
//   2. Per-fix rows — one per CLLocation with timestamp, lat, lon,
//      altitude, cumulative distance. HR at each fix isn't synchronised
//      (RR and GPS arrive on independent clocks), so the HR column is
//      the nearest-in-time beat-derived HR when available.
//
// Unit system: follows `UnitsPreferenceStore.current`. Imperial users
// get miles / feet / min-per-mile columns; metric users get km / m /
// min-per-km. Column headers include units explicitly so an external
// import path can never be ambiguous about what it's reading. This
// was a standing user complaint: "if I set imperial, I want imperial
// everywhere — common sense."
//
// Works for indoor / no-GPS sessions too — in that case only the summary
// row is populated and the trackpoint section is empty.
enum CSVExporter {
    /// Unit system for the export, resolved once. Every conversion here keeps
    /// metric internally and converts only at cell-render time, so a mixed-unit
    /// row is not expressible.
    struct Units {
        let imperial: Bool
        let metresToDist: (Double) -> Double
        let metresToElev: (Double) -> Double
        let secPerKmToSecPerUnit: (Double) -> Double
        let distUnit: String
        let elevUnit: String
        let paceUnit: String
        let altShort: String
        let distShort: String

        init(imperial: Bool = UnitsPreferenceStore.current.resolved == .imperial) {
            self.imperial = imperial
            metresToDist = { m in imperial ? m / 1609.344 : m / 1000.0 }
            metresToElev = { m in imperial ? m * UnitConstants.feetPerMeter : m }
            secPerKmToSecPerUnit = { p in imperial ? p * 1.609_344 : p }
            distUnit = imperial ? "mi" : "km"
            elevUnit = imperial ? "ft" : "m"
            // Pace cells hold whole seconds per km / mile, so the header says so.
            paceUnit = imperial ? "sec_per_mi" : "sec_per_km"
            altShort = imperial ? "ft" : "m"
            distShort = imperial ? "mi" : "km"
        }
    }

    /// The `#`-prefixed preamble. Every line is conditional on the session
    /// actually carrying that field, which is where most of `export`'s
    /// branching lived — eleven independent optionals in a row.
    private static func headerBlock(
        session: HRVSession,
        sport: String,
        units: Units,
        iso: ISO8601DateFormatter
    ) -> String {
        var lines: [String] = [
            "# Emuqu workout export",
            "# Sport: \(sport)",
            "# Start: \(iso.string(from: session.startDate))"
        ]
        lines += optionalFieldLines(session: session, units: units, iso: iso)
        lines.append("# Units preference: \(units.imperial ? "imperial" : "metric")")
        return lines.joined(separator: "\n") + "\n\n"
    }

    /// Eleven independent optionals, each emitted only when the session
    /// actually carries that field.
    private static func optionalFieldLines(
        session: HRVSession,
        units: Units,
        iso: ISO8601DateFormatter
    ) -> [String] {
        let metadata = session.workoutMetadata
        var lines: [String] = []
        func add(_ label: String, _ value: String?) {
            guard let value else { return }
            lines.append("# \(label): \(value)")
        }
        add("End", session.endDate.map { iso.string(from: $0) })
        add("Duration (sec)", session.duration.map { "\(Int($0))" })
        add("Distance (\(units.distUnit))", metadata?.distanceMeters.map { String(format: "%.2f", units.metresToDist($0)) })
        add("Elevation gain (\(units.elevUnit))", metadata?.elevationGainMeters.map { "\(Int(units.metresToElev($0)))" })
        add("Mean HR (bpm)", session.meanHR.map { "\(Int($0))" })
        add("RMSSD (ms)", session.rmssd.map { String(format: "%.1f", $0) })
        add("TRIMP", metadata?.luciaTRIMP.map { String(format: "%.1f", $0) })
        add("hrTSS", metadata?.hrTSS.map { String(format: "%.1f", $0) })
        add("Decoupling (%)", metadata?.decouplingPercent.map { String(format: "%.1f", $0) })
        add("HRR @ 1 min (bpm drop)", metadata?.hrrSamples?.bestAtOneMinute.map { "\($0.drop)" })
        return lines
    }

    static func export(session: HRVSession, track: [CLLocation]) -> String {
        let metadata = session.workoutMetadata
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let units = Units()
        let samples = metadata?.samples ?? []
        var out = headerBlock(
            session: session,
            sport: metadata?.sport.displayName ?? "Workout",
            units: units,
            iso: iso
        )
        out += trackpointBlock(session: session, track: track, samples: samples, units: units, iso: iso)
        // Indoor fallback: no GPS track but a per-second sample series exists.
        if track.isEmpty, !samples.isEmpty {
            out += indoorBlock(samples: samples, units: units)
        }
        if let splits = metadata?.splits, !splits.isEmpty {
            out += splitsBlock(splits, units: units)
        }
        return out
    }

    /// Per-row metrics, joining each GPS fix to the nearest per-second
    /// WorkoutSample (captured at 1 Hz by WorkoutRecorder).
    ///
    /// Without this, previous CSVs were GPS-only — no HR, no pace, no cadence —
    /// and every serious external tool (Strava bulk analysis, Excel pivot
    /// tables, TrainingPeaks imports) was left with half the story. With
    /// `samples` nil (an older session) it falls back to plain GPS.
    ///
    /// Only fixes within the session window are kept. The polyline decoder used
    /// to stretch fixes past `session.endDate` due to a hardcoded 5-s interval
    /// (see GPXExporter.decode); with that fixed this should already be clean,
    /// but belt-and-braces filtering keeps post-stop phantom rows out of the CSV
    /// no matter how the track was reconstructed.
    private static func trackpointBlock(
        session: HRVSession,
        track: [CLLocation],
        samples: [WorkoutSample],
        units: Units,
        iso: ISO8601DateFormatter
    ) -> String {
        let (altShort, distShort, paceUnit) = (units.altShort, units.distShort, units.paceUnit)
        let sessionEnd = session.endDate ?? (session.duration.map { session.startDate.addingTimeInterval($0) } ?? Date())
        let inWindow = track.filter { $0.timestamp <= sessionEnd && $0.timestamp >= session.startDate }
        var out = "timestamp,seconds_from_start,latitude,longitude,altitude_\(altShort),cumulative_distance_\(distShort),hr_bpm,pace_\(paceUnit),cadence_spm,mets,power_w,dfa_alpha1\n"
        var cumulative = 0.0
        for (idx, fix) in inWindow.enumerated() {
            if idx > 0 { cumulative += fix.distance(from: inWindow[idx - 1]) }
            out += Self.trackpointRow(
                fix: fix, cumulative: cumulative, session: session,
                samples: samples, units: units, iso: iso
            ) + "\n"
        }
        return out
    }

    /// One CSV row: the GPS fix plus whatever the nearest 1 Hz sample carried.
    private static func trackpointRow(
        fix: CLLocation,
        cumulative: Double,
        session: HRVSession,
        samples: [WorkoutSample],
        units: Units,
        iso: ISO8601DateFormatter
    ) -> String {
        let secondsFromStart = Int(fix.timestamp.timeIntervalSince(session.startDate))
        let matched = Self.nearestSample(to: secondsFromStart, in: samples)
        let secPerKmToSecPerUnit = units.secPerKmToSecPerUnit
        let cells: [String] = [
            iso.string(from: fix.timestamp),
            "\(secondsFromStart)",
            String(format: "%.6f", fix.coordinate.latitude),
            String(format: "%.6f", fix.coordinate.longitude),
            String(format: "%.1f", units.metresToElev(fix.altitude)),
            String(format: "%.3f", units.metresToDist(cumulative)),
            matched?.heartRate.map { "\($0)" } ?? "",
            matched.flatMap(\.paceSecPerKm).map { String(format: "%.0f", secPerKmToSecPerUnit($0)) } ?? "",
            matched.flatMap(\.cadenceStepsPerMin).map { String(format: "%.0f", $0) } ?? "",
            matched.flatMap(\.mets).map { String(format: "%.1f", $0) } ?? "",
            matched.flatMap(\.powerWatts).map { "\($0)" } ?? "",
            // DFA α1 is sampled ~every 20 s, so most 1 Hz rows have no fresh
            // value and render empty — expected. External tools can forward-fill.
            matched.flatMap(\.alpha1).map { String(format: "%.3f", $0) } ?? ""
        ]
        return cells.joined(separator: ",")
    }

    /// A track-less table keyed on offsetSec, so treadmill / indoor-bike
    /// sessions aren't just "header with nothing below".
    private static func indoorBlock(samples: [WorkoutSample], units: Units) -> String {
        let secPerKmToSecPerUnit = units.secPerKmToSecPerUnit
        let metresToElev = units.metresToElev
        let (paceUnit, altShort) = (units.paceUnit, units.altShort)
        var out = "\n"
        out += "seconds_from_start,hr_bpm,pace_\(paceUnit),cadence_spm,mets,power_w,altitude_\(altShort),dfa_alpha1\n"
        for s in samples {
            let secCell = "\(s.offsetSec)"
            let hrCell: String = s.heartRate.map { "\($0)" } ?? ""
            let paceCell: String = s.paceSecPerKm.map { String(format: "%.0f", secPerKmToSecPerUnit($0)) } ?? ""
            let cadCell: String = s.cadenceStepsPerMin.map { String(format: "%.0f", $0) } ?? ""
            let metsCell: String = s.mets.map { String(format: "%.1f", $0) } ?? ""
            let powCell: String = s.powerWatts.map { "\($0)" } ?? ""
            let altCell: String = s.altitudeMeters.map { String(format: "%.1f", metresToElev($0)) } ?? ""
            let alphaCell: String = s.alpha1.map { String(format: "%.3f", $0) } ?? ""
            let cells: [String] = [secCell, hrCell, paceCell, cadCell, metsCell, powCell, altCell, alphaCell]
            out += cells.joined(separator: ",") + "\n"
        }
        return out
    }

    private static func splitsBlock(_ splits: [Split], units: Units) -> String {
        let (metresToDist, metresToElev) = (units.metresToDist, units.metresToElev)
        let secPerKmToSecPerUnit = units.secPerKmToSecPerUnit
        let (distShort, altShort, paceUnit) = (units.distShort, units.altShort, units.paceUnit)
        var out = "\n"
        out += "split_index,distance_\(distShort),duration_sec,avg_hr,avg_pace_\(paceUnit),elevation_gain_\(altShort),avg_dfa_alpha1\n"
        for split in splits {
            let row = [
                "\(split.index)",
                String(format: "%.3f", metresToDist(split.distanceMeters)),
                String(format: "%.1f", split.durationSeconds),
                split.averageHR.map { String(format: "%.0f", $0) } ?? "",
                split.averagePaceSecPerKm.map { String(format: "%.0f", secPerKmToSecPerUnit($0)) } ?? "",
                split.elevationGainMeters.map { String(format: "%.1f", metresToElev($0)) } ?? "",
                split.averageAlpha1.map { String(format: "%.3f", $0) } ?? ""
            ].joined(separator: ",")
            out += row + "\n"
        }
        return out
    }

    /// Nearest sample to the given elapsed second. Returns nil when the
    /// closest sample is >5 s away (caller prefers an empty cell to a
    /// misleading stale value). Samples are sorted by offsetSec when
    /// captured — a linear scan from a hint index would be faster, but for
    /// the typical 30–120 min sessions this is negligible.
    private static func nearestSample(to offsetSec: Int, in samples: [WorkoutSample]) -> WorkoutSample? {
        guard !samples.isEmpty else { return nil }
        var best: WorkoutSample?
        var bestDelta = Int.max
        for s in samples {
            let d = abs(s.offsetSec - offsetSec)
            guard d < bestDelta else { continue }
            bestDelta = d
            best = s
            if d == 0 { break }
        }
        return bestDelta <= 5 ? best : nil
    }

    static func writeToTempFile(session: HRVSession, track: [CLLocation]) throws -> URL {
        let csv = export(session: session, track: track)
        let sport = session.workoutMetadata?.sport.rawValue ?? "workout"
        // Machine format: POSIX locale and Gregorian calendar, so a Buddhist-
        // or Japanese-calendar user still gets a 2026… filename.
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        let filename = "\(sport)-\(fmt.string(from: session.startDate)).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        guard let data = csv.data(using: .utf8) else {
            throw NSError(domain: "CSVExporter", code: -1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Couldn't create the CSV file.", bundle: LanguageManager.appBundle)
            ])
        }
        try data.write(to: url, options: .atomic)
        debugLog("[CSVExporter] wrote \(data.count) bytes to \(url.path)")
        return url
    }
}
