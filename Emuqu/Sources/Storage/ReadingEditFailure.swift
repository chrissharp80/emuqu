import Foundation

/// Whether a failed archive write of the user's own edit on a reading (its
/// tags and notes, its morning feeling) must be shown to the user.
///
/// Two failures lose nothing. A reading still awaiting acceptance is archived
/// from the in-memory copy, which already holds the edit, so a write to a copy
/// not stored yet is not a loss. A reading the archive does not hold (not
/// saved yet, or discarded or deleted meanwhile) has nothing left to edit.
/// Any other failure leaves the edit on screen but not stored: the next open
/// shows the reading without it, so the user is told and can make it again.
enum ReadingEditFailure {
    static func mustReport(_ error: Error, acceptanceSavesEdit: Bool) -> Bool {
        guard !acceptanceSavesEdit else { return false }
        switch error as? SessionArchive.ArchiveError {
        case .fileNotFound?, .sessionWasDeleted?:
            return false
        default:
            return true
        }
    }
}
