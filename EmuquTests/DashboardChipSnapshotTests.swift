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

    /// Chips take their width from the row they sit in, so a lone chip is
    /// given the 88pt a row slot has on a 440pt iPhone; unpinned it would
    /// fill the 402pt canvas.
    private func chip(_ view: ContributorChip) -> some View {
        hosted(view.frame(width: 88))
    }

    /// Four fixed 88pt chips needed 412pt with the row's spacing and the
    /// dashboard's padding, wider than a 375, 393 or 402pt iPhone, and the
    /// last chip ran off the screen. The row must fit the narrowest one.
    func testFourChipsFitTheNarrowestIPhone() {
        let dashboardPadding: CGFloat = 18 * 2
        let available = 375 - dashboardPadding
        let row = HStack(spacing: 8) {
            ContributorChip(variant: .hrv(value: "45 ms", trend: .up))
            ContributorChip(variant: .sleep(duration: "6h 40m", efficiency: "95%"))
            ContributorChip(variant: .vitals(status: .elevated, leadVital: "17.8 br/min"))
            ContributorChip(variant: .load(verdict: .building, subline: "CTL 55 · ramp 4.2"))
        }
        let host = UIHostingController(rootView: row.environment(RRCollector()).environment(SettingsManager.shared))
        let fitted = host.sizeThatFits(in: CGSize(width: available, height: 200))
        XCTAssertLessThanOrEqual(fitted.width, available)
    }

    // MARK: - Variants

    func testHRVChipRenders() {
        assertSnapshot(
            of: chip(ContributorChip(variant: .hrv(value: "45 ms", trend: .up))),
            named: "chip-hrv"
        )
    }

    func testSleepChipRenders() {
        assertSnapshot(
            of: chip(ContributorChip(variant: .sleep(duration: "6h 40m", efficiency: "95%"))),
            named: "chip-sleep"
        )
    }

    func testVitalsChipRenders() {
        assertSnapshot(
            of: chip(ContributorChip(variant: .vitals(status: .normal, leadVital: "14.2 br/min"))),
            named: "chip-vitals"
        )
    }

    /// An elevated vitals reading is the one a user needs to notice.
    func testVitalsChipElevatedRenders() {
        assertSnapshot(
            of: chip(ContributorChip(variant: .vitals(status: .elevated, leadVital: "17.8 br/min"))),
            named: "chip-vitals-elevated"
        )
    }

    func testLoadChipRenders() {
        assertSnapshot(
            of: chip(
                ContributorChip(variant: .load(verdict: .building, subline: "CTL 55 · ramp 4.2"))
            ),
            named: "chip-load"
        )
    }

    /// High strain is unintentional deep fatigue — the verdict that should
    /// make someone back off.
    func testLoadChipHighStrainRenders() {
        assertSnapshot(
            of: chip(
                ContributorChip(variant: .load(verdict: .highStrain, subline: "TSB -28"))
            ),
            named: "chip-load-high-strain"
        )
    }

    // MARK: - Display states

    func testChipLoadingRenders() {
        assertSnapshot(
            of: chip(ContributorChip(variant: .hrv(value: "—", trend: nil), state: .loading)),
            named: "chip-loading"
        )
    }

    func testChipNoDataRenders() {
        assertSnapshot(
            of: chip(ContributorChip(variant: .hrv(value: "—", trend: nil), state: .noData)),
            named: "chip-no-data"
        )
    }

    func testChipBuildingBaselineRenders() {
        assertSnapshot(
            of: chip(
                ContributorChip(variant: .hrv(value: "—", trend: nil), state: .buildingBaseline)
            ),
            named: "chip-building-baseline"
        )
    }

    /// Behind the paywall.
    func testChipLockedRenders() {
        assertSnapshot(
            of: chip(ContributorChip(variant: .hrv(value: "—", trend: nil), state: .locked)),
            named: "chip-locked"
        )
    }

    func testChipCompactRenders() {
        assertSnapshot(
            of: chip(ContributorChip(variant: .hrv(value: "45 ms", trend: .down), compact: true)),
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
