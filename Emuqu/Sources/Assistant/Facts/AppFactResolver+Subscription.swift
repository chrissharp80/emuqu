import Foundation

// The app.subscription.* namespace: the user's entitlement and trial state.

// MARK: - app.subscription.* namespace
struct AppSubscriptionNamespace: FactNamespaceResolver {
    let namespace = "app"
    let settings: @Sendable () -> UserSettings

    var entries: [FactEntry] {
        [
            appSubscriptionAccessEntry,
            appSubscriptionTrialDaysRemainingEntry,
            appSubscriptionIsInTrialEntry,
            appSubscriptionTrialStartedAtEntry
        ]
    }

    /// How this person has access. The trial facts alone told a buyer who
    /// started the trial on day one that it still had days left — and the
    /// namespace is named for a subscription the app does not sell.
    private var appSubscriptionAccessEntry: FactEntry {
        .fixed(
            key: "app.subscription.access",
            description: "How the user has access to Emuqu: 'purchased' (bought the one-time unlock; Emuqu has no subscription), 'permanent' (beta tester or test build, nothing to buy), 'trial' (inside the free trial), or 'none'. Read this before saying anything about the trial or paying.",
            valueType: "String"
        ) {
            MainActor.assumeIsolated { .string(Self.accessRoute()) }
        }
    }

    /// Only the trial route has a clock the user needs to hear about.
    @MainActor
    private static func accessRoute() -> String {
        let store = AppDependencies.current.services.storeKitManager
        if store.hasPurchasedProduct { return "purchased" }
        if store.hasPermanentAccess { return "permanent" }
        return StoreKitManager.isTrialActive ? "trial" : "none"
    }

    /// The trial matters only while it is what grants access.
    private static var trialIsTheAccessRoute: Bool {
        MainActor.assumeIsolated { accessRoute() == "trial" }
    }

    private var appSubscriptionTrialDaysRemainingEntry: FactEntry {
        .fixed(
            key: "app.subscription.trial_days_remaining",
            description: "Days remaining in the user's free trial. 0 when the trial hasn't started, has expired, or no longer matters because the user bought the app or has permanent access.",
            valueType: "Int"
        ) {
            guard Self.trialIsTheAccessRoute else { return .integer(0) }
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
            description: "Whether the free trial is what currently gives the user access. False once they have bought the app or have permanent access.",
            valueType: "Bool"
        ) {
            guard Self.trialIsTheAccessRoute else { return .boolean(false) }
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
