import Foundation

/// When the dashboard may ask the system for an App Store rating.
///
/// Apple's guidance is to ask after the person has seen what the app does,
/// at a natural pause, and never in response to a button. The system shows
/// the prompt at most three times a year and may show nothing; this policy
/// only decides when asking is worth it:
///   - at least `minimumScoredNights` nights in the baseline, so the person
///     has had several morning scores, not just a first try;
///   - a score is on screen, so the ask follows a result rather than an empty
///     or loading dashboard;
///   - not already asked in this app version;
///   - at least `minimumDaysBetweenRequests` since the last ask.
///
/// Clock-free: the caller passes `now` and the stored state.
/// Regression coverage lives in `ReviewPromptPolicyTests`.
enum ReviewPromptPolicy {
    static let minimumScoredNights = 5
    static let minimumDaysBetweenRequests = 120

    static let lastVersionKey = "reviewPrompt.lastRequestedVersion"
    static let lastDateKey = "reviewPrompt.lastRequestedDate"

    static func shouldRequest(
        baselineNights: Int,
        hasScore: Bool,
        currentVersion: String,
        lastRequestedVersion: String?,
        lastRequestedDate: Date?,
        now: Date
    ) -> Bool {
        guard baselineNights >= minimumScoredNights, hasScore else { return false }
        if lastRequestedVersion == currentVersion { return false }
        if let last = lastRequestedDate,
           now.timeIntervalSince(last) < Double(minimumDaysBetweenRequests) * 86_400 {
            return false
        }
        return true
    }
}
