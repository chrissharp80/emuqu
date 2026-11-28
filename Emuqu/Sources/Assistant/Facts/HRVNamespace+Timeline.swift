import Foundation

// The night as a curve: heart rate and RMSSD in clock-time buckets from the
// stored RR series, and every HRV-bearing reading of a day. Read-only views
// of recorded beats, so "what was my heart rate at 3am" and "when did my
// heart rate drop" have a lookup that holds the answer.

extension HRVNamespace {
    /// Five-minute buckets cover a 12-hour recording in 144 records; a
    /// longer one gets wider buckets so the result stays near 15 KB.
    static let timelineBucketMinutes = 5
    static let timelineMaxBuckets = 144

    /// A bucket with fewer clean beats than this has no heart rate: a few
    /// beats around a strap dropout are not the heart rate of five minutes.
    static let timelineMinimumBeats = 10

    var timelineEntries: [FactEntry] {
        [hrvTimelineByDateEntry, hrvReadingsByDateEntry]
    }

    private var hrvTimelineByDateEntry: FactEntry {
        .parameterized(
            pattern: "hrv.timeline.by_date($date)",
            paramExample: "2026-04-21",
            description: """
            The night's heart-rate curve for a local date (yyyy-MM-dd): the overnight recording in clock-time buckets (5 minutes each, wider past 12 hours), each with time_iso (the bucket's start on the clock), \
            hr_bpm (mean heart rate of its clean beats), rmssd_ms (HRV over the bucket, absent with under 30 clean beats) and beat_count. Use for 'what was my heart rate at 3am', 'when did my heart rate drop', \
            'when did my HR bottom out', 'was my heart rate high early in the night', 'how did my HRV change through the night'. Buckets with no beats (strap off, dropouts) are left out. \
            \(RecordFields.sentence(RecordFields.hrvTimeline))
            """,
            availability: { OvernightArchive.availability(self.archive) },
            resolve: { param, _ in
                Self.timelineRecord(for: OvernightArchive.anyByDate(param, archive: self.archive), archive: self.archive)
            }
        )
    }

    /// The night's RR series bucketed on the clock. The lightweight decode
    /// skips the series, so the full session is loaded here.
    static func timelineRecord(for session: HRVSession?, archive: SessionArchive) -> FactValue {
        guard let session else { return .missing(reason: .notRecorded, detail: "no overnight session matched") }
        guard let full = archive.retrieveOrLog(session.id), let series = full.rrSeries,
              let first = series.points.first, let last = series.points.last
        else { return .missing(reason: .notRecorded, detail: "no beat-to-beat data stored for this night") }
        let spanMinutes = Double(max(0, last.exportTimeMs - first.exportTimeMs)) / 60000
        let bucketMinutes = max(timelineBucketMinutes, Int((spanMinutes / Double(timelineMaxBuckets)).rounded(.up)))
        let buckets = timelineBuckets(series, flags: full.artifactFlags ?? [], bucketMs: Int64(bucketMinutes) * 60000)
        let record: [String: FactValue] = [
            "date": .date(session.startDate),
            "recording_start_iso": .date(series.clockTime(forTMs: first.t_ms)),
            "recording_end_iso": .date(series.actualEndDate),
            "bucket_minutes": .integer(bucketMinutes),
            "bucket_count": .integer(buckets.count),
            "buckets": .list(buckets)
        ]
        return OvernightArchive.labeled(.record(record), session)
    }

    /// One record per run of beats that fall in the same clock bucket, in
    /// recording order. A beat's clock place is its wall-clock stamp where
    /// the stream recorded one (`RRPoint.exportTimeMs`), so dropouts leave
    /// gaps instead of pulling later beats early. Buckets sit on clock
    /// multiples of their width, so a five-minute bucket starts at 3:00.
    private static func timelineBuckets(_ series: RRSeries, flags: [ArtifactFlags], bucketMs: Int64) -> [FactValue] {
        let points = series.points
        let originMs = Int64((series.startDate.timeIntervalSince1970 * 1000).rounded())
        let slot: (Int) -> Int64 = { (originMs + points[$0].exportTimeMs) / bucketMs }
        var out: [FactValue] = []
        var runStart = 0
        for index in 1 ... points.count where index == points.count || slot(index) != slot(runStart) {
            let start = Date(timeIntervalSince1970: Double(slot(runStart) * bucketMs) / 1000)
            if let bucket = bucketRecord(points, flags: flags, range: runStart ..< index, start: start) { out.append(bucket) }
            runStart = index
        }
        return out
    }

    /// Mean heart rate and RMSSD over the bucket's clean beats: not flagged
    /// as artifact and inside the physiological RR range. RMSSD is the
    /// app's peak-scan estimator (`TimeDomainAnalyzer.peakScanRMSSD`), the
    /// one the overnight chart draws.
    private static func bucketRecord(_ points: [RRPoint], flags: [ArtifactFlags], range: Range<Int>, start: Date) -> FactValue? {
        let clean = range.filter { index in
            !(index < flags.count && flags[index].isArtifact) && points[index].isPhysiologicallyValid
        }
        guard clean.count >= timelineMinimumBeats else { return nil }
        let meanRR = Double(clean.reduce(0) { $0 + points[$1].rr_ms }) / Double(clean.count)
        var record: [String: FactValue] = [
            "time_iso": .date(start),
            "hr_bpm": .double((600_000 / meanRR).rounded() / 10),
            "beat_count": .integer(clean.count)
        ]
        record["rmssd_ms"] = TimeDomainAnalyzer.peakScanRMSSD(points: points, flags: flags, range: range)
            .map { .double(($0 * 10).rounded() / 10) }
        return .record(record)
    }

    // MARK: - Every reading of a day

    private var hrvReadingsByDateEntry: FactEntry {
        .parameterized(
            pattern: "hrv.readings.by_date($date)",
            paramExample: "2026-04-21",
            description: """
            Every HRV reading filed under a local date (yyyy-MM-dd), in the order recorded: the overnight, naps and quick readings, unreliable ones included (reliable_for_trends false, data_quality preSleep or insufficient). \
            hrv.by_date gives only the day's headline reading; use this for 'what was my nap HRV', 'my quick reading this afternoon', 'all my readings on Tuesday', 'the partial recording last night'. \
            One hrv record per reading, session_type saying which, plus reliable_for_trends and data_quality. \
            \(RecordFields.sentence(RecordFields.hrv, except: RecordFields.hrvSingleNightOnly))
            """,
            availability: { OvernightArchive.availability(self.archive) },
            resolve: { param, _ in Self.readingsRecord(on: param, archive: self.archive) }
        )
    }

    /// The day's readings that carry an analysis, each labelled with whether
    /// it feeds trends. A reading with no analysis has no HRV to report.
    static func readingsRecord(on iso: String, archive: SessionArchive) -> FactValue {
        let records: [FactValue] = OvernightArchive.readings(on: iso, archive: archive).compactMap { entry in
            guard let session = archive.retrieveLightweightOrLog(entry.sessionId),
                  case var .record(fields) = hrvRecord(for: session)
            else { return nil }
            fields["reliable_for_trends"] = .boolean(session.isReliableForHRVAggregates)
            fields["data_quality"] = session.hrvDataQuality.map { .string($0.rawValue) }
            return .record(fields)
        }
        guard !records.isEmpty else { return .missing(reason: .notRecorded, detail: "no HRV reading on \(iso)") }
        return .list(records)
    }
}
