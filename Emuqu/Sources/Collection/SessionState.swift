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
/// together and holds dependencies. What it still observes itself is the
/// recording's control state (capture choice, device-fetch policy, the
/// overnight backup and ending flags, the cached training load); the
/// session and its analysis live here.
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

    /// The night saved to the archive before the user reviewed it (the
    /// crash-safety pre-archive, or a paused night finalized for review).
    /// "Discard" trashes this id; nil when the reviewed session was already
    /// in the archive before this review began.
    var reviewArchivedSessionId: UUID?

    /// The night already in the archive that this review's recording was
    /// folded into when it was saved, a second recording of the same night.
    /// The fold cannot be undone, so "Discard" leaves that night as it is and
    /// says so; nil when the recording was saved under its own id.
    var reviewFoldedIntoSessionId: UUID?

    /// Forget which archived night this review saved or was folded into, so
    /// Discard no longer points at it.
    func forgetReviewedNight() {
        reviewArchivedSessionId = nil
        reviewFoldedIntoSessionId = nil
    }

    /// The user's own entries on a session, as one value to compare.
    struct ReviewEntries: Equatable {
        let sessionId: UUID
        let tags: [ReadingTag]
        let notes: String?
        let morningFeeling: Int?

        init(of session: HRVSession) {
            sessionId = session.id
            tags = session.tags
            notes = session.notes
            morningFeeling = session.morningFeeling
        }
    }

    /// The tags, notes and feeling the archive held for the reviewed night
    /// when the card last matched it: when the review saved the night, and
    /// each time a rescore was carried onto the card. An entry on the card
    /// that differs from these was made on the card and wins over the
    /// archive's; one that matches gives way to an edit made elsewhere.
    var reviewArchivedEntries: ReviewEntries?

    /// Cached result of `findRecentPausedSession()` — surfaces the resume
    /// banner. Refreshed on every archive signal bump.
    var recentPausedSession: HRVSession?
}
