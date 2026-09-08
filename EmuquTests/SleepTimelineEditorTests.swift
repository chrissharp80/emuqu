@testable import Emuqu
import XCTest

/// Tests for `SleepTimelineState` — pure edit transforms used by the
/// timeline-based sleep editor, plus the `SleepScienceAnalyzer` save path.
final class SleepTimelineEditorTests: XCTestCase {
    // MARK: - Helpers

    /// Midnight of Jan 1 2026 in the test runner's timezone, used as a stable
    /// anchor so formatted summaries don't change across timezones.
    private let anchor: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 1; comps.day = 1; comps.hour = 0; comps.minute = 0
        return TestDate.from(comps)
    }()

    private func date(_ minutesFromAnchor: Int) -> Date {
        anchor.addingTimeInterval(TimeInterval(minutesFromAnchor) * 60)
    }

    private func interval(
        stage: HealthKitManager.SleepStage,
        _ startMin: Int,
        _ endMin: Int,
        provenance: HealthKitManager.SleepStageProvenance = .watch
    ) -> HealthKitManager.SleepStageInterval {
        HealthKitManager.SleepStageInterval(
            stage: stage,
            start: date(startMin),
            end: date(endMin),
            provenance: provenance
        )
    }

    /// Build a SleepData with one segment: deep + core + REM across 480 min (8h).
    private func makeSingleNight() -> SleepData {
        let intervals = [
            interval(stage: .deep, 0, 90),
            interval(stage: .core, 90, 300),
            interval(stage: .rem, 300, 420),
            interval(stage: .core, 420, 480)
        ]
        return SleepData(
            date: anchor,
            inBedStart: anchor,
            sleepStart: anchor,
            sleepEnd: date(480),
            totalSleepMinutes: 480,
            inBedMinutes: 480,
            deepSleepMinutes: 90,
            remSleepMinutes: 120,
            awakeMinutes: 0,
            sleepEfficiency: 100,
            boundarySource: .healthKit,
            stageIntervals: intervals
        )
    }

    // MARK: - addSegment

    func testAddSegmentContributesToTotalButNotToStages() {
        var state = SleepTimelineState.initial(from: makeSingleNight())
        XCTAssertEqual(state.segments.count, 1)

        // Add a 45 min user-declared nap entirely outside the HK night
        state = state.applying(.addSegment(start: date(600), end: date(645)))
        XCTAssertEqual(state.segments.count, 2)

        let rebuilt = SleepScienceAnalyzer.buildSleepDataFromTimelineState(
            original: makeSingleNight(),
            state: state
        )

        // Total sleep should include the new 45 min
        XCTAssertEqual(rebuilt.nightSleepMinutes, 480 + 45)
        // Stage totals should *not* — they reflect HK-classified time only
        XCTAssertEqual(rebuilt.deepSleepMinutes, 90)
        XCTAssertEqual(rebuilt.remSleepMinutes, 120)
        // Audit trail has one entry
        XCTAssertEqual(rebuilt.edits.count, 1)
        XCTAssertEqual(rebuilt.edits.first?.kind, .addSegment)
        // Provenance was tagged correctly on the inserted interval
        let userInterval = rebuilt.stageIntervals.first { $0.provenance == .userAdded }
        XCTAssertNotNil(userInterval)
        XCTAssertEqual(userInterval?.stage, .unspecified)
    }

    // MARK: - carveAwake

    func testCarveAwakeReducesTotalAndInsertsAwakeInterval() {
        var state = SleepTimelineState.initial(from: makeSingleNight())
        // Carve a 30 min awake hole inside the first Core block
        state = state.applying(.carveAwake(start: date(120), end: date(150)))

        let rebuilt = SleepScienceAnalyzer.buildSleepDataFromTimelineState(
            original: makeSingleNight(),
            state: state
        )

        // Total sleep drops by ~30 min
        XCTAssertEqual(rebuilt.nightSleepMinutes, 480 - 30)
        // Exactly one user-carved awake interval now exists
        let carved = rebuilt.stageIntervals.filter { $0.provenance == .userCarved }
        XCTAssertEqual(carved.count, 1)
        XCTAssertEqual(carved.first?.stage, .awake)
        XCTAssertEqual(carved.first?.durationMinutes, 30)
        // Apple HK constraint: no two Asleep intervals overlap each other
        let sleepIntervals = rebuilt.stageIntervals
            .filter { $0.stage != .awake }
            .sorted { $0.start < $1.start }
        for (a, b) in zip(sleepIntervals, sleepIntervals.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end, b.start, "Asleep intervals must not overlap")
        }
    }

    // MARK: - split

    func testSplitPreservesTotalAndProducesTwoSegments() {
        var state = SleepTimelineState.initial(from: makeSingleNight())
        state = state.applying(.split(segmentId: state.segments[0].id, atTime: date(240)))
        XCTAssertEqual(state.segments.count, 2)

        let leftMin = Int(state.segments[0].end.timeIntervalSince(state.segments[0].start) / 60)
        let rightMin = Int(state.segments[1].end.timeIntervalSince(state.segments[1].start) / 60)
        XCTAssertEqual(leftMin + rightMin, 480)

        let rebuilt = SleepScienceAnalyzer.buildSleepDataFromTimelineState(
            original: makeSingleNight(),
            state: state
        )
        // Total sleep unchanged by a clean split
        XCTAssertEqual(rebuilt.nightSleepMinutes, 480)
    }

    // MARK: - merge

    func testMergeWithinGapSucceedsOutsideRejects() {
        var state = SleepTimelineState.initial(from: makeSingleNight())
        // Add a second segment 45 min after the first ends (within 60 min gap)
        state = state.applying(.addSegment(start: date(525), end: date(585)))
        XCTAssertEqual(state.segments.count, 2)

        let first = state.segments[0].id
        let second = state.segments[1].id
        let merged = state.applying(.merge(leftId: first, rightId: second))
        XCTAssertEqual(merged.segments.count, 1, "45-min gap is within merge threshold — should merge")

        // A 90-min gap should refuse
        var wide = SleepTimelineState.initial(from: makeSingleNight())
        wide = wide.applying(.addSegment(start: date(570), end: date(630)))
        let wideMerged = wide.applying(.merge(
            leftId: wide.segments[0].id,
            rightId: wide.segments[1].id
        ))
        XCTAssertEqual(wideMerged.segments.count, 2, "90-min gap exceeds merge threshold — should be refused")
    }

    // MARK: - remove

    func testRemoveSegmentDropsItFromTotals() {
        var state = SleepTimelineState.initial(from: makeSingleNight())
        // Add a nap, then remove the ORIGINAL night — leaving only the nap
        state = state.applying(.addSegment(start: date(600), end: date(645)))
        let originalId = state.segments[0].id
        state = state.applying(.removeSegment(segmentId: originalId))
        XCTAssertEqual(state.segments.count, 1)

        let rebuilt = SleepScienceAnalyzer.buildSleepDataFromTimelineState(
            original: makeSingleNight(),
            state: state
        )
        XCTAssertEqual(rebuilt.nightSleepMinutes, 45, "Only the 45-min user-added nap remains")
    }

    // MARK: - adjustBoundary

    func testAdjustBoundaryShortensSegmentAndClipsIntervals() {
        var state = SleepTimelineState.initial(from: makeSingleNight())
        let id = state.segments[0].id
        // Pull start forward by 60 min (remove first hour)
        state = state.applying(.adjustBoundary(segmentId: id, side: .start, newTime: date(60)))

        let rebuilt = SleepScienceAnalyzer.buildSleepDataFromTimelineState(
            original: makeSingleNight(),
            state: state
        )
        XCTAssertEqual(rebuilt.nightSleepMinutes, 480 - 60)
        // Deep was 0-90 originally → now 60-90 = 30 min
        XCTAssertEqual(rebuilt.deepSleepMinutes, 30)
    }

    // MARK: - undo

    func testUndoRestoresPreviousStateExactly() {
        let initial = SleepTimelineState.initial(from: makeSingleNight())
        var stack = SleepTimelineUndoStack()
        var state = initial

        // Five edits — push each prior state onto the stack
        let edits: [SleepTimelineEdit] = [
            .adjustBoundary(segmentId: state.segments[0].id, side: .start, newTime: date(30)),
            .addSegment(start: date(600), end: date(630)),
            .carveAwake(start: date(180), end: date(210)),
            .split(segmentId: state.segments[0].id, atTime: date(300)),
            .removeSegment(segmentId: state.segments[0].id)
        ]
        for edit in edits {
            let before = state
            let after = state.applying(edit)
            if after != before {
                stack.push(before)
                state = after
            }
        }
        XCTAssertTrue(stack.canUndo)

        // Undo exactly as many times as we pushed
        while let previous = stack.pop() {
            state = previous
        }
        XCTAssertEqual(state, initial, "Undoing all edits returns to initial state")
    }

    // MARK: - Round-trip through JSON

    func testProvenanceRoundTripsThroughJSON() throws {
        var state = SleepTimelineState.initial(from: makeSingleNight())
        state = state.applying(.addSegment(start: date(600), end: date(630)))
        state = state.applying(.carveAwake(start: date(120), end: date(150)))

        let rebuilt = SleepScienceAnalyzer.buildSleepDataFromTimelineState(
            original: makeSingleNight(),
            state: state
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(rebuilt)
        let decoded = try decoder.decode(SleepData.self, from: data)

        // edits + provenance survived the round trip
        XCTAssertEqual(decoded.edits.count, rebuilt.edits.count)
        XCTAssertEqual(
            Set(decoded.stageIntervals.map(\.provenance)),
            Set(rebuilt.stageIntervals.map(\.provenance))
        )
    }

    // MARK: - Backward-compat decode (no provenance field in old archives)

    func testDecodingIntervalWithoutProvenanceDefaultsToWatch() throws {
        let legacyJSON = Data("""
        {
            "id": "\(UUID().uuidString)",
            "stage": "deep",
            "start": "2026-01-01T00:00:00Z",
            "end": "2026-01-01T01:30:00Z"
        }
        """.utf8)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HealthKitManager.SleepStageInterval.self, from: legacyJSON)
        XCTAssertEqual(decoded.provenance, .watch, "Legacy intervals decode with .watch provenance")
    }
}
