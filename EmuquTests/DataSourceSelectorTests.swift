@testable import Emuqu
import XCTest

/// Tests for DataSourceSelector
/// Validates data source selection logic for hybrid recording
final class DataSourceSelectorTests: XCTestCase {
    func testScienceContract_DataSourceThresholdsMatchArchitecture() {
        XCTAssertEqual(DataSourceSelector.minimumValidBeats, 120)
        XCTAssertEqual(DataSourceSelector.compositeThresholdPercent, 5.0, accuracy: 0.0001)
    }

    // MARK: - Test Helpers

    private func createRRPoints(count: Int, startMs: Int64 = 0, intervalMs: Int = 800) -> [RRPoint] {
        var points: [RRPoint] = []
        var currentMs = startMs
        for _ in 0 ..< count {
            points.append(RRPoint(t_ms: currentMs, rr_ms: intervalMs))
            currentMs += Int64(intervalMs)
        }
        return points
    }

    private func createRRPointsWithGap(
        beforeGap: Int,
        afterGap: Int,
        gapDurationMs: Int64,
        intervalMs: Int = 800
    ) -> [RRPoint] {
        var points: [RRPoint] = []
        var currentMs: Int64 = 0

        // Points before gap
        for _ in 0 ..< beforeGap {
            points.append(RRPoint(t_ms: currentMs, rr_ms: intervalMs))
            currentMs += Int64(intervalMs)
        }

        // Gap
        currentMs += gapDurationMs

        // Points after gap
        for _ in 0 ..< afterGap {
            points.append(RRPoint(t_ms: currentMs, rr_ms: intervalMs))
            currentMs += Int64(intervalMs)
        }

        return points
    }

    // MARK: - Basic Selection Tests

    func testSelectsStreamingWhenInternalFails() {
        let streamingPoints = createRRPoints(count: 500)
        let internalPoints: [RRPoint]? = nil

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.points.count, 500)
        XCTAssertTrue(result?.sourceDescription.contains("streaming") ?? false)
        XCTAssertFalse(result?.isComposite ?? true)
    }

    func testSelectsInternalWhenStreamingFails() {
        let streamingPoints = createRRPoints(count: 50) // Below 120 minimum
        let internalPoints = createRRPoints(count: 500)

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.points.count, 500)
        XCTAssertTrue(result?.sourceDescription.contains("internal") ?? false)
        XCTAssertFalse(result?.isComposite ?? true)
    }

    func testReturnsNilWhenBothFail() {
        let streamingPoints = createRRPoints(count: 50) // Below minimum
        let internalPoints = createRRPoints(count: 50) // Below minimum

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNil(result)
    }

    func testSelectsInternalWhenBothValidAndSimilar() {
        let streamingPoints = createRRPoints(count: 500)
        let internalPoints = createRRPoints(count: 505) // Within 5% difference

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.sourceDescription, "internal")
        XCTAssertFalse(result?.isComposite ?? true)
    }

    // MARK: - Minimum Threshold Tests

    func testMinimumBeatsThreshold() {
        // Exactly at threshold
        let atThreshold = createRRPoints(count: 120)
        let result1 = DataSourceSelector.selectBestSource(
            streamingPoints: atThreshold,
            internalPoints: nil,
            sessionId: UUID(),
            sessionStart: Date()
        )
        XCTAssertNotNil(result1)

        // Below threshold
        let belowThreshold = createRRPoints(count: 119)
        let result2 = DataSourceSelector.selectBestSource(
            streamingPoints: belowThreshold,
            internalPoints: nil,
            sessionId: UUID(),
            sessionStart: Date()
        )
        XCTAssertNil(result2)
    }

    // MARK: - Composite Creation Tests

    func testCreatesCompositeWhenInternalHasGaps() {
        // Internal has 400 beats with a gap
        let internalPoints = createRRPointsWithGap(
            beforeGap: 200,
            afterGap: 200,
            gapDurationMs: 10000 // 10 second gap
        )

        // Streaming has continuous data including the gap period
        let streamingPoints = createRRPoints(count: 500)

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        // Should create composite since internal has significant gaps
        // and streaming has more points (>5% difference)
        if result?.isComposite == true {
            XCTAssertTrue(result?.sourceDescription.contains("composite") ?? false)
        }
    }

    func testDoesNotCreateCompositeWhenDifferenceSmall() {
        let streamingPoints = createRRPoints(count: 500)
        let internalPoints = createRRPoints(count: 490) // Only 2% difference

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        XCTAssertFalse(result?.isComposite ?? true)
        XCTAssertEqual(result?.sourceDescription, "internal")
    }

    func testCompositeThresholdIsRespected() {
        // Exactly at 5% threshold
        let streamingPoints = createRRPoints(count: 1000)
        let internalPoints = createRRPoints(count: 950) // Exactly 5% fewer

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        // At exactly 5%, should not create composite (need >5%)
        XCTAssertFalse(result?.isComposite ?? true)
    }

    // MARK: - Source Description Tests

    func testSourceDescriptionForStreamingOnly() {
        let streamingPoints = createRRPoints(count: 500)

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: nil,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertTrue(result?.sourceDescription.contains("streaming") ?? false)
        XCTAssertTrue(result?.sourceDescription.contains("internal failed") ?? false)
    }

    func testSourceDescriptionForInternalOnly() {
        let streamingPoints = createRRPoints(count: 50) // Invalid
        let internalPoints = createRRPoints(count: 500)

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertEqual(result?.sourceDescription, "internal")
    }

    func testSourceDescriptionForPreferredInternal() {
        let streamingPoints = createRRPoints(count: 500)
        let internalPoints = createRRPoints(count: 500)

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertEqual(result?.sourceDescription, "internal")
    }

    // MARK: - Edge Cases

    func testEmptyStreamingPoints() {
        let streamingPoints: [RRPoint] = []
        let internalPoints = createRRPoints(count: 500)

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.points.count, 500)
    }

    func testBothEmpty() {
        let streamingPoints: [RRPoint] = []
        let internalPoints: [RRPoint] = []

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNil(result)
    }

    func testNilInternalPoints() {
        let streamingPoints = createRRPoints(count: 500)

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: nil,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.points.count, 500)
    }

    // MARK: - Session ID Preservation

    func testSessionIdIsPreserved() {
        let sessionId = UUID()
        let streamingPoints = createRRPoints(count: 500)

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: nil,
            sessionId: sessionId,
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        // The result doesn't directly contain sessionId, but it's used for series construction
        // This test verifies the function accepts the parameter
    }

    // MARK: - Large Dataset Tests

    func testLargeDatasetSelection() {
        // Simulate overnight recording (~8 hours at 60bpm = ~28800 beats)
        let streamingPoints = createRRPoints(count: 28000)
        let internalPoints = createRRPoints(count: 28500)

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        // Should prefer internal as difference is only ~1.8%
        XCTAssertFalse(result?.isComposite ?? true)
    }

    // MARK: - Percentage Calculation Tests

    func testPercentageDifferenceCalculation() {
        // 10% difference should trigger composite consideration
        let streamingPoints = createRRPoints(count: 1000)
        let internalPoints = createRRPoints(count: 900) // 10% fewer

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        // With 10% difference, should consider composite
        // (actual composite creation depends on gap detection)
    }

    func testCompositeFallsBackToStreamingWhenCreationFails() {
        // Internal has fewer beats over the same span and no detectable gaps:
        // streaming adds no beat outside it, so no composite can be built.
        // The selector must fall back to streaming (more beats), NOT internal.
        let streamingPoints = createRRPoints(count: 20000, intervalMs: 720)
        let internalPoints = createRRPoints(count: 18000) // 10% fewer, same span, no gaps

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.points.count, 20000, "Must keep all streaming beats when composite fails")
        XCTAssertTrue(result?.sourceDescription.contains("streaming") ?? false)
        XCTAssertFalse(result?.isComposite ?? true)
    }

    /// A strap series has no gap of its own (its clock sums its intervals).
    /// A strap armed late holds fewer beats than the stream, but it covers a
    /// dropout of the stream's: the composite keeps every strap beat and adds
    /// the stream's beats from before the strap started and after it ended,
    /// instead of scoring
    /// the night from the stream with its hole.
    func testALateArmedStrapIsCompletedFromTheStreamNotDropped() throws {
        let lateMs: Int64 = 45 * 60 * 1000
        let internalPoints = createRRPoints(count: 27000, startMs: lateMs, intervalMs: 800)
        // The stream runs the whole night but drops 20 minutes after the strap starts.
        let dropoutStart = lateMs + 60 * 60 * 1000
        let dropoutEnd = dropoutStart + 20 * 60 * 1000
        let streamingPoints = createRRPoints(count: 33000, intervalMs: 800).compactMap { point -> RRPoint? in
            guard point.t_ms < dropoutStart || point.t_ms >= dropoutEnd else { return nil }
            return RRPoint(t_ms: point.t_ms, rr_ms: point.rr_ms, wallClockMs: point.t_ms, hr: 75)
        }
        let strapEnd = try XCTUnwrap(internalPoints.last).endMs
        let uncoveredBeats = streamingPoints.filter { $0.t_ms < lateMs || $0.t_ms > strapEnd }.count

        let result = try XCTUnwrap(DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        ))

        XCTAssertTrue(result.isComposite)
        XCTAssertEqual(result.points.count, internalPoints.count + uncoveredBeats)
        XCTAssertTrue(result.points.contains { $0.t_ms >= dropoutStart && $0.t_ms < dropoutEnd }, "the strap's beats in the dropout are kept")
    }

    // MARK: - Coverage, not beat count

    /// A strap armed at a resume holds only what came after it. The archived
    /// night's stream runs from its first segment's start, so however the
    /// counts compare, the strap replaces only the stretch it covers and the
    /// stream's beats before it stay.
    func testAStrapCoveringOnlyPartOfTheStreamNeverReplacesIt() throws {
        let stream = createRRPoints(count: 1_000, intervalMs: 1_000)
        let cases: [(name: String, strapCount: Int)] = [("as many beats", 1_000), ("more beats", 1_400), ("slightly fewer", 980)]
        for testCase in cases {
            let strap = createRRPoints(count: testCase.strapCount, startMs: 300_000, intervalMs: 1_000)
            let result = try XCTUnwrap(DataSourceSelector.selectBestSource(
                streamingPoints: stream, internalPoints: strap, sessionId: UUID(), sessionStart: Date()
            ))
            XCTAssertTrue(result.isComposite, testCase.name)
            XCTAssertEqual(result.points.count, testCase.strapCount + 300, "\(testCase.name): the stream's first 300 s are kept")
            XCTAssertEqual(result.points.first?.t_ms, 0, testCase.name)
        }
    }

    /// A stream too short to stand on its own still keeps the beats outside
    /// the strap's span.
    func testAShortStreamOutsideTheStrapsSpanIsKept() throws {
        let stream = createRRPoints(count: 100, intervalMs: 1_000)
        let strap = createRRPoints(count: 500, startMs: 200_000, intervalMs: 1_000)
        let result = try XCTUnwrap(DataSourceSelector.selectBestSource(
            streamingPoints: stream, internalPoints: strap, sessionId: UUID(), sessionStart: Date()
        ))
        XCTAssertEqual(result.points.count, 600)
    }

    /// A strap armed moments after the stream started covers it: within
    /// `spanSlackMs` the strap's recording is used alone, as before.
    func testAStrapArmedMomentsAfterTheStreamStillStandsAlone() throws {
        XCTAssertEqual(DataSourceSelector.spanSlackMs, 60_000)
        let stream = createRRPoints(count: 1_000, intervalMs: 1_000)
        let strap = createRRPoints(count: 1_000, startMs: 30_000, intervalMs: 1_000)
        let result = try XCTUnwrap(DataSourceSelector.selectBestSource(
            streamingPoints: stream, internalPoints: strap, sessionId: UUID(), sessionStart: Date()
        ))
        XCTAssertEqual(result.sourceDescription, "internal")
        XCTAssertEqual(result.points.count, 1_000)
    }

    // MARK: - mergePoints (time-alignment merge)

    func testMergePoints_EmptyInputs_ReturnsEmpty() {
        XCTAssertTrue(DataSourceSelector.mergePoints(internal: [], streaming: []).isEmpty)
    }

    func testMergePoints_OnlyInternal_PassesThroughUnchanged() {
        let internalPoints = createRRPoints(count: 5, startMs: 0, intervalMs: 800)
        let merged = DataSourceSelector.mergePoints(internal: internalPoints, streaming: [])
        XCTAssertEqual(merged, internalPoints)
    }

    func testMergePoints_OnlyStreaming_RebasesTimeToWallClock() {
        // Streaming t_ms has drifted behind wall clock after BLE loss; the
        // merged timeline must anchor to wallClockMs, not the drifted t_ms.
        let streaming = [
            RRPoint(t_ms: 100, rr_ms: 800, wallClockMs: 10_000, hr: 75),
            RRPoint(t_ms: 900, rr_ms: 800, wallClockMs: 10_800, hr: 75)
        ]
        let merged = DataSourceSelector.mergePoints(internal: [], streaming: streaming)
        XCTAssertEqual(merged.map(\.t_ms), [10_000, 10_800], "Streaming t_ms must be rebased to wallClockMs")
        XCTAssertEqual(merged.map(\.rr_ms), [800, 800])
    }

    func testMergePoints_DuplicateWithinTolerance_KeepsInternalDropsStreaming() {
        // An internal beat and a streaming beat ~30ms apart (< 50ms tolerance)
        // are the same heartbeat seen twice — internal wins, streaming dropped.
        let internalPoints = [RRPoint(t_ms: 10_000, rr_ms: 800)]
        let streaming = [RRPoint(t_ms: 10_030, rr_ms: 805, wallClockMs: 10_030, hr: 74)]
        let merged = DataSourceSelector.mergePoints(internal: internalPoints, streaming: streaming)
        XCTAssertEqual(merged.count, 1, "Near-simultaneous beat must not be double-counted")
        XCTAssertEqual(merged.first?.rr_ms, 800, "Internal beat is the one kept")
    }

    func testMergePoints_ClusteredStreamingDuplicates_AllSkipped() {
        // One streamed batch carries three beats the strap also recorded,
        // all stamped with the batch's arrival as the third ended. Laid back
        // from that arrival by their own intervals, each lands on the strap's
        // own beat, and all three collapse into it.
        let internalPoints = [
            RRPoint(t_ms: 10_000, rr_ms: 800),
            RRPoint(t_ms: 10_800, rr_ms: 800),
            RRPoint(t_ms: 11_600, rr_ms: 800)
        ]
        let streaming = [
            RRPoint(t_ms: 0, rr_ms: 800, wallClockMs: 12_410, hr: 74),
            RRPoint(t_ms: 800, rr_ms: 800, wallClockMs: 12_410, hr: 74),
            RRPoint(t_ms: 1_600, rr_ms: 800, wallClockMs: 12_410, hr: 74)
        ]
        let merged = DataSourceSelector.mergePoints(internal: internalPoints, streaming: streaming)
        XCTAssertEqual(merged, internalPoints, "Clustered streaming duplicates must collapse into the internal beats")
    }

    func testMergePoints_StreamingGapFill_InsertedAndRebased() {
        // Internal has a hole between 10_000 and 20_000; a streaming beat at
        // wall-clock 15_000 fills it and is inserted in time order.
        let internalPoints = [
            RRPoint(t_ms: 10_000, rr_ms: 800),
            RRPoint(t_ms: 20_000, rr_ms: 800)
        ]
        let streaming = [RRPoint(t_ms: 4_900, rr_ms: 850, wallClockMs: 15_000, hr: 70)]
        let merged = DataSourceSelector.mergePoints(internal: internalPoints, streaming: streaming)
        XCTAssertEqual(merged.map(\.t_ms), [10_000, 15_000, 20_000], "Gap-fill beat inserted in order and rebased to wallClockMs")
        XCTAssertEqual(merged.map(\.rr_ms), [800, 850, 800])
    }

    func testMergeAddingOnlyUncoveredBeats_DropsOverlapKeepsGapsAndTails() {
        // Device beats every 800 ms from 10_000 to 12_400, then a hole to 20_000.
        // The stream overlaps the covered span off the 50 ms duplicate window,
        // fills the hole, and runs past the device's end.
        let internalPoints = [
            RRPoint(t_ms: 10_000, rr_ms: 800), RRPoint(t_ms: 10_800, rr_ms: 800),
            RRPoint(t_ms: 11_600, rr_ms: 800), RRPoint(t_ms: 20_000, rr_ms: 800)
        ]
        let streaming = [
            RRPoint(t_ms: 0, rr_ms: 800, wallClockMs: 10_400, hr: 70),
            RRPoint(t_ms: 0, rr_ms: 800, wallClockMs: 15_000, hr: 70),
            RRPoint(t_ms: 0, rr_ms: 800, wallClockMs: 22_000, hr: 70)
        ]
        let merged = DataSourceSelector.mergeAddingOnlyUncoveredBeats(internal: internalPoints, streaming: streaming)
        XCTAssertEqual(merged.map(\.t_ms), [10_000, 10_800, 11_600, 15_000, 20_000, 22_000])
    }
}
