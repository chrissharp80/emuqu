import StoreKit
import SwiftUI

/// Asks the system for an App Store rating when the view appears, if
/// `ReviewPromptPolicy` allows it. Kept out of `DashboardV2View` so the
/// dashboard only declares where the ask belongs.
struct ReviewPromptOnAppear: ViewModifier {
    @Environment(\.requestReview) private var requestReview
    let isActive: Bool
    let baselineNights: Int
    let hasScore: Bool

    func body(content: Content) -> some View {
        content.onAppear { requestIfEligible() }
    }

    /// Waits until the dashboard's score reveal has settled so the system
    /// sheet does not land mid-animation. The ask is recorded even though
    /// the system may decide to show nothing.
    private func requestIfEligible() {
        let defaults = UserDefaults.standard
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard isActive, !UITestLaunchArguments.isUITestRun,
              ReviewPromptPolicy.shouldRequest(
                  baselineNights: baselineNights,
                  hasScore: hasScore,
                  currentVersion: version,
                  lastRequestedVersion: defaults.string(forKey: ReviewPromptPolicy.lastVersionKey),
                  lastRequestedDate: defaults.object(forKey: ReviewPromptPolicy.lastDateKey) as? Date,
                  now: Date()
              ) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            defaults.set(version, forKey: ReviewPromptPolicy.lastVersionKey)
            defaults.set(Date(), forKey: ReviewPromptPolicy.lastDateKey)
            requestReview()
        }
    }
}
