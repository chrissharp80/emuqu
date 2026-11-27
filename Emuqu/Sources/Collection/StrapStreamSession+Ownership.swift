import Foundation

// MARK: - Whose stream it is

/// The strap has one stream, one buffer and one link, shared by every session
/// that records from it: an overnight, a quick reading, a workout, and the
/// workout's heart-rate recovery after its Stop. A session names its own
/// stream by the `streamingStartTime` it was started at, and acts on the
/// stream, its buffer or the link only by these rules, so it never stops,
/// reads or releases what a session started since owns.
extension StrapStreamSession {
    /// The live stream is the one started at `start`. False with no start: a
    /// session that never streamed owns no stream.
    func isBuffering(startedAt start: Date?) -> Bool {
        guard isStreaming, let start else { return false }
        return streamingStartTime == start
    }

    /// A session other than the one whose stream started at `ownStart` is
    /// buffering now.
    func isBufferingForAnotherSession(than ownStart: Date?) -> Bool {
        isStreaming && !isBuffering(startedAt: ownStart)
    }

    /// Whether a session done with the strap may let go of its link: no other
    /// session buffers on it, no transfer is taking a recording off it, and it
    /// is not recording to its own memory (a strap-only recording, or a
    /// recording whose stop was never confirmed, still needs the link to be
    /// stopped or read). `ownStart` is the session's own stream, which it
    /// stops before letting go.
    func mayReleaseLink(after ownStart: Date?, recording: StrapRecordingState) -> Bool {
        !isBufferingForAnotherSession(than: ownStart)
            && recording.transfersInFlight == 0
            && !recording.isRecordingOnDevice
    }
}
