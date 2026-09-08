@testable import Emuqu
import SwiftUI
import XCTest

/// Snapshot coverage for the sleep-stage timeline and the remaining panels.
///
/// `SleepTimelineChart` draws the deep / core / REM / awake bands a user reads
/// their night from. The stage order and colours carry the meaning, so a
/// mis-drawn band is a wrong clinical impression rather than a cosmetic bug.
@MainActor
final class SleepChartSnapshotTests: XCTestCase {
    private func hosted(_ view: some View) -> some View {
        view
            .environment(RRCollector())
            .environment(SettingsManager.shared)
    }

    /// A plausible night: core-dominant with deep early and REM weighted late,
    /// plus two brief awakenings. Frozen to the fixture anchor.
    private func stageIntervals() -> [SleepStageInterval] {
        let start = SnapshotFixtures.anchor
        let plan: [(SleepStage, Double, Double)] = [
            (.core, 0, 25), (.deep, 25, 70), (.core, 70, 110),
            (.rem, 110, 135), (.awake, 135, 141), (.core, 141, 200),
            (.deep, 200, 230), (.core, 230, 275), (.rem, 275, 320),
            (.awake, 320, 325), (.core, 325, 380), (.rem, 380, 420)
        ]
        return plan.map { stage, from, to in
            SleepStageInterval(
                stage: stage,
                start: start.addingTimeInterval(from * 60),
                end: start.addingTimeInterval(to * 60)
            )
        }
    }

    func testSleepTimelineRenders() {
        assertSnapshot(
            of: hosted(
                SleepTimelineChart(
                    stageIntervals: stageIntervals(),
                    sleepStart: SnapshotFixtures.anchor,
                    sleepEnd: SnapshotFixtures.anchor.addingTimeInterval(420 * 60),
                    inBedStart: SnapshotFixtures.anchor.addingTimeInterval(-10 * 60),
                    boundaryValidation: nil
                )
            ),
            named: "chart-sleep-timeline"
        )
    }

    /// No staging at all — a strap-only user with no watch. The chart has to
    /// say so rather than drawing an empty band nobody can interpret.
    func testSleepTimelineWithoutStagesRenders() {
        assertSnapshot(
            of: hosted(
                SleepTimelineChart(
                    stageIntervals: [],
                    sleepStart: SnapshotFixtures.anchor,
                    sleepEnd: SnapshotFixtures.anchor.addingTimeInterval(420 * 60),
                    inBedStart: nil,
                    boundaryValidation: nil
                )
            ),
            named: "chart-sleep-timeline-no-stages"
        )
    }

    /// Unknown boundaries: the recording exists but nothing pins when sleep
    /// began or ended.
    func testSleepTimelineWithoutBoundariesRenders() {
        assertSnapshot(
            of: hosted(
                SleepTimelineChart(
                    stageIntervals: stageIntervals(),
                    sleepStart: nil,
                    sleepEnd: nil,
                    inBedStart: nil,
                    boundaryValidation: nil
                )
            ),
            named: "chart-sleep-timeline-no-boundaries"
        )
    }
}
