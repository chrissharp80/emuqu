@testable import Emuqu
import SwiftUI
import XCTest

/// Snapshot coverage for the two largest screens in the app.
///
/// `MorningResultsView` (2,558 lines) and `FitnessPostSummaryView` (2,774) are
/// what a user actually looks at after a reading or a workout, and between them
/// they are a meaningful slice of the ~73,000-line view layer that is otherwise
/// barely covered. Three view types were split out of the fitness
/// summary on a "behaviour-preserving by construction" argument;
/// these pin the assembled screen those pieces sit in.
///
/// The environment objects are constructed fresh rather than taken from
/// singletons, so a snapshot does not depend on whatever state a previous test
/// left behind.
@MainActor
final class BigScreenSnapshotTests: XCTestCase {
    /// Wrapped in a `NavigationStack`: these bodies are scroll content that
    /// lays out to nothing without a container, which the blank guard catches
    /// rather than letting a uniform reference be recorded.
    private func environment(_ view: some View) -> some View {
        NavigationStack { view }
            .environment(RRCollector())
            .environment(SettingsManager.shared)
            .environment(ArchiveSignal())
            .environment(MorningCoordination())
    }

    func testMorningResultsRenders() {
        let session = SnapshotFixtures.overnightSession()
        let recent = (1 ... 5).map { SnapshotFixtures.overnightSession(dayOffset: -$0) }
        assertSnapshot(
            of: environment(
                MorningResultsView(
                    session: session,
                    result: SnapshotFixtures.analysisResult(),
                    recentSessions: recent,
                    onDiscard: {}
                )
            ),
            named: "screen-morning-results"
        )
    }

    /// No prior readings is the first-morning state, and the one most likely to
    /// be broken by a change written against a populated trend.
    func testMorningResultsWithNoHistoryRenders() {
        assertSnapshot(
            of: environment(
                MorningResultsView(
                    session: SnapshotFixtures.overnightSession(),
                    result: SnapshotFixtures.analysisResult(),
                    recentSessions: [],
                    onDiscard: {}
                )
            ),
            named: "screen-morning-results-no-history"
        )
    }

    func testFitnessPostSummaryRenders() {
        assertSnapshot(
            of: environment(
                FitnessPostSummaryView(
                    session: SnapshotFixtures.workoutSession(),
                    onDone: {}
                )
            ),
            named: "screen-fitness-post-summary"
        )
    }
}
