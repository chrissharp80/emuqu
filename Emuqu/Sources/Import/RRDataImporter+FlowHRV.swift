import Foundation

// MARK: - Emuqu Multi-Session Parsing

extension RRDataImporter {
    // MARK: - Emuqu Multi-Session Parsing

    /// Parse Emuqu multi-session RR export
    /// Format: session_date,timestamp_ms,rr_ms[,session_type]
    /// Each session_date value represents a different recording session.
    /// Workouts are skipped: their exercise RR is not a resting reading and
    /// the export carries none of their workout details.
    func parseFlowHRVMultiSession(_ content: String, fileName: String) throws -> FlowHRVMultiSessionResult {
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let headerLine = lines.first, lines.count >= 2 else {
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
        dataLines: ArraySlice<String>,
        columns: FlowHRVColumns
    ) throws -> [FlowHRVMultiSessionResult.SessionRRData] {
        let sessionGroups = try Self.groupBeatsBySession(dataLines: dataLines, columns: columns)
        let sessionTypes = Self.sessionTypesBySession(dataLines: dataLines, columns: columns)
        logSessionGroups(sessionGroups)
        let dateFormatter = Self.flowHRVSessionDateFormatter()
        return sessionGroups
            .filter { Self.isImportableType(sessionTypes[$0.key], sessionDateStr: $0.key) }
            .compactMap { group in
                flowHRVSession(
                    sessionDateStr: group.key, points: group.value,
                    sessionType: sessionTypes[group.key], formatter: dateFormatter
                )
            }
            .sorted { $0.date < $1.date }
    }

    private func logSessionGroups(_ sessionGroups: [String: [(timestamp: Int64, rr: Int)]]) {
        debugLog("[RRDataImporter] Found \(sessionGroups.count) unique session_date values:")
        for (sessionDateStr, points) in sessionGroups {
            debugLog("[RRDataImporter]   '\(sessionDateStr)' -> \(points.count) RR intervals")
        }
    }

    // MARK: - parseFlowHRVMultiSession helpers
    //
    // Kept out of the parser body to hold its cyclomatic complexity down.

    /// A session is only worth importing once it has enough beats for the
    /// analysis pipeline to produce anything meaningful.
    private static let minimumBeatsPerSession = 60

    /// Column layout of an Emuqu multi-session export. `timestamp` and
    /// `sessionType` are optional because older exports omit them.
    struct FlowHRVColumns {
        let session: Int
        let timestamp: Int?
        let rr: Int
        var sessionType: Int?
    }

    static func flowHRVColumns(fromHeaderLine line: String) throws -> FlowHRVColumns {
        let headers = line.lowercased().split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        let column = { (name: String) in headers.lastIndex { $0.contains(name) } }
        guard let session = column("session_date"), let rr = column("rr_ms") else {
            throw ImportError.invalidFormat(String(localized: "Emuqu format requires session_date and rr_ms columns", bundle: LanguageManager.appBundle))
        }
        return FlowHRVColumns(
            session: session, timestamp: column("timestamp_ms"), rr: rr, sessionType: column("session_type")
        )
    }

    /// The `session_type` each session was exported with, keyed by its
    /// `session_date`. Empty for older exports without the column.
    static func sessionTypesBySession(
        dataLines: ArraySlice<String>,
        columns: FlowHRVColumns
    ) -> [String: SessionType] {
        guard let typeIndex = columns.sessionType else { return [:] }
        var types: [String: SessionType] = [:]
        for line in dataLines {
            let fields = line.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard fields.count > max(columns.session, typeIndex),
                  let type = SessionType(rawValue: fields[typeIndex]) else { continue }
            types[fields[columns.session]] = type
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

    /// Groups beats by their `session_date` value. Throws
    /// `invalidTimestamps` for the first beat whose timestamp cannot belong
    /// to one recording: the file is damaged or hand-made, and nothing in it
    /// can be trusted to be what was recorded.
    static func groupBeatsBySession(
        dataLines: ArraySlice<String>,
        columns: FlowHRVColumns
    ) throws -> [String: [(timestamp: Int64, rr: Int)]] {
        var groups: [String: [(timestamp: Int64, rr: Int)]] = [:]
        for line in dataLines {
            let fields = line.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard fields.count > max(columns.session, columns.rr) else { continue }

            let sessionKey = fields[columns.session]
            guard let rrValue = Int(fields[columns.rr]),
                  HRVConstants.RRInterval.isValid(rrValue)
            else { continue }

            let timestamp = try beatTimestamp(
                sessionKey: sessionKey, fields: fields, columns: columns, groups: groups
            )
            groups[sessionKey, default: []].append((timestamp: timestamp, rr: rrValue))
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
        sessionKey: String,
        fields: [String],
        columns: FlowHRVColumns,
        groups: [String: [(timestamp: Int64, rr: Int)]]
    ) throws -> Int64 {
        let timestamp = try statedTimestamp(sessionKey: sessionKey, fields: fields, columns: columns)
            ?? synthesisedTimestamp(after: groups[sessionKey]?.last)
        guard recordingTimestampRange.contains(timestamp) else {
            throw ImportError.invalidTimestamps(session: String(sessionKey.prefix(40)))
        }
        return timestamp
    }

    /// The row's `timestamp_ms`, or nil when the export has no such column
    /// or the row stops short of it. A value that is not whole milliseconds
    /// ("1e30", "nan", "12.5") is an error, not a missing timestamp.
    private static func statedTimestamp(sessionKey: String, fields: [String], columns: FlowHRVColumns) throws -> Int64? {
        guard let tsIdx = columns.timestamp, tsIdx < fields.count else { return nil }
        guard let timestamp = Int64(fields[tsIdx]) else {
            throw ImportError.invalidTimestamps(session: String(sessionKey.prefix(40)))
        }
        return timestamp
    }

    /// The beat after `lastPoint` starts when `lastPoint` ends; the first
    /// beat at zero. `lastPoint.timestamp` has passed the range check, so the
    /// sum cannot overflow.
    private static func synthesisedTimestamp(after lastPoint: (timestamp: Int64, rr: Int)?) -> Int64 {
        guard let lastPoint else { return 0 }
        return lastPoint.timestamp + Int64(lastPoint.rr)
    }

    /// Session-date format used by the exporter, e.g. `2026-01-25_0443`.
    static func flowHRVSessionDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    /// Builds one session, or nil when it is too short to be worth importing
    /// or its session date doesn't parse. An undated session is skipped
    /// rather than dated now, which would put it on today and into today's
    /// baseline.
    private func flowHRVSession(
        sessionDateStr: String,
        points: [(timestamp: Int64, rr: Int)],
        sessionType: SessionType?,
        formatter: DateFormatter
    ) -> FlowHRVMultiSessionResult.SessionRRData? {
        guard points.count >= Self.minimumBeatsPerSession else {
            debugLog("[RRDataImporter] Skipping '\(sessionDateStr)' - only \(points.count) beats (need \(Self.minimumBeatsPerSession))")
            return nil
        }
        guard let parsedDate = formatter.date(from: sessionDateStr) else {
            debugLog("[RRDataImporter] Skipping '\(sessionDateStr)' - session date does not parse")
            return nil
        }
        debugLog("[RRDataImporter] Parsed '\(sessionDateStr)' -> \(parsedDate)")
        // Sort by timestamp to ensure correct order
        let sortedPoints = points.sorted { $0.timestamp < $1.timestamp }
        return FlowHRVMultiSessionResult.SessionRRData(
            sessionDate: sessionDateStr,
            date: parsedDate,
            rrIntervals: sortedPoints.map(\.rr),
            timestamps: sortedPoints.map(\.timestamp),
            sessionType: sessionType
        )
    }

    /// Create an HRVSession from Emuqu RR data (requires full analysis).
    /// Its type is the one it was exported with; exports from before the
    /// `session_type` column carried none and come back as overnights.
    func createSessionFromFlowHRVData(_ sessionData: FlowHRVMultiSessionResult.SessionRRData, originalFileName: String) -> HRVSession {
        // Build RRPoints with original timestamps
        var points: [RRPoint] = []
        for (index, rr) in sessionData.rrIntervals.enumerated() {
            let timestamp = index < sessionData.timestamps.count ? sessionData.timestamps[index] : Int64(index) * Int64(rr)
            points.append(RRPoint(t_ms: timestamp, rr_ms: rr))
        }

        let series = RRSeries(
            points: points,
            sessionId: UUID(),
            startDate: sessionData.date
        )

        let durationMs = sessionData.rrIntervals.reduce(0, +)
        var session = HRVSession(startDate: sessionData.date, sessionType: sessionData.sessionType ?? .overnight)
        session.rrSeries = series
        session.endDate = sessionData.date.addingTimeInterval(Double(durationMs) / 1000.0)
        session.notes = String(localized: "Imported from Emuqu: \(originalFileName)\nOriginal session: \(sessionData.sessionDate)", bundle: LanguageManager.appBundle)

        return session
    }
}
