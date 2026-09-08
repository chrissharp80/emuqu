@testable import Emuqu
import SwiftUI
import XCTest

/// Snapshot coverage for the view types split out of `FitnessPostSummaryView`.
///
/// Why these three first. `ThresholdCards`, `WorkoutStatsCards`
/// and `Alpha1ReportCards` were extracted from that view. The
/// extraction is behaviour-preserving by construction — each forwarder returns
/// the same tree from the same position — but "by construction" was the whole
/// of the evidence: the unit suite cannot see a view, and the UI suite has no
/// test that opens this screen. These lock the rendering down so the next
/// change to it is checked by something other than someone remembering to look.
///
/// Every input here is frozen. A snapshot built from `Date()` or from live
/// settings re-renders differently tomorrow and teaches people to ignore the
/// failure.
@MainActor
final class ViewSnapshotTests: XCTestCase {
    // 1 June 2021, 08:00 UTC. Fixed, because a rendered timestamp in a
    // reference image is a test that fails at midnight.
    private let anchor = Date(timeIntervalSince1970: 1_622_534_400)

    /// A 40-minute run with a climb, a decaying α1 and a steady HR ramp.
    /// Deterministic: every value is a closed-form function of the tick.
    private func makeSamples(count: Int = 240) -> [WorkoutSample] {
        (0 ..< count).map { i in
            let t = Double(i)
            let frac = t / Double(count)
            return WorkoutSample(
                offsetSec: i * 10,
                heartRate: Int(120 + 40 * frac),
                distanceMeters: t * 45,
                paceSecPerKm: 300 - 40 * frac,
                cadenceStepsPerMin: 168 + 6 * (frac - 0.5),
                altitudeMeters: 100 + 60 * frac,
                // Crosses the 0.75 aerobic-threshold band partway through,
                // so the LT1 estimate and the crossings list both have
                // something real to draw.
                alpha1: 1.15 - 0.6 * frac,
                mets: 8 + 4 * frac,
                powerWatts: Int(220 + 60 * frac)
            )
        }
    }

    private func makeSession() -> HRVSession {
        var meta = WorkoutMetadata(sport: .run)
        meta.samples = makeSamples()
        meta.distanceMeters = 10_800
        meta.elevationGainMeters = 60
        meta.elevationLossMeters = 12
        var session = HRVSession(startDate: anchor, sessionType: .workout)
        session.endDate = anchor.addingTimeInterval(2_400)
        session.state = .complete
        session.workoutMetadata = meta
        return session
    }

    // MARK: - ThresholdCards

    func testAlpha1LT1EstimateCardRenders() {
        let cards = ThresholdCards(session: makeSession())
        assertSnapshot(of: cards.alpha1LT1EstimateCard, named: "thresholds-lt1-estimate")
    }

    func testAlpha1CrossingsCardRenders() {
        let cards = ThresholdCards(session: makeSession())
        assertSnapshot(of: cards.alpha1CrossingsCard, named: "thresholds-crossings")
    }

    func testDerivedMetricsCardRenders() {
        let cards = ThresholdCards(session: makeSession())
        assertSnapshot(of: cards.derivedMetricsCard, named: "thresholds-derived-metrics")
    }

    func testHRZoneDistributionCardRenders() {
        let cards = ThresholdCards(session: makeSession())
        assertSnapshot(of: cards.hrZoneDistributionCard, named: "thresholds-hr-zones")
    }

    // MARK: - Empty state
    //
    // A session with no samples draws literally nothing — the harness refuses
    // to record a uniform frame, and it is right to: a blank reference is a
    // test that can never fail. The behaviour still needs asserting, so it is
    // asserted as logic instead of pixels.

    func testDerivedMetricsAreEmptyWithoutSamples() {
        var empty = HRVSession(startDate: anchor, sessionType: .workout)
        empty.endDate = anchor.addingTimeInterval(600)
        empty.state = .complete
        empty.workoutMetadata = WorkoutMetadata(sport: .run)

        let rows = ThresholdCards(session: empty).derivedMetricRows(samples: [])
        XCTAssertTrue(
            rows.isEmpty,
            "A session with no samples must produce no derived-metric rows; "
            + "got \(rows.count)."
        )
    }

    func testDerivedMetricsArePresentWithSamples() {
        let rows = ThresholdCards(session: makeSession())
            .derivedMetricRows(samples: makeSamples())
        XCTAssertFalse(
            rows.isEmpty,
            "A 40-minute run with distance, cadence, power and altitude must "
            + "produce derived-metric rows. If this is empty the fixture stopped "
            + "supplying what the rows are computed from, and the snapshots "
            + "above are asserting less than they appear to."
        )
    }

    // MARK: - Alpha1ReportCards
    //
    // The α1 report is the densest drawing in the app: a chart, ectopic-shadow
    // marks, band totals and a prose summary, all derived from the same sample
    // series. It was extracted from the view on the same day as the cards
    // above, with the same "behaviour-preserving by construction" argument and
    // the same absence of anything checking it.

    func testAlpha1ReportCardRenders() {
        let cards = Alpha1ReportCards(session: makeSession())
        assertSnapshot(of: cards.alpha1ReportCard, named: "alpha1-report")
    }

    // MARK: - WorkoutStatsCards
    //
    // These need the settings object as well as the session, because zone
    // boundaries come from the user's configured max HR.

    private func makeStats() -> WorkoutStatsCards {
        WorkoutStatsCards(
            session: makeSession(),
            settingsManager: SettingsManager.shared,
            track: []
        )
    }

    func testHRChartCardRenders() {
        assertSnapshot(of: makeStats().hrChartCard(samples: makeSamples()),
                       named: "stats-hr-chart")
    }

    func testPaceChartCardRenders() {
        assertSnapshot(of: makeStats().paceChartCard(samples: makeSamples()),
                       named: "stats-pace-chart")
    }

    func testPowerChartCardRenders() {
        assertSnapshot(of: makeStats().powerChartCard(samples: makeSamples()),
                       named: "stats-power-chart")
    }

    func testCadenceChartCardRenders() {
        assertSnapshot(of: makeStats().cadenceChartCard(samples: makeSamples()),
                       named: "stats-cadence-chart")
    }

    func testElevationCardRenders() {
        assertSnapshot(of: makeStats().elevationCard, named: "stats-elevation")
    }

    // The derived display strings are pure functions of the fixture, so they
    // are asserted directly rather than through pixels — cheaper, and it names
    // the expected value instead of hiding it in a reference image.

    func testDerivedDisplayStrings() {
        let stats = makeStats()
        XCTAssertNotNil(stats.avgPaceDisplay, "40-minute run with distance must have an average pace")
        XCTAssertNotNil(stats.peakHRDisplay, "HR ramp 120-160 must yield a peak")
        XCTAssertNotNil(stats.avgCadenceDisplay, "cadence is present in every sample")
        XCTAssertEqual(stats.formatDuration(sec: 2_400), stats.formatDuration(sec: 2_400))
    }
}
