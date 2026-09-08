import Foundation
import Observation

/// Published core session state for the active recording and its analysis.
///
/// Final slice extracted from `RRCollector` — covers the recording
/// state-machine, the active session + its RR samples, error surface,
/// analysis outcome (verification, recovery window, baseline deviation),
/// and the paused-session recovery cache.
///
/// `RRCollector` is the orchestration shell that wires sub-objects
/// together and holds dependencies; it publishes no state of its own.
///
/// Writers: RRCollector's extension files (lifecycle, streaming,
/// overnight, acceptance, recovery, analysis). The collector exposes
/// back-compat forwarding properties so extension code migrates
/// incrementally.
@MainActor
@Observable
final class SessionState {
    /// Explicit state machine for the recording lifecycle.
    var recordingPhase: RecordingPhase = .idle

    /// True while beats are actively being collected (streaming or device).
    var isCollecting: Bool = false

    /// The session currently being recorded / analyzed / awaiting acceptance.
    var currentSession: HRVSession?

    /// RR samples captured for the active session.
    var collectedPoints: [RRPoint] = []

    /// Last error surfaced from a recording / acceptance / analysis path.
    var lastError: Error?

    /// Quality verification verdict for the current session, if computed.
    var verificationResult: Verification.Result?

    /// Selected recovery window for the current session, if analyzed.
    var recoveryWindow: WindowSelector.RecoveryWindow?

    /// UI gate — true when the user must review the session before accept.
    var needsAcceptance: Bool = false

    /// Baseline-deviation summary for the current session, if computed.
    var baselineDeviation: BaselineTracker.BaselineDeviation?

    /// Cached result of `findRecentPausedSession()` — surfaces the resume
    /// banner. Refreshed on every archive signal bump.
    var recentPausedSession: HRVSession?
}
