@testable import Emuqu
import SwiftUI
import XCTest

/// Snapshot coverage for the shareable cards and the live recording readouts.
///
/// `RecapCard` is what a user posts to social media, so it leaves the app and
/// cannot be corrected after the fact. `LiveWaveformView` is what they watch
/// during a reading — if it renders wrong, the session looks broken while it is
/// actually fine, and they stop the recording.
@MainActor
final class CardSnapshotTests: XCTestCase {
    private func hosted(_ view: some View) -> some View {
        view
            .environment(RRCollector())
            .environment(SettingsManager.shared)
    }

    // MARK: - Recap cards (these leave the app)

    func testRecapCardRecoveryRenders() {
        assertSnapshot(
            of: hosted(
                RecapCard(variant: .recovery(score: 78, verdict: .good, date: SnapshotFixtures.anchor))
            ),
            named: "card-recap-recovery"
        )
    }

    func testRecapCardWorkoutRenders() {
        assertSnapshot(
            of: hosted(
                RecapCard(variant: .workout(
                    distance: "10.8 km",
                    duration: "40:00",
                    pace: "3:42 /km",
                    verdict: "Strong aerobic effort",
                    summary: "Held threshold for the back half without drift.",
                    date: SnapshotFixtures.anchor,
                    routeMap: nil
                ))
            ),
            named: "card-recap-workout"
        )
    }

    /// The lowest tier: a card someone shares on a bad day still has to look
    /// deliberate rather than broken.
    func testRecapCardVeryLowRenders() {
        assertSnapshot(
            of: hosted(
                RecapCard(variant: .recovery(score: 18, verdict: .veryLow, date: SnapshotFixtures.anchor))
            ),
            named: "card-recap-very-low"
        )
    }

    // MARK: - Result cards

    func testTechnicalDetailsCardRenders() {
        assertSnapshot(
            of: hosted(
                TechnicalDetailsCard(
                    session: SnapshotFixtures.overnightSession(),
                    result: SnapshotFixtures.analysisResult()
                )
            ),
            named: "card-technical-details"
        )
    }

    func testTrendComparisonCardRenders() {
        assertSnapshot(
            of: hosted(
                TrendComparisonCard(
                    result: SnapshotFixtures.analysisResult(),
                    recentSessions: (1 ... 6).map { SnapshotFixtures.overnightSession(dayOffset: -$0) }
                )
            ),
            named: "card-trend-comparison"
        )
    }

    /// One prior reading is not enough to draw a trend; this is the state a
    /// user is in on day two.
    func testTrendComparisonCardWithOneSessionRenders() {
        assertSnapshot(
            of: hosted(
                TrendComparisonCard(
                    result: SnapshotFixtures.analysisResult(),
                    recentSessions: [SnapshotFixtures.overnightSession(dayOffset: -1)]
                )
            ),
            named: "card-trend-comparison-sparse"
        )
    }

    // MARK: - Live recording

    func testLiveWaveformRenders() {
        assertSnapshot(
            of: hosted(
                LiveWaveformView(
                    rrPoints: SnapshotFixtures.rrSeries(beats: 120).points,
                    maxPoints: 120,
                    showGrid: true,
                    accentColor: .blue
                )
            ),
            named: "live-waveform"
        )
    }

    /// The first seconds of a recording, before any beats have arrived.
    func testLiveWaveformEmptyRenders() {
        assertSnapshot(
            of: hosted(
                LiveWaveformView(rrPoints: [], maxPoints: 120, showGrid: true, accentColor: .blue)
            ),
            named: "live-waveform-empty"
        )
    }
}
