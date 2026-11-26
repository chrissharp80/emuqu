@testable import Emuqu
import SwiftUI
import XCTest

/// Snapshot coverage for the remaining large screens.
///
/// Dashboard, history, main tab shell, settings subpages, the coach home and
/// the trail discovery screen. With the tab and detail suites these cover the
/// screens a user reaches in ordinary use.
@MainActor
final class RemainingScreenSnapshotTests: XCTestCase {
    private func hosted(_ view: some View) -> some View {
        NavigationStack { view }
            .environment(SnapshotFixtures.collector())
            .environment(SettingsManager.shared)
            .environment(StoreKitManager.shared)
            .environment(LanguageManager.shared)
            .environment(SnapshotFixtures.syncManager())
            .environment(VoiceConversationController.shared)
            .environment(ArchiveSignal())
            .environment(MorningCoordination())
            .environment(DeviceStatus())
            .environment(StreamingLifecycle())
            .environment(SessionState())
    }

    private var sessions: [HRVSession] {
        (0 ..< 8).map { SnapshotFixtures.overnightSession(dayOffset: -$0) }
    }

    func testMainTabShellRenders() {
        useEmptyDashboardCache()
        assertSnapshot(of: hosted(MainTabView()), named: "shell-main-tab")
    }

    func testHistoryRenders() {
        assertSnapshot(
            of: hosted(
                HistoryView(
                    // Empty: the list groups readings under "This Week" and
                    // "Last Week", counted from today, so a populated list
                    // would change as the days pass.
                    archive: SessionArchive(directory: SnapshotFixtures.emptyArchiveDirectory),
                    settingsManager: AppDependencies.current.app.settingsManager,
                    onDelete: { _ in },
                    onUpdateTags: { _, _, _ in },
                    onReanalyze: nil,
                    scrollToTopToken: UUID()
                )
            ),
            named: "screen-history"
        )
    }

    func testBiometricsSettingsRenders() {
        assertSnapshot(of: hosted(BiometricsSettingsPage()), named: "screen-biometrics-settings")
    }

    func testWearablesSettingsRenders() {
        assertSnapshot(of: hosted(WearablesSettingsPage()), named: "screen-wearables-settings")
    }

    /// The coach's home, after the data-handling notice has been accepted.
    func testCoachHomeRenders() {
        useAssistantDisclaimerAccepted(true)
        assertSnapshot(
            of: hosted(CoachHomeV2View(scrollToBottomSignal: UUID())),
            named: "screen-coach-home"
        )
    }

    func testDiscoverTrailsRenders() {
        assertSnapshot(
            of: hosted(DiscoverTrailsView(onTrailPicked: { _ in })),
            named: "screen-discover-trails"
        )
    }

    func testSessionHRVDetailRenders() {
        assertSnapshot(
            of: hosted(
                SessionHRVDetailView(
                    session: SnapshotFixtures.overnightSession(),
                    result: SnapshotFixtures.analysisResult(),
                    recentSessions: sessions
                )
            ),
            named: "screen-session-hrv-detail"
        )
    }

    func testSleepTimelineEditorRenders() {
        assertSnapshot(
            of: hosted(
                SleepTimelineEditorView(
                    sleepData: SnapshotFixtures.sleepData(),
                    onSave: { _ in },
                    onRefreshFromHealthKit: nil
                )
            ),
            named: "screen-sleep-timeline-editor"
        )
    }
}
