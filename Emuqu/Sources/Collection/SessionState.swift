import Foundation
import Observation

/// Published core session state for the active recording and its analysis.
///
/// Covers the recording
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
/// overnight, acceptance, recovery, analysis), mostly through the
/// collector's forwarding properties.
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

    /// The holds on the recorder taken by work that spans suspensions and
    /// writes this state when it resumes (`RecorderClaim`).
    private(set) var recorderClaims: [RecorderClaim] = []

    @ObservationIgnored private var recorderClaimsMade = 0
}

// MARK: - Recorder claims

extension SessionState {
    /// One caller's hold on the recorder while its work runs across
    /// suspensions: a strap recording's start, a stop's download and
    /// analysis, a review's acceptance, a discard, a crash recovery to the
    /// pause. Each publishes into `currentSession` and the phase, or clears
    /// them, when it resumes, so a recording started meanwhile would be the
    /// one it overwrote. While a claim is held no recording starts
    /// (`blocksStart`); several callers may hold one each.
    struct RecorderClaim: Equatable {
        fileprivate let number: Int
        /// When the caller took the claim.
        let claimedAt: Date
    }

    /// How old a claim must be before a start may take it as left behind.
    /// Every step under a claim is bounded (the strap budgets, the Health
    /// timeouts, the analysis); half an hour also covers work the system
    /// suspended briefly in the background, as for a night's ending
    /// (`StreamingLifecycle.staleEndingClaimAge`).
    static let staleRecorderClaimAge: TimeInterval = 30 * 60

    /// Takes a claim for the caller, which releases it when its work is done.
    func claimRecorder(now: Date = Date()) -> RecorderClaim {
        recorderClaimsMade += 1
        let claim = RecorderClaim(number: recorderClaimsMade, claimedAt: now)
        recorderClaims.append(claim)
        return claim
    }

    /// The caller's work is over. Only its own claim goes.
    func releaseRecorder(_ claim: RecorderClaim) {
        recorderClaims.removeAll { $0 == claim }
    }

    /// Whether a claim younger than `staleRecorderClaimAge` is held, so a
    /// recording must not start. An older one belongs to a caller that never
    /// returned and no longer blocks; that caller still checks
    /// `recorderTaken(since:)` before it writes.
    func blocksStart(now: Date = Date()) -> Bool {
        recorderClaims.contains { now.timeIntervalSince($0.claimedAt) < Self.staleRecorderClaimAge }
    }

    /// No recording starts while work that resumes into the session state
    /// holds the recorder (`blocksStart`): a stop's analysis, a review's
    /// acceptance, a discard or a crash recovery would publish over the new
    /// recording, or clear it. Throws `alreadyRecording`; `what` names the
    /// start in the log.
    func refuseStartWhileClaimed(starting what: String) throws {
        guard blocksStart() else { return }
        debugLog("[RRCollector] Not starting \(what): an earlier session's work still holds the recorder", level: .warning)
        throw RRCollector.CollectorError.alreadyRecording
    }

    /// Whether a session other than `before`, the one a caller found on the
    /// recorder before it suspended (nil for none), is on it now. Work that
    /// resumes writes or clears the session state only when it is not: a
    /// recording that took the recorder meanwhile keeps it. No session at all
    /// has taken nothing.
    func recorderTaken(since before: UUID?) -> Bool {
        guard let current = currentSession else { return false }
        return current.id != before
    }
}
