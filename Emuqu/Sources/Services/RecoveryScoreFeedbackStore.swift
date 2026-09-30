import Foundation

/// Daily user feedback on recovery-score accuracy.
///
/// **Why this exists.** The recovery score's weights (HRV 60% / Sleep 25% /
/// Vitals 15%) are calibrated against published practitioner heuristics
/// (Plews 2013, Buchheit 2014, Altini's HRV4Training methodology) — not
/// validated against outcomes. There is no ground-truth recovery score
/// anywhere in the literature, only expert judgment about what message
/// the user should be told. The honest way to tighten that calibration
/// over time is to ask the user, daily, whether the score matched how
/// they actually felt — and learn from the aggregate.
///
/// **What it captures.** One tap per day on a thumbs-up / thumbs-down /
/// dismiss control on the dashboard. Stores `{date, score, sentiment,
/// tier}` per entry. Local-only on device. Used internally for analysis;
/// no telemetry leaves the phone.
///
/// **Privacy.** No PHI is exfiltrated. The feedback log is a small JSON
/// file in the App Group container alongside other app state. The user
/// can wipe it via Settings → Diagnostics → Clear local feedback log.
///
/// **Not used to retrain weights automatically.** Adjusting score weights
/// based on user feedback would be a self-fulfilling prophecy — the user
/// who consistently rates high-score-bad-day will pull the score down
/// even when the algorithm is correct. The log is for the developer to
/// inspect periodically and decide whether a class of failure is
/// surfacing.
@Observable
@MainActor
final class RecoveryScoreFeedbackStore {
    static let shared = RecoveryScoreFeedbackStore()

    enum Sentiment: String, Codable {
        case matched     // thumbs up
        case mismatched  // thumbs down
    }

    struct Entry: Codable, Identifiable {
        let id: UUID
        /// Local calendar date (start-of-day) the feedback applies to.
        let date: Date
        /// Score the user was rating. 0–100.
        let recoveryScore: Double
        /// Tier (1, 2, 3) the score was computed under.
        let tier: Int
        /// Whether the user said the score matched their felt experience.
        let sentiment: Sentiment
        /// Comeback-mode active when the score was computed (so a future
        /// review can separate comeback-window feedback from standard).
        let comebackModeActive: Bool

        init(
            id: UUID = UUID(),
            date: Date,
            recoveryScore: Double,
            tier: Int,
            sentiment: Sentiment,
            comebackModeActive: Bool
        ) {
            self.id = id
            self.date = date
            self.recoveryScore = recoveryScore
            self.tier = tier
            self.sentiment = sentiment
            self.comebackModeActive = comebackModeActive
        }
    }

    private(set) var entries: [Entry]

    private let fileURL: URL

    /// Written with complete protection, so unreadable while the phone is
    /// locked. A store created in that state started empty, and its first write
    /// replaced every rating already given. Until the disk has been read, a
    /// write folds it back in, and waits while it still cannot be read.
    private var unreadableOnDisk: Bool

    private init() {
        let url = Self.storeURL()
        let loaded = Self.loadEntries(from: url)
        fileURL = url
        entries = loaded
        unreadableOnDisk = FileManager.default.fileExists(atPath: url.path)
            && loaded.isEmpty
            && attempt("RecoveryScoreFeedbackStore.probe", { try Data(contentsOf: url) }) == nil
    }

    /// App Group first so the data survives a reinstall of a sibling target,
    /// then Documents, then tmp — each fallback only on the previous failing.
    private static func storeURL() -> URL {
        let fm = FileManager.default
        let baseURL: URL = {
            if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier) {
                return group.appendingPathComponent("Feedback", isDirectory: true)
            }
            if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                return docs.appendingPathComponent("Feedback", isDirectory: true)
            }
            return fm.temporaryDirectory.appendingPathComponent("Feedback", isDirectory: true)
        }()
        _ = attempt("RecoveryScoreFeedbackStore.create") { try fm.createDirectory(at: baseURL, withIntermediateDirectories: true) }
        return baseURL.appendingPathComponent("recovery_score_feedback.json")
    }

    /// A missing file is normal. A file that exists and does not decode is
    /// feedback the user actually gave about their scores being dropped, along
    /// with whatever calibration it was feeding — so that case is logged.
    private static func loadEntries(from url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([Entry].self, from: data)
        } catch {
            debugLog("[RecoveryScoreFeedback] store present but failed to decode: \(error)", level: .error)
            return []
        }
    }

    /// True when the user has already rated today's score (any sentiment).
    /// The dashboard hides the prompt when true so we don't pester them.
    func hasFeedbackForToday() -> Bool {
        let today = Calendar.current.startOfDay(for: Date())
        return entries.contains { Calendar.current.isDate($0.date, inSameDayAs: today) }
    }

    /// Record a feedback entry for today. If a previous entry exists for
    /// today (e.g. user changed their mind), it is replaced so we keep
    /// at most one per day per device.
    func recordFeedback(
        sentiment: Sentiment,
        recoveryScore: Double,
        tier: Int,
        comebackModeActive: Bool
    ) {
        let today = Calendar.current.startOfDay(for: Date())
        entries.removeAll { Calendar.current.isDate($0.date, inSameDayAs: today) }
        entries.append(Entry(
            date: today,
            recoveryScore: recoveryScore,
            tier: tier,
            sentiment: sentiment,
            comebackModeActive: comebackModeActive
        ))
        persist()
    }

    /// Clear all feedback entries (Settings → Diagnostics).
    func clearAll() {
        entries = []
        unreadableOnDisk = false
        persist()
    }

    /// Aggregate stats over the last `days` (default 90) for inspection.
    /// Returns a compact summary tuple — not displayed in the consumer UI.
    func recentSummary(days: Int = 90) -> (total: Int, matched: Int, mismatched: Int)? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        let recent = entries.filter { $0.date >= cutoff }
        guard !recent.isEmpty else { return nil }
        let matched = recent.filter { $0.sentiment == .matched }.count
        let mismatched = recent.filter { $0.sentiment == .mismatched }.count
        return (recent.count, matched, mismatched)
    }

    private func persist() {
        if unreadableOnDisk {
            guard mergeSavedFeedbackOnceReadable() else {
                debugLog("[RecoveryScoreFeedback] write held — saved feedback still unreadable", level: .warning)
                return
            }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = attempt("scoreFeedback.encode", { try encoder.encode(entries) }) {
            attempt("scoreFeedback.write") {
                try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            }
        }
    }

    /// The saved file could not be read at load, so writing now would replace
    /// feedback this store never saw. Once it reads, its days are merged in —
    /// a day recorded since then wins — and writing resumes. False while it
    /// still won't read.
    private func mergeSavedFeedbackOnceReadable() -> Bool {
        guard attempt("RecoveryScoreFeedbackStore.reread", { try Data(contentsOf: fileURL) }) != nil else { return false }
        let onDisk = Self.loadEntries(from: fileURL)
        let calendar = Calendar.current
        let keptFromDisk = onDisk.filter { saved in
            !entries.contains { calendar.isDate($0.date, inSameDayAs: saved.date) }
        }
        entries = (keptFromDisk + entries).sorted { $0.date < $1.date }
        unreadableOnDisk = false
        return true
    }
}
