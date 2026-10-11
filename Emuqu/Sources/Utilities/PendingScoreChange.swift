import Foundation

/// One pending "your score changed while the app was away" notice.
///
/// Written when the auto-rescore listener finishes a recompute and the score
/// moved meaningfully (≥ 3 points). The dashboard reads this on appear and
/// surfaces a one-tap banner so the user understands why the number on
/// screen differs from what they last saw — e.g. Apple Watch finally synced
/// the rest of the night's sleep, the score climbed 67 → 74, the dashboard
/// shows 74 without the banner this would feel arbitrary.
///
/// Single-slot (latest wins) by design: if multiple rescores happen between
/// foregrounds, the most recent delta is what's surfaced; intermediate ones
/// would just be noise.
///
/// The notice explains a change the user is about to see, so it expires:
/// `read` drops an entry older than `maxAge`, or one for a session other than
/// the one the caller is showing, instead of carrying an old night's delta
/// into later days.
enum PendingScoreChange {
    struct Entry: Codable {
        let sessionId: UUID
        let priorScore: Double
        let newScore: Double
        let reason: String // "sleep", "training", etc.
        let timestamp: Date
    }

    private static let key = "PendingScoreChange.v1"

    /// How long a notice stays relevant. Rescores land within hours of the
    /// morning they belong to; half a day keeps a notice through that morning
    /// and drops it before the next night's report.
    static let maxAge: TimeInterval = 12 * 60 * 60

    /// Stores the entry and, only when it was stored, tells on-screen views,
    /// so a live banner never shows a notice a later `read` cannot return.
    static func write(_ entry: Entry) {
        guard let data = attempt("pendingScoreChange.encode", { try JSONEncoder().encode(entry) }) else { return }
        UserDefaults.standard.set(data, forKey: key)
        NotificationCenter.default.post(name: .pendingScoreChangeWritten, object: entry)
    }

    /// The stored notice if it is no older than `maxAge`; an older one is
    /// cleared and not returned. No session check — see
    /// `read(currentSessionId:now:)`.
    static func read() -> Entry? {
        read(currentSessionId: nil)
    }

    /// The stored notice if it is still current. An entry older than `maxAge`
    /// at `now`, or for a session other than `currentSessionId` (when one is
    /// given), is cleared and not returned.
    static func read(currentSessionId: UUID?, now: Date = Date()) -> Entry? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        guard let entry = attempt("pendingScoreChange.decode", { try JSONDecoder().decode(Entry.self, from: data) }),
              isCurrent(entry, currentSessionId: currentSessionId, now: now) else {
            clear()
            return nil
        }
        return entry
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func isCurrent(_ entry: Entry, currentSessionId: UUID?, now: Date) -> Bool {
        if let currentSessionId, currentSessionId != entry.sessionId { return false }
        let age = now.timeIntervalSince(entry.timestamp)
        return age >= 0 && age <= maxAge
    }
}

extension Notification.Name {
    /// Posted by `PendingScoreChange.write` so views that are already on
    /// screen (dashboard, etc.) can surface the banner without waiting for
    /// the next `.onAppear`.
    static let pendingScoreChangeWritten = Notification.Name("FlowRecoveryPendingScoreChangeWritten")
}
