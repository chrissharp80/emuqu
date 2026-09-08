@testable import Emuqu
import XCTest

/// Tests for merging a workout's RR intervals from the strap stream and the
/// Watch-routed fallback.
///
/// Merge these wrong and every HRV number for the workout is computed on a
/// corrupted series — out-of-order intervals become enormous successive
/// differences, which is what RMSSD squares.
final class WorkoutRRMergeTests: XCTestCase {
    private typealias Source = WorkoutRecorder.HRSource

    private func points(_ times: [Int64]) -> [RRPoint] {
        times.map { RRPoint(t_ms: $0, rr_ms: 900) }
    }

    // MARK: - Which buffers belong to this workout

    func testAStrapWorkoutTakesTheStreamingBuffer() {
        let merged = WorkoutRRMerge.merged(
            source: .strap, streaming: points([0, 900, 1_800]), watchRouted: []
        )
        XCTAssertEqual(merged.map(\.t_ms), [0, 900, 1_800])
    }

    /// A watch or sourceless workout never started a strap stream, so that
    /// buffer is not theirs to read — it can still hold points from an earlier
    /// session, and adopting them would fabricate beats.
    func testANonStrapWorkoutIgnoresTheStreamingBuffer() {
        for source in [Source.watch, .none] {
            let merged = WorkoutRRMerge.merged(
                source: source, streaming: points([0, 900, 1_800]), watchRouted: []
            )
            XCTAssertTrue(merged.isEmpty, "\(source) must not adopt strap stream points")
        }
    }

    /// The Watch fallback can carry strap data the phone never saw, so it is
    /// merged whatever the recorded source.
    func testWatchRoutedPointsAreTakenWhateverTheSource() {
        for source in [Source.strap, .watch, .none] {
            let merged = WorkoutRRMerge.merged(
                source: source, streaming: [], watchRouted: points([100, 1_000])
            )
            XCTAssertEqual(merged.map(\.t_ms), [100, 1_000], "\(source) must keep watch-routed RR")
        }
    }

    // MARK: - Ordering

    /// The reason the merge exists: a workout that bounced between the phone
    /// and the Watch has interleaved timestamps, and analysis needs one ordered
    /// series.
    func testInterleavedSourcesComeBackInTimeOrder() {
        let merged = WorkoutRRMerge.merged(
            source: .strap,
            streaming: points([0, 900, 5_400]),
            watchRouted: points([1_800, 2_700, 3_600])
        )
        XCTAssertEqual(merged.map(\.t_ms), [0, 900, 1_800, 2_700, 3_600, 5_400])
    }

    func testTheMergedSeriesIsAlwaysNonDecreasingWhenBothSourcesContribute() {
        let merged = WorkoutRRMerge.merged(
            source: .strap,
            streaming: points([5_000, 100, 3_000]),
            watchRouted: points([4_000, 200])
        )
        XCTAssertEqual(merged.map(\.t_ms), merged.map(\.t_ms).sorted())
    }

    /// Characterising the existing behaviour: with nothing to interleave the
    /// streaming buffer is returned untouched. It is ordered by construction,
    /// and re-sorting a long series on every finalize is work for nothing.
    func testWithNoWatchPointsTheStreamingBufferIsReturnedAsIs() {
        let unordered = points([5_000, 100, 3_000])
        let merged = WorkoutRRMerge.merged(source: .strap, streaming: unordered, watchRouted: [])
        XCTAssertEqual(merged.map(\.t_ms), [5_000, 100, 3_000])
    }

    // MARK: - Nothing is lost

    /// Every interval from a contributing buffer must survive the merge. A
    /// dropped beat shortens the series and shifts every window after it.
    func testNoIntervalIsLost() {
        let streaming = points([0, 900, 1_800])
        let watch = points([450, 1_350])
        let merged = WorkoutRRMerge.merged(source: .strap, streaming: streaming, watchRouted: watch)
        XCTAssertEqual(merged.count, streaming.count + watch.count)
    }

    /// Duplicate timestamps are kept rather than silently de-duplicated —
    /// dropping them here would hide a real double-delivery bug from the
    /// artifact detector downstream, which is the layer that should judge it.
    func testDuplicateTimestampsAreKeptForTheArtifactDetectorToJudge() {
        let merged = WorkoutRRMerge.merged(
            source: .strap, streaming: points([0, 900]), watchRouted: points([900])
        )
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged.map(\.t_ms), [0, 900, 900])
    }

    // MARK: - Empty cases

    func testAWorkoutWithNoRRAtAllYieldsAnEmptySeries() {
        XCTAssertTrue(WorkoutRRMerge.merged(source: .strap, streaming: [], watchRouted: []).isEmpty)
        XCTAssertTrue(WorkoutRRMerge.merged(source: .none, streaming: [], watchRouted: []).isEmpty)
    }

    /// A Watch-only workout that never got strap data still finalizes.
    func testAWatchWorkoutWithNoRoutedPointsFinalizesEmpty() {
        XCTAssertTrue(
            WorkoutRRMerge.merged(source: .watch, streaming: points([0, 900]), watchRouted: []).isEmpty
        )
    }
}
