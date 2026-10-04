@testable import Emuqu
import SwiftUI
import XCTest

/// Snapshot coverage for the tab-level screens.
///
/// These are the largest views in the app and the ones a user is looking at
/// most of the time: the record tab (3,182 lines), the fitness tab (2,108),
/// settings (1,851), trends and import. Together with the result screens they
/// are the bulk of the ~73,000-line view layer.
///
/// The collector, archive signal and recording sub-observables are
/// constructed fresh per test over an empty archive, and the settings are put
/// on fresh-install defaults. `LanguageManager`, `CloudKitSyncManager`,
/// `StoreKitManager` and `VoiceConversationController` have no injectable
/// instance and are the shared ones.
@MainActor
final class TabScreenSnapshotTests: XCTestCase {
    /// Fresh-install settings for every render (restored afterwards), so
    /// the pictures do not depend on the host's settings.
    override func setUp() async throws {
        try await super.setUp()
        useDefaultSettings()
    }

    /// Every environment value the tab screens read between them. Supplying
    /// the full set to each keeps the helper simple; SwiftUI ignores what a
    /// given view does not ask for.
    private func hosted(_ view: some View) -> some View {
        NavigationStack { view }
            .environment(SnapshotFixtures.collector())
            .environment(SettingsManager.shared)
            .environment(LanguageManager.shared)
            .environment(CloudKitSyncManager.shared)
            .environment(VoiceConversationController.shared)
            // SwiftUI fatal-errors when a view reads an `@EnvironmentObject`
            // nothing supplied — `PurchaseStatusView` inside Settings reads
            // StoreKitManager, and omitting it crashed the render rather than
            // failing it. This is the same hazard that makes converting the
            // remaining view-side `.shared` reads to `@EnvironmentObject` a bad
            // trade while view coverage is still low.
            .environment(StoreKitManager.shared)
            .environment(ArchiveSignal())
            .environment(MorningCoordination())
            .environment(DeviceStatus())
            .environment(StreamingLifecycle())
            .environment(SessionState())
    }

    func testSettingsRenders() {
        assertSnapshot(of: hosted(SettingsView(scrollToTopToken: UUID())),
                       named: "tab-settings")
    }

    func testTrendsRenders() {
        assertSnapshot(of: hosted(TrendsV2View()), named: "tab-trends")
    }

    func testImportDataRenders() {
        assertSnapshot(of: hosted(ImportDataView()), named: "screen-import-data")
    }

    func testFitnessTabRenders() {
        assertSnapshot(of: hosted(FitnessTabView(scrollToTopToken: UUID())),
                       named: "tab-fitness")
    }

    func testRecordTabRenders() {
        assertSnapshot(
            of: hosted(RecordView(selectedTab: .constant(.record))),
            named: "tab-record"
        )
    }
}
