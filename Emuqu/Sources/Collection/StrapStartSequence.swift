import Foundation

/// The order of operations when starting a recording on the strap's own memory.
///
/// ## Why this is a type and not three lines inside an async function
///
/// Both straps clear whatever is already stored before starting — the H10
/// refuses to start otherwise (error 106), and a Verity would otherwise
/// accumulate. Clearing is destructive: it deletes a recording the user may
/// never have downloaded, which after a crash or a session started on the device
/// itself is a whole night.
///
/// Both straps guard that by downloading what the app does not already hold
/// and handing it to the backup *first*. Getting those two the wrong way round
/// destroys exactly the data the rescue exists to save, and buried in the
/// collector nothing could catch it (it ran at 0% coverage).
///
/// So the order is data here, and the invariant "a rescue precedes the clear it
/// protects" is a test rather than a comment.
///
/// ## The H10 rescues too, now that it can tell what needs rescuing
///
/// The H10 used to clear without rescuing: its file can take minutes to
/// download, the start ran inline on the workout-start path, and nothing could
/// say whether the stored file had already been downloaded, so a rescue would
/// have meant a full download on every start. All three have changed. Arming is
/// off the critical path (workouts and nights arm in the background), and
/// `StrapDownloadLedger` records every download, so the rescue downloads only
/// what the app does not hold — normally nothing. A file that cannot be
/// downloaded stops the start instead of being deleted with it.
///
/// The two straps still differ in what a failed rescue means. A Verity Sense
/// starts beside the recording it kept; the H10 refuses to start while it
/// holds one (error 106), so it does not start.
enum StrapStartSequence {
    /// One step in bringing up a recording on the strap.
    enum Step: Equatable {
        /// Download anything already stored and hand it to the backup.
        case rescueExisting
        /// Delete what is stored so the strap will accept a new recording.
        case clearExisting
        /// Begin recording.
        case beginRecording

        /// Whether this step destroys data on the strap.
        var isDestructive: Bool { self == .clearExisting }
        /// Whether this step preserves data before something destroys it.
        var isRescue: Bool { self == .rescueExisting }
    }

    /// The steps for a strap, in order.
    /// The same for every strap: the rescue downloads only what the download
    /// record says the app lacks, so it costs nothing when everything is saved.
    static func steps(for deviceType: PolarDeviceType?) -> [Step] {
        [.rescueExisting, .clearExisting, .beginRecording]
    }

    /// Whether a strap's sequence protects stored data before destroying it.
    /// Stated this way so the test suite asserts that every strap is
    /// protected, and adding one without a rescue is a decision someone has
    /// to make on purpose.
    static func rescuesBeforeClearing(_ deviceType: PolarDeviceType?) -> Bool {
        let sequence = steps(for: deviceType)
        guard let clearIndex = sequence.firstIndex(where: \.isDestructive) else { return true }
        guard let rescueIndex = sequence.firstIndex(where: \.isRescue) else { return false }
        return rescueIndex < clearIndex
    }
}
