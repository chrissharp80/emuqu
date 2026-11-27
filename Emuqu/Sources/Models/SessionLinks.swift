import Foundation

/// What a session's `linkedSessionIds` say, read in one place.
///
/// A link from one session to another says the linked recording's beats are
/// inside the linking session: a resumed segment holds its paused parent's
/// beats, and a night that superseded same-night recordings holds theirs.
/// Resume writes its link both ways, so there is one exception: the paused
/// parent lists the segment resumed from it, and that link is a reference
/// back, not a holding. The segment names the parent first and runs on
/// after the parent stopped; the parent holds none of its beats.
///
/// Every reader that asks which recording holds which, or which session a
/// segment was resumed from, asks here: read as a holding, the parent's
/// back-reference makes a resumed night's own final session look absorbed,
/// so a recording of that night finds nothing to merge into.
enum SessionLinks {
    /// One recording as the links see it: its id, its links in order, and
    /// when it stopped.
    struct Node: Sendable {
        let id: UUID
        let links: [UUID]
        let end: Date

        nonisolated init(id: UUID, links: [UUID]?, end: Date) {
            self.id = id
            self.links = links ?? []
            self.end = end
        }

        nonisolated init(_ entry: SessionArchiveEntry) {
            self.init(id: entry.sessionId, links: entry.linkedSessionIds, end: entry.endDate ?? entry.date)
        }

        nonisolated init(_ session: HRVSession) {
            self.init(id: session.id, links: session.linkedSessionIds, end: session.endDate ?? session.startDate)
        }
    }

    /// Whether `parent` is the session `child` was resumed from: the parent
    /// lists the child, the child names the parent as its first link, and
    /// the child ran on after the parent stopped.
    nonisolated static func isResumeParent(_ parent: Node, of child: Node) -> Bool {
        child.links.first == parent.id && listsEarlierSegment(parent, childId: child.id, childEnd: child.end)
    }

    /// `isResumeParent` for a child whose own links are not known (a backup
    /// with no archive entry): only a resume parent lists a recording that
    /// was never archived, and it stopped before that recording did.
    nonisolated static func isResumeParent(_ parent: Node, ofUnarchived childId: UUID, childEnd: Date) -> Bool {
        listsEarlierSegment(parent, childId: childId, childEnd: childEnd)
    }

    nonisolated private static func listsEarlierSegment(_ parent: Node, childId: UUID, childEnd: Date) -> Bool {
        parent.links.contains(childId) && childEnd > parent.end
    }

    /// Whether `holder`'s link to `linkedId` says it holds that recording's
    /// beats: every link does except a resume parent's to its own segment.
    /// A linked recording missing from `byId` (deleted, or not yet archived)
    /// counts as held.
    nonisolated static func holds(_ holder: Node, _ linkedId: UUID, byId: [UUID: Node]) -> Bool {
        guard let linked = byId[linkedId] else { return true }
        return !isResumeParent(holder, of: linked)
    }

    /// The recordings among `nodes` whose beats another of them holds. A
    /// resumed night's final session is not among them: its parent only
    /// refers back to it.
    nonisolated static func absorbedIds(in nodes: [Node]) -> Set<UUID> {
        let byId = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(nodes.flatMap { holder in holder.links.filter { holds(holder, $0, byId: byId) } })
    }

    /// `absorbedIds` over archive index entries.
    nonisolated static func absorbedIds(in entries: [SessionArchiveEntry]) -> Set<UUID> {
        absorbedIds(in: entries.map(Node.init))
    }
}
