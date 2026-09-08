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
enum PendingScoreChange {
    struct Entry: Codable {
        let sessionId: UUID
        let priorScore: Double
        let newScore: Double
        let reason: String // "sleep", "training", etc.
        let timestamp: Date
    }

    private static let key = "PendingScoreChange.v1"

    static func write(_ entry: Entry) {
        if let data = attempt("pendingScoreChange.encode", { try JSONEncoder().encode(entry) }) {
            UserDefaults.standard.set(data, forKey: key)
        }
        NotificationCenter.default.post(name: .pendingScoreChangeWritten, object: entry)
    }

    static func read() -> Entry? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

extension Notification.Name {
    /// Posted by `PendingScoreChange.write` so views that are already on
    /// screen (dashboard, etc.) can surface the banner without waiting for
    /// the next `.onAppear`.
    static let pendingScoreChangeWritten = Notification.Name("FlowRecoveryPendingScoreChangeWritten")
}
