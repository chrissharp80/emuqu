import Foundation

// MARK: - CSV & Text Parsing

extension RRDataImporter {
    // MARK: - CSV Parsing

    /// The metadata and date slots are part of the tuple contract this importer
    /// shares with the other parsers; the CSV path has nowhere to read them
    /// from and has always returned them empty. Preserved rather than changed,
    /// because the signature is shared.
    func parseCSV(_ content: String) throws -> ([Int], [String: String], Date?) {
        // Comments go before the header is looked for, so a leading comment
        // is never taken for the header and the RR column is still found.
        let lines = Self.recordLines(of: content, quoteAware: csvRecords)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !Self.isComment($0) }
        guard let headerLine = lines.first else {
            throw ImportError.noRRData
        }
        let separator = Self.detectSeparator(firstLine: headerLine)
        let hasHeader = Self.looksLikeHeader(headerLine)
        let rrColumn = hasHeader
            ? Self.rrColumnIndex(inHeaderLine: headerLine, separator: separator)
            : nil
        let values = rrValues(
            from: lines.dropFirst(hasHeader ? 1 : 0), separator: separator, rrColumn: rrColumn
        )
        return (values, [:], nil)
    }

    /// The RR column of each data line, in milliseconds.
    private func rrValues(from lines: ArraySlice<String>, separator: Character, rrColumn: Int?) -> [Int] {
        lines
            .compactMap { line -> Int? in
                let columns = Self.fields(of: line, separator: separator)
                return Self.rrValue(fromColumns: columns, rrColumnIndex: rrColumn, convert: convertToMilliseconds)
            }
            // Zero, negative or absurd values ("1e30") are not beats, and
            // would overflow the running time sums downstream.
            .filter { Self.storableRRRange.contains($0) }
    }

    // MARK: - parseCSV helpers

    /// The file's records. Quote-aware only when its quotes pair up: one
    /// stray `"` (in a comment, a device name) would otherwise make every
    /// line after it one record and import nothing, so an odd count splits
    /// on plain line breaks.
    static func recordLines(of content: String, quoteAware: (String) -> [String]) -> [String] {
        guard content.count(where: { $0 == "\"" }).isMultiple(of: 2) else {
            return content.components(separatedBy: .newlines)
        }
        return quoteAware(content)
    }

    /// A `#` or `//` comment line, which no CSV or text format here reads.
    static func isComment(_ line: String) -> Bool {
        line.hasPrefix("#") || line.hasPrefix("//")
    }
    //
    // All four are
    // pure and `static`, so each is testable without an importer instance.

    /// Semicolon only when the line uses it *instead of* commas — a European
    /// CSV. A line containing both is treated as comma-separated.
    static func detectSeparator(firstLine: String) -> Character {
        firstLine.contains(";") && !firstLine.contains(",") ? ";" : ","
    }

    /// Whether the first row looks like column names rather than data.
    static func looksLikeHeader(_ firstLine: String) -> Bool {
        let lowered = firstLine.lowercased()
        return ["rr", "ibi", "interval", "time", "ms"].contains { lowered.contains($0) }
    }

    /// Index of the column holding RR intervals, or nil when no header column
    /// names one. Read with `fields(of:separator:)`, as the rows are, so
    /// the index means the same column in both.
    static func rrColumnIndex(inHeaderLine line: String, separator: Character) -> Int? {
        fields(of: line.lowercased(), separator: separator).firstIndex(where: namesRRColumn)
    }

    /// Whether a lowercased header names the RR column: one of its words is
    /// "rr" or "ibi", or starts with one ("rr_ms", "RR interval (ms)",
    /// "rrms", "IBI"), or the whole header is "ms" or "interval". Whole
    /// words, so "current_hr", "error" or "correction" do not match just
    /// because they contain the letters "rr".
    private static func namesRRColumn(_ header: String) -> Bool {
        let words = header.split { !$0.isLetter && !$0.isNumber }
        return words.contains { $0.hasPrefix("rr") || $0.hasPrefix("ibi") }
            || header == "ms" || header == "interval"
    }

    /// Picks the RR value out of one already-split data row, or nil to skip it.
    ///
    /// These rules are load-bearing for real files and easy to "tidy away" by
    /// accident:
    ///
    ///  • A header-detected RR column, and the single-column shorthand, are
    ///    trusted verbatim with NO range check here. Both shapes are
    ///    unambiguous, and filtering them would silently drop rows the user
    ///    can see in their own file. `parseCSV` still drops values that are
    ///    not beats at all (outside `storableRRRange`).
    ///  • The two-column guess IS range-checked, because "the second column
    ///    is RR" is only a heuristic about `timestamp,rr` exports, and a
    ///    wrong guess must not inject garbage into the series.
    ///  • The first-column fallback fires only when column 1 failed to parse
    ///    as a finite number at all — NOT when it parsed and then failed the
    /// range check: the fallback branches on the parse, not on validity.
    ///  • A row too short to reach the header's RR column is skipped, not
    ///    guessed at: its other columns are not RR.
    static func rrValue(
        fromColumns columns: [String],
        rrColumnIndex: Int?,
        convert: (Double) -> Int
    ) -> Int? {
        if let colIndex = rrColumnIndex {
            guard colIndex < columns.count, let value = Double(columns[colIndex]), value.isFinite else { return nil }
            return convert(value)
        }
        if columns.count == 1 {
            guard let value = Double(columns[0]), value.isFinite else { return nil }
            return convert(value)
        }
        guard columns.count >= 2 else { return nil }
        if let value = Double(columns[1]), value.isFinite {
            return validRRValue(convert(value))
        }
        guard let value = Double(columns[0]), value.isFinite else { return nil }
        return validRRValue(convert(value))
    }

    private static func validRRValue(_ converted: Int) -> Int? {
        HRVConstants.RRInterval.isValid(converted) ? converted : nil
    }

    // MARK: - Plain Text Parsing

    func parsePlainText(_ content: String) throws -> [Int] {
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !Self.isComment($0) }
        return lines.flatMap { line in
            // Handle space-separated values on same line
            line.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
                .compactMap { validRRValue(in: $0) }
        }
    }

    /// One whitespace- or delimiter-separated token as an RR value in
    /// milliseconds. Nil when it isn't a finite number or is not a beat at all
    /// (outside `storableRRRange`). The policy a CSV column gets: values out
    /// of the physiological range are kept, for `validate` and artifact
    /// detection to judge, so the same beats import the same whichever
    /// format holds them, and the summed timeline keeps every interval.
    private func validRRValue(in token: Substring) -> Int? {
        guard let value = Double(token), value.isFinite else { return nil }
        let converted = convertToMilliseconds(value)
        return Self.storableRRRange.contains(converted) ? converted : nil
    }

    /// The file's records: its lines, except that a newline inside a quoted
    /// field (an Elite HRV Notes or Tags value) stays in its record instead
    /// of splitting it in two.
    func csvRecords(_ content: String) -> [String] {
        var records: [String] = []
        var current = ""
        var inQuotes = false
        for char in content {
            if char == "\"" { inQuotes.toggle() }
            if char.isNewline, !inQuotes {
                records.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        records.append(current)
        return records
    }

    func parseCSVLine(_ line: String) -> [String] {
        Self.fields(of: line, separator: ",")
    }

    /// One record's fields, trimmed. Empty fields are kept, so a field's
    /// index is its column ("a,,b" has three), and `separator` inside
    /// double quotes is part of the field.
    static func fields(of line: String, separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == separator, !inQuotes {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current.trimmingCharacters(in: .whitespaces))

        return result
    }

    // MARK: - Helpers

    /// Convert RR value to milliseconds
    /// Handles values in seconds (0.5-2.0) or already in ms (200-2000)
    func convertToMilliseconds(_ value: Double) -> Int {
        // Convert seconds→ms when the value looks like seconds; otherwise it's
        // already ms. The result is returned UNCLAMPED — range validation is
        // the caller's job (isValid). We only guard the Int() cast itself,
        // which traps at runtime on NaN/Infinity or a magnitude beyond Int's
        // range. Non-finite → 0 (below the minimum RR, so isValid rejects it);
        // out-of-Int-range → clamped to Int bounds (also rejected by isValid).
        // Rounded, not truncated: 1.005 s is 1004.999… ms in binary floating
        // point, and truncating would lose a millisecond.
        let ms: Double = (value < 10 ? value * 1000 : value).rounded()
        guard ms.isFinite else { return 0 }
        if ms >= Double(Int.max) { return Int.max }
        if ms <= Double(Int.min) { return Int.min }
        return Int(ms)
    }

    /// Parse various date formats
    func parseDate(_ string: String) -> Date? {
        for formatter in Self.dateFormatters {
            if let date = formatter.date(from: string) {
                return date
            }
        }
        // Try ISO8601
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: string)
    }

    /// The fixed formats exporters write, tried in order. POSIX locale so a
    /// device set to a non-Gregorian calendar still parses them.
    private static let dateFormatters: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd",
            "MM/dd/yyyy HH:mm:ss",
            "MM/dd/yyyy"
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter
        }
    }()
}
