@testable import Emuqu
import SwiftUI
import XCTest

/// Snapshot coverage for every state of the app's primary readouts.
///
/// `ScoreRing` is the first thing a user looks at each morning, and it has five
/// distinct states. Three of them — no data, building baseline, error — are
/// only reached when something is missing or wrong, which makes them the least
/// likely to be checked by hand and the most damaging to render badly: a user
/// who opens the app to an unreadable score has no idea whether the app or
/// their body is the problem.
///
/// Every verdict tier is pinned too, because the tier drives the colour and a
/// mis-mapped tier would tell someone they are recovered when they are not.
@MainActor
final class StateSnapshotTests: XCTestCase {
    private func hosted(_ view: some View) -> some View {
        view
            .environment(RRCollector())
            .environment(SettingsManager.shared)
    }

    // MARK: - Score ring states

    func testScoreRingDefaultRenders() {
        assertSnapshot(
            of: hosted(ScoreRing(state: .default(score: 78, verdict: .good), size: .hero)),
            named: "ring-default"
        )
    }

    func testScoreRingLoadingRenders() {
        assertSnapshot(of: hosted(ScoreRing(state: .loading, size: .hero)), named: "ring-loading")
    }

    func testScoreRingBuildingBaselineRenders() {
        assertSnapshot(
            of: hosted(ScoreRing(state: .buildingBaseline(day: 4, target: 14), size: .hero)),
            named: "ring-building-baseline"
        )
    }

    func testScoreRingNoDataRenders() {
        assertSnapshot(of: hosted(ScoreRing(state: .noData, size: .hero)), named: "ring-no-data")
    }

    func testScoreRingErrorRenders() {
        assertSnapshot(
            of: hosted(ScoreRing(state: .error(message: "Couldn't read sleep"), size: .hero)),
            named: "ring-error"
        )
    }

    // MARK: - Every verdict tier
    //
    // The tier drives the ring's colour. A mis-mapped tier tells someone they
    // are recovered when they are not, so each is pinned separately.

    // Written out one per tier rather than looped: a loop builds the snapshot
    // name by interpolation, and `check_snapshot_references.sh` reads the call
    // sites statically. Teaching that gate to evaluate interpolation would make
    // it weaker; naming each case makes both the test and the gate exact.
    func testVerdictExcellentRenders() {
        assertSnapshot(
            of: hosted(ScoreRing(state: .default(score: 50, verdict: .excellent), size: .card)),
            named: "ring-verdict-excellent"
        )
    }

    func testVerdictGoodRenders() {
        assertSnapshot(
            of: hosted(ScoreRing(state: .default(score: 50, verdict: .good), size: .card)),
            named: "ring-verdict-good"
        )
    }

    func testVerdictFairRenders() {
        assertSnapshot(
            of: hosted(ScoreRing(state: .default(score: 50, verdict: .fair), size: .card)),
            named: "ring-verdict-fair"
        )
    }

    func testVerdictPayAttentionRenders() {
        assertSnapshot(
            of: hosted(ScoreRing(state: .default(score: 50, verdict: .payAttention), size: .card)),
            named: "ring-verdict-pay-attention"
        )
    }

    func testVerdictLowRenders() {
        assertSnapshot(
            of: hosted(ScoreRing(state: .default(score: 50, verdict: .low), size: .card)),
            named: "ring-verdict-low"
        )
    }

    func testVerdictVeryLowRenders() {
        assertSnapshot(
            of: hosted(ScoreRing(state: .default(score: 50, verdict: .veryLow), size: .card)),
            named: "ring-verdict-very-low"
        )
    }

    // MARK: - Sizes

    func testScoreRingInlineSizeRenders() {
        assertSnapshot(
            of: hosted(ScoreRing(state: .default(score: 61, verdict: .fair), size: .inline)),
            named: "ring-inline"
        )
    }

    // MARK: - Feeling prompts
    //
    // Shown once per reading; the "already answered" variant is a different
    // layout that only appears on a revisit.

    func testMorningFeelingPromptRenders() {
        assertSnapshot(
            of: hosted(
                MorningFeelingPrompt(onSelect: { _, _ in }, onSkip: {}, existing: nil, existingTags: [])
            ),
            named: "prompt-morning-feeling"
        )
    }

    func testWorkoutFeelingPromptRenders() {
        assertSnapshot(
            of: hosted(
                WorkoutFeelingPrompt(onSelect: { _, _ in }, onSkip: {}, existing: 3, existingNote: "Heavy legs")
            ),
            named: "prompt-workout-feeling"
        )
    }

    // MARK: - Static content screens

    func testPrivacyPolicyRenders() {
        assertSnapshot(of: NavigationStack { PrivacyPolicyView() }, named: "screen-privacy-policy")
    }

    func testHelpCenterRenders() {
        assertSnapshot(of: hosted(NavigationStack { HelpCenterView() }), named: "screen-help-center")
    }
}
