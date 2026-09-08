import CoreLocation
import Foundation

// The subscription and live-coaching namespaces, split out of
// `AppFactResolver+HealthKitFacts.swift` at a top-level type
// boundary. HealthKit facts stay behind.

// MARK: - app.subscription.* namespace
struct AppSubscriptionNamespace: FactNamespaceResolver {
    let namespace = "app"
    let settings: @Sendable () -> UserSettings

    var entries: [FactEntry] {
        [
            appSubscriptionTrialDaysRemainingEntry,
            appSubscriptionIsInTrialEntry,
            appSubscriptionTrialStartedAtEntry
        ]
    }

    private var appSubscriptionTrialDaysRemainingEntry: FactEntry {
        .fixed(
            key: "app.subscription.trial_days_remaining",
            description: "Days remaining in the user's free trial. 0 when the trial hasn't started or has expired.",
            valueType: "Int"
        ) {
            // Resolved through `EntitlementAnchor`, same as
            // `SettingsManager.trialDaysRemaining`. Reading `settings`
            // alone would report 0 for a reinstalled user whose trial
            // start survives only in the keychain anchor, and the
            // assistant would confidently tell them the wrong thing.
            let anchor = EntitlementAnchor.cached()
            let start = anchor.trialStartDate ?? self.settings().trialStartDate
            let now = EntitlementAnchor.effectiveNow(anchor, wallClock: Date())
            return .integer(TrialPolicy.daysRemaining(start: start, now: now))
        }
    }

    private var appSubscriptionIsInTrialEntry: FactEntry {
        .fixed(
            key: "app.subscription.is_in_trial",
            description: "Whether the user is currently within the free trial period.",
            valueType: "Bool"
        ) {
            let anchor = EntitlementAnchor.cached()
            let start = anchor.trialStartDate ?? self.settings().trialStartDate
            let now = EntitlementAnchor.effectiveNow(anchor, wallClock: Date())
            return .boolean(TrialPolicy.isActive(start: start, now: now))
        }
    }

    private var appSubscriptionTrialStartedAtEntry: FactEntry {
        .fixed(
            key: "app.subscription.trial_started_at",
            description: "When the free trial was started (or null if never started).",
            valueType: "Date"
        ) {
            guard let start = EntitlementAnchor.cached().trialStartDate ?? self.settings().trialStartDate else {
                return .missing(reason: .notRecorded, detail: "trial never started")
            }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return .string(f.string(from: start))
        }
    }
}
