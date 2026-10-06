@testable import Emuqu
import XCTest

/// Two recordings of one night are merged on ONE clock.
///
/// `RRPoint.t_ms` counts from the start of its own recording. A merge that
/// treats two recordings as if both began at t = 0 interleaves their beats:
/// the reviewer's night (23:00 for 90 min at ~1000 ms, then a second recording
/// at ~850 ms) came out with a third of its beats under 300 ms after the one
/// before and an RMSSD of 135.7 ms where each recording alone reads ~35.
final class SessionMergeClockTests: XCTestCase {
    private let night = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - Distinct recordings of one sleep

    /// 23:00 for 90 min and 04:50 for 120 min: a 4 h 20 min gap, inside the
    /// default 4.5 h, so one sleep. The later series must sit 5 h 50 min
    /// along the earlier one's clock.
    func testTwoRecordingsOfOneSleepAreMergedOnOneClock() {
        var existing = MergeClockFixture.session(start: night, minutes: 90, meanRR: 1000)
        let laterStart = night.addingTimeInterval((5 * 60 + 50) * 60)
        let imported = MergeClockFixture.session(start: laterStart, minutes: 120, meanRR: 850)
        let existingCount = existing.rrSeries?.points.count ?? 0
        let importedCount = imported.rrSeries?.points.count ?? 0

        XCTAssertTrue(SessionMerger.mergeSessionData(from: imported, into: &existing))

        let points = existing.rrSeries?.points ?? []
        XCTAssertEqual(points.count, existingCount + importedCount, "disjoint recordings keep every beat")
        XCTAssertEqual(MergeClockFixture.beatsTooSoon(points), 0, "no beat may land inside another recording's beat")
        XCTAssertLessThan(MergeClockFixture.rmssd(points), 30, "interleaving inflated RMSSD to ~135 ms")
        XCTAssertEqual(points[existingCount].t_ms, 21_000_000, "the later recording starts 5 h 50 min along")
        XCTAssertEqual(existing.startDate, night)
        XCTAssertEqual(existing.rrSeries?.startDate, night)
        XCTAssertEqual(existing.rrSeries?.sessionId, existing.id)
        XCTAssertEqual(existing.endDate, imported.endDate, "the merged night ends when the later recording ends")
    }

    /// The imported recording is the EARLIER one: the merged session keeps
    /// its own id but starts when the earlier recording started, and every
    /// time it held — sleep bounds, analysis window, window indices — moves
    /// to the shared clock.
    func testAnEarlierImportMovesTheMergedStartBackAndRecountsItsTimes() throws {
        let laterStart = night.addingTimeInterval((5 * 60 + 50) * 60)
        var existing = MergeClockFixture.session(start: laterStart, minutes: 120, meanRR: 850, withAnalysis: true)
        existing.sleepStartMs = 120_000
        existing.sleepEndMs = 7_140_000
        var imported = MergeClockFixture.session(start: night, minutes: 90, meanRR: 1000, withAnalysis: true)
        imported.sleepStartMs = 600_000
        imported.sleepEndMs = 5_400_000
        let originalId = existing.id
        let window = try XCTUnwrap(existing.analysisResult)
        let importedCount = imported.rrSeries?.points.count ?? 0

        XCTAssertTrue(SessionMerger.mergeSessionData(from: imported, into: &existing))

        XCTAssertEqual(existing.id, originalId)
        XCTAssertEqual(existing.startDate, night)
        XCTAssertEqual(existing.sleepStartMs, 600_000, "the sleep starts with the earlier recording's sleep")
        XCTAssertEqual(existing.sleepEndMs, 21_000_000 + 7_140_000, "and ends with the later one's, re-counted")
        let result = try XCTUnwrap(existing.analysisResult)
        XCTAssertEqual(result.windowStart, window.windowStart + importedCount, "the window still points at its beats")
        XCTAssertEqual(result.windowStartMs, window.windowStartMs.map { $0 + 21_000_000 })
        XCTAssertEqual(MergeClockFixture.beatsTooSoon(existing.rrSeries?.points ?? []), 0)
    }

    // MARK: - Copies of one recording

    /// The stream started 5 s before the strap's own recording of the same
    /// beats. On one clock every device beat coincides with its streamed copy,
    /// so only the 5 s the device lacks are added — at the start, where they
    /// happened — and the device beats begin 5 s in.
    func testTwoCopiesOfOneRecordingAreAlignedNotDoubled() throws {
        let stream = MergeClockFixture.points(minutes: 30, meanRR: 900, wallClock: true)
        let lead = try XCTUnwrap(stream.firstIndex { $0.t_ms >= 5000 })
        let leadMs = stream[lead].t_ms
        let device = stream[lead...].map { RRPoint(t_ms: $0.t_ms - leadMs, rr_ms: $0.rr_ms) }
        var existing = MergeClockFixture.session(start: night, points: stream, source: "streaming")
        let deviceStart = night.addingTimeInterval(Double(leadMs) / 1000)
        let imported = MergeClockFixture.session(start: deviceStart, points: device, source: "internal")

        XCTAssertTrue(SessionMerger.mergeSessionData(from: imported, into: &existing))

        let points = existing.rrSeries?.points ?? []
        XCTAssertEqual(points.count, device.count + lead, "each beat counted once")
        XCTAssertEqual(points.first { $0.wallClockMs == nil }?.t_ms, leadMs, "device beats start where they happened")
        XCTAssertEqual(MergeClockFixture.beatsTooSoon(points), 0)
        XCTAssertEqual(existing.startDate, night)
    }

    // MARK: - The shared time rule

    func testTheMergeGapDecidesBetweenOneSleepAndTwo() {
        let early = DateInterval(start: night, duration: 90 * 60)
        let reviewers = DateInterval(start: night.addingTimeInterval((6 * 60 + 10) * 60), duration: 120 * 60)
        let within = DateInterval(start: night.addingTimeInterval((5 * 60 + 50) * 60), duration: 120 * 60)
        let copy = DateInterval(start: night.addingTimeInterval(60), duration: 30 * 60)
        let gap = 4.5 * 3600
        XCTAssertEqual(SessionMerger.relation(of: reviewers, to: early, mergeGap: gap), .separate, "4 h 40 min apart")
        XCTAssertEqual(SessionMerger.relation(of: within, to: early, mergeGap: gap), .sameSleep, "4 h 20 min apart")
        XCTAssertEqual(SessionMerger.relation(of: copy, to: early, mergeGap: gap), .sameRecording)
        XCTAssertEqual(SessionMerger.relation(of: within, to: early, mergeGap: 3600), .separate, "a custom 1 h gap")
    }

    /// `copy(of:startDate:)` lists every stored field of `HRVSession` by
    /// hand. A field added to the session must be added there too, or a
    /// merge that moves a session's start would drop it.
    func testTheStartDateCopyCarriesEveryStoredField() {
        let session = MergeClockFixture.session(start: night, minutes: 1, meanRR: 1000)
        XCTAssertEqual(Mirror(reflecting: session).children.count, SessionMerger.copiedSessionFieldCount)
    }
}

/// Deterministic recordings for the merge-clock tests. Each beat varies by a
/// fixed +20, −5, −20, +5 ms cycle, so one recording alone has an RMSSD of
/// about 21 ms and any interleaving of two recordings shows at once.
enum MergeClockFixture {
    private static let cycle = [20, -5, -20, 5]

    static func points(minutes: Double, meanRR: Int, wallClock: Bool = false) -> [RRPoint] {
        var points: [RRPoint] = []
        var elapsed: Int64 = 0
        while elapsed < Int64(minutes * 60_000) {
            let rr = meanRR + cycle[points.count % cycle.count]
            points.append(RRPoint(t_ms: elapsed, rr_ms: rr, wallClockMs: wallClock ? elapsed : nil))
            elapsed += Int64(rr)
        }
        return points
    }

    static func session(
        start: Date, minutes: Double, meanRR: Int, sessionType: SessionType = .overnight, withAnalysis: Bool = false
    ) -> HRVSession {
        var built = session(start: start, points: points(minutes: minutes, meanRR: meanRR), sessionType: sessionType)
        if withAnalysis, let series = built.rrSeries { built.analysisResult = analysis(of: series) }
        return built
    }

    static func session(
        start: Date, points: [RRPoint], source: String? = nil, sessionType: SessionType = .overnight
    ) -> HRVSession {
        let id = UUID()
        let durationMs = points.last?.endMs ?? 0
        return HRVSession(
            id: id, startDate: start, endDate: start.addingTimeInterval(Double(durationMs) / 1000),
            state: .complete, sessionType: sessionType,
            rrSeries: RRSeries(points: points, sessionId: id, startDate: start),
            analysisResult: nil, artifactFlags: nil,
            dataSourceSummary: source.map {
                HRVSession.DataSourceSummary(
                    selectedSource: $0, streamingBeats: points.count, deviceBeats: nil, totalBeats: points.count,
                    beatDifferencePercent: nil, reconnectCount: 0, deviceModel: nil
                )
            }
        )
    }

    /// An analysis over beats 100 ..< 300, with its window times set.
    static func analysis(of series: RRSeries) -> HRVAnalysisResult? {
        let flags = [ArtifactFlags](repeating: .clean, count: series.points.count)
        guard series.points.count > 300,
              let timeDomain = TimeDomainAnalyzer.computeTimeDomain(series, flags: flags, windowStart: 100, windowEnd: 300)
        else { return nil }
        return HRVAnalysisResult(
            windowStart: 100, windowEnd: 300, timeDomain: timeDomain, frequencyDomain: nil,
            nonlinear: NonlinearMetrics(
                sd1: 20, sd2: 40, sd1Sd2Ratio: 0.5, sampleEntropy: 1.5, approxEntropy: 1.2,
                dfaAlpha1: 1.0, dfaAlpha2: 1.0, dfaAlpha1R2: 0.95
            ),
            ansMetrics: nil, artifactPercentage: 0, cleanBeatCount: 200, analysisDate: series.startDate,
            windowStartMs: series.points[100].t_ms, windowEndMs: series.points[300].t_ms
        )
    }

    static func rmssd(_ points: [RRPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        let squares = zip(points, points.dropFirst()).map { pair -> Double in
            let diff = Double(pair.1.rr_ms - pair.0.rr_ms)
            return diff * diff
        }
        return (squares.reduce(0, +) / Double(squares.count)).squareRoot()
    }

    /// Beats that start under 300 ms after the one before: a heart rate over
    /// 200 bpm, which only interleaving two recordings produces here.
    static func beatsTooSoon(_ points: [RRPoint]) -> Int {
        zip(points, points.dropFirst()).filter { $0.1.t_ms - $0.0.t_ms < 300 }.count
    }
}
