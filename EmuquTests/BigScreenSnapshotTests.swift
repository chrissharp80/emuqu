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
/// The environment objects come from a container of each test's own (fresh
/// settings, an empty archive and baseline in a temporary folder), which is
/// also put in force for the test, so a snapshot does not depend on whatever
/// state the app or a previous test left behind.
@MainActor
final class BigScreenSnapshotTests: XCTestCase {
    /// A container over fresh stores in a temporary folder
    /// (`SnapshotTesting.isolatedDependencies`), in force until the test
    /// ends, when the folder is removed.
    private func isolatedDependencies() -> AppDependencies {
        let isolated = SnapshotTesting.isolatedDependencies()
        let installed = AppDependencies.install(isolated.dependencies)
        addTeardownBlock { @MainActor in
            installed.end()
            isolated.discard()
        }
        return isolated.dependencies
    }

    /// Wrapped in a `NavigationStack`: these bodies are scroll content that
    /// lays out to nothing without a container, which the blank guard catches
    /// rather than letting a uniform reference be recorded.
    private func environment(_ view: some View) -> some View {
        let dependencies = isolatedDependencies()
        return NavigationStack { view }
            .environment(\.dependencies, dependencies)
            .environment(RRCollector(dependencies: dependencies))
            .environment(dependencies.app.settingsManager)
            .environment(dependencies.collection.archiveSignal)
            .environment(MorningCoordination())
    }

    /// Tall enough to hold the trend and history cards below the score: the
    /// part a populated history and a first morning draw differently. At the
    /// device height both captures stop above it and are the same picture.
    private let fullLength = CGSize(width: SnapshotTesting.defaultSize.width, height: 2_400)

    /// The fixture's objects are the container's own, never the app's.
    func testTheFixtureBuildsItsOwnInstances() {
        let dependencies = isolatedDependencies()
        XCTAssertFalse(dependencies.app.settingsManager === AppDependencies.live.app.settingsManager)
        XCTAssertFalse(dependencies.storage.sessionArchive === AppDependencies.live.storage.sessionArchive)
        XCTAssertFalse(dependencies.collection.archiveSignal === AppDependencies.live.collection.archiveSignal)
        XCTAssertTrue(AppDependencies.current.app.settingsManager === dependencies.app.settingsManager)
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
            named: "screen-morning-results",
            size: fullLength
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
            named: "screen-morning-results-no-history",
            size: fullLength
        )
    }

    /// The header says how long ago the workout ended, so the frozen
    /// fixture's "5 years ago" would change as the years pass. Moved forward
    /// by whole days to end between three and four days before the render,
    /// which reads "3 days ago" on every run; nothing else on the screen
    /// depends on the date.
    private func workoutEndedThreeDaysAgo() -> HRVSession {
        let day: TimeInterval = 86_400
        let length: TimeInterval = 2_400
        let days = ((Date().timeIntervalSince(SnapshotFixtures.anchor) - length) / day).rounded(.down) - 3
        return SnapshotFixtures.workoutSession(start: SnapshotFixtures.anchor.addingTimeInterval(days * day))
    }

    func testFitnessPostSummaryRenders() {
        assertSnapshot(
            of: environment(
                FitnessPostSummaryView(
                    session: workoutEndedThreeDaysAgo(),
                    onDone: {}
                )
            ),
            named: "screen-fitness-post-summary"
        )
    }
}
