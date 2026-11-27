import Foundation

// MARK: - Emuqu Multi-Session Parsing

extension RRDataImporter {
    // MARK: - Emuqu Multi-Session Parsing

    /// One exported beat: its `timestamp_ms`, its `rr_ms`, its
    /// `wall_clock_ms` when the row states one, and its
    /// `follows_removed_beat` mark.
    struct ExportedBeat {
        let timestamp: Int64
        let rr: Int
        let wallClockMs: Int64?
        let followsRemovedBeat: Bool
    }

    /// Parse Emuqu multi-session RR export
    /// Format: session_date,timestamp_ms,rr_ms[,session_type[,wall_clock_ms]][,session_id]
    /// Each session_date value (an exact instant with its UTC offset) is one
    /// recording, split further where its timestamps restart
    /// (`legacyRecordingSegments`): a legacy minute-only date can name more
    /// than one. A session_id column, which no exporter writes, groups rows
    /// by id when present.
    /// Workouts are skipped: their exercise RR is not a resting reading and
    /// the export carries none of their workout details.
    func parseFlowHRVMultiSession(_ content: String, fileName: String) throws -> FlowHRVMultiSessionResult {
        let lines = Self.dataLines(of: content, quoteAware: false)
        guard let headerLine = lines.first(where: { _ in true }), lines.dropFirst().contains(where: { _ in true }) else {
            throw ImportError.noRRData
        }
        let columns = try Self.flowHRVColumns(fromHeaderLine: headerLine)
        let sessions = try flowHRVSessions(dataLines: lines.dropFirst(), columns: columns)
        guard !sessions.isEmpty else {
            throw ImportError.noRRData
        }
        return FlowHRVMultiSessionResult(sessions: sessions, originalFileName: fileName)
    }

    /// Every importable session in the file, oldest first.
    private func flowHRVSessions(
        dataLines: some Sequence<String>,
        columns: FlowHRVColumns
    ) throws -> [FlowHRVMultiSessionResult.SessionRRData] {
        let sessionGroups = try Self.groupBeatsBySession(dataLines: dataLines, columns: columns)
        let sessionTypes = Self.sessionTypesBySession(dataLines: dataLines, columns: columns)
        logSessionGroups(sessionGroups)
        let dateFormatter = Self.flowHRVSessionDateFormatter()
        return sessionGroups
            .filter { Self.isImportableType(sessionTypes[$0.key], sessionDateStr: $0.key.sessionDate) }
            .flatMap { group in
                flowHRVRecordings(key: group.key, points: group.value, sessionType: sessionTypes[group.key], formatter: dateFormatter)
            }
            .sorted { $0.date < $1.date }
    }

    /// The recordings one group of rows holds. A group keyed by `session_id`
    /// is one recording. A group keyed by `session_date` alone can hold
    /// several recordings when the date is a legacy local minute (the two
    /// 01:30s of a night the clocks go back, or a reading restarted within a
    /// minute): each one is kept apart, never merged.
    private func flowHRVRecordings(
        key: FlowHRVRecordingKey,
        points: [ExportedBeat],
        sessionType: SessionType?,
        formatter: DateFormatter
    ) -> [FlowHRVMultiSessionResult.SessionRRData] {
        let segments = key.sessionID == nil ? Self.legacyRecordingSegments(points) : [points]
        guard segments.count > 1 else {
            return [flowHRVSession(sessionDateStr: key.sessionDate, points: points, sessionType: sessionType, formatter: formatter)]
                .compactMap { $0 }
        }
        debugLog("[RRDataImporter] '\(key.sessionDate)' holds \(segments.count) recordings; importing each on its own")
        let starts = Self.legacySegmentStarts(key.sessionDate, segments: segments, formatter: formatter)
        return zip(segments, starts).compactMap { segment, start in
            flowHRVSession(sessionDateStr: key.sessionDate, points: segment, sessionType: sessionType, start: start)
        }
    }

    private func logSessionGroups(_ sessionGroups: [FlowHRVRecordingKey: [ExportedBeat]]) {
        debugLog("[RRDataImporter] Found \(sessionGroups.count) unique sessions:")
        for (key, points) in sessionGroups {
            debugLog("[RRDataImporter]   '\(key.sessionDate)' -> \(points.count) RR intervals")
        }
    }

    // MARK: - parseFlowHRVMultiSession helpers
    //
    // Kept out of the parser body to hold its cyclomatic complexity down.

    /// A session is only worth importing once it has enough beats for the
    /// analysis pipeline to produce anything meaningful.
    private static let minimumBeatsPerSession = 60

    /// Column layout of an Emuqu multi-session export. `timestamp`,
    /// `sessionType`, `wallClock` and `sessionID` are optional because older
    /// exports omit them.
    struct FlowHRVColumns {
        let session: Int
        let timestamp: Int?
        let rr: Int
        var sessionType: Int?
        var sessionID: Int?
        var wallClock: Int?
        var removedBeat: Int?
    }

    /// Which recording a row belongs to: its `session_date`, or its
    /// `session_id` when a file carries that column.
    struct FlowHRVRecordingKey: Hashable {
        let sessionDate: String
        let sessionID: String?

        init(sessionDate: String, sessionID: String? = nil) {
            self.sessionDate = sessionDate
            self.sessionID = sessionID
        }

        init(fields: [String], columns: FlowHRVColumns) {
            let id = columns.sessionID.flatMap { $0 < fields.count ? fields[$0] : nil }
            self.init(sessionDate: fields[columns.session], sessionID: id?.isEmpty == false ? id : nil)
        }
    }

    static func flowHRVColumns(fromHeaderLine line: String) throws -> FlowHRVColumns {
        // Empty fields kept, as in the rows, so an index names one column in both.
        let headers = Self.fields(of: line.lowercased(), separator: ",")
        let column = { (name: String) in headers.lastIndex { $0.contains(name) } }
        guard let session = column("session_date"), let rr = column("rr_ms") else {
            throw ImportError.invalidFormat(String(localized: "Emuqu format requires session_date and rr_ms columns", bundle: LanguageManager.appBundle))
        }
        return FlowHRVColumns(
            session: session, timestamp: column("timestamp_ms"), rr: rr,
            sessionType: column("session_type"), sessionID: column("session_id"), wallClock: column("wall_clock_ms"),
            removedBeat: column("follows_removed_beat")
        )
    }

    /// The `session_type` each session was exported with, keyed by its
    /// recording. Empty for older exports without the column.
    static func sessionTypesBySession(
        dataLines: some Sequence<String>,
        columns: FlowHRVColumns
    ) -> [FlowHRVRecordingKey: SessionType] {
        guard let typeIndex = columns.sessionType else { return [:] }
        var types: [FlowHRVRecordingKey: SessionType] = [:]
        for line in dataLines {
            let fields = Self.fields(of: line, separator: ",")
            guard fields.count > max(columns.session, typeIndex),
                  let type = SessionType(rawValue: fields[typeIndex]) else { continue }
            types[FlowHRVRecordingKey(fields: fields, columns: columns)] = type
        }
        return types
    }

    /// Workouts are not brought back: as an RR series alone they would read
    /// as a resting reading and feed the baseline.
    private static func isImportableType(_ type: SessionType?, sessionDateStr: String) -> Bool {
        guard type == .workout else { return true }
        debugLog("[RRDataImporter] Skipping '\(sessionDateStr)' - workout session")
        return false
    }

    /// The most beats a multi-session import reads: `maxFileBytes` of the
    /// shortest row any export writes for a beat, a 15-character session
    /// date, a comma, a one-digit RR and a line break (18 bytes), so about
    /// 14.9 million.
    static let maxExportBeats = maxFileBytes / 18

    /// Groups beats by recording (`FlowHRVRecordingKey`), in file order. Throws
    /// `invalidTimestamps` for the first beat whose timestamp cannot belong
    /// to one recording: the file is damaged or hand-made, and nothing in it
    /// can be trusted to be what was recorded. Throws `.tooLarge`, without
    /// reading further, at a session past `maxBeatsPerRecording` beats or a
    /// file past `maxExportBeats`. Beats are kept across the whole
    /// `storableRRRange`, as the archive stored them; values outside the
    /// physiological range are for artifact detection to judge.
    static func groupBeatsBySession(
        dataLines: some Sequence<String>,
        columns: FlowHRVColumns,
        maxBeatsPerSession: Int = maxBeatsPerRecording
    ) throws -> [FlowHRVRecordingKey: [ExportedBeat]] {
        var groups: [FlowHRVRecordingKey: [ExportedBeat]] = [:]
        var total = 0
        for line in dataLines {
            let fields = Self.fields(of: line, separator: ",")
            guard fields.count > max(columns.session, columns.rr) else { continue }
            let sessionKey = FlowHRVRecordingKey(fields: fields, columns: columns)
            guard let rrValue = Int(fields[columns.rr]).flatMap(storableRR) else { continue }
            total += 1
            guard total <= maxExportBeats, groups[sessionKey, default: []].count < maxBeatsPerSession else {
                throw ImportError.tooLarge
            }
            let timestamp = try beatTimestamp(
                sessionKey: sessionKey, fields: fields, columns: columns, groups: groups
            )
            let beat = try exportedBeat(fields, columns: columns, session: sessionKey.sessionDate, timestamp: timestamp, rr: rrValue)
            groups[sessionKey, default: []].append(beat)
        }
        return groups
    }

    /// The row's own `timestamp_ms` when the export carries one; otherwise a
    /// timestamp synthesised by walking the running RR sum for that session,
    /// which is why this reads `groups` as it is being built. Either way it
    /// must lie in `recordingTimestampRange`, milliseconds from the start of
    /// one recording as the exporter writes them. Outside it, a timestamp
    /// near the limit of `Int64` overflows the analysis's time arithmetic,
    /// and epoch and relative timestamps mixed in one session make a span of
    /// decades the frequency-domain resample would try to fill. Sessions are
    /// sorted by timestamp afterwards, so each series is in time order.
    private static func beatTimestamp(
        sessionKey: FlowHRVRecordingKey,
        fields: [String],
        columns: FlowHRVColumns,
        groups: [FlowHRVRecordingKey: [ExportedBeat]]
    ) throws -> Int64 {
        let timestamp = try statedTimestamp(sessionKey: sessionKey.sessionDate, fields: fields, columns: columns)
            ?? synthesisedTimestamp(after: groups[sessionKey]?.last)
        guard recordingTimestampRange.contains(timestamp) else {
            throw ImportError.invalidTimestamps(session: String(sessionKey.sessionDate.prefix(40)))
        }
        return timestamp
    }

    /// The row's `timestamp_ms`, or nil when the export has no such column,
    /// or the row stops short of it or leaves it blank. A value that is not whole milliseconds
    /// ("1e30", "nan", "12.5") is an error, not a missing timestamp.
    private static func statedTimestamp(sessionKey: String, fields: [String], columns: FlowHRVColumns) throws -> Int64? {
        guard let tsIdx = columns.timestamp, tsIdx < fields.count, !fields[tsIdx].isEmpty else { return nil }
        guard let timestamp = Int64(fields[tsIdx]) else {
            throw ImportError.invalidTimestamps(session: String(sessionKey.prefix(40)))
        }
        return timestamp
    }

    /// One row's beat: its timestamp and RR, its `wall_clock_ms`
    /// (`statedWallClock`) and its `follows_removed_beat` mark.
    private static func exportedBeat(
        _ fields: [String], columns: FlowHRVColumns, session: String, timestamp: Int64, rr: Int
    ) throws -> ExportedBeat {
        let wallClock = try statedWallClock(sessionKey: session, fields: fields, columns: columns)
        let removed = statesRemovedBeat(fields, column: columns.removedBeat)
        return ExportedBeat(timestamp: timestamp, rr: rr, wallClockMs: wallClock, followsRemovedBeat: removed)
    }

    /// The row's `wall_clock_ms`, or nil when the export has no such column
    /// or the cell is blank (a beat the sensor recorded itself). Like the
    /// timestamp, a value that is not whole milliseconds in
    /// `recordingTimestampRange` is an error.
    private static func statedWallClock(sessionKey: String, fields: [String], columns: FlowHRVColumns) throws -> Int64? {
        guard let index = columns.wallClock, index < fields.count, !fields[index].isEmpty else { return nil }
        guard let wallClock = Int64(fields[index]), recordingTimestampRange.contains(wallClock) else {
            throw ImportError.invalidTimestamps(session: String(sessionKey.prefix(40)))
        }
        return wallClock
    }

    /// The beat after `lastPoint` starts when `lastPoint` ends; the first
    /// beat at zero. `lastPoint.timestamp` has passed the range check, so the
    /// sum cannot overflow.
    private static func synthesisedTimestamp(after lastPoint: ExportedBeat?) -> Int64 {
        guard let lastPoint else { return 0 }
        return lastPoint.timestamp + Int64(lastPoint.rr)
    }

    /// The header row of an Emuqu RR export. `session_date` is the
    /// recording's start as an ISO 8601 instant with the exporting phone's UTC
    /// offset, which names the recording: two recordings at the same clock
    /// time on a night the clocks go back carry different offsets.
    /// `timestamp_ms` is the beat's start on the recording's beat timeline and
    /// `wall_clock_ms` when a streamed beat reached the phone, blank for one
    /// the sensor recorded itself, and `follows_removed_beat` 1 for a beat
    /// the sensor removed an interval before: the columns of the
    /// one-recording export (`recordingCSVHeader`), and read back the same way.
    static let emuquRRExportHeader = "session_date,timestamp_ms,rr_ms,session_type,wall_clock_ms,follows_removed_beat"

    /// A recording's start as the exporter writes it in `session_date`:
    /// ISO 8601 to the second with the UTC offset of `timeZone`, e.g.
    /// `2026-11-01T01:30:15-04:00`, one instant wherever it is read.
    static func emuquRRExportSessionDate(_ start: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: start)
    }

    /// Legacy session-date format, written by older exporters, e.g.
    /// `2026-01-25_0443`: local time to the minute, with no offset.
    static func flowHRVSessionDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    /// When a session started, from its `session_date`: an ISO 8601 instant
    /// with its UTC offset (`2026-11-01T01:30:15-04:00`, what the exporter
    /// writes), read exactly whatever time zone the importing phone is in;
    /// or the legacy `yyyy-MM-dd_HHmm` (to the minute, no offset), read in
    /// the importing phone's time zone.
    static func flowHRVSessionStart(_ text: String, formatter: DateFormatter) -> Date? {
        formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// A legacy group's rows split into recordings, in file order. Each
    /// recording's `timestamp_ms` counts up from its own start, so a row
    /// whose timestamp does not move past the row before it begins another
    /// recording: sorting the two together would interleave their beats.
    static func legacyRecordingSegments(
        _ points: [ExportedBeat]
    ) -> [[ExportedBeat]] {
        var segments: [[ExportedBeat]] = []
        for point in points {
            if let last = segments.last?.last, point.timestamp > last.timestamp {
                segments[segments.count - 1].append(point)
            } else {
                segments.append([point])
            }
        }
        return segments
    }

    /// Where each recording of a legacy group starts. The group's local
    /// minute can name more than one instant (the two 01:30s of a night the
    /// clocks go back), so each recording takes the earliest such instant
    /// that is not before the recording ahead of it ends, or that end when
    /// none is left. Empty when the session date does not parse.
    static func legacySegmentStarts(
        _ text: String,
        segments: [[ExportedBeat]],
        formatter: DateFormatter
    ) -> [Date] {
        guard let parsed = flowHRVSessionStart(text, formatter: formatter) else { return [] }
        let candidates = localMinuteInstants(text, near: parsed, formatter: formatter)
        var earliest = candidates[0]
        var starts: [Date] = []
        for segment in segments {
            let start = candidates.first { $0 >= earliest } ?? earliest
            starts.append(start)
            let spanMs = (segment.last.map { $0.timestamp + Int64($0.rr) } ?? 0) - (segment.first?.timestamp ?? 0)
            earliest = start.addingTimeInterval(Double(spanMs) / 1000.0)
        }
        return starts
    }

    /// Every instant, oldest first, that `formatter` writes as `text`: the
    /// parsed one, and the one a daylight-saving shift away when the clocks
    /// went back through that minute.
    private static func localMinuteInstants(_ text: String, near parsed: Date, formatter: DateFormatter) -> [Date] {
        let shifts: [TimeInterval] = [-3_600, -1_800, 0, 1_800, 3_600]
        return shifts.map { parsed.addingTimeInterval($0) }
            .filter { $0 == parsed || formatter.string(from: $0) == text }
    }

    /// Builds one session, or nil when it is too short to be worth importing
    /// or its session date doesn't parse. An undated session is skipped
    /// rather than dated now, which would put it on today and into today's
    /// baseline.
    private func flowHRVSession(
        sessionDateStr: String,
        points: [ExportedBeat],
        sessionType: SessionType?,
        formatter: DateFormatter
    ) -> FlowHRVMultiSessionResult.SessionRRData? {
        guard let parsedDate = Self.flowHRVSessionStart(sessionDateStr, formatter: formatter) else {
            debugLog("[RRDataImporter] Skipping '\(sessionDateStr)' - session date does not parse")
            return nil
        }
        debugLog("[RRDataImporter] Parsed '\(sessionDateStr)' -> \(parsedDate)")
        return flowHRVSession(sessionDateStr: sessionDateStr, points: points, sessionType: sessionType, start: parsedDate)
    }

    /// One recording starting at `start`, its beats in time order, or nil
    /// when it is too short to be worth importing.
    private func flowHRVSession(
        sessionDateStr: String,
        points: [ExportedBeat],
        sessionType: SessionType?,
        start: Date
    ) -> FlowHRVMultiSessionResult.SessionRRData? {
        guard points.count >= Self.minimumBeatsPerSession else {
            debugLog("[RRDataImporter] Skipping '\(sessionDateStr)' - only \(points.count) beats (need \(Self.minimumBeatsPerSession))")
            return nil
        }
        // Ties keep the file's order: a composite an earlier build exported
        // stamped a streamed batch's beats with one time.
        let sortedPoints = points.enumerated()
            .sorted { ($0.element.timestamp, $0.offset) < ($1.element.timestamp, $1.offset) }
            .map(\.element)
        return FlowHRVMultiSessionResult.SessionRRData(
            sessionDate: sessionDateStr,
            date: start,
            rrIntervals: sortedPoints.map(\.rr),
            timestamps: sortedPoints.map(\.timestamp),
            sessionType: sessionType,
            wallClocks: sortedPoints.map(\.wallClockMs),
            removedBeats: sortedPoints.map(\.followsRemovedBeat)
        )
    }

    /// Create an HRVSession from Emuqu RR data (requires full analysis).
    /// Its type is the one it was exported with; exports from before the
    /// `session_type` column carried none and come back as overnights.
    func createSessionFromFlowHRVData(_ sessionData: FlowHRVMultiSessionResult.SessionRRData, originalFileName: String) -> HRVSession {
        // `rrIntervals`, `timestamps` and `wallClocks` are built from the same
        // sorted beats, so they pair up one to one.
        let points = Self.spreadingSharedTimes(sessionData.timestamps.indices.map { i in
            RRPoint(
                t_ms: sessionData.timestamps[i], rr_ms: sessionData.rrIntervals[i],
                wallClockMs: sessionData.wallClock(at: i), followsRemovedBeat: sessionData.followsRemovedBeat(at: i)
            )
        })
        var session = HRVSession(startDate: sessionData.date, sessionType: sessionData.sessionType ?? .overnight)
        session.rrSeries = RRSeries(points: points, sessionId: session.id, startDate: sessionData.date)
        // Where the last beat ends on the exported timeline, which runs past
        // the sum of the intervals when the recording has gaps.
        let endMs = points.last?.endMs ?? 0
        session.endDate = sessionData.date.addingTimeInterval(Double(endMs) / 1000.0)
        session.notes = String(localized: "Imported from Emuqu: \(originalFileName)\nOriginal session: \(sessionData.sessionDate)", bundle: LanguageManager.appBundle)
        return session
    }
}
