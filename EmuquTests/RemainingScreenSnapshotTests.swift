@testable import Emuqu
import SwiftUI
import XCTest

/// Snapshot coverage for the coach home, a session's HRV analysis and the
/// sleep timeline editor.
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

    // Not snapshot-tested: the main tab shell, the history list, the biometrics and wearables settings and the trail picker. The layout includes system navigation
    // chrome (large titles, sheet bars, the tab bar) that settles at different
    // offsets with timing, the content is static or covered by the component
    // snapshots, and the behaviour is covered by unit and UI tests.

    /// The coach's home, after the data-handling notice has been accepted.
    func testCoachHomeRenders() {
        useAssistantDisclaimerAccepted(true)
        assertSnapshot(
            of: hosted(CoachHomeV2View(scrollToBottomSignal: UUID())),
            named: "screen-coach-home"
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
