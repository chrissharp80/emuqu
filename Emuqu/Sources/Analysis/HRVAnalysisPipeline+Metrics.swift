//
//  HRVAnalysisPipeline+Metrics.swift
//  Emuqu
//
//  The pipeline's computation half: the four metric families, the overnight HR
//  summary, and the small pure helpers they share. Split out of
//  HRVAnalysisPipeline to keep that class body under 500 lines.
//

import Foundation

extension HRVAnalysisPipeline {
    // MARK: - Pure Computation Helpers

    /// Compute median heart rate from clean RR intervals.
    /// Pure function: takes values in, returns value out.
    static func nocturnalMedianHR(from cleanRRs: [Double]) -> Double? {
        guard !cleanRRs.isEmpty else { return nil }
        let hrValues = cleanRRs.compactMap { $0 > 0 ? 60000.0 / $0 : nil }
        let sorted = hrValues.sorted()
        guard !sorted.isEmpty else { return nil }
        if sorted.count % 2 == 0 {
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2.0
        }
        return sorted[sorted.count / 2]
    }

    /// Compute nocturnal HR dip percentage.
    /// Pure function: compares daytime resting HR to nocturnal median HR.
    static func nocturnalHRDip(daytimeHR: Double, nocturnalMedian: Double) -> Double? {
        guard daytimeHR > 0 else { return nil }
        return (daytimeHR - nocturnalMedian) / daytimeHR * 100.0
    }

    /// Extract clean (non-artifact) RR intervals from a windowed region.
    /// Pure function: filters artifacts, returns clean values.
    static func extractCleanRRs(
        series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int,
        windowEnd: Int
    ) -> [Double] {
        var cleanRR = [Double]()
        for i in windowStart ..< windowEnd where !flags[i].isArtifact {
            cleanRR.append(Double(series.points[i].rr_ms))
        }
        return cleanRR
    }

    // MARK: - Private Helpers

    func computeTimeDomain(series: RRSeries, flags: [ArtifactFlags], start: Int, end: Int) -> TimeDomainMetrics? {
        TimeDomainAnalyzer.computeTimeDomain(series, flags: flags, windowStart: start, windowEnd: end)
    }

    func computeFrequencyDomain(series: RRSeries, flags: [ArtifactFlags], start: Int, end: Int) -> FrequencyDomainMetrics? {
        FrequencyDomainAnalyzer.computeFrequencyDomain(series, flags: flags, windowStart: start, windowEnd: end)
    }

    func computeNonlinear(series: RRSeries, flags: [ArtifactFlags], start: Int, end: Int) -> NonlinearMetrics? {
        NonlinearAnalyzer.computeNonlinear(series, flags: flags, windowStart: start, windowEnd: end)
    }

    func fetchDaytimeRestingHR(for date: Date, sessionId: UUID) async -> Double? {
        do {
            let hr = try await healthKit.fetchDaytimeRestingHR(for: date)
            if hr != nil {
                debugLog("[HRVAnalysisPipeline] fetchDaytimeRestingHR session=\(sessionId.uuidString.prefix(8)) found")
            }
            return hr
        } catch {
            logPipelineError(.healthKitFetchFailed(sessionId: sessionId, operation: "daytimeRestingHR", underlying: error))
            return nil
        }
    }

    /// Compute autonomic nervous system metrics from time domain and nonlinear results.
    func computeANSMetrics(
        series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int,
        windowEnd: Int,
        timeDomain: TimeDomainMetrics,
        nonlinear: NonlinearMetrics,
        daytimeRestingHR: Double? = nil,
        config: ANSConfiguration
    ) -> ANSMetrics {
        let cleanRR = Self.extractCleanRRs(series: series, flags: flags, windowStart: windowStart, windowEnd: windowEnd)
        let stressIndex = StressAnalyzer.computeStressIndex(cleanRR)
        let pnsIndex = StressAnalyzer.computePNSIndex(
            meanRR: timeDomain.meanRR, rmssd: timeDomain.rmssd, sd1: nonlinear.sd1
        )
        let snsIndex = stressIndex.map { StressAnalyzer.computeSNSIndex(meanHR: timeDomain.meanHR, stressIndex: $0, sd2: nonlinear.sd2) }
        let nocturnalMedian = Self.nocturnalMedianHR(from: cleanRR)
        return ANSMetrics(
            stressIndex: stressIndex,
            pnsIndex: pnsIndex,
            snsIndex: snsIndex,
            readinessScore: readinessScore(timeDomain: timeDomain, nonlinear: nonlinear, pnsIndex: pnsIndex, snsIndex: snsIndex, config: config),
            respirationRate: RespirationAnalyzer.estimateRespirationRate(cleanRR),
            nocturnalHRDip: nocturnalDip(daytimeRestingHR: daytimeRestingHR, nocturnalMedian: nocturnalMedian),
            daytimeRestingHR: daytimeRestingHR,
            nocturnalMedianHR: nocturnalMedian
        )
    }

    private func readinessScore(
        timeDomain: TimeDomainMetrics,
        nonlinear: NonlinearMetrics,
        pnsIndex: Double?,
        snsIndex: Double?,
        config: ANSConfiguration
    ) -> Double? {
        StressAnalyzer.computeReadinessScore(
            rmssd: timeDomain.rmssd,
            baselineRMSSD: config.baselineRMSSD,
            alpha1: nonlinear.dfaAlpha1,
            pnsIndex: pnsIndex,
            snsIndex: snsIndex,
            trainingLoadAdjustment: config.trainingLoadAdjustment,
            vo2Max: config.vo2Max
        )
    }

    /// The dip needs both a daytime reference and an overnight median; either
    /// missing means there is no dip to report, not a dip of zero.
    private func nocturnalDip(daytimeRestingHR: Double?, nocturnalMedian: Double?) -> Double? {
        guard let daytimeHR = daytimeRestingHR, let median = nocturnalMedian else { return nil }
        return Self.nocturnalHRDip(daytimeHR: daytimeHR, nocturnalMedian: median)
    }

    /// Log a categorized pipeline error at warning level.
    func logPipelineError(_ error: PipelineError) {
        debugLog("[HRVAnalysisPipeline] \(error.localizedDescription)", level: .warning)
    }

    /// Whole-recording HR summary — nadir + min/max/mean over the FULL series,
    /// not the analysis window. Persisted on the result so the AI assistant,
    /// history view, and exports all read the same value without rescanning the
    /// RR series. Honors artifact flags so corrupted beats can't drag the nadir
    /// to physiologically impossible values. `nadirTimeMs` is relative to the
    /// series start (`series.points[0].t_ms`); pair with
    /// `series.wallClockTime(forTMs:)` for clock time.
    static func attachOvernightHRStats(_ result: inout HRVAnalysisResult, series: RRSeries, flags: [ArtifactFlags]) {
        let points = series.points
        guard !points.isEmpty else { return }

        guard let stats = overnightHRStats(points: points, flags: flags) else { return }
        result.overnightNadirHR = stats.minHR
        result.overnightNadirTimeMs = stats.nadirTimeMs
        result.overnightMinHR = stats.minHR
        result.overnightMaxHR = stats.maxHR
        result.overnightMeanHR = stats.meanHR
    }

    /// Min / max / mean HR and the time of the nadir, over artifact-clean beats
    /// only. Nil when no beat survived the plausibility filter.
    private static func overnightHRStats(
        points: [RRPoint],
        flags: [ArtifactFlags]
    ) -> OvernightHRStats? {
        var minHR: Double = .greatestFiniteMagnitude
        var maxHR: Double = -.greatestFiniteMagnitude
        var sumHR: Double = 0
        var count = 0
        var nadirTimeMs: Int64 = points[0].t_ms
        for (idx, point) in points.enumerated() {
            // Skip artifact-flagged beats so a 30 BPM corruption blip doesn't
            // get reported as the user's true nocturnal nadir.
            if idx < flags.count, flags[idx].isArtifact { continue }
            guard let hrValue = plausibleHR(of: point) else { continue }
            if hrValue < minHR {
                minHR = hrValue
                nadirTimeMs = point.t_ms
            }
            if hrValue > maxHR { maxHR = hrValue }
            sumHR += hrValue
            count += 1
        }
        guard count > 0, minHR.isFinite, maxHR.isFinite else { return nil }
        return OvernightHRStats(minHR: minHR, maxHR: maxHR, meanHR: sumHR / Double(count), nadirTimeMs: nadirTimeMs)
    }

    /// The beat's own HR when the strap reported a believable one, otherwise
    /// derived from RR. Nil rejects physiologically implausible artifact
    /// survivors.
    private static func plausibleHR(of point: RRPoint) -> Double? {
        let hrValue: Double
        if let stored = point.hr, stored > 20, stored < 220 {
            hrValue = Double(stored)
        } else if point.rr_ms > 0 {
            hrValue = 60_000.0 / Double(point.rr_ms)
        } else {
            return nil
        }
        guard hrValue >= 25, hrValue <= 220 else { return nil }
        return hrValue
    }
}
