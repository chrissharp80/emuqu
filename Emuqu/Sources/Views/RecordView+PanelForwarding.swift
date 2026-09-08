import SwiftUI

// Record-tab panels live in `RecordPanels`.
//
// `panels` is rebuilt on each access from the view's live state, and every
// mutation travels back through a binding.

extension RecordView {
    /// Grouped onto fewer lines than one argument per line to stay inside the
    /// 20-line declaration limit the refactor spec enforces; the call is a
    /// single expression either way.
    var panels: RecordPanels {
        RecordPanels(
            collector: collector, deviceStatus: deviceStatus,
            morningCoordination: morningCoordination,
            streamingLifecycle: streamingLifecycle, sessionState: sessionState,
            settingsManager: settingsManager,
            isActivelyRecording: isActivelyRecording,
            isBatteryLow: isBatteryLow, isBatteryCritical: isBatteryCritical,
            startOvernightRecording: { startOvernightRecording() },
            startLinkedRecording: { startLinkedRecording(linkedTo: $0) },
            pauseRecording: { pauseRecording() }, resumeRecording: { resumeRecording() },
            finalizeFromPause: { finalizeFromPause() }, stopAndFetch: { stopAndFetch() },
            startStreaming: { startStreaming(seconds: $0) }, stopStreaming: { stopStreaming() },
            extendedCaptureMode: $extendedCaptureMode, quickSource: $quickSource,
            selectedTags: $selectedTags, sessionNotes: $sessionNotes,
            fetchFailed: $fetchFailed,
            watchBreatheButton: { AnyView(watchBreatheButton) },
            breathingAudio: breathingAudio
        )
    }

    var overnightRecordingSection: some View { panels.overnightRecordingSection }

    var quickReadingSection: some View { panels.quickReadingSection }

    var quickSourcePicker: some View { panels.quickSourcePicker }

    func continueRecoveryCard(session: HRVSession) -> some View {
        panels.continueRecoveryCard(session: session)
    }

    func recoverStoredData() { panels.recoverStoredData() }

    func discardAndStartFresh() { panels.discardAndStartFresh() }
}
