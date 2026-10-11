import Foundation

/// A/B-style local telemetry for the pre-score
/// subjective prompt. Tracks shown / completed / skipped counts so the
/// build owner can spot the "completion drops > 20%" regression trigger.
///
/// Stored on-device only via UserDefaults. Never uploaded. The
/// Diagnostics page surfaces a one-line read-out so a single user (or a
/// TestFlight tester) can sanity-check completion in the field without
/// any analytics SDK.
///
/// Each record call counts on from the value stored in UserDefaults, not
/// the in-memory copy, so a sweep of these keys (Delete All My Data) is
/// not undone by writing an old total back.
@Observable
@MainActor
final class PreScorePromptTelemetry {
    static let shared = PreScorePromptTelemetry()

    private let defaults: UserDefaults
    private let shownKey   = "preScorePrompt.telemetry.shownCount"
    private let completedKey = "preScorePrompt.telemetry.completedCount"
    private let skippedKey   = "preScorePrompt.telemetry.skippedCount"
    /// Written by earlier builds and never read; `reset()` still removes it.
    private let legacyFirstSeenKey = "preScorePrompt.telemetry.firstSeen"

    private(set) var shownCount: Int
    private(set) var completedCount: Int
    private(set) var skippedCount: Int

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shownCount = defaults.integer(forKey: shownKey)
        completedCount = defaults.integer(forKey: completedKey)
        skippedCount = defaults.integer(forKey: skippedKey)
    }

    /// Called when the prompt mounts.
    func recordShown() {
        shownCount = defaults.integer(forKey: shownKey) + 1
        defaults.set(shownCount, forKey: shownKey)
    }

    /// Called when the user taps "Show my score" with at least one
    /// answer set.
    func recordCompleted() {
        completedCount = defaults.integer(forKey: completedKey) + 1
        defaults.set(completedCount, forKey: completedKey)
    }

    /// Called when the user taps "Skip this time" or dismisses with
    /// zero answers set.
    func recordSkipped() {
        skippedCount = defaults.integer(forKey: skippedKey) + 1
        defaults.set(skippedCount, forKey: skippedKey)
    }

    /// Completion rate over total presentations. Returns nil when the
    /// prompt has never been shown — caller renders "—" rather than a
    /// nonsense `0.00 / 0`.
    var completionRate: Double? {
        guard shownCount > 0 else { return nil }
        return Double(completedCount) / Double(shownCount)
    }

    /// One-line summary for the Diagnostics page.
    var diagnosticsSummary: String {
        guard shownCount > 0 else {
            return "Pre-score prompt: not yet shown."
        }
        let pct = (completionRate ?? 0) * 100
        let rounded = String(format: "%.0f%%", pct)
        return "Pre-score prompt: \(completedCount)/\(shownCount) completed (\(rounded)), \(skippedCount) skipped."
    }

    /// Reset all counters. Wired into Diagnostics for users who want to
    /// re-baseline after a build update.
    func reset() {
        shownCount = 0
        completedCount = 0
        skippedCount = 0
        defaults.removeObject(forKey: shownKey)
        defaults.removeObject(forKey: completedKey)
        defaults.removeObject(forKey: skippedKey)
        defaults.removeObject(forKey: legacyFirstSeenKey)
    }
}
