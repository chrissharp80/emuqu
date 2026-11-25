import Foundation

/// What a whole-history load read: each archived session in the archive's
/// order, nil where its file could not be read or decoded. A screen that
/// charts the history uses it to tell a complete load from a partial one.
struct SessionLoad: Sendable {
    let ids: [UUID]
    let decoded: [HRVSession?]

    /// The sessions that were read, in order.
    var sessions: [HRVSession] { decoded.compactMap(\.self) }

    /// How many archived sessions could not be read.
    var unreadableCount: Int { decoded.count { $0 == nil } }

    /// This load with each unreadable session filled in from `earlier`, the
    /// copy the screen showed before, when it has one. A read that fails
    /// for a moment (the file locked while the phone is, a sync rewriting
    /// it) then keeps the session in the charts instead of dropping it.
    /// `missing` counts the sessions still left out.
    func fillingGaps(from earlier: [HRVSession]) -> (sessions: [HRVSession], missing: Int) {
        let previous = Dictionary(earlier.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var sessions: [HRVSession] = []
        var missing = 0
        for (id, session) in zip(ids, decoded) {
            if let found = session ?? previous[id] { sessions.append(found) } else { missing += 1 }
        }
        return (sessions, missing)
    }
}
