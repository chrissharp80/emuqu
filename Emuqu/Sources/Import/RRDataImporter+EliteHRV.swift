import Foundation

// MARK: - Elite HRV Summary Parsing

extension RRDataImporter {
    // MARK: - Elite HRV Summary Parsing

    /// Resolved column indices for Elite HRV CSV (supports old and new formats)
    struct EliteHRVColumnIndices {
        var date: Int?
        var rmssd: Int?
        var rmssdRaw: Int?
        var artifactPct: Int?
        var beatCount: Int?
        var rrMin: Int?
        var rrMax: Int?
        var fileName: Int?
        var duration: Int?
        var hr: Int?
        var type: Int?
        var sdnn: Int?
        var pnn50: Int?
    }

    /// Parse Elite HRV summary CSV format
    /// Old format: datetime,rmssd_clean_ms,rmssd_raw_ms,removed_rr_pct,n_rr,rr_min_ms,rr_max_ms,file
    /// New format: Member,Type,Position,Breathing Pattern,Date Time Start,Date Time End,Duration,Tags,Notes,Value 1,Value 2,Value 3,HRV,Morning Readiness,Balance,HRV CV,HR,lnRmssd,Rmssd,Nn50,Pnn50,Sdnn,Low Frequency Power,High Frequency Power,LF/HF Ratio,Total Power
    func parseEliteHRVSummary(_ content: String, fileName: String) throws -> EliteHRVSummaryResult {
        let lines = csvRecords(content)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else {
            throw ImportError.noRRData
        }
        // Quote-aware, like the rows, so a quoted header lines up with them.
        let headers = parseCSVLine(lines[0].lowercased())
        let indices = resolveEliteHRVColumns(headers: headers)
        guard let rmssdIdx = indices.rmssd else {
            let found = headers.joined(separator: ", ")
            throw ImportError.invalidFormat(String(localized: "Elite HRV format requires an RMSSD column (found headers: \(found))", bundle: LanguageManager.appBundle))
        }
        let sessions = parseEliteHRVRows(lines.dropFirst(), indices: indices, rmssdIdx: rmssdIdx)
        guard !sessions.isEmpty else {
            throw ImportError.noRRData
        }
        return EliteHRVSummaryResult(sessions: sessions, originalFileName: fileName)
    }

    /// Every data row that yields a session, with a log line for the rows
    /// skipped for having no usable date, RMSSD or heart rate.
    private func parseEliteHRVRows(
        _ rows: ArraySlice<String>, indices: EliteHRVColumnIndices, rmssdIdx: Int
    ) -> [EliteHRVSummaryResult.SessionSummary] {
        let sessions = rows.compactMap {
            parseEliteHRVRow(columns: parseCSVLine($0), indices: indices, rmssdIdx: rmssdIdx)
        }
        if sessions.count < rows.count {
            debugLog("[Import] Elite HRV: skipped \(rows.count - sessions.count) of \(rows.count) rows with no usable date, RMSSD or heart rate")
        }
        return sessions
    }

    /// Resolve column indices from CSV headers (supports both old and new Elite HRV formats)
    func resolveEliteHRVColumns(headers: [String]) -> EliteHRVColumnIndices {
        var indices = EliteHRVColumnIndices()
        for (index, header) in headers.enumerated() {
            let h = header.trimmingCharacters(in: .whitespaces)
            if let field = Self.eliteField(for: h) { indices[keyPath: field] = index }
        }
        return indices
    }

    /// The column this header names, or nil for one we don't read. The newer
    /// format's Sdnn and Pnn50 columns are Elite HRV's own measurements and
    /// are used as stated. Its nn50, hrv score and readiness columns are
    /// Elite HRV's scales, not the app's; its frequency-domain columns are
    /// left out because the export does not state their units, and a power
    /// read on the wrong scale would be a different measurement.
    /// First match wins, so specific equality tests precede loose `contains`.
    private static func eliteField(for h: String) -> WritableKeyPath<EliteHRVColumnIndices, Int?>? {
        if h.contains("datetime") || h == "date" || h == "date time start" { return \.date }
        if h == "rmssd" || h.contains("rmssd_clean") { return \.rmssd }
        if h.contains("rmssd_raw") { return \.rmssdRaw }
        if h.contains("removed") || h.contains("artifact") || h.contains("pct") { return \.artifactPct }
        if h.contains("n_rr") || h.contains("beats") || h.contains("count") { return \.beatCount }
        if h.contains("rr_min") || h.contains("min_rr") { return \.rrMin }
        if h.contains("rr_max") || h.contains("max_rr") { return \.rrMax }
        if h == "file" || h.contains("filename") { return \.fileName }
        if h == "duration" { return \.duration }
        if h == "hr" { return \.hr }
        if h == "type" { return \.type }
        if h == "sdnn" { return \.sdnn }
        if h == "pnn50" { return \.pnn50 }
        return nil
    }

    /// Parse a single Elite HRV data row into a SessionSummary (returns nil if row is invalid)
    ///
    /// Every number comes from the file, so each is read through
    /// `eliteNumber`: "nan", "inf" and "1e300" all parse as Doubles and would
    /// trap the integer conversions below. A row with neither a mean HR nor
    /// both RR extremes is skipped: its heart rate would have to be made up.
    func parseEliteHRVRow(
        columns: [String],
        indices: EliteHRVColumnIndices,
        rmssdIdx: Int
    ) -> EliteHRVSummaryResult.SessionSummary? {
        guard columns.count > rmssdIdx else { return nil }
        // RMSSD is the one required field — a row without it carries nothing.
        guard let rmssd = Self.eliteNumber(columns[rmssdIdx], in: 0.1 ... 1_000) else { return nil }
        // A row with no readable date is skipped rather than dated now, which
        // would put it on today and into today's baseline.
        guard let date = eliteDate(columns: columns, indices: indices) else { return nil }
        guard let bounds = eliteRRBounds(columns: columns, indices: indices) else { return nil }
        return EliteHRVSummaryResult.SessionSummary(
            date: date,
            rmssd: rmssd,
            rmssdRaw: eliteRawRMSSD(columns: columns, indices: indices) ?? rmssd,
            artifactPercent: eliteArtifactPercent(columns: columns, indices: indices),
            beatCount: eliteBeatCount(columns: columns, indices: indices),
            rrMin: bounds.min,
            rrMax: bounds.max,
            fileName: eliteFileName(columns: columns, indices: indices),
            sdnn: Self.eliteStated(columns, at: indices.sdnn, in: 0.1 ... 1_000),
            pnn50: Self.eliteStated(columns, at: indices.pnn50, in: 0 ... 100),
            rrRangeStated: bounds.stated
        )
    }

    /// The row's number in column `index`, inside `range`, or nil when the
    /// file has no such column or the cell is not a number in range.
    static func eliteStated(_ columns: [String], at index: Int?, in range: ClosedRange<Double>) -> Double? {
        guard let index, index < columns.count else { return nil }
        return eliteNumber(columns[index], in: range)
    }

    /// A finite number inside `range`, or nil. Bounds every value read from
    /// an Elite HRV file before any arithmetic or integer conversion.
    static func eliteNumber(_ text: String, in range: ClosedRange<Double>) -> Double? {
        guard let value = Double(text), value.isFinite, range.contains(value) else { return nil }
        return value
    }

    /// The pre-artifact-correction RMSSD the old format states, or nil when
    /// the file carries only the clean value.
    private func eliteRawRMSSD(columns: [String], indices: EliteHRVColumnIndices) -> Double? {
        guard let rawIdx = indices.rmssdRaw, rawIdx < columns.count else { return nil }
        return Self.eliteNumber(columns[rawIdx], in: 0.1 ... 1_000)
    }

    /// Row timestamp, or nil for a row with no parseable date.
    private func eliteDate(columns: [String], indices: EliteHRVColumnIndices) -> Date? {
        guard let dateIdx = indices.date, dateIdx < columns.count else { return nil }
        return parseDate(columns[dateIdx])
    }

    /// Beat count, derived from duration (seconds) × HR when the file doesn't
    /// state it; nil when it gives neither, rather than a made-up count.
    /// Bounded to a day of beats.
    private func eliteBeatCount(columns: [String], indices: EliteHRVColumnIndices) -> Int? {
        if let beatIdx = indices.beatCount, beatIdx < columns.count,
           let beats = Self.eliteNumber(columns[beatIdx], in: 1 ... 250_000) {
            return Int(beats)
        }
        guard let durIdx = indices.duration, let hrIdx = indices.hr,
              durIdx < columns.count, hrIdx < columns.count,
              let duration = Self.eliteNumber(columns[durIdx], in: 0 ... 86_400),
              let hr = Self.eliteNumber(columns[hrIdx], in: 20 ... 250)
        else { return nil }
        return max(1, Int(duration * hr / 60.0))
    }

    /// RR extremes. Each one the file states is used; each one it doesn't is
    /// derived from mean HR ±15%, and without a mean HR there is no bound:
    /// nil. The maximum is never below the minimum. `stated` is true only
    /// when the file gives both, so the HR range built from them is a
    /// measurement; otherwise the session marks it as an estimate.
    private func eliteRRBounds(
        columns: [String], indices: EliteHRVColumnIndices
    ) -> (min: Double, max: Double, stated: Bool)? {
        let fromHR = eliteMeanRR(columns: columns, indices: indices).map { (min: $0 * 0.85, max: $0 * 1.15) }
        let statedMin = eliteStatedRR(columns: columns, index: indices.rrMin)
        let statedMax = eliteStatedRR(columns: columns, index: indices.rrMax)
        guard let rrMin = statedMin ?? fromHR?.min, let rrMax = statedMax ?? fromHR?.max else { return nil }
        return (rrMin, max(rrMin, rrMax), statedMin != nil && statedMax != nil)
    }

    /// An RR extreme the row states, in `eliteRRRange`, or nil.
    private func eliteStatedRR(columns: [String], index: Int?) -> Double? {
        guard let index, index < columns.count else { return nil }
        return Self.eliteNumber(columns[index], in: Self.eliteRRRange)
    }

    /// The mean RR implied by the row's mean HR, or nil without one.
    private func eliteMeanRR(columns: [String], indices: EliteHRVColumnIndices) -> Double? {
        guard let hrIdx = indices.hr, hrIdx < columns.count,
              let hr = Self.eliteNumber(columns[hrIdx], in: 20 ... 250) else { return nil }
        return 60000.0 / hr
    }

    /// RR extremes a summary row may state, in milliseconds (20–300 bpm).
    private static let eliteRRRange: ClosedRange<Double> = 200 ... 3_000

    private func eliteArtifactPercent(columns: [String], indices: EliteHRVColumnIndices) -> Double {
        guard let artIdx = indices.artifactPct, artIdx < columns.count,
              let art = Self.eliteNumber(columns[artIdx], in: 0 ... 100)
        else { return 0.0 }
        return art
    }

    /// The file column, falling back to the session type as a label.
    private func eliteFileName(columns: [String], indices: EliteHRVColumnIndices) -> String {
        if let fileIdx = indices.fileName, fileIdx < columns.count {
            return columns[fileIdx]
        }
        if let typeIdx = indices.type, typeIdx < columns.count {
            return columns[typeIdx]
        }
        return ""
    }

    /// ── ESTIMATION NOTE ────────────────────────────────────────────
    /// An Elite HRV summary states RMSSD, and the newer format also SDNN,
    /// pNN50 and mean HR; the older one states the RR extremes. It never
    /// carries SDSD, SD HR, the Poincaré set or a stress index.
    /// `HRVAnalysisResult` holds every time-domain and Poincaré field as a
    /// plain number, so a field the file does not state is filled with the
    /// estimate below and named in the result's `estimatedMetrics`: display
    /// marks it as an estimate, and baselines, trends, cause rules, AI
    /// context and Apple Health leave it out. The stress index, which the
    /// model can hold as absent, is not filled at all.
    ///
    /// Typical morning-reading empirical ratios:
    ///   SDNN ≈ RMSSD × 1.8   (RMSSD/SDNN ≈ 0.5–0.7)
    ///   pNN50 rises ~linearly with RMSSD above a ~10 ms floor
    enum EliteHRVEstimates {
        /// ESTIMATED: SDNN ≈ RMSSD × this
        static let sdnnFromRMSSD = 1.8
        /// ESTIMATED: pNN50 per (RMSSD − floor)
        static let pnn50Slope = 1.5
        /// ESTIMATED: RMSSD floor below which pNN50 ≈ 0
        static let pnn50FloorMs = 10.0
        /// ESTIMATED: cap on the pNN50 estimate
        static let pnn50Ceiling = 50.0
    }

    /// Create a fully-analyzed HRV session directly from Elite HRV summary
    /// metrics instead of re-analyzing. No ANS metrics: the file has none,
    /// and a stress index or readiness made from RMSSD alone would be a
    /// reading nobody took.
    func createAnalyzedSession(from summary: EliteHRVSummaryResult.SessionSummary, originalFileName: String) -> HRVSession {
        let meanRR = (summary.rrMin + summary.rrMax) / 2.0
        let analysisResult = HRVAnalysisResult(
            windowStart: 0,
            windowEnd: summary.beatCount ?? 0,
            timeDomain: eliteTimeDomain(from: summary, meanRR: meanRR),
            frequencyDomain: nil, // Elite HRV summary doesn't include frequency data
            nonlinear: estimatedNonlinear(rmssd: summary.rmssd, sdnn: Self.eliteSDNN(summary)),
            ansMetrics: nil,
            artifactPercentage: summary.artifactPercent,
            cleanBeatCount: summary.beatCount.map { Int(Double($0) * (1.0 - summary.artifactPercent / 100.0)) } ?? 0,
            analysisDate: Date(),
            estimatedMetrics: Self.eliteEstimatedMetrics(for: summary).map(\.rawValue)
        )
        return importedSession(
            from: summary,
            originalFileName: originalFileName,
            meanRR: meanRR,
            analysisResult: analysisResult
        )
    }

    /// The metrics a session from this row holds as estimates: SDSD, SD HR
    /// and the Poincaré set always (the file never states them), SDNN and
    /// pNN50 when it has no column for them, the HR range unless it
    /// states both RR extremes, and the beat count (stored as 0) when it is
    /// unknown.
    static func eliteEstimatedMetrics(for summary: EliteHRVSummaryResult.SessionSummary) -> [EstimatedMetric] {
        var metrics: [EstimatedMetric] = [.sdsd, .sdHR, .sd1, .sd2, .sd1Sd2Ratio]
        if summary.sdnn == nil { metrics.append(.sdnn) }
        if summary.pnn50 == nil { metrics.append(.pnn50) }
        if !summary.rrRangeStated { metrics.append(.hrRange) }
        if summary.beatCount == nil { metrics.append(.beatCount) }
        return metrics
    }

    /// The file's SDNN, or the RMSSD-based estimate when it has none.
    static func eliteSDNN(_ summary: EliteHRVSummaryResult.SessionSummary) -> Double {
        summary.sdnn ?? summary.rmssd * EliteHRVEstimates.sdnnFromRMSSD
    }

    /// The file's pNN50, or the RMSSD-based estimate when it has none.
    static func elitePNN50(_ summary: EliteHRVSummaryResult.SessionSummary) -> Double {
        summary.pnn50 ?? min(
            EliteHRVEstimates.pnn50Ceiling,
            max(0, (summary.rmssd - EliteHRVEstimates.pnn50FloorMs) * EliteHRVEstimates.pnn50Slope)
        )
    }

    /// RMSSD is Elite HRV's real measured value; SDNN and pNN50 are the
    /// file's when it states them. SDSD (≈ RMSSD for short recordings) and
    /// SD HR are estimates, named as such by `eliteEstimatedMetrics`.
    private func eliteTimeDomain(
        from summary: EliteHRVSummaryResult.SessionSummary, meanRR: Double
    ) -> TimeDomainMetrics {
        let meanHR = 60000.0 / meanRR
        let sdnn = Self.eliteSDNN(summary)
        return TimeDomainMetrics(
            meanRR: meanRR,
            sdnn: sdnn,
            rmssd: summary.rmssd,
            pnn50: Self.elitePNN50(summary),
            sdsd: summary.rmssd,
            meanHR: meanHR,
            sdHR: sdnn * meanHR / meanRR / 2,
            minHR: 60000.0 / summary.rrMax,
            maxHR: 60000.0 / summary.rrMin,
            triangularIndex: nil // Not available from Elite HRV
        )
    }

    /// ESTIMATED: nonlinear metrics. SD1 = RMSSD / √2 takes RMSSD for SDSD,
    /// and SD2 = √(2·SDNN² − SD1²) builds on that SD1, so all three are
    /// estimates even when `sdnn` is the file's.
    private func estimatedNonlinear(rmssd: Double, sdnn: Double) -> NonlinearMetrics {
        let sd1 = rmssd / sqrt(2.0)
        let sd2 = sqrt(max(0, 2.0 * sdnn * sdnn - sd1 * sd1))
        return NonlinearMetrics(
            sd1: sd1,
            sd2: max(sd1, sd2), // SD2 should be >= SD1
            sd1Sd2Ratio: sd1 / max(sd1, sd2),
            sampleEntropy: nil,
            approxEntropy: nil,
            dfaAlpha1: nil, // Would need raw RR data
            dfaAlpha2: nil,
            dfaAlpha1R2: nil
        )
    }

    /// Assemble the stored session. The RR series is a single placeholder
    /// point: a summary file carries no beat-by-beat data, and fabricating
    /// some would be worse than storing none. Elite HRV readings are short
    /// morning spot checks, so they come in as quick readings — not
    /// overnights feeding the overnight baseline — and with no recovery
    /// score, which the app only gives a reading it scored itself. A row with
    /// no beat count has no length either: the session ends where it starts.
    private func importedSession(
        from summary: EliteHRVSummaryResult.SessionSummary,
        originalFileName: String,
        meanRR: Double,
        analysisResult: HRVAnalysisResult
    ) -> HRVSession {
        let durationMs = Int64(Double(summary.beatCount ?? 0) * meanRR)
        let id = UUID()
        let series = RRSeries(points: [RRPoint(t_ms: 0, rr_ms: Int(meanRR))], sessionId: id, startDate: summary.date)
        return HRVSession(
            id: id,
            startDate: summary.date,
            endDate: summary.date.addingTimeInterval(Double(durationMs) / 1000.0),
            state: .complete,
            sessionType: .quick,
            rrSeries: series,
            analysisResult: analysisResult,
            artifactFlags: [ArtifactFlags.clean],
            notes: Self.eliteNote(summary, originalFileName: originalFileName),
            importedMetrics: HRVSession.ImportedMetrics(
                rmssd: summary.rmssd,
                rmssdRaw: summary.rmssdRaw,
                artifactPercent: summary.artifactPercent,
                source: HRVSession.ImportedMetrics.eliteHRVSource
            )
        )
    }

    /// The session note: file name, Elite HRV's RMSSD, and the beat count
    /// when the file gives one.
    static func eliteNote(_ summary: EliteHRVSummaryResult.SessionSummary, originalFileName: String) -> String {
        guard let beats = summary.beatCount else {
            return String(localized: "Imported from Elite HRV: \(originalFileName)\nOriginal RMSSD: \(summary.rmssd, specifier: "%.1f") ms", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Imported from Elite HRV: \(originalFileName)\nOriginal RMSSD: \(summary.rmssd, specifier: "%.1f") ms\nBeats: \(beats)", bundle: LanguageManager.appBundle)
    }
}
