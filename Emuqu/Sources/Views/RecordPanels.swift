import SwiftUI

/// The record-tab panels: device status, capture-mode selection, the recording
/// controls, and the battery and fetch-failure banners.
///
/// The recording actions arrive as closures: they drive the session
/// lifecycle and belong with the view that owns it. This type holds only the
/// presentation of that state.
///
/// Deliberately NOT a `View`: it returns view trees into the host view's
/// body, so SwiftUI identity, animation and `@State` stay the host's; the
/// snapshot suite pins that.
@MainActor
struct RecordPanels {
    let collector: RRCollector
    let deviceStatus: DeviceStatus
    let morningCoordination: MorningCoordination
    let streamingLifecycle: StreamingLifecycle
    let sessionState: SessionState
    let settingsManager: SettingsManager

    let isActivelyRecording: Bool
    let isBatteryLow: Bool
    let isBatteryCritical: Bool

    let startOvernightRecording: () -> Void
    let startLinkedRecording: (HRVSession) -> Void
    let pauseRecording: () -> Void
    let resumeRecording: () -> Void
    let finalizeFromPause: () -> Void
    let stopAndFetch: () -> Void
    /// Ends the recording in progress without keeping it; `true` starts a
    /// new one straight after.
    let discardRecording: (_ startOver: Bool) -> Void
    let discardPausedNight: () -> Void
    let startStreaming: (Int) -> Void
    let stopStreaming: () -> Void

    @Binding var extendedCaptureMode: RecordView.ExtendedCaptureMode
    @Binding var selectedTags: Set<ReadingTag>
    @Binding var sessionNotes: String
    @Binding var fetchFailed: Bool
    @Binding var showingDiscardConfirm: Bool
    let isDiscarding: Bool

    let breathingAudio: BreathingAudioManager
}
