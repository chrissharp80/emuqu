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
    // The collector's entire observable surface lives on five focused
    // observables — `ArchiveSignal`, `DeviceStatus`, `StreamingLifecycle`,
    // `MorningCoordination`, `SessionState`. `RRCollector` itself publishes
    // nothing; it is an orchestration shell that holds the sub-objects and
    // wires dependencies.
    //
    // ⚠️ DO NOT READ THESE FROM A SwiftUI VIEW.
    // The forwarders below are *plain computed properties*. Reading
    // `collector.isOvernightStreaming` from a view body does NOT establish
    // a Combine subscription to the sub-object that owns the value, so the
    // view will never re-render when the value changes (stale
    // recording-state UI). Each view that needs sub-object state declares
    // it explicitly:
    //
    //     @Environment(StreamingLifecycle.self) var streamingLifecycle
    //     ...
    //     if streamingLifecycle.isOvernightStreaming { ... }   // ✅ observed
    //     if collector.isOvernightStreaming { ... }            // ❌ stale
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
    var deviceRefinement: DeviceRefinement? {
        get { morningCoordination.deviceRefinement }
        set { morningCoordination.deviceRefinement = newValue }
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
