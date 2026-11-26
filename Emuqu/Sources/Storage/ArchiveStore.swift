import Foundation

/// The persistence mechanics behind the archive: writing a session to disk,
/// reading one back, maintaining the index, and the deleted-session tombstones
/// that stop a deleted night reappearing from a CloudKit pull.
///
/// ## Why this is not on `SessionArchive`
///
/// The split makes `SessionArchive` a facade over a store: the type callers
/// hold keeps the API (`entries`, `delete`, `exists`, `updateTags`) and this
/// owns how any of it reaches the filesystem. The encryption fallback, the
/// index rollback and the tombstones all live here, and none of them are the
/// archive's interface.
///
/// It is given the archive's index state (`ArchiveIndexState`: the directory,
/// the lock, the key, the merge settings and the in-memory index), not the
/// archive, so it depends on that small set and nothing else, and the archive
/// is not reachable from here.
struct ArchiveStore {
    let state: ArchiveIndexState

    /// A full read under the lock, counted for the read-health card
    /// (`ArchiveIndexState.countRead`). `SessionArchive.retrieve` is this.
    func retrieveCounted(_ id: UUID) throws -> HRVSession? {
        state.archiveLock.lock()
        defer { state.archiveLock.unlock() }
        do {
            let session = try _retrieve(id)
            state.countRead(failure: nil)
            return session
        } catch {
            state.countRead(failure: error)
            throw error
        }
    }
}
