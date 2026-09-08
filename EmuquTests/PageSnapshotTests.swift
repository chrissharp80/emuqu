@testable import Emuqu
import SwiftUI
import XCTest

/// Snapshot coverage for the settings subpages and standalone screens.
///
/// None of these take constructor arguments, which makes them cheap to pin and
/// means there is no excuse for them being unpinned. Several are destructive or
/// legal screens — delete-all-data, trash, the health disclaimer, onboarding —
/// where rendering wrong is worse than a cosmetic bug: a user who cannot read
/// the delete confirmation cannot give informed consent to it.
@MainActor
final class PageSnapshotTests: XCTestCase {
    private func hosted(_ view: some View) -> some View {
        NavigationStack { view }
            .environment(RRCollector())
            .environment(SettingsManager.shared)
            .environment(StoreKitManager.shared)
            .environment(LanguageManager.shared)
            .environment(CloudKitSyncManager.shared)
            .environment(VoiceConversationController.shared)
            .environment(ArchiveSignal())
            .environment(MorningCoordination())
    }

    // MARK: - Destructive and legal screens

    func testDeleteAllDataRenders() {
        assertSnapshot(of: hosted(DeleteAllDataPage()), named: "page-delete-all-data")
    }

    func testTrashRenders() {
        assertSnapshot(of: hosted(TrashView()), named: "page-trash")
    }

    func testHealthDisclaimerRenders() {
        assertSnapshot(of: hosted(HealthDisclaimerView()), named: "page-health-disclaimer")
    }

    func testAdvancedDataControlsRenders() {
        assertSnapshot(of: hosted(AdvancedDataControlsPage()), named: "page-advanced-data")
    }

    // MARK: - Onboarding

    func testOnboardingRenders() {
        assertSnapshot(of: hosted(OnboardingView()), named: "page-onboarding")
    }

    // MARK: - Settings subpages

    func testNotificationsSettingsRenders() {
        assertSnapshot(of: hosted(NotificationsSettingsPage()), named: "page-notifications-settings")
    }

    func testTrainingSettingsRenders() {
        assertSnapshot(of: hosted(TrainingSettingsPage()), named: "page-training-settings")
    }

    func testModesSettingsRenders() {
        assertSnapshot(of: hosted(ModesSettingsPage(settingsManager: SettingsManager.shared)), named: "page-modes-settings")
    }

    func testReportsSettingsRenders() {
        assertSnapshot(of: hosted(ReportsSettingsPage(settingsManager: SettingsManager.shared)), named: "page-reports-settings")
    }

    func testSavedRoutesRenders() {
        assertSnapshot(of: hosted(SavedRoutesPage()), named: "page-saved-routes")
    }

    // MARK: - Recovery and methodology

    func testRecoveryMethodologyRenders() {
        assertSnapshot(of: hosted(RecoveryMethodologyView()), named: "page-recovery-methodology")
    }

    func testLostSessionsRenders() {
        assertSnapshot(of: hosted(LostSessionsView()), named: "page-lost-sessions")
    }

}
