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

    /// What the paywall offers. Only an actual purchase ends the offer: a
    /// grandfathered beta tester, a developer install and the debug grant
    /// have free access, but nothing stops them buying, and an Apple ID that
    /// earlier sandbox builds anchored as a tester (App Review's included)
    /// must still be able to reach both in-app purchases. The trial is
    /// offered while the user can still start it; see `canStartTrial`.
    static func offer(hasPurchasedProduct: Bool, canStartTrial: Bool) -> PaywallOffer {
        if hasPurchasedProduct { return .unlocked }
        return canStartTrial ? .trialAndUnlock : .unlockOnly
    }

    /// Whether the trial product is still on offer. Once StoreKit has
    /// answered, its record for this Apple ID decides: a trial start kept on
    /// this device from another Apple ID or an earlier build does not hide the
    /// product. Until it answers, a trial start kept on this device does.
    /// Starting the trial again never extends a running one, because the
    /// earliest start is the one kept.
    static func canStartTrial(storeKitHasTrialTransaction: Bool?, hasLocalTrialStart: Bool) -> Bool {
        guard let storeKitHasTrialTransaction else { return !hasLocalTrialStart }
        return !storeKitHasTrialTransaction
    }

    /// What the trial terms say when the trial is on offer. Someone with free
    /// access that does not expire is told the trial leaves it as it is. For
    /// everyone else a trial start already kept on this device is the one
    /// that counts, so the terms give its end date, or say that it has ended,
    /// instead of promising the full trial.
    static func trialTerms(hasFreePermanentAccess: Bool, localTrialStart: Date?, now: Date) -> PaywallTrialTerms {
        if hasFreePermanentAccess { return .keepsFreeAccess }
        guard let localTrialStart else { return .fullTrial }
        guard TrialPolicy.isActive(start: localTrialStart, now: now) else { return .alreadyEnded }
        return .endsOn(localTrialStart.addingTimeInterval(TrialPolicy.duration))
    }

    /// The note above the offer for someone who already has access that does
    /// not expire. A buyer is told the app is unlocked; a grandfathered beta
    /// tester that the access is free and buying is still possible; a
    /// developer install that access is active. Nil for everyone else.
    static func accessNote(hasPurchasedProduct: Bool, isBetaTester: Bool, hasPermanentAccess: Bool) -> PaywallAccessNote? {
        if hasPurchasedProduct { return .purchased }
        guard hasPermanentAccess else { return nil }
        return isBetaTester ? .betaTester : .freeAccess
    }
}

/// The paywall's three coherent states. See `PaywallGatePolicy.offer`.
enum PaywallOffer: Equatable {
    case trialAndUnlock
    case unlockOnly
    case unlocked
}

/// The trial terms beside the trial button. See `PaywallGatePolicy.trialTerms`.
enum PaywallTrialTerms: Equatable {
    case fullTrial
    case keepsFreeAccess
    case endsOn(Date)
    case alreadyEnded
}

/// The note above the paywall's offer. See `PaywallGatePolicy.accessNote`.
enum PaywallAccessNote: Equatable {
    case purchased
    case betaTester
    case freeAccess
}
