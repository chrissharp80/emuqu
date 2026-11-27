import Foundation

// MARK: - Recording CSV timeline
//
// The one-recording RR CSV the app writes (a reading's RR export, a raw
// backup) and reads back. Its columns:
//
//   timestamp_ms   when the beat starts, ms from the recording's start, on
//                  the beat timeline: two merged recordings keep their gap
//   rr_ms          the interval, ms
//   hr_bpm         60000 / rr_ms, blank for a non-positive interval
//   wall_clock_ms  when a streamed beat reached the phone, ms from the
//                  stream's start; blank for a beat the sensor recorded in
//                  its own memory. A Bluetooth dropout shows here as a jump
//                  the timestamps do not have.
//
// Kubios and spreadsheets read the rr_ms column as before, and either time
// column can serve as the time axis. An import of the file keeps both clocks
// (`statedTimeline`), so every recording break the app saw
// (`TimeDomainAnalyzer.isRecordingBreak`) is still one after the round trip,
// instead of the beats being laid end to end.

extension RRDataImporter {
    static let recordingCSVHeader = "timestamp_ms,rr_ms,hr_bpm,wall_clock_ms"

    /// The comment line an export's provenance block carries, so the file
    /// says what its last column means wherever it is opened.
    static let recordingCSVColumnNote =
        "# wall_clock_ms: arrival time of a streamed beat, ms from the stream's start; a jump past rr_ms is a dropout\n"

    /// The header and one row per beat (`recordingCSVHeader`).
    static func recordingCSV(points: [RRPoint]) -> String {
        let posix = Locale(identifier: "en_US_POSIX")
        var csv = recordingCSVHeader + "\n"
        csv.reserveCapacity(points.count * 32)
        for point in points {
            // POSIX locale: a decimal comma would split the value into two CSV fields.
            let hr = point.rr_ms > 0 ? String(format: "%.1f", locale: posix, 60000.0 / Double(point.rr_ms)) : ""
            csv += "\(point.t_ms),\(point.rr_ms),\(hr),\(point.wallClockMs.map(String.init) ?? "")\n"
        }
        return csv
    }

    /// Where a timeline file keeps each column.
    struct TimelineColumns {
        let layout: DelimitedLayout
        let timestamp: Int
        let rr: Int
        let wallClock: Int?
    }

    /// The file's own beat times: its header names a `timestamp_ms` column
    /// beside the RR one, and every beat row states a rising timestamp in
    /// `recordingTimestampRange` (and a `wall_clock_ms` in it, where the row
    /// has one) for the very beats `rrIntervals` holds. Nil otherwise: the
    /// beats are then timed by their running sum (`createSession`).
    func statedTimeline(in content: String, rrIntervals: [Int]) -> [RRPoint]? {
        let lines = Self.dataLines(of: content, quoteAware: Self.quotesPairUp(in: content)).filter { !Self.isComment($0) }
        guard let header = lines.first(where: { _ in true }),
              let columns = Self.timelineColumns(headerLine: header, rows: lines.dropFirst()) else { return nil }
        var points: [RRPoint] = []
        for line in lines.dropFirst() {
            let fields = Self.fields(of: line, separator: columns.layout.separator)
            let numbers = columns.layout.decimalComma ? fields.map(Self.withDecimalPoint) : fields
            guard let rr = Self.rrValue(fromColumns: numbers, rrColumnIndex: columns.rr, convert: convertToMilliseconds),
                  Self.storableRRRange.contains(rr) else { continue }
            guard let point = Self.timelinePoint(fields, columns: columns, rr: rr) else { return nil }
            points.append(point)
        }
        return Self.isTimeline(points, of: rrIntervals) ? points : nil
    }

    /// The columns of a header that names `timestamp_ms` and an RR column.
    static func timelineColumns(headerLine: String, rows: some Sequence<String>) -> TimelineColumns? {
        let layout = delimitedLayout(headerLine: headerLine, hasHeader: true, rows: rows)
        let names = fields(of: headerLine.lowercased(), separator: layout.separator)
        guard let timestamp = names.firstIndex(of: "timestamp_ms"),
              let rr = rrColumnIndex(inHeaderLine: headerLine, separator: layout.separator) else { return nil }
        return TimelineColumns(layout: layout, timestamp: timestamp, rr: rr, wallClock: names.firstIndex(of: "wall_clock_ms"))
    }

    /// One row's beat, or nil when its timestamp is missing or out of range,
    /// or its wall clock is written but unreadable or out of range.
    private static func timelinePoint(_ fields: [String], columns: TimelineColumns, rr: Int) -> RRPoint? {
        guard columns.timestamp < fields.count, let t = Int64(fields[columns.timestamp]),
              recordingTimestampRange.contains(t) else { return nil }
        let wallText = columns.wallClock.flatMap { $0 < fields.count ? fields[$0] : nil } ?? ""
        guard !wallText.isEmpty else { return RRPoint(t_ms: t, rr_ms: rr, wallClockMs: nil) }
        guard let wall = Int64(wallText), recordingTimestampRange.contains(wall) else { return nil }
        return RRPoint(t_ms: t, rr_ms: rr, wallClockMs: wall)
    }

    /// Whether `points` are the beats of `rrIntervals`, rising in time and
    /// ending inside one recording.
    private static func isTimeline(_ points: [RRPoint], of rrIntervals: [Int]) -> Bool {
        guard points.map(\.rr_ms) == rrIntervals, let last = points.last,
              last.endMs <= maximumRecordingSpanMs else { return false }
        return zip(points, points.dropFirst()).allSatisfy { $0.t_ms < $1.t_ms }
    }
}
