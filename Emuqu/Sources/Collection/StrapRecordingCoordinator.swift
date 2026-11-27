import Foundation
#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

/// Everything the app does with a recording held in the strap's own memory:
/// starting and stopping one, asking whether one is running, listing what is
/// stored, downloading it, and the retry/reconnect dance the SDK needs for a
/// large transfer.
///
/// `PolarManager` stays the BLE link itself — discovery, connection, the
/// observers, and the live stream.
///
/// Recording-to-device is a different job from streaming-to-phone. It runs on a
/// different SDK feature set, it fails in different ways (a file that will not
/// finalize, a transfer that times out at 20 MB), and it is the path that holds
/// a user's night hostage until the download succeeds.
///
/// Three files: `+Recording` starts recordings and reads the strap's status
/// and storage, `StrapRecordingCoordinator+Transfer` is the one way a
/// recording comes off the strap (stop, download, retry/reconnect, deadlines,
/// Cancel), and `+VeritySense` handles the optical variant.
///
/// A value built on demand by the manager. It holds the link (to wait on it
/// and read which strap is linked), the strap's recording state, and
/// discovery (to bring the strap back for a transfer); it stores nothing of
/// its own.
@MainActor
struct StrapRecordingCoordinator {
    let link: StrapLinkControl
    let device: StrapRecordingState
    let discovery: StrapDiscoveryCoordinator

    /// The linked strap, its connection and the readings it reports.
    var linkState: StrapLinkState { link.state }

    #if canImport(PolarBleSdk)
        var strapAPI: (any StrapRadio)? { link.radio.strapAPI }
    #endif
}

/// What the strap's own memory is doing as far as the app knows, and the
/// bookkeeping around taking a recording off it. One per `PolarManager`, which
/// views observe it through.
@Observable
@MainActor
final class StrapRecordingState {
    var recordingState: PolarManager.RecordingState = .idle
    var isRecordingOnDevice: Bool = false
    var hasStoredExercise: Bool = false // True if H10 has stored data that can be recovered
    var storedExerciseDate: Date? // Date of stored exercise on H10 (for archive comparison)
    var fetchProgress: PolarManager.FetchProgress? // Non-nil during fetch operations

    // Fetch cancellation
    var fetchCancelled = false
    /// The strap transfer phase running now, so Cancel can end it.
    @ObservationIgnored var activeTransfer: StrapTransferHandle?
    /// Downloads and reconnects running now. Arming never starts while one
    /// is: it would stop, clear or start the strap under the transfer.
    @ObservationIgnored var transfersInFlight = 0
    /// Whether the app already holds a strap recording that began at the
    /// given time (`StrapRecordingPolicy.recordingIsSaved`). Set by
    /// RRCollector, which also knows the archive; without it, only a
    /// download on record counts.
    @ObservationIgnored var savedRecordingCheck: ((Date) -> Bool)?
    /// The strap recordings already downloaded; see `StrapDownloadLedger`.
    @ObservationIgnored var downloadLedger = StrapDownloadLedger()

    /// Called when a recording left on the strap is downloaded so the strap
    /// can be cleared or reused, or when a download turns out not to belong
    /// to the session that asked for it. RRCollector backs it up via
    /// RawRRBackup, dated by the recording's own start, and returns whether
    /// the backup is on disk.
    var onUnrecoveredDataRescued: ((StrapRecording) -> Bool)?

    /// Whether a stored strap recording that began at `start` may be cleared.
    func isRecordingSaved(startedAt start: Date) -> Bool {
        savedRecordingCheck?(start) ?? downloadLedger.wasSaved(recordingStartedAt: start)
    }

    /// Backs `recording` up through `onUnrecoveredDataRescued`. False when
    /// the backup failed or nothing is set to take it: the strap then still
    /// holds the only copy, and must not be cleared. A backup on disk puts
    /// the recording on the saved record.
    func rescueToBackup(_ recording: StrapRecording) -> Bool {
        guard onUnrecoveredDataRescued?(recording) ?? false else { return false }
        noteSaved(recording)
        return true
    }

    /// `recording`'s beats are on disk, in a backup or an archived session,
    /// so the strap's copy of it may be cleared (`StrapDownloadLedger`).
    func noteSaved(_ recording: StrapRecording) {
        guard let start = recording.startedAt else { return }
        downloadLedger.markSaved(recordingStartedAt: start)
    }

    /// The beats of the recording a session downloaded for itself, one that
    /// began at or after the session's `start`, are on disk.
    func noteDownloadsSaved(recordedSince start: Date) {
        downloadLedger.markDownloadsSaved(recordedSince: start)
    }

    /// Helper to update fetch progress on main thread
    func updateProgress(
        _ stage: PolarManager.FetchProgress.Stage, progress: Double,
        attempt: Int = 1, maxAttempts: Int = 5, message: String = ""
    ) async {
        await MainActor.run {
            fetchProgress = PolarManager.FetchProgress(
                stage: stage,
                progress: progress,
                attempt: attempt,
                maxAttempts: maxAttempts,
                statusMessage: message
            )
        }
    }
}
