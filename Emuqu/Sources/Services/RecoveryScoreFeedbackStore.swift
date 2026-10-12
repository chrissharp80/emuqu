import Foundation

/// The recovery-score feedback log earlier versions kept.
///
/// Earlier builds asked the user each morning whether the recovery score
/// matched how they felt, and saved one `{date, score, sentiment, tier}`
/// entry per day to a small JSON file in the App Group container. It stayed
/// on device, was never read into scoring, and was never used to retrain the
/// weights (that would be a self-fulfilling prophecy: a user who rates
/// high-score-bad-day would pull the score down even when the algorithm is
/// correct).
///
/// No screen records feedback any more and nothing reads the file. This
/// store exists only so Delete All My Data removes what those versions saved.
@MainActor
final class RecoveryScoreFeedbackStore {
    static let shared = RecoveryScoreFeedbackStore()

    private let fileURL: URL

    private init() {
        fileURL = Self.storeURL()
    }

    /// Where earlier versions saved the log: the App Group container, then
    /// Documents, then tmp — each fallback only on the previous failing.
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
        return baseURL.appendingPathComponent("recovery_score_feedback.json")
    }

    /// Delete the saved feedback log. Called by Delete All My Data, the only
    /// way it is removed. Nothing to do when no earlier version saved one.
    func clearAll() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        attempt("scoreFeedback.remove") { try FileManager.default.removeItem(at: fileURL) }
    }
}
