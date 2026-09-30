import Foundation

// MARK: - Overnight stats computation
//
// The pure analysis half of `OvernightChartsView`: RR → HR, rolling RMSSD,
// peak-HRV search, sleep duration, and the assembly of the rendered
// `OvernightStats`. Split out of the view file so the type stays under the
// body-length budget; nothing here touches SwiftUI state.

/// Pure overnight-statistics computation, split from the view so it can run
/// on a detached task without capturing the view (which is not `Sendable`).
struct OvernightStatsComputer: Sendable {
    let session: HRVSession
    let result: HRVAnalysisResult
    let healthKitSleep: SleepData?

    func computeOvernightStats() -> OvernightStats {
        guard let series = session.rrSeries, !series.points.isEmpty else { return OvernightStats.empty }
        let (flags, points) = (session.artifactFlags ?? [], series.points)
        // Prefer live HealthKit boundaries over stored session data.
        let (sleepStartMs, sleepEndMs) = resolveSleepBoundaries(points: points)
        let segmentRanges = resolveSleepSegmentRanges(points: points)
        let hasStoredHR = points.contains { $0.hr != nil }
        let allHrValues = computeHRValues(
            points: points, flags: flags, hasStoredHR: hasStoredHR, rangeStart: nil, rangeEnd: nil)
        let hrValues = sleepWindowHRValues(
            points: points, flags: flags, hasStoredHR: hasStoredHR, segmentRanges: segmentRanges,
            sleepStartMs: sleepStartMs, sleepEndMs: sleepEndMs, fallback: allHrValues)
        guard let nadirPoint = hrValues.min(by: { $0.hr < $1.hr }),
              let peakPoint = hrValues.max(by: { $0.hr < $1.hr }),
              let firstPoint = points.first, let lastPoint = points.last
        else { return OvernightStats.empty }
        return makeStats(StatsInputs(
            series: series, points: points, flags: flags, hrValues: hrValues, allHrValues: allHrValues,
            rollingRMSSD: computeRollingRMSSD(points: points, flags: flags),
            nadirPoint: nadirPoint, peakPoint: peakPoint, firstPoint: firstPoint, lastPoint: lastPoint,
            segmentRanges: segmentRanges, sleepStartMs: sleepStartMs, sleepEndMs: sleepEndMs))
    }

    /// Everything `makeStats` needs, bundled so the assembly step reads as one
    /// wide field table rather than a fifteen-parameter signature.
    private struct StatsInputs {
        let series: RRSeries
        let points: [RRPoint]
        let flags: [ArtifactFlags]
        let hrValues: [(index: Int, hr: Double, timeMs: Int64)]
        let allHrValues: [(index: Int, hr: Double, timeMs: Int64)]
        let rollingRMSSD: [(index: Int, rmssd: Double, timeMs: Int64)]
        let nadirPoint: (index: Int, hr: Double, timeMs: Int64)
        let peakPoint: (index: Int, hr: Double, timeMs: Int64)
        let firstPoint: RRPoint
        let lastPoint: RRPoint
        let segmentRanges: [(startMs: Int64, endMs: Int64)]
        let sleepStartMs: Int64
        let sleepEndMs: Int64
    }

    /// Assemble the rendered stats. Everything here is projection and
    /// formatting — the analysis itself already happened. The peak-HRV search
    /// stays inside the 30-70% sleep band.
    private func makeStats(_ inputs: StatsInputs) -> OvernightStats {
        let durationMs = inputs.lastPoint.t_ms - inputs.firstPoint.t_ms
        let (peakHRV, avgRMSSD) = findPeakHRV(rollingRMSSD: inputs.rollingRMSSD, recordingDurationMs: durationMs)
        let (window, sleep) = (windowFields(inputs), sleepFields(inputs, durationMs: durationMs))
        let (rolling, nadir) = (inputs.rollingRMSSD.map { ($0.index, $0.rmssd) }, inputs.nadirPoint)
        return OvernightStats(
            nadirHR: nadir.hr, nadirIndex: nadir.index, nadirTimeMs: nadir.timeMs,
            nadirTimeFormatted: formatClockTime(inputs.series.wallClockTime(forTMs: nadir.timeMs)),
            minHR: nadir.hr, maxHR: inputs.peakPoint.hr, avgHR: Self.trimmedMeanHR(inputs.hrValues), peakRMSSD: peakHRV?.rmssd ?? 0,
            peakHRVIndex: peakHRV?.index ?? 0, peakHRVTimeMs: peakHRV?.timeMs ?? 0, peakHRVTimeFormatted: formatClockTime(inputs.series.wallClockTime(forTMs: peakHRV?.timeMs ?? 0)),
            avgRMSSD: avgRMSSD, rollingRMSSD: rolling, hrValues: inputs.hrValues.map { ($0.index, $0.hr) },
            allHrValues: inputs.allHrValues.map { ($0.index, $0.hr) }, allRollingRMSSD: rolling,
            windowStartIndex: result.windowStart, windowEndIndex: result.windowEnd, windowStartMs: window.startMs, windowEndMs: window.endMs,
            windowStartTimeFormatted: window.startLabel, windowEndTimeFormatted: window.endLabel,
            estimatedSleepDurationMinutes: sleep.minutes, estimatedSleepDurationFormatted: sleep.formatted,
            deepSleepMinutes: sleep.deepMinutes, awakeningsCount: sleep.awakenings, sleepEfficiency: sleep.efficiency,
            isHealthKitData: sleep.isFromHealthKit, sleepSegmentRanges: inputs.segmentRanges, chartStartMs: Self.chartStart(firstPoint: inputs.firstPoint, segmentRanges: inputs.segmentRanges),
            chartEndMs: Self.chartEnd(lastPoint: inputs.lastPoint, segmentRanges: inputs.segmentRanges), healthKitHR: [],
            organizedRecoveryZones: organizedZones(
                series: inputs.series, flags: inputs.flags, sleepStartMs: inputs.sleepStartMs, sleepEndMs: inputs.sleepEndMs)
        )
    }

    /// The analysis window's bounds and their formatted clock labels.
    private struct WindowFields {
        let startMs: Int64
        let endMs: Int64
        let startLabel: String
        let endLabel: String
    }

    private func windowFields(_ inputs: StatsInputs) -> WindowFields {
        let window = analysisWindowTimes(points: inputs.points, series: inputs.series)
        return WindowFields(
            startMs: window.startMs, endMs: window.endMs,
            startLabel: formatClockTime(window.startTime), endLabel: formatClockTime(window.endTime)
        )
    }

    /// Sleep duration (HealthKit → boundary diff → HR estimation).
    private func sleepFields(
        _ inputs: StatsInputs,
        durationMs: Int64
    ) -> SleepDurationFields {
        deriveSleepDuration(recordingStartTime: inputs.firstPoint.t_ms, recordingDurationMs: durationMs)
    }

    /// HR for the sleep period, computed per-segment on a split night so the
    /// gap between segments is excluded from stats (nadir, avg HR, etc.).
    ///
    /// Falls back to the full RR range when the sleep-boundary filter excludes
    /// everything, and then to the caller's full-recording set.
    private func sleepWindowHRValues(
        points: [RRPoint],
        flags: [ArtifactFlags],
        hasStoredHR: Bool,
        segmentRanges: [(startMs: Int64, endMs: Int64)],
        sleepStartMs: Int64,
        sleepEndMs: Int64,
        fallback: [(index: Int, hr: Double, timeMs: Int64)]
    ) -> [(index: Int, hr: Double, timeMs: Int64)] {
        var hrValues: [(index: Int, hr: Double, timeMs: Int64)] = []
        if segmentRanges.count > 1 {
            for range in segmentRanges {
                hrValues += computeHRValues(
                    points: points, flags: flags, hasStoredHR: hasStoredHR,
                    rangeStart: range.startMs, rangeEnd: range.endMs)
            }
            // Sort by index to maintain ordering for downstream consumers.
            hrValues.sort { $0.index < $1.index }
        } else {
            hrValues = computeHRValues(
                points: points, flags: flags, hasStoredHR: hasStoredHR,
                rangeStart: sleepStartMs, rangeEnd: sleepEndMs)
        }
        if hrValues.isEmpty {
            debugLog("[OvernightChartsView] Sleep boundary filter excluded all data — falling back to full RR range")
            hrValues = fallback
        }
        return hrValues
    }

    /// Trimmed mean (5th–95th percentile) for a robust overnight average.
    /// Brief ectopic runs, arrhythmia episodes, or apnea-related HR spikes
    /// (e.g. 146 bpm during sleep) inflate a simple mean by several bpm.
    /// Trimming is standard in polysomnography for this reason.
    private static func trimmedMeanHR(_ hrValues: [(index: Int, hr: Double, timeMs: Int64)]) -> Double {
        let sorted = hrValues.map(\.hr).sorted()
        let count = sorted.count
        guard count >= 10 else { return sorted.reduce(0, +) / Double(count) }
        let trimmed = Array(sorted[Int(Double(count) * 0.05) ..< Int(Double(count) * 0.95)])
        return trimmed.reduce(0, +) / Double(trimmed.count)
    }

    /// The analysis window's bounds in ms and wall-clock. Wall-clock timestamps
    /// are preferred so data gaps don't shift displayed times earlier than
    /// reality.
    private struct AnalysisWindow {
        let startMs: Int64
        let endMs: Int64
        let startTime: Date
        let endTime: Date
    }

    private func analysisWindowTimes(
        points: [RRPoint],
        series: RRSeries
    ) -> AnalysisWindow {
        let startMs: Int64
        let endMs: Int64
        if let wsMs = result.windowStartMs, let weMs = result.windowEndMs {
            startMs = wsMs
            endMs = weMs
        } else {
            startMs = result.windowStart < points.count ? points[result.windowStart].t_ms : 0
            endMs = result.windowEnd < points.count ? points[result.windowEnd].t_ms : points.last?.t_ms ?? 0
        }
        return AnalysisWindow(
            startMs: startMs, endMs: endMs,
            startTime: series.wallClockTime(forTMs: startMs), endTime: series.wallClockTime(forTMs: endMs)
        )
    }

    /// Chart viewport: the recording session IS the bound. The user can't
    /// start a session while asleep — they put the strap on awake, tap
    /// start, then sleep happens inside the recording. So chart start =
    /// first RR point, chart end = last RR point. Sleep stages and HK HR
    /// data are plotted WITHIN this window; anything HealthKit reports
    /// outside the session window is irrelevant to the chart. For split
    /// nights (paused/resumed) the viewport expands to cover all segments.
    private static func chartStart(
        firstPoint: RRPoint,
        segmentRanges: [(startMs: Int64, endMs: Int64)]
    ) -> Int64 {
        guard segmentRanges.count > 1, let segMin = segmentRanges.map(\.startMs).min() else {
            return firstPoint.t_ms
        }
        return min(firstPoint.t_ms, segMin)
    }

    private static func chartEnd(
        lastPoint: RRPoint,
        segmentRanges: [(startMs: Int64, endMs: Int64)]
    ) -> Int64 {
        guard segmentRanges.count > 1, let segMax = segmentRanges.map(\.endMs).max() else {
            return lastPoint.endMs
        }
        return max(lastPoint.endMs, segMax)
    }

    /// Prefer pre-computed zones from the analysis result; fall back to
    /// an on-demand scan (cached + disk-backfilled) so sessions recorded
    /// before this feature existed still get the green overlay.
    private func organizedZones(
        series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64,
        sleepEndMs: Int64
    ) -> [HRVAnalysisResult.TimeRange] {
        result.organizedRecoveryZones ?? Self.computeOrganizedZonesOnDemand(
            sessionId: session.id, series: series, flags: flags,
            sleepStartMs: sleepStartMs, sleepEndMs: sleepEndMs
        )
    }

    // MARK: - Overnight Stats Helpers

    /// Compute organized-recovery zones on-demand for sessions that don't have
    /// them pre-stored (recorded before the feature existed, or imported).
    /// Uses the same WindowSelector the analysis pipeline uses, so what the
    /// user sees matches what the scorer picked.
    ///
    /// Two-level cache:
    ///   1. In-memory `OrganizedZonesCache` — survives view recreations
    ///      within the same app launch. Zero cost after the first compute.
    ///   2. On-disk backfill via async archive update — the next app launch
    ///      finds the zones already baked into `HRVAnalysisResult` and skips
    ///      the scan entirely (same cache hit path newly-analyzed sessions get).
    ///      (The backfill call itself fires from the
    ///      `.task(id:)` block in `body`, not from inside this compute
    ///      function, so the archive write is a task-boundary side effect
    ///      rather than something buried in the stats pipeline.)
    private static func computeOrganizedZonesOnDemand(
        sessionId: UUID,
        series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64,
        sleepEndMs: Int64
    ) -> [HRVAnalysisResult.TimeRange] {
        // Level 1: memory cache.
        if let cached = AppDependencies.current.app.organizedZonesCache.get(sessionId) {
            return cached
        }
        let selector = WindowSelector()
        // Invoke findBestWindow for its side effect: populating lastOrganizedZones.
        // The returned window is irrelevant here — we only want the zone array.
        _ = selector.findBestWindow(
            in: series,
            flags: flags,
            sleepStartMs: sleepStartMs,
            wakeTimeMs: sleepEndMs
        )
        let zones = selector.lastOrganizedZones
        AppDependencies.current.app.organizedZonesCache.set(sessionId, zones: zones)
        // Level 2 (disk backfill) is triggered by the caller — see the
        // `.task(id:)` block in `body`.
        return zones
    }

    /// Persist computed zones back to the session's analysisResult so future
    /// launches hit the pre-computed path. Runs detached + background — never
    /// blocks the chart render. Silent on failure (the in-memory cache still
    /// protects this app-launch; a failed backfill just means we'll recompute
    /// the zones next launch and try again).
    static func backfillZonesToArchive(
        sessionId: UUID,
        zones: [HRVAnalysisResult.TimeRange]
    ) {
        Task.detached(priority: .background) {
            writeZonesIfStillEmpty(sessionId: sessionId, zones: zones)
        }
    }

    /// Only writes when the field is actually empty — we might race with
    /// ReanalysisService or the main pipeline.
    private static func writeZonesIfStillEmpty(
        sessionId: UUID,
        zones: [HRVAnalysisResult.TimeRange]
    ) {
        do {
            guard var session = try AppDependencies.current.storage.sessionArchive.retrieve(sessionId),
                  session.analysisResult != nil,
                  session.analysisResult?.organizedRecoveryZones == nil
            else { return }
            session.analysisResult?.organizedRecoveryZones = zones.isEmpty ? nil : zones
            _ = try AppDependencies.current.storage.sessionArchive.archive(session)
            debugLog("[OvernightCharts] 💾 backfilled organizedRecoveryZones for session \(sessionId.uuidString.prefix(8)) (\(zones.count) zones)")
        } catch {
            debugLog("[OvernightCharts] backfill failed for \(sessionId.uuidString.prefix(8)): \(error)", level: .warning)
        }
    }

    /// Resolve sleep boundaries from HealthKit or stored session data, clamped to recording range
    private func resolveSleepBoundaries(points: [RRPoint]) -> (start: Int64, end: Int64) {
        let recordingEnd = points.last?.t_ms ?? Int64.max
        if let hkSleep = healthKitSleep,
           let hkStart = hkSleep.sleepStart,
           let hkEnd = hkSleep.sleepEnd {
            let start = max(0, MillisecondOffset.between(hkStart, and: session.startDate, fallback: 0))
            let end = min(recordingEnd, MillisecondOffset.between(hkEnd, and: session.startDate, fallback: 0))
            return (start, end)
        } else {
            let start = session.sleepStartMs ?? 0
            let rawEnd = session.sleepEndMs ?? recordingEnd
            let end = (rawEnd > start && rawEnd >= 0) ? rawEnd : recordingEnd
            return (start, end)
        }
    }

    /// Resolve individual sleep segment ranges for split-night support.
    /// Returns per-segment boundaries from HealthKit segments or session.sleepSegments,
    /// falling back to a single envelope range for normal nights.
    /// Ranges are NOT clamped to recording bounds so that charts can extend to
    /// cover the full HealthKit sleep envelope (e.g., a segment that started
    /// hours before the Polar recording).
    private func resolveSleepSegmentRanges(points: [RRPoint]) -> [(startMs: Int64, endMs: Int64)] {
        // Prefer live HealthKit segment data
        if let hkSleep = healthKitSleep, hkSleep.effectiveSegments.count > 1 {
            return hkSleep.effectiveSegments.map { seg in
                let start = MillisecondOffset.between(seg.sleepStart, and: session.startDate, fallback: 0)
                let end = MillisecondOffset.between(seg.sleepEnd, and: session.startDate, fallback: 0)
                return (startMs: start, endMs: end)
            }
        }

        // Fall back to stored sleep segments on the session
        if let segments = session.sleepSegments, segments.count > 1 {
            return segments.map { seg in
                (startMs: seg.startMs, endMs: seg.endMs)
            }
        }

        // Single-segment: return the overall envelope
        let (start, end) = resolveSleepBoundaries(points: points)
        return [(startMs: start, endMs: end)]
    }

    /// Compute HR values from RR data within an optional time range.
    /// Uses stored HR when available, otherwise calculates from 10-second RR windows.
    /// Pass nil for rangeStart/rangeEnd to use the full recording.
    private func computeHRValues(
        points: [RRPoint],
        flags: [ArtifactFlags],
        hasStoredHR: Bool,
        rangeStart: Int64?,
        rangeEnd: Int64?
    ) -> [(index: Int, hr: Double, timeMs: Int64)] {
        hasStoredHR
            ? Self.storedHRValues(points: points, flags: flags, rangeStart: rangeStart, rangeEnd: rangeEnd)
            : Self.windowedHRValues(points: points, flags: flags, rangeStart: rangeStart, rangeEnd: rangeEnd)
    }

    /// Stored per-beat HR, filtered to the range and to physiologically
    /// plausible values on non-artifact beats.
    private static func storedHRValues(
        points: [RRPoint],
        flags: [ArtifactFlags],
        rangeStart: Int64?,
        rangeEnd: Int64?
    ) -> [(index: Int, hr: Double, timeMs: Int64)] {
        var out: [(index: Int, hr: Double, timeMs: Int64)] = []
        for (i, point) in points.enumerated() {
            if let start = rangeStart, point.t_ms < start { continue }
            if let end = rangeEnd, point.t_ms > end { continue }
            let isArtifact = i < flags.count ? flags[i].isArtifact : false
            guard !isArtifact, let hr = point.hr, hr >= 30, hr <= 200 else { continue }
            out.append((i, Double(hr), point.t_ms))
        }
        return out
    }

    /// HR derived from ~10-second RR windows, for recordings with no stored HR.
    /// Each window needs at least 5 clean beats before it counts.
    private static func windowedHRValues(
        points: [RRPoint],
        flags: [ArtifactFlags],
        rangeStart: Int64?,
        rangeEnd: Int64?
    ) -> [(index: Int, hr: Double, timeMs: Int64)] {
        var out: [(index: Int, hr: Double, timeMs: Int64)] = []
        var idx = 0
        while idx < points.count {
            if let start = rangeStart, points[idx].t_ms < start {
                idx += 1
                continue
            }
            if let end = rangeEnd, points[idx].t_ms > end { break }
            let window = rrWindow(points: points, flags: flags, from: idx, rangeEnd: rangeEnd)
            if let hr = physiologicalHR(window) { out.append((idx, hr, points[idx].t_ms)) }
            idx = window.nextIndex > idx + 5 ? idx + 5 : window.nextIndex
        }
        return out
    }

    /// Nil when the window is too sparse or the derived rate falls outside the
    /// 30–200 bpm physiological range.
    private static func physiologicalHR(_ window: (beatCount: Int, durationMs: Int64, nextIndex: Int)) -> Double? {
        guard window.beatCount >= 5, window.durationMs > 0 else { return nil }
        let hr = (Double(window.beatCount) / Double(window.durationMs)) * 60000.0
        guard hr >= 30, hr <= 200 else { return nil }
        return hr
    }

    /// Accumulate clean beats forward from `from` until ~10 s of RR time has
    /// passed or the range ends.
    private static func rrWindow(
        points: [RRPoint],
        flags: [ArtifactFlags],
        from idx: Int,
        rangeEnd: Int64?
    ) -> (beatCount: Int, durationMs: Int64, nextIndex: Int) {
        let windowDurationMs: Int64 = 10000
        let effectiveEnd = rangeEnd ?? Int64.max
        var beatCount = 0
        var durationMs: Int64 = 0
        var j = idx
        while j < points.count, points[j].t_ms <= effectiveEnd, durationMs < windowDurationMs {
            let isArtifact = j < flags.count ? flags[j].isArtifact : false
            let rr = points[j].rr_ms
            if !isArtifact, rr >= 300, rr <= 2000 {
                beatCount += 1
                durationMs += Int64(rr)
            }
            j += 1
        }
        return (beatCount, durationMs, j)
    }

    /// Compute rolling RMSSD using 5-minute windows every 30 beats.
    private func computeRollingRMSSD(
        points: [RRPoint],
        flags: [ArtifactFlags]
    ) -> [(index: Int, rmssd: Double, timeMs: Int64)] {
        let windowSize = 300
        let stepSize = 30
        var out: [(index: Int, rmssd: Double, timeMs: Int64)] = []
        var i = 0
        while i <= points.count - 1 {
            let lo = max(0, i - windowSize / 2)
            let hi = min(points.count, i + windowSize / 2)
            if let rmssd = TimeDomainAnalyzer.peakScanRMSSD(points: points, flags: flags, range: lo ..< max(lo, hi)) {
                out.append((i, rmssd, points[i].t_ms))
            }
            // Snap the last step to the final point so the tail isn't dropped.
            i = (i < points.count - 1 && i + stepSize > points.count - 1) ? points.count - 1 : i + stepSize
        }
        return out
    }

    /// Find peak HRV within the 30-70% sleep band, matching WindowSelector's search region.
    /// Uses the overall sleep envelope (or full recording) — no segment-specific restriction
    /// so that users can sample any portion of the night.
    private func findPeakHRV(
        rollingRMSSD: [(index: Int, rmssd: Double, timeMs: Int64)],
        recordingDurationMs: Int64
    ) -> (peak: (index: Int, rmssd: Double, timeMs: Int64)?, avgRMSSD: Double) {
        let band = searchBand(recordingDurationMs: recordingDurationMs)
        let constrained = rollingRMSSD.filter { $0.timeMs >= band.earlyMs && $0.timeMs <= band.lateMs }
        let peak = (constrained.isEmpty ? rollingRMSSD : constrained).max(by: { $0.rmssd < $1.rmssd })
        let avg = rollingRMSSD.isEmpty
            ? 0
            : rollingRMSSD.map(\.rmssd).reduce(0, +) / Double(rollingRMSSD.count)
        return (peak, avg)
    }

    /// The 30–70% slice of the sleep envelope, or of the whole recording when
    /// HealthKit gave us no boundaries.
    private func searchBand(recordingDurationMs: Int64) -> (earlyMs: Int64, lateMs: Int64) {
        var boundaryStart: Int64 = 0
        var boundaryEnd = recordingDurationMs
        if let hk = healthKitSleep, let sleepStart = hk.sleepStart, let sleepEnd = hk.sleepEnd {
            boundaryStart = max(0, MillisecondOffset.between(sleepStart, and: session.startDate, fallback: 0))
            boundaryEnd = min(recordingDurationMs, MillisecondOffset.between(sleepEnd, and: session.startDate, fallback: 0))
        }
        let sleepDuration = boundaryEnd - boundaryStart
        return (
            boundaryStart + Int64(Double(sleepDuration) * 0.30),
            boundaryStart + Int64(Double(sleepDuration) * 0.70)
        )
    }

    private func deriveSleepDuration(
        recordingStartTime _: Int64,
        recordingDurationMs: Int64
    ) -> SleepDurationFields {
        if let hk = healthKitSleep, let minutes = Self.healthKitSleepMinutes(hk) {
            return SleepDurationFields(
                minutes: minutes, formatted: formatDuration(minutes),
                deepMinutes: hk.deepSleepMinutes ?? 0,
                awakenings: hk.awakeMinutes > 0 ? max(1, hk.awakeMinutes / 10) : 0,
                efficiency: hk.sleepEfficiency, isFromHealthKit: true
            )
        }
        return estimatedSleepFromRecording(durationMs: recordingDurationMs)
    }

    /// Total sleep from HealthKit — the reported total when it has one, else
    /// the span between its sleep boundaries. Nil when neither is available.
    private static func healthKitSleepMinutes(_ hk: SleepData) -> Int? {
        if hk.totalSleepIncludingNapMinutes > 0 { return hk.totalSleepIncludingNapMinutes }
        guard let sleepStart = hk.sleepStart, let sleepEnd = hk.sleepEnd else { return nil }
        return Int(sleepEnd.timeIntervalSince(sleepStart) / 60)
    }

    /// Fallback estimate from the recording length alone. Recordings past 3 h
    /// are assumed to be a real night (90% asleep, 20% deep, one awakening per
    /// 90 min); shorter ones get the more conservative nap profile.
    private func estimatedSleepFromRecording(
        durationMs: Int64
    ) -> SleepDurationFields {
        let recordingMinutes = Int(durationMs / 60000)
        let isFullNight = recordingMinutes > 180
        let sleepMinutes = Int(Double(recordingMinutes) * (isFullNight ? 0.90 : 0.85))
        return SleepDurationFields(
            minutes: sleepMinutes,
            formatted: formatDuration(sleepMinutes),
            deepMinutes: Int(Double(sleepMinutes) * (isFullNight ? 0.20 : 0.15)),
            awakenings: isFullNight ? recordingMinutes / 90 : 0,
            efficiency: recordingMinutes > 0 ? Double(sleepMinutes) / Double(recordingMinutes) * 100 : 0,
            isFromHealthKit: false
        )
    }

    /// Format minutes as "Xh Ym" string
    private func formatDuration(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    /// Format a date as clock time (e.g., "2:45 AM")
    private func formatClockTime(_ date: Date) -> String {
        OvernightChartFormatters.clockTimeFormatter.string(from: date)
    }
}

extension OvernightChartsView {
    /// Fetch Apple Watch HR samples for HealthKit sleep segments that fall outside
    /// the Polar recording range. Returns samples as (timeMs, hr) relative to session.startDate.
    ///
    /// When a single sleep segment spans the entire night
    /// (typical) but the Polar recording only covers a small portion of
    /// it (typical for overnight crashes — recording cut short, sleep
    /// continued tracked by Apple Watch), skipping the segment because
    /// it "overlaps" with the recording would mean the post-crash hours
    /// never get fetched and the HR chart looks truncated forever.
    /// So we fetch HK HR for the PARTS of the
    /// segment that don't overlap the recording — pre-recording (rare,
    /// segment starts before strap connects) and post-recording (the
    /// crash case). The Polar data still wins inside its recorded range.
    func fetchHealthKitHRForUncoveredSegments(
        segments: [HealthKitManager.SleepSegment],
        recordingStartMs: Int64,
        recordingEndMs: Int64
    ) async -> [(timeMs: Int64, hr: Double)] {
        var allSamples: [(timeMs: Int64, hr: Double)] = []
        for (segIdx, seg) in segments.enumerated() {
            let segStartMs = MillisecondOffset.between(seg.sleepStart, and: session.startDate, fallback: 0)
            let segEndMs = MillisecondOffset.between(seg.sleepEnd, and: session.startDate, fallback: 0)
            guard Self.isPlausibleSegment(startMs: segStartMs, endMs: segEndMs, index: segIdx) else { continue }
            let subWindows = Self.uncoveredWindows(
                segStartMs: segStartMs, segEndMs: segEndMs,
                recordingStartMs: recordingStartMs, recordingEndMs: recordingEndMs
            )
            debugLog("[ChartGate] seg[\(segIdx)] segMs=\(segStartMs)..\(segEndMs) recMs=\(recordingStartMs)..\(recordingEndMs) → \(subWindows.count) sub-window(s)")
            for win in subWindows {
                allSamples += await hkSamples(in: win, segIdx: segIdx)
            }
        }
        return allSamples.sorted { $0.timeMs < $1.timeMs }
    }

    /// Defensive guard: ignore obviously invalid multi-day segments so chart
    /// HR fetches stay bounded to real overnight windows.
    private static func isPlausibleSegment(startMs: Int64, endMs: Int64, index: Int) -> Bool {
        let maxReasonableSegmentMs: Int64 = 16 * 60 * 60 * 1000
        let durationMs = endMs - startMs
        guard durationMs > 0, durationMs <= maxReasonableSegmentMs else {
            debugLog("[ChartGate] seg[\(index)] duration=\(durationMs / 60000)min out of bounds — skip")
            return false
        }
        return true
    }

    /// The sub-windows of a segment that do NOT overlap the Polar recording.
    /// There are 0, 1, or 2:
    ///   • Segment fully outside recording → 1 range = full segment
    ///   • Segment overlaps from one side → 1 range (the non-overlap side)
    ///   • Segment encloses recording      → 2 ranges (before + after)
    ///   • Segment fully inside recording  → 0 ranges (Polar already covered)
    private static func uncoveredWindows(
        segStartMs: Int64,
        segEndMs: Int64,
        recordingStartMs: Int64,
        recordingEndMs: Int64
    ) -> [(start: Int64, end: Int64)] {
        if segEndMs <= recordingStartMs || segStartMs >= recordingEndMs {
            return [(segStartMs, segEndMs)]
        }
        var windows: [(start: Int64, end: Int64)] = []
        if segStartMs < recordingStartMs { windows.append((segStartMs, recordingStartMs)) }
        if segEndMs > recordingEndMs { windows.append((recordingEndMs, segEndMs)) }
        return windows
    }

    /// HealthKit HR for one uncovered sub-window. Negligible windows (<1 min)
    /// are skipped — HK won't have meaningful samples and the round trip isn't
    /// worth it.
    private func hkSamples(
        in win: (start: Int64, end: Int64),
        segIdx: Int
    ) async -> [(timeMs: Int64, hr: Double)] {
        guard win.end - win.start >= 60_000 else {
            debugLog("[ChartGate] seg[\(segIdx)] sub-window \((win.end - win.start) / 1000)s — too small, skip")
            return []
        }
        let winStart = session.startDate.addingTimeInterval(Double(win.start) / 1000.0)
        let winEnd = session.startDate.addingTimeInterval(Double(win.end) / 1000.0)
        let samples = (try? await AppDependencies.current.collection.healthKitManager.fetchHeartRateSamples(from: winStart, to: winEnd)) ?? []
        debugLog("[ChartGate] seg[\(segIdx)] sub-window \(winStart.formatted(date: .omitted, time: .shortened))→\(winEnd.formatted(date: .omitted, time: .shortened)) returned \(samples.count) HK HR samples")
        return samples.map {
            (timeMs: Int64($0.date.timeIntervalSince(session.startDate) * 1000), hr: $0.hr)
        }
    }

}

/// Moved out of the view so the stats computer can use it.
/// Derive sleep duration metrics from HealthKit or HR-based estimation.
///
/// How long the user slept, and how confident we are about it.
///
/// A named type rather than a six-member tuple. Every function returning it
/// is `private`, so there is no signature to break — and a tuple is read
/// positionally at construction while being read by name at the call site,
/// which is exactly the mismatch a named type removes.
struct SleepDurationFields {
    let minutes: Int
    let formatted: String
    let deepMinutes: Int
    let awakenings: Int
    let efficiency: Double
    /// False when the numbers are estimated from the recording alone.
    let isFromHealthKit: Bool
}
