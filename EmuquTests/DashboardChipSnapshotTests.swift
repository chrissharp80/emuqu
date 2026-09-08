@testable import Emuqu
import SwiftUI
import XCTest

/// Snapshot coverage for the dashboard contributor chips and the breathing
/// guide.
///
/// `ContributorChip` is four variants times five display states — the row of
/// summaries under the score ring, and the densest state matrix in the app.
/// The loading / no-data / locked states are what a user sees before their
/// data arrives or behind the paywall, so they are seen constantly and
/// hand-checked almost never.
@MainActor
final class DashboardChipSnapshotTests: XCTestCase {
    private func hosted(_ view: some View) -> some View {
        view
            .environment(RRCollector())
            .environment(SettingsManager.shared)
    }

    // MARK: - Variants

    func testHRVChipRenders() {
        assertSnapshot(
            of: hosted(ContributorChip(variant: .hrv(value: "45 ms", trend: .up))),
            named: "chip-hrv"
        )
    }

    func testSleepChipRenders() {
        assertSnapshot(
            of: hosted(ContributorChip(variant: .sleep(duration: "6h 40m", efficiency: "95%"))),
            named: "chip-sleep"
        )
    }

    func testVitalsChipRenders() {
        assertSnapshot(
            of: hosted(ContributorChip(variant: .vitals(status: .normal, leadVital: "14.2 br/min"))),
            named: "chip-vitals"
        )
    }

    /// An elevated vitals reading is the one a user needs to notice.
    func testVitalsChipElevatedRenders() {
        assertSnapshot(
            of: hosted(ContributorChip(variant: .vitals(status: .elevated, leadVital: "17.8 br/min"))),
            named: "chip-vitals-elevated"
        )
    }

    func testLoadChipRenders() {
        assertSnapshot(
            of: hosted(
                ContributorChip(variant: .load(verdict: .building, subline: "CTL 55 · ramp 4.2"))
            ),
            named: "chip-load"
        )
    }

    /// High strain is unintentional deep fatigue — the verdict that should
    /// make someone back off.
    func testLoadChipHighStrainRenders() {
        assertSnapshot(
            of: hosted(
                ContributorChip(variant: .load(verdict: .highStrain, subline: "TSB -28"))
            ),
            named: "chip-load-high-strain"
        )
    }

    // MARK: - Display states

    func testChipLoadingRenders() {
        assertSnapshot(
            of: hosted(ContributorChip(variant: .hrv(value: "—", trend: nil), state: .loading)),
            named: "chip-loading"
        )
    }

    func testChipNoDataRenders() {
        assertSnapshot(
            of: hosted(ContributorChip(variant: .hrv(value: "—", trend: nil), state: .noData)),
            named: "chip-no-data"
        )
    }

    func testChipBuildingBaselineRenders() {
        assertSnapshot(
            of: hosted(
                ContributorChip(variant: .hrv(value: "—", trend: nil), state: .buildingBaseline)
            ),
            named: "chip-building-baseline"
        )
    }

    /// Behind the paywall.
    func testChipLockedRenders() {
        assertSnapshot(
            of: hosted(ContributorChip(variant: .hrv(value: "—", trend: nil), state: .locked)),
            named: "chip-locked"
        )
    }

    func testChipCompactRenders() {
        assertSnapshot(
            of: hosted(ContributorChip(variant: .hrv(value: "45 ms", trend: .down), compact: true)),
            named: "chip-compact"
        )
    }

    // MARK: - Breathing guide

    func testBreathingMandalaRenders() {
        // `isAnimating: false` so the frame is deterministic — an animating
        // view would snapshot at whatever phase the render happened to catch.
        assertSnapshot(
            of: hosted(BreathingMandalaView(cycleDuration: 5.5, isAnimating: false)),
            named: "breathing-mandala"
        )
    }
}
