@testable import Emuqu
import SwiftUI
import XCTest

/// Snapshot coverage for the screens the suite had never rendered.
///
/// ## Why these
///
/// The view layer is checked by rendering it, and whatever is never rendered is
/// checked by nobody: half of `Emuqu/Sources/Views` sat at 0%, including the
/// Record tab's panels, the settings pages, the export screen and the sensor
/// sheet. Those are not decorative — the Record panels decide what the user is
/// offered mid-session, and the settings pages write the values everything else
/// reads. A rendering crash or a blank screen there is a broken app, and
/// nothing in the suite would have said so.
///
/// Every input is frozen (`SnapshotFixtures.anchor`), because a reference image
/// built from `Date()` re-renders differently tomorrow and teaches people to
/// ignore the failure.
@MainActor
final class UncoveredScreenSnapshotTests: XCTestCase {
    /// The environment a screen needs to render outside the app.
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
            .environment(DeviceStatus())
            .environment(StreamingLifecycle())
            .environment(SessionState())
    }

    // MARK: - Settings pages

    func testProfileSettingsRenders() {
        assertSnapshot(of: hosted(ProfileSettingsPage()), named: "uncovered-settings-profile")
    }

    func testSleepSettingsRenders() {
        assertSnapshot(of: hosted(SleepSettingsPage()), named: "uncovered-settings-sleep")
    }

    func testDataSettingsRenders() {
        assertSnapshot(of: hosted(DataSettingsPage()), named: "uncovered-settings-data")
    }

    func testCustomTagsRenders() {
        assertSnapshot(of: hosted(CustomTagsPage()), named: "uncovered-settings-custom-tags")
    }

    func testNotificationsSettingsRenders() {
        assertSnapshot(of: hosted(NotificationsSettingsPage()), named: "uncovered-settings-notifications")
    }

    func testModesSettingsRenders() {
        assertSnapshot(of: hosted(ModesSettingsPage()), named: "uncovered-settings-modes")
    }

    func testPrivacyPolicyRenders() {
        assertSnapshot(of: hosted(PrivacyPolicyView()), named: "uncovered-privacy-policy")
    }

    // MARK: - Data in and out

    func testExportDataRenders() {
        assertSnapshot(of: hosted(ExportDataView()), named: "uncovered-export-data")
    }

    func testImportDataRenders() {
        assertSnapshot(of: hosted(ImportDataView()), named: "uncovered-import-data")
    }

    // MARK: - Sensors

    func testSensorManagementRenders() {
        assertSnapshot(of: hosted(SensorManagementSheet(polarManager: PolarManager(), onDismiss: {})), named: "uncovered-sensor-management")
    }

    func testOnboardingSensorPageRenders() {
        assertSnapshot(of: hosted(OnboardingSensorPage(advance: {})), named: "uncovered-onboarding-sensor")
    }

    // MARK: - Recording status

    func testDeviceRecordingStatusRenders() {
        assertSnapshot(
            of: hosted(DeviceRecordingStatus(
                deviceStatus: recordingDeviceStatus(),
                persistedStartTime: SnapshotFixtures.anchor
            )),
            named: "uncovered-device-recording-status"
        )
    }

    func testOvernightStreamingStatusRenders() {
        let lifecycle = StreamingLifecycle()
        lifecycle.isOvernightStreaming = true
        lifecycle.streamingElapsedSeconds = 3 * 3_600 + 12 * 60
        assertSnapshot(
            of: hosted(OvernightStreamingStatus(
                streamingLifecycle: lifecycle,
                polarManager: PolarManager(),
                strapBackup: .recording
            )),
            named: "uncovered-overnight-streaming-status"
        )
    }

    func testDeviceInfoPanelRenders() {
        assertSnapshot(of: hosted(DeviceInfoPanelObserving(polarManager: PolarManager())), named: "uncovered-device-info-panel")
    }

    // MARK: - Archive status

    func testArchiveStatusLineRenders() {
        assertSnapshot(
            of: hosted(ArchiveStatusLine(
                session: SnapshotFixtures.overnightSession(), collector: RRCollector(),
                archiveSignal: ArchiveSignal(), syncManager: CloudKitSyncManager.shared
            )),
            named: "uncovered-archive-status-line"
        )
    }

    func testArchiveStatusDetailRenders() {
        assertSnapshot(
            of: hosted(ArchiveStatusDetailSheet(
                session: SnapshotFixtures.overnightSession(), collector: RRCollector(),
                archiveSignal: ArchiveSignal(), syncManager: CloudKitSyncManager.shared
            )),
            named: "uncovered-archive-status-detail"
        )
    }

    // MARK: - Detail and troubleshooting screens

    func testRecoveryScoreDetailRenders() {
        assertSnapshot(
            of: hosted(RecoveryScoreDetailView(
                session: SnapshotFixtures.overnightSession(),
                result: SnapshotFixtures.analysisResult(),
                recentSessions: (0 ..< 6).map { SnapshotFixtures.overnightSession(dayOffset: -$0) },
                baselineStats: nil,
                totalSessionCount: 42
            )),
            named: "uncovered-recovery-score-detail"
        )
    }

    func testTroubleshootingRenders() {
        assertSnapshot(of: hosted(TroubleshootingPage()), named: "uncovered-troubleshooting")
    }

    func testWorkoutPreflightRenders() {
        assertSnapshot(
            of: hosted(
                WorkoutPreflightView(
                    collector: RRCollector(),
                    recorder: recordingRecorder(),
                    onStart: { _, _, _, _, _, _ in }
                )
                .environment(WorkoutPlanModel())
            ),
            named: "uncovered-workout-preflight"
        )
    }

    func testFitnessRecordingRenders() {
        assertSnapshot(
            of: hosted(FitnessRecordingView(recorder: recordingRecorder(), onStop: {})),
            named: "uncovered-fitness-recording"
        )
    }

    // MARK: - Record panels

    func testOvernightRecordingPanelRenders() {
        assertSnapshot(of: hosted(panels().overnightRecordingSection), named: "uncovered-panel-overnight")
    }

    func testQuickReadingPanelRenders() {
        assertSnapshot(of: hosted(panels().quickReadingSection), named: "uncovered-panel-quick-reading")
    }

    // MARK: - Morning reanalysis

    func testReanalysisControlsRender() {
        let session = SnapshotFixtures.overnightSession()
        let result = SnapshotFixtures.analysisResult()
        let controls = MorningReanalysisControls(
            vm: MorningResultsViewModel(session: session, result: result),
            session: session,
            result: result,
            recentSessions: (0 ..< 4).map { SnapshotFixtures.overnightSession(dayOffset: -$0) },
            collector: RRCollector(),
            onReanalyze: nil,
            onReanalyzeAt: nil,
            onApplyManualResult: nil,
            exportURL: .constant(nil),
            emailURL: .constant(nil),
            isManualWindowMode: .constant(false),
            manualResult: .constant(nil),
            manualPickMessage: .constant(nil),
            strapMergeWorking: .constant(false),
            strapMergeMessage: .constant(nil)
        )
        assertSnapshot(of: hosted(controls.windowSelectionMethodSection), named: "uncovered-reanalysis-controls")
    }

    // MARK: - Helpers

    /// The Record tab's panels, wired to idle state: what the user sees before
    /// anything is recording.
    private func panels() -> RecordPanels {
        RecordPanels(
            collector: RRCollector(),
            deviceStatus: recordingDeviceStatus(),
            morningCoordination: MorningCoordination(),
            streamingLifecycle: StreamingLifecycle(),
            sessionState: SessionState(),
            settingsManager: SettingsManager.shared,
            isActivelyRecording: false,
            isBatteryLow: false,
            isBatteryCritical: false,
            startOvernightRecording: {},
            startLinkedRecording: { _ in },
            pauseRecording: {},
            resumeRecording: {},
            finalizeFromPause: {},
            stopAndFetch: {},
            startStreaming: { _ in },
            stopStreaming: {},
            extendedCaptureMode: .constant(.both),
            quickSource: .constant(nil),
            selectedTags: .constant([]),
            sessionNotes: .constant(""),
            fetchFailed: .constant(false),
            watchBreatheButton: { AnyView(EmptyView()) },
            breathingAudio: BreathingAudioManager()
        )
    }


    /// The live workout screen, rendered from a recorder in its default state:
    /// what the user sees in the first seconds of a workout, before any sample
    /// has landed.
    private func recordingRecorder() -> WorkoutRecorder {
        WorkoutRecorder(core: RRCollector(), conversation: VoiceConversationController.shared)
    }


    /// A strap mid-recording, so the status views draw their populated state
    /// rather than their empty one.
    private func recordingDeviceStatus() -> DeviceStatus {
        let status = DeviceStatus()
        status.isDeviceConnected = true
        status.connectedDeviceType = .h10
        status.isRecordingOnDevice = true
        status.recordingState = .recording
        status.batteryLevel = 82
        return status
    }
}
