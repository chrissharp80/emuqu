@testable import Emuqu
import XCTest

/// A beat carries two clocks: `t_ms`, the running sum of the intervals kept,
/// and `wallClockMs`, a Verity Sense memory beat's real start or a streamed
/// batch's arrival. These fixtures are recorded the way the sensors record
/// them (a Verity Sense's quality gate rejects intervals, the phone receives
/// beats in notification batches and loses some to dropouts), and every
/// merge, coverage test, spectrum, breathing rate, DFA, import, Watch relay,
/// gap report and sleep window reads them on one real clock (`BeatTimeline`).
@MainActor
final class BeatTimelineTests: XCTestCase {
    // MARK: - Fixtures

    /// One measured interval, and whether the Verity Sense's quality gate
    /// rejects it.
    private struct Sample {
        let ms: Int
        let rejected: Bool

        var ppi: StrapPPISample {
            StrapPPISample(ppInMs: ms, ppErrorEstimate: 5, blockerBit: rejected ? 1 : 0)
        }
    }

    /// `count` intervals around 1 s, rising and falling with a four-beat
    /// breath (15 a minute), every `rejectEvery`-th rejected (none for 0).
    private func night(_ count: Int, rejectEvery: Int = 0) -> [Sample] {
        (0 ..< count).map { i in
            let rr = 1_000 + Int((60 * sin(Double(i) * .pi / 2)).rounded())
            return Sample(ms: rr, rejected: rejectEvery > 0 && i % rejectEvery == rejectEvery / 2)
        }
    }

    /// When each sample really started, ms from the recording's start.
    private func starts(_ samples: [Sample]) -> [Int64] {
        var sum: Int64 = 0
        return samples.map { sample in
            defer { sum += Int64(sample.ms) }
            return sum
        }
    }

    /// A Verity Sense recording pulled from its memory.
    private func memory(_ samples: [Sample]) -> [RRPoint] {
        StrapPPIFilter.rrPoints(from: samples.map(\.ppi))
    }

    /// An H10's own recording: every interval at its real start, those at
    /// `missing` never recorded.
    private func h10Memory(_ samples: [Sample], missing: Range<Int> = 0 ..< 0) -> [RRPoint] {
        zip(samples, starts(samples)).enumerated().compactMap { i, beat in
            missing.contains(i) ? nil : RRPoint(t_ms: beat.1, rr_ms: beat.0.ms)
        }
    }

    /// The samples as the phone streams them: a notification every `tickMs`
    /// carries the intervals that ended since the one before and arrives
    /// `latencyMs` after it was sent; notifications sent inside `lost` never
    /// arrive. Each beat's `t_ms` is the running sum of the beats kept, and a
    /// rejected interval is gated as `StrapStreamSession.ingestPpi` gates it.
    private func streamed(
        _ samples: [Sample], tickMs: Int64 = 1_000, latencyMs: Int64 = 40, lost: Range<Int64> = 0 ..< 0
    ) -> [RRPoint] {
        var (points, endMs, beatSum, removed) = ([RRPoint](), Int64(0), Int64(0), false)
        for sample in samples {
            endMs += Int64(sample.ms)
            let sentMs = (endMs + tickMs - 1) / tickMs * tickMs
            guard !lost.contains(sentMs) else { continue }
            guard StrapPPIFilter.acceptedInterval(sample.ppi) != nil else {
                removed = true
                continue
            }
            let marked = StrapPPIFilter.marksRemovedBeat(removed, after: points)
            points.append(RRPoint(t_ms: beatSum, rr_ms: sample.ms, wallClockMs: sentMs + latencyMs, followsRemovedBeat: marked))
            (beatSum, removed) = (beatSum + Int64(sample.ms), false)
        }
        return points
    }

    /// The real start of every sample that reached `streamed` or `memory`.
    private func keptStarts(_ samples: [Sample], lost: Range<Int64> = 0 ..< 0, tickMs: Int64 = 1_000) -> [Int64] {
        zip(samples, starts(samples)).compactMap { sample, start in
            let sentMs = (start + Int64(sample.ms) + tickMs - 1) / tickMs * tickMs
            return sample.rejected || lost.contains(sentMs) ? nil : start
        }
    }

    private func isStrictlyRising(_ times: [Int64]) -> Bool {
        zip(times, times.dropFirst()).allSatisfy { $0 < $1 }
    }

    private func sharesAnArrival(_ points: [RRPoint]) -> Bool {
        zip(points, points.dropFirst()).contains { $0.wallClockMs != nil && $0.wallClockMs == $1.wallClockMs }
    }

    private func session(_ points: [RRPoint], source: String, start: Date) -> HRVSession {
        var session = HRVSession(startDate: start, sessionType: .overnight)
        session.rrSeries = RRSeries(points: points, sessionId: session.id, startDate: start)
        session.dataSourceSummary = HRVSession.DataSourceSummary(
            selectedSource: source, streamingBeats: points.count, deviceBeats: nil,
            totalBeats: points.count, beatDifferencePercent: nil, reconnectCount: 0
        )
        return session
    }

    // MARK: - The clock

    /// A streamed batch's beats are laid back from its arrival by their own
    /// intervals, and a dropout's time comes back: every beat sits at its
    /// real start plus no more than the latency and one notification wait.
    func testAStreamedBeatIsTimedFromItsBatchAndADropoutKeepsItsTime() {
        let samples = night(600)
        let lost: Range<Int64> = 200_000 ..< 230_000
        let points = streamed(samples, lost: lost)
        let real = keptStarts(samples, lost: lost)
        XCTAssertTrue(sharesAnArrival(points), "the fixture streams batches")
        let times = points.beatTimesMs
        XCTAssertTrue(isStrictlyRising(times))
        for (time, start) in zip(times, real) {
            XCTAssertGreaterThanOrEqual(time, start)
            XCTAssertLessThanOrEqual(time - start, 1_040)
        }
    }

    /// A Verity Sense recording's beats sit at their real starts, though its
    /// beat clock runs behind by every interval the gate rejected.
    func testAVeritySenseMemoryBeatIsTimedAtItsRealStart() throws {
        let samples = night(600, rejectEvery: 10)
        let points = memory(samples)
        XCTAssertEqual(points.beatTimesMs, keptStarts(samples))
        let last = try XCTUnwrap(points.last)
        XCTAssertEqual(try XCTUnwrap(points.beatTimesMs.last) - last.t_ms, Int64(samples.filter(\.rejected).map(\.ms).reduce(0, +)))
        let plotted = HRVDetailV2View.sampledRRPoints(RRSeries(points: points, sessionId: UUID(), startDate: Date()))
        XCTAssertEqual(plotted.map(\.elapsedSec), plotted.map { Double(points[$0.id].wallClockMs ?? 0) / 1000 }, "the beat chart's time axis is real time")
    }

    /// A workout's Verity Sense recording is cut at the stop by real time:
    /// its beat clock runs behind, and by it the beats from after the stop
    /// still fit.
    func testAWorkoutsVeritySenseRecordingIsCutAtTheStopByRealTime() {
        let samples = night(600, rejectEvery: 10)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let bounded = boundedToWorkoutWindow(memory(samples), startDate: start, stopDate: start.addingTimeInterval(300))
        XCTAssertEqual(bounded.count, keptStarts(samples).filter { $0 <= 300_000 }.count)
    }

    // MARK: - Merges

    /// Two streamed copies of one night (a backup and the full stream, or
    /// the copies two devices synced) merge into the fuller one with no beat
    /// in twice, directly and through the session merge the iCloud
    /// fuller-copy pull and the same-night merge use.
    func testTwoStreamedCopiesOfANightMergeWithNoBeatTwice() throws {
        let full = streamed(night(900))
        let shorter = Array(full.prefix(600))
        let merged = DataSourceSelector.mergePoints(internal: full, streaming: shorter)
        XCTAssertEqual(merged.map(\.rr_ms), full.map(\.rr_ms))
        XCTAssertTrue(isStrictlyRising(merged.map(\.t_ms)))
        let onRealClock = DataSourceSelector.mergePoints(internal: [], streaming: full)
        XCTAssertEqual(DataSourceSelector.mergePoints(internal: onRealClock, streaming: shorter).count, full.count)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var existing = session(full, source: "streaming", start: start)
        XCTAssertTrue(SessionMerger.mergeSessionData(from: session(shorter, source: "streaming", start: start), into: &existing))
        XCTAssertEqual(try XCTUnwrap(existing.rrSeries).points.map(\.rr_ms), full.map(\.rr_ms))
    }

    /// A Verity Sense night whose memory stopped early is completed from the
    /// stream with only the beats after the memory's end: the memory's beat
    /// clock runs behind the stream's arrival clock by every rejected
    /// interval, and compared raw the stream's beats from that stretch were
    /// put in a second time.
    func testAVeritySenseCompositeAddsOnlyTheStreamsBeatsPastTheMemorysEnd() throws {
        let samples = night(1_000, rejectEvery: 20)
        let device = memory(Array(samples.prefix(850)))
        let stream = streamed(samples)
        let result = try XCTUnwrap(DataSourceSelector.selectBestSource(
            streamingPoints: stream, internalPoints: device, sessionId: UUID(), sessionStart: Date()
        ))
        XCTAssertTrue(result.isComposite)
        let tail = samples[850...].filter { !$0.rejected }.count
        XCTAssertEqual(result.points.count, device.count + tail)
        XCTAssertTrue(isStrictlyRising(result.points.map(\.t_ms)))
    }

    /// The phone's beats arrive after they end and the Watch's carry their
    /// starts: a workout that hands over between them is interleaved by
    /// when each beat started.
    func testTheWatchsBeatsAndThePhonesInterleaveOnTheRealClock() {
        let phone = [
            RRPoint(t_ms: 0, rr_ms: 880, wallClockMs: 5_440),
            RRPoint(t_ms: 880, rr_ms: 920, wallClockMs: 5_440)
        ]
        let watch = [
            RRPoint(t_ms: 0, rr_ms: 910, wallClockMs: 5_400),
            RRPoint(t_ms: 910, rr_ms: 930, wallClockMs: 6_310)
        ]
        let merged = WorkoutRRMerge.merged(source: .strap, streaming: phone, watchRouted: watch)
        XCTAssertEqual(merged.map(\.rr_ms), [880, 920, 910, 930])
    }

    // MARK: - Imports and backups

    /// A composite's RR export reads back with its timeline: the stream's
    /// gap-fill beats carry their real starts, so no two share a timestamp.
    func testACompositeRRExportImportsWithItsTimeline() throws {
        let samples = night(400)
        let stream = streamed(samples, tickMs: 2_000)
        let result = try XCTUnwrap(DataSourceSelector.selectBestSource(
            streamingPoints: stream, internalPoints: h10Memory(samples, missing: 150 ..< 200),
            sessionId: UUID(), sessionStart: Date()
        ))
        XCTAssertTrue(result.isComposite)
        XCTAssertTrue(sharesAnArrival(result.points), "the gap fill holds a batch")
        XCTAssertTrue(isStrictlyRising(result.points.map(\.t_ms)))
        let imported = try RRDataImporter().importContent(RRDataImporter.recordingCSV(points: result.points), fileName: "rr.csv")
        XCTAssertEqual(imported.timeline, result.points)
    }

    /// A composite an earlier build saved stamped a gap-fill batch's beats
    /// with its arrival. Its export still imports with its timeline, the
    /// batch's beats laid back from that arrival.
    func testAnEarlierCompositeExportWithSharedTimestampsImportsSpreadOut() throws {
        var points = (0 ..< 60).map { RRPoint(t_ms: Int64($0) * 1_000, rr_ms: 1_000) }
        points += [RRPoint(t_ms: 63_000, rr_ms: 1_000, wallClockMs: 63_000), RRPoint(t_ms: 63_000, rr_ms: 1_000, wallClockMs: 63_000)]
        points += (64 ..< 124).map { RRPoint(t_ms: Int64($0) * 1_000, rr_ms: 1_000) }
        let imported = try RRDataImporter().importContent(RRDataImporter.recordingCSV(points: points), fileName: "rr.csv")
        let timeline = try XCTUnwrap(imported.timeline)
        XCTAssertEqual(timeline.map(\.t_ms)[59 ... 62], [59_000, 61_000, 62_000, 64_000])
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date(timeIntervalSince1970: 1_700_000_000))
        var session = HRVSession(startDate: series.startDate, sessionType: .overnight)
        session.rrSeries = series
        let csv = RRDataImporter.emuquRRExportHeader + "\n" + ExportDataView.rrCSVRows(for: session, series: series, timeZone: .gmt)
        let importer = RRDataImporter()
        let data = try XCTUnwrap(importer.parseFlowHRVMultiSession(csv, fileName: "e.csv").sessions.first)
        let reread = try XCTUnwrap(importer.createSessionFromFlowHRVData(data, originalFileName: "e.csv").rrSeries?.points)
        XCTAssertEqual(reread.map(\.t_ms)[59 ... 62], [59_000, 61_000, 62_000, 64_000])
    }

    /// Beats that share a timestamp are each recovered from a backup, in the
    /// order written; a beat written twice is recovered once.
    func testABackupReadKeepsBeatsThatShareATimestamp() {
        let first = RRPoint(t_ms: 63_000, rr_ms: 980, wallClockMs: 63_000)
        let second = RRPoint(t_ms: 63_000, rr_ms: 1_020, wallClockMs: 63_000)
        let earlier = RRPoint(t_ms: 1_000, rr_ms: 1_000)
        XCTAssertEqual(RawRRBackup.onceEachInTimeOrder([first, second, earlier, first]), [earlier, first, second])
    }

    // MARK: - Spectrum, breathing rate, DFA

    /// The same Verity Sense night, once as pulled from the strap (its beat
    /// clock behind real time by the 10% rejected) and once with every beat
    /// timed at its real start, reads one breathing rate and one spectrum:
    /// the four-beat breath, 15 a minute. On the beat clock both read 10%
    /// high.
    func testBreathingRateAndSpectrumReadAVeritySenseNightOnItsRealClock() throws {
        let pulled = memory(night(480, rejectEvery: 10))
        let timed = pulled.map { RRPoint(t_ms: $0.wallClockMs ?? $0.t_ms, rr_ms: $0.rr_ms) }
        let (a, b) = (RRSeries(points: pulled, sessionId: UUID(), startDate: Date()), RRSeries(points: timed, sessionId: UUID(), startDate: Date()))
        let flags = Array(repeating: ArtifactFlags.clean, count: pulled.count)
        let rate = try XCTUnwrap(HRVAnalysisPipeline.respirationRate(series: a, flags: flags, windowStart: 0, windowEnd: pulled.count))
        let reference = try XCTUnwrap(HRVAnalysisPipeline.respirationRate(series: b, flags: flags, windowStart: 0, windowEnd: pulled.count))
        XCTAssertEqual(rate, reference, accuracy: 1e-9)
        XCTAssertEqual(rate, 15, accuracy: 0.75)
        let spectrum = try XCTUnwrap(FrequencyDomainAnalyzer.computeFrequencyDomain(a, flags: flags, windowStart: 0, windowEnd: pulled.count))
        let referenceSpectrum = try XCTUnwrap(FrequencyDomainAnalyzer.computeFrequencyDomain(b, flags: flags, windowStart: 0, windowEnd: pulled.count))
        XCTAssertEqual(spectrum.hf, referenceSpectrum.hf, accuracy: referenceSpectrum.hf * 1e-9)
        XCTAssertEqual(spectrum.lf, referenceSpectrum.lf, accuracy: max(referenceSpectrum.lf, 1) * 1e-9)
    }

    /// DFA interpolates each beat the Verity Sense removed, as it does a beat
    /// the app flagged: the night pulled from the strap gives the α1 of the
    /// same night with the removed intervals kept and flagged.
    func testDFAInterpolatesTheBeatsAVeritySenseRemoved() throws {
        let samples = night(480, rejectEvery: 10)
        let pulled = RRSeries(points: memory(samples), sessionId: UUID(), startDate: Date())
        let whole = RRSeries(points: h10Memory(samples), sessionId: UUID(), startDate: Date())
        let flagged = samples.map { $0.rejected ? ArtifactFlags(isArtifact: true, type: .technical, confidence: 1) : .clean }
        let pulledWindow = try XCTUnwrap(TimeDomainAnalyzer.cleanWindow(
            pulled, flags: Array(repeating: .clean, count: pulled.points.count), windowStart: 0, windowEnd: pulled.points.count
        ))
        let wholeWindow = try XCTUnwrap(TimeDomainAnalyzer.cleanWindow(whole, flags: flagged, windowStart: 0, windowEnd: samples.count))
        XCTAssertEqual(DFAAnalyzer.interpolatedSegments(pulledWindow), DFAAnalyzer.interpolatedSegments(wholeWindow))
        let alpha1 = try XCTUnwrap(DFAAnalyzer.compute(window: pulledWindow)?.alpha1)
        XCTAssertEqual(alpha1, try XCTUnwrap(DFAAnalyzer.compute(window: wholeWindow)?.alpha1), accuracy: 1e-12)
        let selector = WindowSelector()
        let pulledBlock = try XCTUnwrap(selector.evaluateWindow(
            series: pulled, flags: Array(repeating: .clean, count: pulled.points.count), startIdx: 0, endIdx: pulled.points.count,
            sessionStartMs: 0, sessionEndMs: try XCTUnwrap(pulled.points.last).endMs
        ))
        let wholeBlock = try XCTUnwrap(selector.evaluateWindow(
            series: whole, flags: flagged, startIdx: 0, endIdx: samples.count, sessionStartMs: 0, sessionEndMs: try XCTUnwrap(whole.points.last).endMs
        ))
        XCTAssertEqual(try XCTUnwrap(pulledBlock.dfaAlpha1), try XCTUnwrap(wholeBlock.dfaAlpha1), accuracy: 1e-12, "the window ranking reads the same α1")
    }

    /// A merge that moves a Verity Sense recording onto the real clock moves
    /// the kept analysis's times with their beats.
    func testAMergeOntoTheRealClockMovesTheAnalysisTimesWithTheirBeats() throws {
        let pulled = memory(night(480, rejectEvery: 10))
        let result = try XCTUnwrap(MergeClockFixture.analysis(of: RRSeries(points: pulled, sessionId: UUID(), startDate: Date())))
        let merged = DataSourceSelector.mergePoints(internal: pulled, streaming: [])
        let moved = SessionMerger.reindexed(result, from: pulled, onto: merged)
        XCTAssertEqual(moved.windowStart, result.windowStart)
        XCTAssertEqual(moved.windowStartMs, pulled[100].wallClockMs)
        XCTAssertEqual(moved.windowEndMs, pulled[300].wallClockMs)
    }

    // MARK: - Watch relay

    /// An interval the Watch relays that the bounds reject is no beat, but
    /// its time passed: the beat before it is placed back across it, and the
    /// beat after it is marked as following a removed one, also when the
    /// rejection ended the sample before.
    func testAWatchIntervalTheBoundsRejectKeepsItsTimeAndMarksTheNextBeat() {
        let beats = WatchStrapBeat.beats(rrMillis: [850, 150, 750], sentAt: 1_010)
        XCTAssertEqual(beats.map(\.endEpochMs), [1_009_100, 1_009_250, 1_010_000])
        let placed = WatchStrapBeat.placed(beats, after: 0)
        XCTAssertEqual(placed.map(\.startEpochMs), [1_008_250, 1_009_250])
        XCTAssertEqual(placed.map(\.followsRemovedBeat), [false, true])
        var removed = false
        _ = WatchStrapBeat.placed(WatchStrapBeat.beats(rrMillis: [800, 150], sentAt: 1_020), after: 0, removedBefore: &removed)
        XCTAssertTrue(removed)
        let next = WatchStrapBeat.placed(WatchStrapBeat.beats(rrMillis: [900], sentAt: 1_021), after: 0, removedBefore: &removed)
        XCTAssertEqual(next.map(\.followsRemovedBeat), [true])
    }

    // MARK: - Reports

    /// The intervals a Verity Sense stream received and rejected are no
    /// dropout: two hours with 10% rejected report no missing minutes, and
    /// a 15-minute dropout reports its 15.
    func testAVeritySenseStreamsRejectedIntervalsAreNotReportedAsADropout() throws {
        let samples = night(7_200, rejectEvery: 10)
        XCTAssertEqual(OvernightStreamingCoordinator.streamGapMinutes(streamed(samples)), 0)
        let dropout = OvernightStreamingCoordinator.streamGapMinutes(streamed(samples, lost: 3_000_000 ..< 3_900_000))
        XCTAssertTrue((14 ... 15).contains(dropout), "\(dropout)")
        let series = RRSeries(points: streamed(samples), sessionId: UUID(), startDate: Date())
        XCTAssertLessThan(try XCTUnwrap(series.estimatedDataLossPercent), 0.5, "the detail screen shows no data loss")
    }

    /// The verification badge sees a streamed night's dropout, which its
    /// beat clock never shows.
    func testVerificationSeesAStreamedDropout() throws {
        let points = streamed(night(3_600), lost: 600_000 ..< 2_400_000)
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let result = Verification().verify(series, flags: Array(repeating: .clean, count: points.count))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.metrics.maxGapMs), 29 * 60_000)
    }

    /// The sleep stage windows read each streamed beat at its own time, so
    /// the beats of one batch no longer share one.
    func testSleepStageBeatsOfOneBatchEachKeepTheirOwnTime() {
        let points = streamed(night(120), tickMs: 2_000)
        XCTAssertTrue(sharesAnArrival(points))
        XCTAssertTrue(isStrictlyRising(HRVSleepStageClassifier.wallClockTimed(points).map(\.t_ms)))
    }
}
