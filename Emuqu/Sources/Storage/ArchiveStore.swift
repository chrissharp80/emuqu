import Foundation

/// The persistence mechanics behind the archive: writing a session to disk,
/// reading one back, maintaining the index, and the deleted-session tombstones
/// that stop a deleted night reappearing from a CloudKit pull.
///
/// ## Why this is not on `SessionArchive`
///
/// As an 887-line extension it would be. The split makes `SessionArchive` a facade over a store: the type callers
/// hold keeps the API — `entries`, `delete`, `exists`, `updateTags` — and this
/// owns how any of it reaches the filesystem. That is a boundary worth having
/// on its own terms, not just for the line count: the encryption fallback, the
/// index rollback and the tombstones all live here, and none of them are the
/// archive's interface.
///
/// The coupling was measured before the move: 25 members of the archive, mostly
/// the lock, the index and the directory URLs.
struct ArchiveStore {
    let archive: SessionArchive

}
