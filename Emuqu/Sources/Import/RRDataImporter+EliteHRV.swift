import Foundation

// MARK: - Elite HRV Summary Parsing

extension RRDataImporter {
    // MARK: - Elite HRV Summary Parsing

    /// Resolved column indices for Elite HRV CSV (supports old and new formats)
    struct EliteHRVColumnIndices {
        var date: Int?
        var rmssd: Int?
        var artifactPct: Int?
        var beatCount: Int?
        var rrMin: Int?
        var rrMax: Int?
        var fileName: Int?
        var duration: Int?
        var hr: Int?
        var type: Int?
    }

    /// Parse Elite HRV summary CSV format
    /// Old format: datetime,rmssd_clean_ms,rmssd_raw_ms,removed_rr_pct,n_rr,rr_min_ms,rr_max_ms,file
    /// New format: Member,Type,Position,Breathing Pattern,Date Time Start,Date Time End,Duration,Tags,Notes,Value 1,Value 2,Value 3,HRV,Morning Readiness,Balance,HRV CV,HR,lnRmssd,Rmssd,Nn50,Pnn50,Sdnn,Low Frequency Power,High Frequency Power,LF/HF Ratio,Total Power
    func parseEliteHRVSummary(_ content: String, fileName: String) throws -> EliteHRVSummaryResult {
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else {
            throw ImportError.noRRData
        }
        let headers = lines[0].lowercased().split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
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
    /// skipped for having no usable date or RMSSD.
    private func parseEliteHRVRows(
        _ rows: ArraySlice<String>, indices: EliteHRVColumnIndices, rmssdIdx: Int
    ) -> [EliteHRVSummaryResult.SessionSummary] {
        let sessions = rows.compactMap {
            parseEliteHRVRow(columns: parseCSVLine($0), indices: indices, rmssdIdx: rmssdIdx)
        }
        if sessions.count < rows.count {
            debugLog("[Import] Elite HRV: skipped \(rows.count - sessions.count) of \(rows.count) rows with no usable date or RMSSD")
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

    /// The column this header names, or nil when it names one we recognize but
    /// don't use — sdnn, pnn50, nn50, frequency domain, hrv score and readiness
    /// columns are all recomputed from raw data rather than read from the file.
    /// First match wins, so specific equality tests precede loose `contains`.
    private static func eliteField(for h: String) -> WritableKeyPath<EliteHRVColumnIndices, Int?>? {
        if h.contains("datetime") || h == "date" || h == "date time start" { return \.date }
        if h == "rmssd" || h.contains("rmssd_clean") { return \.rmssd }
        if h.contains("removed") || h.contains("artifact") || h.contains("pct") { return \.artifactPct }
        if h.contains("n_rr") || h.contains("beats") || h.contains("count") { return \.beatCount }
        if h.contains("rr_min") || h.contains("min_rr") { return \.rrMin }
        if h.contains("rr_max") || h.contains("max_rr") { return \.rrMax }
        if h == "file" || h.contains("filename") { return \.fileName }
        if h == "duration" { return \.duration }
        if h == "hr" { return \.hr }
        if h == "type" { return \.type }
        return nil
    }

    /// Parse a single Elite HRV data row into a SessionSummary (returns nil if row is invalid)
    ///
    /// Every number comes from the file, so each is read through
    /// `eliteNumber`: "nan", "inf" and "1e300" all parse as Doubles and would
    /// trap the integer conversions below.
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
        let bounds = eliteRRBounds(columns: columns, indices: indices)
        return EliteHRVSummaryResult.SessionSummary(
            date: date,
            rmssd: rmssd,
            rmssdRaw: rmssd,
            artifactPercent: eliteArtifactPercent(columns: columns, indices: indices),
            beatCount: eliteBeatCount(columns: columns, indices: indices),
            rrMin: bounds.min,
            rrMax: bounds.max,
            fileName: eliteFileName(columns: columns, indices: indices)
        )
    }

    /// A finite number inside `range`, or nil. Bounds every value read from
    /// an Elite HRV file before any arithmetic or integer conversion.
    static func eliteNumber(_ text: String, in range: ClosedRange<Double>) -> Double? {
        guard let value = Double(text), value.isFinite, range.contains(value) else { return nil }
        return value
    }

    /// Row timestamp, or nil for a row with no parseable date.
    private func eliteDate(columns: [String], indices: EliteHRVColumnIndices) -> Date? {
        guard let dateIdx = indices.date, dateIdx < columns.count else { return nil }
        return parseDate(columns[dateIdx])
    }

    /// Beat count, derived from duration (seconds) × HR when the file doesn't
    /// state it. Bounded to a day of beats.
    private func eliteBeatCount(columns: [String], indices: EliteHRVColumnIndices) -> Int {
        if let beatIdx = indices.beatCount, beatIdx < columns.count,
           let beats = Self.eliteNumber(columns[beatIdx], in: 1 ... 250_000) {
            return Int(beats)
        }
        guard let durIdx = indices.duration, let hrIdx = indices.hr,
              durIdx < columns.count, hrIdx < columns.count,
              let duration = Self.eliteNumber(columns[durIdx], in: 0 ... 86_400),
              let hr = Self.eliteNumber(columns[hrIdx], in: 20 ... 250)
        else { return 100 }
        return max(1, Int(duration * hr / 60.0))
    }

    /// RR extremes, derived from mean HR ±15% when the file doesn't state them.
    private func eliteRRBounds(
        columns: [String], indices: EliteHRVColumnIndices
    ) -> (min: Double, max: Double) {
        var rrMin = 600.0
        var rrMax = 1000.0
        if let minIdx = indices.rrMin, minIdx < columns.count,
           let parsed = Self.eliteNumber(columns[minIdx], in: Self.eliteRRRange) {
            rrMin = parsed
        } else if let hrIdx = indices.hr, hrIdx < columns.count,
                  let hr = Self.eliteNumber(columns[hrIdx], in: 20 ... 250) {
            let meanRR = 60000.0 / hr
            rrMin = meanRR * 0.85
            rrMax = meanRR * 1.15
        }
        if let maxIdx = indices.rrMax, maxIdx < columns.count,
           let parsed = Self.eliteNumber(columns[maxIdx], in: Self.eliteRRRange) {
            rrMax = parsed
        }
        return (rrMin, rrMax)
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

    // Parse a CSV line handling quoted values

    /// ── ESTIMATION NOTE ────────────────────────────────────────────
    /// Elite HRV summary files give us RMSSD and a few raw stats but NOT
    /// SDNN/pNN50/SD1/SD2/stress/readiness. The values below are
    /// ESTIMATED from RMSSD via empirical relationships, not measured.
    /// The magic multipliers are named here so it's explicit which
    /// fields are derived rather than sourced from the file. (There is
    /// no isEstimated flag on HRVAnalysisResult to set; adding one would
    /// touch the model and every construction site.)
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
        /// ESTIMATED: softening term in the stress-index denominator
        static let stressBaseMs = 10.0
        /// ESTIMATED: stress-index scale factor
        static let stressNumerator = 1000.0
    }

    /// Create a fully-analyzed HRV session directly from Elite HRV summary metrics
    /// Uses the pre-computed metrics from Elite HRV instead of re-analyzing
    func createAnalyzedSession(from summary: EliteHRVSummaryResult.SessionSummary, originalFileName: String) -> HRVSession {
        let meanRR = (summary.rrMin + summary.rrMax) / 2.0
        let readinessScore = estimatedReadiness(rmssd: summary.rmssd)
        let analysisResult = HRVAnalysisResult(
            windowStart: 0,
            windowEnd: summary.beatCount,
            timeDomain: estimatedTimeDomain(from: summary, meanRR: meanRR),
            frequencyDomain: nil, // Elite HRV summary doesn't include frequency data
            nonlinear: estimatedNonlinear(rmssd: summary.rmssd),
            ansMetrics: estimatedANS(rmssd: summary.rmssd, readinessScore: readinessScore),
            artifactPercentage: summary.artifactPercent,
            cleanBeatCount: Int(Double(summary.beatCount) * (1.0 - summary.artifactPercent / 100.0)),
            analysisDate: Date()
        )
        return importedSession(
            from: summary,
            originalFileName: originalFileName,
            meanRR: meanRR,
            readinessScore: readinessScore,
            analysisResult: analysisResult
        )
    }

    /// ESTIMATED: SDNN from RMSSD (typical ratio RMSSD/SDNN ≈ 0.5-0.7 for
    /// morning readings), and pNN50 from RMSSD via an empirical linear
    /// relationship. RMSSD itself is Elite HRV's real measured value.
    private func estimatedTimeDomain(
        from summary: EliteHRVSummaryResult.SessionSummary, meanRR: Double
    ) -> TimeDomainMetrics {
        let meanHR = 60000.0 / meanRR
        let estimatedSDNN = summary.rmssd * EliteHRVEstimates.sdnnFromRMSSD
        let estimatedPNN50 = min(
            EliteHRVEstimates.pnn50Ceiling,
            max(0, (summary.rmssd - EliteHRVEstimates.pnn50FloorMs) * EliteHRVEstimates.pnn50Slope)
        )
        return TimeDomainMetrics(
            meanRR: meanRR,
            sdnn: estimatedSDNN,
            rmssd: summary.rmssd, // Use actual Elite HRV RMSSD!
            pnn50: estimatedPNN50,
            sdsd: summary.rmssd, // SDSD ≈ RMSSD for short recordings
            meanHR: meanHR,
            sdHR: estimatedSDNN * meanHR / meanRR / 2, // Approximate
            minHR: 60000.0 / summary.rrMax,
            maxHR: 60000.0 / summary.rrMin,
            triangularIndex: nil // Not available from Elite HRV
        )
    }

    /// ESTIMATED: nonlinear metrics.
    /// SD1 = RMSSD / √2 is an exact Poincaré identity, but SD2 is
    /// derived from the ESTIMATED SDNN, so both are estimates here.
    private func estimatedNonlinear(rmssd: Double) -> NonlinearMetrics {
        let estimatedSDNN = rmssd * EliteHRVEstimates.sdnnFromRMSSD
        let sd1 = rmssd / sqrt(2.0)
        let sd2 = sqrt(2.0 * estimatedSDNN * estimatedSDNN - sd1 * sd1)
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

    /// ESTIMATED: readiness score based on RMSSD relative to typical values.
    /// RMSSD < 20 = poor, 20-40 = moderate, 40-60 = good, 60+ = excellent.
    private func estimatedReadiness(rmssd: Double) -> Double {
        if rmssd >= 60 {
            8.0 + min(2.0, (rmssd - 60) / 20.0)
        } else if rmssd >= 40 {
            6.0 + (rmssd - 40) / 10.0
        } else if rmssd >= 20 {
            4.0 + (rmssd - 20) / 10.0
        } else {
            max(1.0, rmssd / 5.0)
        }
    }

    /// ESTIMATED: ANS metrics. Stress Index from RMSSD, an inverse
    /// relationship — higher RMSSD means lower stress.
    private func estimatedANS(rmssd: Double, readinessScore: Double) -> ANSMetrics {
        ANSMetrics(
            stressIndex: EliteHRVEstimates.stressNumerator / (rmssd + EliteHRVEstimates.stressBaseMs),
            pnsIndex: nil, // Would need frequency domain
            snsIndex: nil,
            readinessScore: readinessScore,
            respirationRate: nil,
            nocturnalHRDip: nil,
            daytimeRestingHR: nil,
            nocturnalMedianHR: nil
        )
    }

    /// Assemble the stored session. The RR series is a single placeholder
    /// point: a summary file carries no beat-by-beat data, and fabricating
    /// some would be worse than storing none.
    private func importedSession(
        from summary: EliteHRVSummaryResult.SessionSummary,
        originalFileName: String,
        meanRR: Double,
        readinessScore: Double,
        analysisResult: HRVAnalysisResult
    ) -> HRVSession {
        let durationMs = Int64(Double(summary.beatCount) * meanRR)
        let series = RRSeries(points: [RRPoint(t_ms: 0, rr_ms: Int(meanRR))], sessionId: UUID(), startDate: summary.date)
        return HRVSession(
            id: UUID(),
            startDate: summary.date,
            endDate: summary.date.addingTimeInterval(Double(durationMs) / 1000.0),
            state: .complete,
            rrSeries: series,
            analysisResult: analysisResult,
            artifactFlags: [ArtifactFlags.clean],
            recoveryScore: readinessScore,
            tags: [],
            notes: String(localized: "Imported from Elite HRV: \(originalFileName)\nOriginal RMSSD: \(summary.rmssd, specifier: "%.1f") ms\nBeats: \(summary.beatCount)", bundle: LanguageManager.appBundle),
            importedMetrics: HRVSession.ImportedMetrics(
                rmssd: summary.rmssd,
                rmssdRaw: summary.rmssdRaw,
                artifactPercent: summary.artifactPercent,
                source: "Elite HRV"
            )
        )
    }

    /// Import Elite HRV summary file and return multiple sessions
    func importEliteHRVFile(at url: URL) async throws -> EliteHRVSummaryResult {
        guard url.startAccessingSecurityScopedResource() else {
            throw ImportError.fileNotFound
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            debugLog("[Import] Failed to read Elite HRV file \(url.lastPathComponent): \(error.localizedDescription)")
            throw ImportError.unreadableFile
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw ImportError.unreadableFile
        }

        let fileName = url.lastPathComponent
        return try parseEliteHRVSummary(content, fileName: fileName)
    }
}
