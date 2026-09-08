import Foundation

// MARK: - Emuqu Multi-Session Parsing

extension RRDataImporter {
    // MARK: - Emuqu Multi-Session Parsing

    /// Parse Emuqu multi-session RR export
    /// Format: session_date,timestamp_ms,rr_ms
    /// Each session_date value represents a different recording session
    func parseFlowHRVMultiSession(_ content: String, fileName: String) throws -> FlowHRVMultiSessionResult {
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let headerLine = lines.first, lines.count >= 2 else {
            throw ImportError.noRRData
        }
        let columns = try Self.flowHRVColumns(fromHeaderLine: headerLine)
        let sessionGroups = Self.groupBeatsBySession(dataLines: lines.dropFirst(), columns: columns)
        logSessionGroups(sessionGroups)
        let dateFormatter = Self.flowHRVSessionDateFormatter()
        let sessions = sessionGroups
            .compactMap { flowHRVSession(sessionDateStr: $0.key, points: $0.value, formatter: dateFormatter) }
            // Sort sessions by date (oldest first)
            .sorted { $0.date < $1.date }
        guard !sessions.isEmpty else {
            throw ImportError.noRRData
        }
        return FlowHRVMultiSessionResult(sessions: sessions, originalFileName: fileName)
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

    /// Column layout of an Emuqu multi-session export. `timestamp` is
    /// optional because older exports omit the column entirely.
    struct FlowHRVColumns {
        let session: Int
        let timestamp: Int?
        let rr: Int
    }

    static func flowHRVColumns(fromHeaderLine line: String) throws -> FlowHRVColumns {
        let headers = line.lowercased().split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }

        var session: Int?
        var timestamp: Int?
        var rr: Int?
        for (index, header) in headers.enumerated() {
            if header.contains("session_date") {
                session = index
            } else if header.contains("timestamp_ms") {
                timestamp = index
            } else if header.contains("rr_ms") {
                rr = index
            }
        }

        guard let session, let rr else {
            throw ImportError.invalidFormat("Emuqu format requires session_date and rr_ms columns")
        }
        return FlowHRVColumns(session: session, timestamp: timestamp, rr: rr)
    }

    /// Groups beats by their `session_date` value.
    static func groupBeatsBySession(
        dataLines: ArraySlice<String>,
        columns: FlowHRVColumns
    ) -> [String: [(timestamp: Int64, rr: Int)]] {
        var groups: [String: [(timestamp: Int64, rr: Int)]] = [:]
        for line in dataLines {
            let fields = line.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard fields.count > max(columns.session, columns.rr) else { continue }

            let sessionKey = fields[columns.session]
            guard let rrValue = Int(fields[columns.rr]),
                  HRVConstants.RRInterval.isValid(rrValue)
            else { continue }

            let timestamp = synthesisedTimestamp(
                sessionKey: sessionKey, fields: fields, columns: columns, groups: groups
            )
            groups[sessionKey, default: []].append((timestamp: timestamp, rr: rrValue))
        }
        return groups
    }

    /// The row's own `timestamp_ms` when the export carries one; otherwise a
    /// timestamp synthesised by walking the running RR sum for that session,
    /// which is why this reads `groups` as it is being built.
    private static func synthesisedTimestamp(
        sessionKey: String,
        fields: [String],
        columns: FlowHRVColumns,
        groups: [String: [(timestamp: Int64, rr: Int)]]
    ) -> Int64 {
        if let tsIdx = columns.timestamp, tsIdx < fields.count, let ts = Int64(fields[tsIdx]) {
            return ts
        }
        guard let lastPoint = groups[sessionKey]?.last else { return 0 }
        return lastPoint.timestamp + Int64(lastPoint.rr)
    }

    /// Session-date format used by the exporter, e.g. `2026-01-25_0443`.
    static func flowHRVSessionDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    /// Builds one session, or nil when it is too short to be worth importing.
    /// An unparseable session date falls back to "now" rather than dropping
    /// the beats, which is the pre-existing behaviour.
    private func flowHRVSession(
        sessionDateStr: String,
        points: [(timestamp: Int64, rr: Int)],
        formatter: DateFormatter
    ) -> FlowHRVMultiSessionResult.SessionRRData? {
        guard points.count >= Self.minimumBeatsPerSession else {
            debugLog("[RRDataImporter] Skipping '\(sessionDateStr)' - only \(points.count) beats (need \(Self.minimumBeatsPerSession))")
            return nil
        }
        let parsedDate = formatter.date(from: sessionDateStr)
        if let parsedDate {
            debugLog("[RRDataImporter] Parsed '\(sessionDateStr)' -> \(parsedDate)")
        } else {
            debugLog("[RRDataImporter] WARNING: Failed to parse date '\(sessionDateStr)', using current time")
        }
        // Sort by timestamp to ensure correct order
        let sortedPoints = points.sorted { $0.timestamp < $1.timestamp }
        return FlowHRVMultiSessionResult.SessionRRData(
            sessionDate: sessionDateStr,
            date: parsedDate ?? Date(),
            rrIntervals: sortedPoints.map(\.rr),
            timestamps: sortedPoints.map(\.timestamp)
        )
    }

    /// Create an HRVSession from Emuqu RR data (requires full analysis)
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
        var session = HRVSession(startDate: sessionData.date)
        session.rrSeries = series
        session.endDate = sessionData.date.addingTimeInterval(Double(durationMs) / 1000.0)
        session.notes = "Imported from Emuqu: \(originalFileName)\nOriginal session: \(sessionData.sessionDate)"

        return session
    }
}
