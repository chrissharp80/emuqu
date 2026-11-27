@testable import Emuqu
import SwiftUI
import XCTest

/// Snapshot coverage for the settings subpages and standalone screens.
///
/// None of these take constructor arguments, which makes them cheap to check
/// and means there is no excuse for leaving them unchecked. Several are destructive or
/// legal screens — delete-all-data, trash, the health disclaimer, onboarding —
/// where rendering wrong is worse than a cosmetic bug: a user who cannot read
/// the delete confirmation cannot give informed consent to it.
///
/// All of these pages are render-checked (`assertRenders`), not pixel-compared: their
/// navigation chrome (large titles, sheet bars, the tab bar) settles at
/// different offsets from run to run, so a reference would fail on timing
/// alone. The check still builds and draws each whole screen.
@MainActor
final class PageSnapshotTests: XCTestCase {
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
    }

    // MARK: - Destructive and legal screens

    func testDeleteAllDataRenders() {
        assertRenders(of: hosted(DeleteAllDataPage()), named: "page-delete-all-data")
    }

    func testTrashRenders() {
        assertRenders(of: hosted(TrashView()), named: "page-trash")
    }

    /// As a new user meets it: the first-launch gate, before acceptance.
    func testHealthDisclaimerRenders() {
        useHealthDisclaimerAccepted(false)
        assertRenders(of: hosted(HealthDisclaimerView()), named: "page-health-disclaimer")
    }

    func testAdvancedDataControlsRenders() {
        assertRenders(of: hosted(AdvancedDataControlsPage()), named: "page-advanced-data")
    }

    // MARK: - Onboarding

    func testOnboardingRenders() {
        assertRenders(of: hosted(OnboardingView()), named: "page-onboarding")
    }

    // MARK: - Settings subpages

    func testNotificationsSettingsRenders() {
        assertRenders(of: hosted(NotificationsSettingsPage()), named: "page-notifications-settings")
    }

    func testTrainingSettingsRenders() {
        assertRenders(of: hosted(TrainingSettingsPage()), named: "page-training-settings")
    }

    func testModesSettingsRenders() {
        assertRenders(of: hosted(ModesSettingsPage(settingsManager: SettingsManager.shared)), named: "page-modes-settings")
    }

    func testReportsSettingsRenders() {
        assertRenders(of: hosted(ReportsSettingsPage(settingsManager: SettingsManager.shared)), named: "page-reports-settings")
    }

    func testSavedRoutesRenders() {
        assertRenders(of: hosted(SavedRoutesPage()), named: "page-saved-routes")
    }

    // MARK: - Recovery and methodology

    func testRecoveryMethodologyRenders() {
        assertRenders(of: hosted(RecoveryMethodologyView()), named: "page-recovery-methodology")
    }

    func testLostSessionsRenders() {
        assertRenders(of: hosted(LostSessionsView()), named: "page-lost-sessions")
    }

}
