@testable import Emuqu
import SwiftUI
import XCTest

/// Snapshot coverage for the detail screens a user drills into from a result.
///
/// `RecoveryScoreDetailView`, `HRVDetailV2View` and `SleepDetailV2View` are
/// where the numbers behind a score are explained. They are also where a user goes when
/// they doubt a reading, so rendering them wrong costs trust directly.
///
/// `baselineStats` is nil in these: that is the state before enough history
/// exists to have a baseline, which every user passes through and which a
/// change written against populated data is most likely to break.
@MainActor
final class DetailScreenSnapshotTests: XCTestCase {
    private func hosted(_ view: some View) -> some View {
        NavigationStack { view }
            .environment(RRCollector())
            .environment(SettingsManager.shared)
            .environment(StoreKitManager.shared)
            .environment(ArchiveSignal())
    }

    private var recent: [HRVSession] {
        (1 ... 5).map { SnapshotFixtures.overnightSession(dayOffset: -$0) }
    }

    func testRecoveryScoreDetailRenders() {
        assertSnapshot(
            of: hosted(
                RecoveryScoreDetailView(
                    session: SnapshotFixtures.overnightSession(),
                    result: SnapshotFixtures.analysisResult(),
                    recentSessions: recent,
                    baselineStats: nil,
                    totalSessionCount: 6
                )
            ),
            named: "detail-recovery-score"
        )
    }

    func testHRVDetailRenders() {
        assertSnapshot(
            of: hosted(
                HRVDetailV2View(
                    session: SnapshotFixtures.overnightSession(),
                    result: SnapshotFixtures.analysisResult(),
                    recentSessions: recent,
                    baselineStats: nil
                )
            ),
            named: "detail-hrv"
        )
    }

    func testSleepDetailRenders() {
        assertSnapshot(
            of: hosted(
                SleepDetailV2View(
                    session: SnapshotFixtures.overnightSession(),
                    sleepData: SnapshotFixtures.sleepData(),
                    recoveryVitals: SnapshotFixtures.recoveryVitals(),
                    recentSessions: recent,
                    temperatureUnit: .celsius,
                    typicalSleepHours: 7.5,
                    userAge: 38
                )
            ),
            named: "detail-sleep"
        )
    }

    /// No HealthKit sleep and no vitals is the common case for a user with a
    /// strap but no watch.
    func testSleepDetailWithoutHealthKitRenders() {
        assertSnapshot(
            of: hosted(
                SleepDetailV2View(
                    session: SnapshotFixtures.overnightSession(),
                    sleepData: nil,
                    recoveryVitals: nil,
                    recentSessions: recent,
                    temperatureUnit: .celsius,
                    typicalSleepHours: 7.5,
                    userAge: 38
                )
            ),
            named: "detail-sleep-no-healthkit"
        )
    }
}

/// The rules the detail screens draw by, outside a render.
@MainActor
final class DetailScreenRuleTests: XCTestCase {
    /// Only the default selection opens on Best Recovery; any other stored
    /// method leaves no segment selected, so tapping Best Recovery
    /// re-analyses instead of doing nothing.
    func testTheWindowPickerOpensOnTheSegmentTheStoredWindowCameFrom() {
        XCTAssertEqual(RecoveryDetailCopy.initialSegment(forWindowReason: nil), .bestRecovery)
        XCTAssertEqual(RecoveryDetailCopy.initialSegment(forWindowReason: "Organized recovery window"), .bestRecovery)
        XCTAssertNil(RecoveryDetailCopy.initialSegment(forWindowReason: "Manual selection at 03:12"))
        XCTAssertNil(RecoveryDetailCopy.initialSegment(forWindowReason: "Peak RMSSD window"))
    }

    /// A streamed night whose beats fell 60 s behind the wall clock after a
    /// Bluetooth drop: the recording's span is read on the session clock,
    /// and a HealthKit sample after it lands on the beats' axis shifted by
    /// the last beat's drift, before it by the first beat's.
    func testHealthKitSamplesAreMovedOntoTheBeatsClock() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = [
            RRPoint(t_ms: 0, rr_ms: 1000, wallClockMs: 0),
            RRPoint(t_ms: 3_600_000, rr_ms: 1000, wallClockMs: 3_660_000)
        ]
        let series = RRSeries(points: points, sessionId: UUID(), startDate: start)
        let clock = OvernightChartsView.RecordingClock(series: series, sessionStart: start)

        XCTAssertEqual(clock.startMs, 0)
        XCTAssertEqual(clock.endMs, 3_661_000, "the last beat ends at 3,661 s on the session clock")
        XCTAssertEqual(clock.onBeatClock(4_000_000), 3_940_000, "after the recording: 60 s behind, as the last beat")
        XCTAssertEqual(clock.onBeatClock(-120_000), -120_000, "before it: the first beat has no drift")
    }

    /// A strap recording has no wall-clock stamps, so its `t_ms` already is
    /// the session clock and nothing moves.
    func testAStrapRecordingIsAlreadyOnTheSessionClock() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let series = RRSeries(points: [RRPoint(t_ms: 0, rr_ms: 900), RRPoint(t_ms: 900, rr_ms: 900)], sessionId: UUID(), startDate: start)
        let clock = OvernightChartsView.RecordingClock(series: series, sessionStart: start)

        XCTAssertEqual(clock, OvernightChartsView.RecordingClock(startMs: 0, endMs: 1_800, startDriftMs: 0, endDriftMs: 0))
        XCTAssertEqual(clock.onBeatClock(5_000), 5_000)
    }
}
