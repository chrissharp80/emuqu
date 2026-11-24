import SwiftUI

// The Record tab's panels live in `RecordPanels`. `panels` is rebuilt on each
// access from the view's live state, and every mutation travels back through
// a binding or one of the view's actions.

extension RecordView {
    /// Grouped onto fewer lines than one argument per line to stay inside the
    /// 20-line declaration limit; the call is a single expression either way.
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
            discardRecording: { discardRecording(startOver: $0) }, discardPausedNight: { discardPausedNight() },
            startStreaming: { startStreaming(seconds: $0) }, stopStreaming: { stopStreaming() },
            extendedCaptureMode: $extendedCaptureMode,
            selectedTags: $selectedTags, sessionNotes: $sessionNotes,
            fetchFailed: $fetchFailed, showingDiscardConfirm: $showingDiscardConfirm, isDiscarding: isDiscarding,
            breathingAudio: breathingAudio
        )
    }
}
