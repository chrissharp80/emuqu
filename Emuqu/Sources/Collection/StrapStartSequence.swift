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
/// The Verity path guards that by downloading and handing the data to the backup
/// *first*. Getting those two the wrong way round destroys exactly the data the
/// rescue exists to save, and buried in the collector nothing could catch it
/// (it ran at 0% coverage).
///
/// So the order is data here, and the invariant "a rescue precedes the clear it
/// protects" is a test rather than a comment.
///
/// ## The asymmetry between the two straps is deliberate
///
/// The H10 does **not** rescue before clearing, and this type preserves that.
/// It is a tradeoff, not an oversight: an H10 overnight exercise is a single
/// large file that takes minutes to download over BLE, and the rescue happens
/// inline on the workout-start path — the path this codebase instruments for
/// latency more than any other. Adding a multi-minute download before a user's
/// workout can begin would be its own defect.
///
/// The H10 is protected differently instead: `checkForStoredExercises` sets
/// `hasStoredExercise`, and `RecordView` surfaces a recovery affordance so the
/// user is told the data is there before they start something new. That is a
/// softer guarantee than the Verity's automatic rescue, and it is written down
/// here so the difference is a decision on the record rather than a discrepancy
/// someone finds later.
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
    static func steps(for deviceType: PolarDeviceType?) -> [Step] {
        switch deviceType {
        case .veritySense:
            // Offline PPI recordings are small — the rescue download is quick
            // enough to sit on the start path.
            return [.rescueExisting, .clearExisting, .beginRecording]
        case .h10, nil:
            // See the note above: the H10's file is too large to download
            // inline at workout start, and the user is warned instead.
            return [.clearExisting, .beginRecording]
        }
    }

    /// Whether a strap's sequence protects stored data before destroying it.
    ///
    /// False for the H10 by design; the value of stating it this way is that the
    /// test suite asserts *which* straps are unprotected, so adding a third one
    /// without a rescue is a decision someone has to make on purpose.
    static func rescuesBeforeClearing(_ deviceType: PolarDeviceType?) -> Bool {
        let sequence = steps(for: deviceType)
        guard let clearIndex = sequence.firstIndex(where: \.isDestructive) else { return true }
        guard let rescueIndex = sequence.firstIndex(where: \.isRescue) else { return false }
        return rescueIndex < clearIndex
    }
}
