import Foundation

/// Handles importing RR interval data from various file formats
/// Supports: CSV, JSON, TXT (raw RR values), Kubios exports, EliteHRV, Emuqu multi-session formats
/// Stateless: every import runs off its arguments, so it is `Sendable`.
final class RRDataImporter: Sendable {
    // MARK: - Supported Formats

    enum ImportFormat: String, CaseIterable, Identifiable {
        case csv = "CSV"
        case json = "JSON"
        case txt = "Text (RR values)"
        case kubios = "Kubios Export"
        case eliteHRV = "Elite HRV Summary"
        case flowHRVMultiSession = "Emuqu RR Export"

        var id: String {
            rawValue
        }

        /// The format's name in the app's language. `rawValue` is the stable
        /// identifier and stays English.
        var displayName: String {
            let b = LanguageManager.appBundle
            return switch self {
            case .csv: String(localized: "CSV", bundle: b)
            case .json: String(localized: "JSON", bundle: b)
            case .txt: String(localized: "Text (RR values)", bundle: b)
            case .kubios: String(localized: "Kubios Export", bundle: b)
            case .eliteHRV: String(localized: "Elite HRV Summary", bundle: b)
            case .flowHRVMultiSession: String(localized: "Emuqu RR Export", bundle: b)
            }
        }

        /// One-line description shown in the import screen's format list.
        var description: String {
            let b = LanguageManager.appBundle
            return switch self {
            case .csv: String(localized: "Comma-separated RR intervals in milliseconds", bundle: b)
            case .json: String(localized: "JSON array of RR intervals", bundle: b)
            case .txt: String(localized: "Plain text with one RR interval per line", bundle: b)
            case .kubios: String(localized: "Kubios HRV export with raw RR data", bundle: b)
            case .eliteHRV: String(localized: "Elite HRV summary export (multiple sessions)", bundle: b)
            case .flowHRVMultiSession: String(localized: "Emuqu multi-session RR export (raw data)", bundle: b)
            }
        }
    }

    /// The widest RR value an import keeps. Anything outside it is not a beat
    /// at all (zero, negative, or "1e30" read as milliseconds) and would
    /// overflow the running time sums. Values inside it but outside the
    /// physiological range stay, for `validate` and artifact detection to
    /// judge.
    static let storableRRRange: ClosedRange<Int> = 1 ... 30_000

    static func storableRR(_ ms: Int) -> Int? {
        storableRRRange.contains(ms) ? ms : nil
    }

    /// The longest single recording an import accepts, in milliseconds: one
    /// week, longer than any reading the app records. It bounds the beat
    /// timestamps an Emuqu export states and the summed RR intervals of every
    /// other format. Past it the file is damaged or hand-made, not one
    /// recording: a timestamp near the limit of `Int64` overflows the
    /// analysis's time arithmetic, and a span of years makes the
    /// frequency-domain resample allocate memory for every second of it.
    static let maximumRecordingSpanMs: Int64 = 7 * 86_400_000

    /// Beat timestamps one recording can have: milliseconds from its start.
    static let recordingTimestampRange: ClosedRange<Int64> = 0 ... maximumRecordingSpanMs

    /// Result for Elite HRV summary import (multiple sessions with pre-computed metrics)
    struct EliteHRVSummaryResult {
        struct SessionSummary {
            let date: Date
            let rmssd: Double
            let rmssdRaw: Double
            let artifactPercent: Double
            /// Nil when the file states neither a beat count nor duration and HR.
            let beatCount: Int?
            let rrMin: Double
            let rrMax: Double
            let fileName: String
            /// The file's own SDNN (ms) and pNN50 (%), nil when it has no
            /// such column or the cell is unreadable.
            let sdnn: Double?
            let pnn50: Double?
            /// Whether `rrMin` and `rrMax` are both stated by the file rather
            /// than derived from mean HR or defaulted.
            let rrRangeStated: Bool
        }

        let sessions: [SessionSummary]
        let originalFileName: String
    }

    /// Result for Emuqu multi-session RR export (raw RR data per session)
    struct FlowHRVMultiSessionResult {
        struct SessionRRData {
            let sessionDate: String // Original session_date string (e.g. "2026-01-25_0443")
            let date: Date
            let rrIntervals: [Int] // Raw RR intervals in milliseconds
            let timestamps: [Int64] // Original timestamps
            var sessionType: SessionType? // From the session_type column; nil in older exports

            var beatCount: Int {
                rrIntervals.count
            }

            var durationMinutes: Double {
                Double(rrIntervals.reduce(0, +)) / 60000.0
            }
        }

        let sessions: [SessionRRData]
        let originalFileName: String
    }

    enum ImportError: LocalizedError {
        case fileNotFound
        case unreadableFile
        case invalidFormat(String)
        case noRRData
        case insufficientData(found: Int, required: Int)
        case invalidRRValues(String)
        /// A session's beat timestamps fall outside `recordingTimestampRange`
        /// or are not whole milliseconds. Carries the session's name.
        case invalidTimestamps(session: String)
        /// The RR intervals add up to more than `maximumRecordingSpanMs`.
        case recordingTooLong

        /// Shown to the user as the import error. The `details` payloads are
        /// localized where they are thrown.
        var errorDescription: String? {
            let b = LanguageManager.appBundle
            return switch self {
            case .fileNotFound:
                String(localized: "The selected file could not be found.", bundle: b)
            case .unreadableFile:
                String(localized: "Unable to read the file contents.", bundle: b)
            case let .invalidFormat(details):
                String(localized: "Invalid file format: \(details)", bundle: b)
            case .noRRData:
                String(localized: "No RR interval data found in file.", bundle: b)
            case let .insufficientData(found, required):
                String(localized: "Not enough data: the file has \(found) of the \(required) RR intervals needed.", bundle: b)
            case let .invalidRRValues(details):
                String(localized: "Invalid RR values: \(details)", bundle: b)
            case let .invalidTimestamps(session):
                String(localized: "Session \(session) has timestamps that cannot belong to one recording. The file may be damaged.", bundle: b)
            case .recordingTooLong:
                String(localized: "The RR intervals add up to more than a week, longer than one recording. The file may be damaged.", bundle: b)
            }
        }
    }

    struct ImportResult {
        let rrIntervals: [Int] // RR intervals in milliseconds
        let sourceFormat: ImportFormat
        let originalFileName: String
        let recordingDate: Date?
        let metadata: [String: String]

        var beatCount: Int {
            rrIntervals.count
        }

        var durationMinutes: Double {
            Double(rrIntervals.reduce(0, +)) / 60000.0
        }
    }

    // MARK: - Public API

    /// Import RR data from a file URL
    func importFile(at url: URL) async throws -> ImportResult {
        try importContent(try readFile(at: url), fileName: url.lastPathComponent)
    }

    /// The file's UTF-8 text, with its security scope held for the read. The
    /// one reader for an import: a caller that needs the text to pick a
    /// format reads it here and hands it to `importContent`, rather than
    /// reading the file twice.
    func readFile(at url: URL) throws -> String {
        guard url.startAccessingSecurityScopedResource() else {
            throw ImportError.fileNotFound
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try readUTF8(at: url)
    }

    /// Import RR data from a file's text, already read. `fileName` names the
    /// source in the result and gives the extension format detection uses.
    func importContent(_ content: String, fileName: String) throws -> ImportResult {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let format = detectFormat(content: content, extension: ext)
        let parsed = try parse(content, as: format)
        try validate(parsed.rrIntervals)
        return ImportResult(
            rrIntervals: parsed.rrIntervals,
            sourceFormat: format,
            originalFileName: fileName,
            recordingDate: parsed.recordingDate,
            metadata: parsed.metadata
        )
    }

    /// One file's worth of parsed RR data. Plain-text files carry intervals
    /// and nothing else, so metadata and date are empty for them.
    private struct ParsedRRFile {
        let rrIntervals: [Int]
        let metadata: [String: String]
        let recordingDate: Date?
    }

    private func readUTF8(at url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            debugLog("[Import] Failed to read file \(url.lastPathComponent): \(error.localizedDescription)")
            throw ImportError.unreadableFile
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw ImportError.unreadableFile
        }
        return content
    }

    private func parse(_ content: String, as format: ImportFormat) throws -> ParsedRRFile {
        switch format {
        case .json:
            let (intervals, meta, date) = try parseJSON(content)
            return ParsedRRFile(rrIntervals: intervals, metadata: meta, recordingDate: date)
        case .csv, .kubios:
            let (intervals, meta, date) = try parseCSV(content)
            return ParsedRRFile(rrIntervals: intervals, metadata: meta, recordingDate: date)
        case .txt:
            return ParsedRRFile(rrIntervals: try parsePlainText(content), metadata: [:], recordingDate: nil)
        case .eliteHRV:
            // Elite HRV summary files go through parseEliteHRVSummary instead;
            // a caller that hands one here is told so.
            throw ImportError.invalidFormat(String(localized: "Elite HRV summary format detected. Use batch import for summary files.", bundle: LanguageManager.appBundle))
        case .flowHRVMultiSession:
            // Emuqu multi-session files go through parseFlowHRVMultiSession
            // instead; a caller that hands one here is told so.
            throw ImportError.invalidFormat(String(localized: "Emuqu multi-session format detected. Use batch import for multi-session files.", bundle: LanguageManager.appBundle))
        }
    }

    /// Reject files that are empty, too short to analyze, mostly outside
    /// physiologically plausible RR range, or longer than one recording.
    /// These formats carry no timestamps: `createSession` builds them from
    /// the running RR sum, so that sum is the recording's span.
    func validate(_ rrIntervals: [Int]) throws {
        guard !rrIntervals.isEmpty else {
            throw ImportError.noRRData
        }
        let minRequired = 60 // At least 60 beats for meaningful analysis
        guard rrIntervals.count >= minRequired else {
            throw ImportError.insufficientData(found: rrIntervals.count, required: minRequired)
        }
        let rrMin = HRVConstants.RRInterval.minimum
        let rrMax = HRVConstants.RRInterval.maximum
        let invalidValues = rrIntervals.filter { $0 < rrMin || $0 > rrMax }
        if invalidValues.count > rrIntervals.count / 4 {
            throw ImportError.invalidRRValues(String(localized: "Too many values outside the normal range (\(rrMin)–\(rrMax) ms)", bundle: LanguageManager.appBundle))
        }
        let spanMs = rrIntervals.reduce(Int64(0)) { $0 + Int64($1) }
        guard spanMs <= Self.maximumRecordingSpanMs else { throw ImportError.recordingTooLong }
    }

    /// Create an HRVSession from an import result, starting at `startDate`.
    /// For a file that states no recording date (`recordingDate` nil — every
    /// CSV, Kubios and text file) the caller supplies the date the user
    /// gives: dating it now would put an old recording on today and into
    /// today's baseline.
    func createSession(from result: ImportResult, startingAt startDate: Date) -> HRVSession {
        // Build RRPoints with cumulative timestamps
        var points: [RRPoint] = []
        var currentTime: Int64 = 0
        for rr in result.rrIntervals {
            points.append(RRPoint(t_ms: currentTime, rr_ms: rr))
            currentTime += Int64(rr)
        }
        var session = HRVSession(startDate: startDate)
        session.rrSeries = RRSeries(points: points, sessionId: session.id, startDate: startDate)
        session.endDate = startDate.addingTimeInterval(Double(currentTime) / 1000.0)
        session.notes = String(localized: "Imported from \(result.originalFileName)", bundle: LanguageManager.appBundle)
        return session
    }

    // MARK: - Format Detection

    private func detectFormat(content: String, extension ext: String) -> ImportFormat {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // JSON detection
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            return .json
        }
        // CSV detection (has commas or semicolons as separators)
        guard ext == "csv" || content.contains(",") || content.contains(";") else {
            // Default to plain text
            return .txt
        }
        return detectDelimitedFormat(content: content)
    }

    /// Distinguish the delimited formats by their header line and markers.
    ///
    /// Elite HRV summary, old format: datetime,rmssd_clean_ms,rmssd_raw_ms,removed_rr_pct,n_rr,...
    /// Elite HRV summary, new format: Member,Type,...,HRV,...,Rmssd,...
    private func detectDelimitedFormat(content: String) -> ImportFormat {
        if isEliteHRVSummary(content) {
            return .eliteHRV
        }
        if isFlowHRVMultiSession(content) {
            return .flowHRVMultiSession
        }
        // Check for Kubios markers
        let lowered = content.lowercased()
        if lowered.contains("kubios") || lowered.contains("rr interval") || lowered.contains("artifact") {
            return .kubios
        }
        return .csv
    }

    /// Check if content is Elite HRV summary format
    func isEliteHRVSummary(_ content: String) -> Bool {
        let firstLine = content.components(separatedBy: .newlines).first?.lowercased() ?? ""
        // Old format: rmssd_clean, rmssd_raw, n_rr columns
        // New format: Member, Type, Rmssd, lnRmssd, HRV, HR columns
        return firstLine.contains("rmssd_clean") || firstLine.contains("rmssd_raw") ||
            (firstLine.contains("datetime") && firstLine.contains("rmssd") && firstLine.contains("n_rr")) ||
            (firstLine.contains("member") && firstLine.contains("rmssd") && firstLine.contains("hrv"))
    }

    /// Check if content is Emuqu multi-session RR export format
    /// Format: session_date,timestamp_ms,rr_ms
    func isFlowHRVMultiSession(_ content: String) -> Bool {
        let firstLine = content.components(separatedBy: .newlines).first?.lowercased() ?? ""
        return firstLine.contains("session_date") &&
            firstLine.contains("timestamp_ms") &&
            firstLine.contains("rr_ms")
    }
}
