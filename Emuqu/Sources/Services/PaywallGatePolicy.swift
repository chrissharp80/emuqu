import Foundation

/// Which launch modal, if any, the paywall gate presents, and whether the
/// trial clock is anyone's business.
///
/// ## Why this exists
///
/// A gate that reads the trial clock on its own shows anyone inside the
/// trial's last week the daily "N days remaining" reminder, whether or not the trial is
/// the thing letting them in. The developer on an Xcode build and a tester
/// grandfathered onto the App Store build both have
/// permanent access and no purchase ahead of them, and would still be
/// counted down. Permanent access wins; the trial only matters to someone
/// whose access will actually end.
enum PaywallGatePolicy {
    /// The reminder is held back until the last week of the trial. A daily
    /// countdown from day one of thirty is nagging, and it interrupts exactly
    /// the stretch where the user is building the baseline the score needs.
    static let reminderWindowDays = 7

    /// `hasAccess` is every route in, including the trial. `hasPermanentAccess`
    /// is every route that does not expire: a purchase, a grandfathered beta
    /// tester, a developer install, the debug grant.
    static func launchModal(
        hasAccess: Bool,
        hasPermanentAccess: Bool,
        isInTrial: Bool,
        trialDaysRemaining: Int,
        reminderShownToday: Bool
    ) -> LaunchModal? {
        guard hasAccess else { return .paywall }
        guard !hasPermanentAccess, isInTrial, !reminderShownToday else { return nil }
        guard trialDaysRemaining <= reminderWindowDays else { return nil }
        return .trialReminder
    }

    /// The paywall's "Free Trial · N days remaining" note is for a user whose
    /// access ends with the trial, never for one who will never pay.
    static func showsTrialClock(hasPermanentAccess: Bool, isTrialActive: Bool) -> Bool {
        !hasPermanentAccess && isTrialActive
    }

    /// What the paywall offers. Only an actual purchase ends the offer: free
    /// access that does not expire (a grandfathered beta tester, a developer
    /// install, the debug grant) still leaves the unlock on offer, since
    /// nothing stops that person buying. The trial is offered only while
    /// starting it grants one; see `canStartTrial`.
    static func offer(hasPurchasedProduct: Bool, canStartTrial: Bool) -> PaywallOffer {
        if hasPurchasedProduct { return .unlocked }
        return canStartTrial ? .trialAndUnlock : .unlockOnly
    }

    /// Whether buying the trial product now starts a thirty-day trial, which
    /// is the only time the paywall offers it.
    ///
    /// The trial clock is the purchase date of this Apple ID's free-trial
    /// transaction, and the App Store sells that product once per Apple ID.
    /// Once StoreKit has answered, then, an Apple ID without the transaction
    /// gets a full trial from the purchase, whatever start this device kept
    /// from an earlier build or another Apple ID, and one with it gets
    /// nothing new. Until StoreKit answers, a trial start kept on this device
    /// holds the offer back. Free access that does not expire gains nothing
    /// from a trial, so it is never offered one.
    static func canStartTrial(
        storeKitHasTrialTransaction: Bool?,
        hasLocalTrialStart: Bool,
        hasPermanentAccess: Bool
    ) -> Bool {
        guard !hasPermanentAccess else { return false }
        guard let storeKitHasTrialTransaction else { return !hasLocalTrialStart }
        return !storeKitHasTrialTransaction
    }

    /// Whether an Apple ID recorded as a beta tester has free access on this
    /// install. Only on one `AppTransaction` verified as an App Store
    /// (production) build: App Review and TestFlight share the sandbox
    /// environment, earlier sandbox builds anchored App Review's Apple IDs as
    /// testers, and App Review has to meet the customer's paywall.
    static func grantsBetaTesterAccess(isAnchoredBetaTester: Bool, isVerifiedProductionInstall: Bool) -> Bool {
        isAnchoredBetaTester && isVerifiedProductionInstall
    }
}

/// The paywall's three coherent states. See `PaywallGatePolicy.offer`.
enum PaywallOffer: Equatable {
    case trialAndUnlock
    case unlockOnly
    case unlocked
}
