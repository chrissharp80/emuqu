import Foundation

/// The overnight peak-HRV search, shared by the Overnight screen
/// (`OvernightChartsView`) and its PDF report (`OvernightReportRenderer`) so
/// the two cannot pick different peaks for one recording: RMSSD over a
/// 300-beat window centred every 30 beats (the last step snapped to the final
/// beat), the peak taken from the windows centred in the 30–70% band of the
/// sleep window, or from all of them when none is.
enum OvernightPeakHRV {
    struct Sample: Equatable {
        /// The beat the window is centred on.
        let index: Int
        let rmssd: Double
        let timeMs: Int64
    }

    /// A sleep envelope with both ends known, else nil.
    static func envelope(start: Date?, end: Date?) -> (start: Date, end: Date)? {
        guard let start, let end else { return nil }
        return (start, end)
    }

    static let windowBeats = 300
    static let stepBeats = 30

    /// The sleep window on the beats' `t_ms` axis: HealthKit's sleep
    /// envelope, else the session's stored sleep period, else the whole
    /// recording.
    static func sleepWindowMs(
        series: RRSeries, sessionStart: Date, healthKit: (start: Date, end: Date)?, stored: (startMs: Int64?, endMs: Int64?)
    ) -> (start: Int64, end: Int64) {
        let recordingEnd = series.points.last?.t_ms ?? Int64.max
        let onBeatClock = { (offset: Int64) in tMs(forSessionOffset: offset, series: series, sessionStart: sessionStart) }
        if let healthKit {
            let start = max(0, onBeatClock(MillisecondOffset.between(healthKit.start, and: sessionStart, fallback: 0)))
            let end = min(recordingEnd, onBeatClock(MillisecondOffset.between(healthKit.end, and: sessionStart, fallback: 0)))
            return (start, end)
        }
        let start = stored.startMs.map(onBeatClock) ?? 0
        let rawEnd = stored.endMs.map(onBeatClock) ?? recordingEnd
        return (start, (rawEnd > start && rawEnd >= 0) ? rawEnd : recordingEnd)
    }

    /// A session-clock offset (ms after `sessionStart`, as HealthKit dates
    /// and the stored sleep fields are) moved onto the `t_ms` axis the beats
    /// are filtered and plotted on. Streamed `t_ms` is cumulative RR time and
    /// falls behind the wall clock after a Bluetooth drop, so the offset is
    /// shifted by the drift (`t_ms` minus wall clock) of the beat nearest to
    /// it in wall-clock time; past either end of the recording the drift at
    /// that end applies. A beat without a wall-clock stamp has no drift: its
    /// `t_ms` already is the session clock (strap recordings, and sessions
    /// `DataSourceSelector` re-based), so the offset is returned unchanged.
    static func tMs(forSessionOffset offsetMs: Int64, series: RRSeries, sessionStart: Date) -> Int64 {
        let date = sessionStart.addingTimeInterval(TimeInterval(offsetMs) / 1000)
        guard let index = series.indexClosestToWallClock(date),
              let wallMs = series.points[index].wallClockMs else { return offsetMs }
        let seriesShiftMs = MillisecondOffset.between(series.startDate, and: sessionStart, fallback: 0)
        return offsetMs + series.points[index].t_ms - (wallMs + seriesShiftMs)
    }

    /// The 30–70% slice of a sleep window, on the `t_ms` axis.
    static func searchBand(sleepStartMs: Int64, sleepEndMs: Int64) -> (earlyMs: Int64, lateMs: Int64) {
        let sleepDuration = sleepEndMs - sleepStartMs
        return (
            sleepStartMs + Int64(Double(sleepDuration) * 0.30),
            sleepStartMs + Int64(Double(sleepDuration) * 0.70)
        )
    }

    /// RMSSD over `windowBeats` beats centred every `stepBeats` beats; a
    /// window without enough clean beats (`TimeDomainAnalyzer.peakScanRMSSD`)
    /// gives no sample.
    static func rollingRMSSD(points: [RRPoint], flags: [ArtifactFlags]) -> [Sample] {
        var out: [Sample] = []
        var i = 0
        while i <= points.count - 1 {
            let lo = max(0, i - windowBeats / 2)
            let hi = min(points.count, i + windowBeats / 2)
            if let rmssd = TimeDomainAnalyzer.peakScanRMSSD(points: points, flags: flags, range: lo ..< max(lo, hi)) {
                out.append(Sample(index: i, rmssd: rmssd, timeMs: points[i].t_ms))
            }
            // Snap the last step to the final point so the tail isn't dropped.
            i = (i < points.count - 1 && i + stepBeats > points.count - 1) ? points.count - 1 : i + stepBeats
        }
        return out
    }

    /// The highest sample centred in `band`, or in the whole recording when
    /// none is.
    static func peak(in samples: [Sample], band: (earlyMs: Int64, lateMs: Int64)) -> Sample? {
        let constrained = samples.filter { $0.timeMs >= band.earlyMs && $0.timeMs <= band.lateMs }
        return (constrained.isEmpty ? samples : constrained).max { $0.rmssd < $1.rmssd }
    }
}
