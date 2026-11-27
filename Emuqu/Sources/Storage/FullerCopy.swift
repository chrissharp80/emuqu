import Foundation

/// The one rule every keep, replace, retire or discard decision between two
/// copies of one recording follows: a copy may be dropped, or written over,
/// only when the copy that stays holds at least as many beats.
///
/// Which copy is newer, already held here, already archived, or uploaded by
/// this device does not decide it. Any of those can be the fragment: a live
/// backup pulled early in another device's night, a night recovered from that
/// pull, an edit made on a device that never saw a later fold. Deciding by
/// them dropped the fuller copy and kept the fragment.
///
/// Used by the raw backup writes (`RawRRBackup.backup`, the streaming format
/// switch, `OneShotBackupName.isSuperseded`), the iCloud live-backup scan
/// (`SessionRecoveryService.cloudBackupDisposition`), recovery over an
/// archived copy (`SessionRecoveryService.archivedCopyHoldingMore`) and the
/// session sync (`CloudKitSessionFreshness.keepingBeatsOnlyHere`).
enum FullerCopy {
    /// Whether the copy that stays, holding `kept` beats, covers one holding
    /// `dropped`. A count that is not known (a copy that could not be read)
    /// covers nothing.
    static func covers(_ kept: Int?, _ dropped: Int) -> Bool {
        guard let kept else { return false }
        return kept >= dropped
    }
}
