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

    /// What the paywall offers. Someone whose access never expires is shown
    /// that the app is unlocked, with nothing to start or buy. Once the trial
    /// has started, running or ended, only the unlock is offered. The trial is
    /// offered only to someone who has never started it.
    static func offer(hasPermanentAccess: Bool, hasTrialStarted: Bool) -> PaywallOffer {
        if hasPermanentAccess { return .unlocked }
        return hasTrialStarted ? .unlockOnly : .trialAndUnlock
    }
}

/// The paywall's three coherent states. See `PaywallGatePolicy.offer`.
enum PaywallOffer: Equatable {
    case trialAndUnlock
    case unlockOnly
    case unlocked
}
