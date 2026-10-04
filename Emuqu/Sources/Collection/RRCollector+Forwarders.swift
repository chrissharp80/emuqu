import Combine
import Foundation

// `RRCollector`'s forwarders to its sub-objects, split out of
// `RRCollector.swift` to keep that class body under the 500-line
// limit. The collector's own state, dependencies and initialisation stay
// behind; these pass-throughs — which exist so call sites outside SwiftUI can
// reach the Polar manager, the recorder and the archive without holding them
// directly — live here.
//
// Only the file boundary changed.

extension RRCollector {
    // MARK: - Forwarders to sub-objects (NOT FOR SwiftUI VIEWS)
    //
    // The recording state views render lives on five focused observables:
    // `ArchiveSignal`, `DeviceStatus`, `StreamingLifecycle`,
    // `MorningCoordination`, `SessionState`. `RRCollector` is itself
    // `@Observable`, and its own stored `var`s (about fifteen, among them
    // `deviceFetchPolicy`, `useDeviceBackupForOvernight`,
    // `overnightDeviceBackupActive`, `sessionStartTime`, the training-load
    // caches and the reanalysis bookkeeping) are tracked like any other;
    // only the properties marked `@ObservationIgnored` are not. `RecordView`
    // reads a few of them directly.
    //
    // Views read sub-object state from the sub-object itself, so each view
    // names what it depends on:
    //
    //     @Environment(StreamingLifecycle.self) var streamingLifecycle
    //     ...
    //     if streamingLifecycle.isOvernightStreaming { ... }
    //
    // The forwarders below are plain computed properties. Observation still
    // tracks a read made through one, because it reads the sub-object's
    // observable property, but the dependency is then hidden behind the
    // collector.
    //
    // The forwarders exist purely so non-view callers (extensions on
    // RRCollector, tests, the orchestration code in this file) can keep
    // writing `self.isOvernightStreaming = true` without sprinkling
    // sub-object names everywhere. A setter writes through to the
    // sub-object's own observable storage, so views observing that
    // sub-object see writes made through these forwarders.
    var recordingPhase: RecordingPhase {
        get { sessionState.recordingPhase }
        set { sessionState.recordingPhase = newValue }
    }
    var isCollecting: Bool {
        get { sessionState.isCollecting }
        set { sessionState.isCollecting = newValue }
    }
    var currentSession: HRVSession? {
        get { sessionState.currentSession }
        set { sessionState.currentSession = newValue }
    }
    var collectedPoints: [RRPoint] {
        get { sessionState.collectedPoints }
        set { sessionState.collectedPoints = newValue }
    }
    var lastError: Error? {
        get { sessionState.lastError }
        set { sessionState.lastError = newValue }
    }
    var verificationResult: Verification.Result? {
        get { sessionState.verificationResult }
        set { sessionState.verificationResult = newValue }
    }
    var recoveryWindow: WindowSelector.RecoveryWindow? {
        get { sessionState.recoveryWindow }
        set { sessionState.recoveryWindow = newValue }
    }
    var needsAcceptance: Bool {
        get { sessionState.needsAcceptance }
        set { sessionState.needsAcceptance = newValue }
    }
    var baselineDeviation: BaselineTracker.BaselineDeviation? {
        get { sessionState.baselineDeviation }
        set { sessionState.baselineDeviation = newValue }
    }

    // Streaming + pause/resume state moved to `StreamingLifecycle`. Views
    // that only care about recording mode / elapsed time / pause state
    // now observe that object directly; extension-site writers go through
    // these back-compat forwarding properties so the orchestration code
    // doesn't all have to change at once.
    var isStreamingMode: Bool {
        get { streamingLifecycle.isStreamingMode }
        set { streamingLifecycle.isStreamingMode = newValue }
    }
    var streamingTargetSeconds: Int {
        get { streamingLifecycle.streamingTargetSeconds }
        set { streamingLifecycle.streamingTargetSeconds = newValue }
    }
    var streamingElapsedSeconds: Int {
        get { streamingLifecycle.streamingElapsedSeconds }
        set { streamingLifecycle.streamingElapsedSeconds = newValue }
    }
    var isOvernightStreaming: Bool {
        get { streamingLifecycle.isOvernightStreaming }
        set { streamingLifecycle.isOvernightStreaming = newValue }
    }
    var isPaused: Bool {
        get { streamingLifecycle.isPaused }
        set { streamingLifecycle.isPaused = newValue }
    }
    var pausedSession: HRVSession? {
        get { streamingLifecycle.pausedSession }
        set { streamingLifecycle.pausedSession = newValue }
    }
    var pausedBeatCount: Int {
        get { streamingLifecycle.pausedBeatCount }
        set { streamingLifecycle.pausedBeatCount = newValue }
    }

    // Morning-processing progress / device refinement / sleep-data signal
    // live on `MorningCoordination`. RecordView / MorningResultsView /
    // RecoveryDashboardView can observe that object directly; readers and
    // writers that still go through the collector use these forwarding
    // properties.
    var morningStatus: MorningProcessingStatus? {
        get { morningCoordination.morningStatus }
        set { morningCoordination.morningStatus = newValue }
    }
    var isDeviceFetchInProgress: Bool {
        get { morningCoordination.isDeviceFetchInProgress }
        set { morningCoordination.isDeviceFetchInProgress = newValue }
    }
    var sleepDataVersion: Int {
        get { morningCoordination.sleepDataVersion }
        set { morningCoordination.sleepDataVersion = newValue }
    }

    /// Controls whether morning processing attempts to fetch internal device data.
    enum DeviceFetchPolicy {
        /// Attempt to fetch internal recording from H10 (default)
        case automatic
        /// Skip device fetch — user requested streaming-only analysis
        case skipByUser
    }
}
