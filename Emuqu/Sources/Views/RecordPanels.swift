import SwiftUI

/// The record-tab panels: device status, capture-mode selection, the recording
/// controls, and the battery and fetch-failure banners.
///
/// Split out of `RecordView` — 923 lines out of a 2,757-line view.
///
/// The recording actions arrive as closures rather than being moved: they
/// drive the session lifecycle and belong with the view that owns it. What
/// moves here is the presentation of that state.
///
/// Deliberately NOT a `View`. It returns the same view trees from the same
/// positions, so SwiftUI identity, animation and `@State` behaviour are
/// unchanged; the snapshot suite pins that.
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
    let startStreaming: (Int) -> Void
    let stopStreaming: () -> Void

    @Binding var extendedCaptureMode: RecordView.ExtendedCaptureMode
    @Binding var selectedTags: Set<ReadingTag>
    @Binding var sessionNotes: String
    @Binding var fetchFailed: Bool

    let breathingAudio: BreathingAudioManager
}
