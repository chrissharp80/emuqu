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
    /// to physiologically impossible values. The nadir (and the minimum) is
    /// the lowest `nadirWindowMs` rolling mean, not the slowest single beat:
    /// one long interval from a breathing swing or an unflagged pause would
    /// otherwise read several bpm low. `nadirTimeMs` is on the series' own
    /// `t_ms` timeline (the middle of that window); pair with
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

    /// Width of the rolling window the nadir is taken over.
    static let nadirWindowMs: Int64 = 30_000

    /// One artifact-clean beat: its time and HR.
    private struct CleanBeat {
        let tMs: Int64
        let hr: Double
    }

    /// Min / max / mean HR and the time of the nadir, over artifact-clean beats
    /// only. Nil when no beat survived the plausibility filter.
    private static func overnightHRStats(
        points: [RRPoint],
        flags: [ArtifactFlags]
    ) -> OvernightHRStats? {
        // Skip artifact-flagged beats so a 30 BPM corruption blip doesn't
        // get reported as the user's true nocturnal nadir.
        let beats: [CleanBeat] = points.enumerated().compactMap { idx, point in
            if idx < flags.count, flags[idx].isArtifact { return nil }
            return plausibleHR(of: point).map { CleanBeat(tMs: point.t_ms, hr: $0) }
        }
        guard let maxHR = beats.map(\.hr).max(), let slowest = beats.min(by: { $0.hr < $1.hr }) else { return nil }
        let meanHR = beats.reduce(0.0) { $0 + $1.hr } / Double(beats.count)
        let nadir = smoothedNadir(beats) ?? (hr: slowest.hr, tMs: slowest.tMs)
        return OvernightHRStats(minHR: nadir.hr, maxHR: maxHR, meanHR: meanHR, nadirTimeMs: nadir.tMs)
    }

    /// The lowest mean HR over any `nadirWindowMs` stretch of clean beats, and
    /// the middle of that stretch. A window counts once it spans at least half
    /// its width. Nil for a recording too short to fill one.
    private static func smoothedNadir(_ beats: [CleanBeat]) -> (hr: Double, tMs: Int64)? {
        var best: (hr: Double, tMs: Int64)?
        var start = 0
        var sum = 0.0
        for (end, beat) in beats.enumerated() {
            sum += beat.hr
            while beat.tMs - beats[start].tMs > nadirWindowMs {
                sum -= beats[start].hr
                start += 1
            }
            let span = beat.tMs - beats[start].tMs
            let mean = sum / Double(end - start + 1)
            if span >= nadirWindowMs / 2, mean < (best?.hr ?? .infinity) {
                best = (mean, beats[start].tMs + span / 2)
            }
        }
        return best
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
