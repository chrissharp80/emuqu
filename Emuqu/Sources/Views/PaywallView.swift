import StoreKit
import SwiftUI

/// Full-screen paywall presented when the user hasn't purchased the app.
struct PaywallView: View {
    @Environment(StoreKitManager.self) private var storeKit
    @Environment(\.dismiss) private var dismiss

    /// Whether this is being shown as a mandatory gate (no dismiss) vs from Settings.
    var isGate: Bool = true

    @State private var showPrivacyPolicy = false
    @State private var showTermsOfUse = false
    /// What the last Restore tap found.
    @State private var restoreNotice: String?

    /// Access that needs no purchase: a beta tester, a developer install.
    ///
    /// Such a person still sees the purchase and trial buttons, under a note
    /// saying nothing is needed. They used to see "Beta Access — No Purchase
    /// Required" in place of the buttons, and App Review, which runs on a
    /// sandbox receipt exactly like TestFlight, would have seen the same: a
    /// reference to a beta (Guideline 2.2) and no in-app purchase to review
    /// (2.1). No API tells a reviewer from a tester, so the screen has to
    /// work for both. The gate never shows this screen to either of them;
    /// they reach it only from Settings → Purchase.
    private var hasAccessWithoutPurchase: Bool {
        storeKit.hasPermanentAccess && !storeKit.hasPurchasedProduct
    }

    /// The trial is offered until it has started once, and never to someone
    /// who has bought the app.
    private var offersTrial: Bool {
        !storeKit.hasPurchasedProduct && !StoreKitManager.hasTrialStarted
    }

    /// The trial ran out and nothing else lets this person in.
    private var trialHasEnded: Bool {
        !storeKit.hasActiveAccess && StoreKitManager.hasTrialStarted
    }

    var body: some View {
        withPaywallChrome(paywallStack)
    }

    private var paywallStack: some View {
        VStack(spacing: 0) {
            paywallScroll

            bottomSection
        }
    }

    private var paywallScroll: some View {
        ScrollView {
            VStack(spacing: 32) {
                headerSection
                featuresSection
                recoveryFeatures
                moreFeatures
                pricingSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 40)
            .padding(.bottom, 24)
        }
    }

    /// The hard gate applies ONLY to a user with no access at
    /// all. `isGate && !isBetaTester` would trap anyone who
    /// reached the paywall voluntarily while still entitled: "Unlock Now" on
    /// the trial reminder routes here with `isGate: true`, so a user with days
    /// of trial left got a sheet they could not dismiss whose only buttons were
    /// Purchase and Restore. Force-quitting was the only way back into an app
    /// they were entitled to use.
    private func withPaywallChrome(_ content: some View) -> some View {
        content
            .background(AppTheme.background.ignoresSafeArea())
            .interactiveDismissDisabled(isGate && !storeKit.hasActiveAccess)
            .onAppear { NSLog("[Paywall] onAppear — paywall visible (isGate=\(isGate))") }
            .task { await loadProducts() }
            .alert(
                String(localized: "Error", bundle: LanguageManager.appBundle),
                isPresented: Binding(
                    get: { storeKit.errorMessage != nil },
                    set: { if !$0 { storeKit.errorMessage = nil } }
                )
            ) {
                paywallErrorActions
            } message: {
                paywallErrorMessage
            }
    }

    private func loadProducts() async {
        NSLog("[Paywall] .task fired — loading products")
        await storeKit.loadProducts()
        NSLog("[Paywall] loadProducts() returned")
    }

    @ViewBuilder
    private var paywallErrorMessage: some View {
        if let msg = storeKit.errorMessage {
            Text(msg)
        }
    }

    private var paywallErrorActions: some View {
        Button(String(localized: "OK", bundle: LanguageManager.appBundle)) { storeKit.errorMessage = nil }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            paywallLogo

            Text(String(localized: "Emuqu", bundle: LanguageManager.appBundle))
                .font(.title.bold())
                .foregroundColor(AppTheme.textPrimary)

            Text(String(localized: "Professional HRV Recovery Tracking", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    private var paywallLogo: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [AppTheme.primary, AppTheme.primaryDark],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 80, height: 80)

            Image(systemName: "waveform.path.ecg")
                .scaledFont(size: 36, weight: .medium)
                .foregroundColor(.white)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Features

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            featureRow(
                icon: "moon.stars.fill",
                color: AppTheme.primary,
                title: String(localized: "Overnight HRV Recording", bundle: LanguageManager.appBundle),
                subtitle: String(localized: "All night, with a Polar H10 chest strap or Verity Sense armband", bundle: LanguageManager.appBundle)
            )

        }
    }

    private var recoveryFeatures: some View {
        VStack(alignment: .leading, spacing: 16) {
            featureRow(
                icon: "chart.line.uptrend.xyaxis",
                color: AppTheme.sage,
                title: String(localized: "Recovery & Readiness Scores", bundle: LanguageManager.appBundle),
                subtitle: String(localized: "Know when to push hard and when to rest", bundle: LanguageManager.appBundle)
            )

            featureRow(
                icon: "bed.double.fill",
                color: AppTheme.dustyRose,
                title: String(localized: "Sleep Stage Analysis", bundle: LanguageManager.appBundle),
                subtitle: String(localized: "Deep, core, REM and awake estimates", bundle: LanguageManager.appBundle)
            )

        }
    }

    @ViewBuilder
    private var moreFeatures: some View {
        VStack(alignment: .leading, spacing: 16) {
            featureRow(
                icon: "figure.run",
                color: AppTheme.softGold,
                title: String(localized: "Training Load Tracking", bundle: LanguageManager.appBundle),
                subtitle: String(localized: "Fitness, fatigue and daily load from your workouts", bundle: LanguageManager.appBundle)
            )

            featureRow(
                icon: "icloud.fill",
                color: AppTheme.primary,
                title: String(localized: "Encrypted iCloud Backup", bundle: LanguageManager.appBundle),
                subtitle: String(localized: "Your data, securely synced across devices", bundle: LanguageManager.appBundle)
            )
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                .fill(AppTheme.cardBackground)
        )
    }

    private func featureRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)
                .frame(width: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.textPrimary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle)
    }

    // MARK: - Pricing

    private var pricingSection: some View {
        VStack(spacing: 12) {
            Text(String(localized: "Unlock Emuqu", bundle: LanguageManager.appBundle))
                .font(.headline)
                .foregroundColor(AppTheme.textPrimary)

            priceLine

            Text(String(localized: "Pay once, own it forever. No subscriptions.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
    }

    /// The store price, a spinner while it loads, or — when the App Store could
    /// not be reached — a way to try again. The spinner used to wait forever,
    /// and the trial button, which needs the price in its terms, stayed off.
    @ViewBuilder
    private var priceLine: some View {
        if let product = storeKit.product {
            Text(String(localized: "\(product.displayPrice) — one-time purchase", bundle: LanguageManager.appBundle))
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
        } else if storeKit.productsUnavailable {
            retryProductsButton
        } else {
            ProgressView()
                .controlSize(.small)
                .padding(.vertical, 2)
        }
    }

    private var retryProductsButton: some View {
        Button(String(localized: "Couldn't reach the App Store. Try Again", bundle: LanguageManager.appBundle)) {
            Task { await storeKit.loadProducts() }
        }
        .font(.subheadline)
        .accessibilityIdentifier("paywall.retryProducts")
    }

    /// What Guideline 3.1.1 asks be said before a trial starts: how long it
    /// lasts, what stops working when it ends, and what it costs to continue.
    /// It sits with the buttons, not in the scrolling feature list, so it is
    /// on screen beside "Start Free Trial" on the smallest iPhone. Without the
    /// store price it cannot say the last of those, so it waits for it, and so
    /// does the button.
    @ViewBuilder
    private var trialTerms: some View {
        if offersTrial, let price = storeKit.product?.displayPrice {
            Text(trialTermsText(price: price))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("paywall.trialTerms")
        } else if trialHasEnded {
            Text(String(localized: "Your free trial has ended. Unlock Emuqu to keep recording and to see your scores and history again. Everything you recorded is kept.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private func trialTermsText(price: String) -> String {
        let days = TrialPolicy.durationDays
        return String(localized: "Try everything free for \(days) days. When the trial ends, the app locks until you buy the one-time unlock for \(price). Your recordings are kept. The trial never charges you.", bundle: LanguageManager.appBundle)
    }

    // MARK: - Bottom (CTA + Legal)

    private var bottomSection: some View {
        VStack(spacing: 12) {
            accessWithoutPurchaseNote
            trialTerms
            trialButton
            purchaseButtons

            skipDebugButton
            legalLinks
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private var skipDebugButton: some View {
        #if DEBUG
            Button(String(localized: "Skip (Debug)", bundle: LanguageManager.appBundle)) {
                storeKit.debugGrantAccess()
                dismiss()
            }
            .font(.caption)
            .foregroundColor(AppTheme.textTertiary)
            .accessibilityIdentifier("paywall.skipDebug")
        #endif
    }

    private var legalLinks: some View {
        HStack(spacing: 16) {
            Button(String(localized: "Terms of Use", bundle: LanguageManager.appBundle)) {
                showTermsOfUse = true
            }
            .font(.caption2)
            .foregroundColor(AppTheme.textTertiary)
            .accessibilityIdentifier("paywall.termsOfUse")

            Button(String(localized: "Privacy Policy", bundle: LanguageManager.appBundle)) {
                showPrivacyPolicy = true
            }
            .font(.caption2)
            .foregroundColor(AppTheme.textTertiary)
            .accessibilityIdentifier("paywall.privacyPolicy")
        }
        .sheet(isPresented: $showTermsOfUse) { termsOfUseSheet }
        .sheet(isPresented: $showPrivacyPolicy) { privacyPolicySheet }
    }

    private var termsOfUseSheet: some View {
        NavigationStack {
            TermsOfUseView()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { dismissTermsToolbarItem }
        }
    }

    private var dismissTermsToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) { showTermsOfUse = false }
        }
    }

    private var privacyPolicySheet: some View {
        NavigationStack {
            PrivacyPolicyView()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { dismissPrivacyToolbarItem }
        }
    }

    private var dismissPrivacyToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) { showPrivacyPolicy = false }
                .accessibilityIdentifier("paywall.privacyDone")
        }
    }

    @ViewBuilder
    private var accessWithoutPurchaseNote: some View {
        // Nothing on a sandbox receipt: that is TestFlight or App Review, which
        // no API tells apart, and a reviewer told the purchase is optional, or
        // that this is a test build, has a reason to reject the app.
        if hasAccessWithoutPurchase, !StoreKitManager.isTestFlight {
            Text(accessWithoutPurchaseText)
                .font(.subheadline.weight(.medium))
                .foregroundColor(AppTheme.sage)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("paywall.accessNote")
        }
    }

    /// A beta tester or developer install on a store build: access without a
    /// purchase. Said plainly, so they don't buy something they already have.
    private var accessWithoutPurchaseText: String {
        String(localized: "Full access is already active on this device.", bundle: LanguageManager.appBundle)
    }

    @ViewBuilder
    private var trialButton: some View {
        if offersTrial {
            startTrialButton
        }
    }

    private var startTrialButton: some View {
        Button {
            Task { await startTrial() }
        } label: {
            trialButtonLabel
        }
        .buttonStyle(.zen(AppTheme.primary))
        .disabled(storeKit.isPurchasing || storeKit.product == nil)
        .accessibilityIdentifier("paywall.startTrial")
    }

    private var trialButtonLabel: some View {
        Text(String(localized: "Start \(TrialPolicy.durationDays)-Day Free Trial", bundle: LanguageManager.appBundle))
            .frame(maxWidth: .infinity)
    }

    /// Leaves the paywall once the trial is running. From the launch gate the
    /// `isPurchased` flip already closes it; from Settings this pops back.
    private func startTrial() async {
        await storeKit.startFreeTrial()
        if storeKit.hasActiveAccess { dismiss() }
    }

    @ViewBuilder
    private var purchaseButtons: some View {
        purchaseButton
        restoreButton
        continueWithAccessButton
    }

    private var purchaseButton: some View {
        Button {
            Task { await storeKit.purchase() }
        } label: {
            purchaseButtonLabel
        }
        .buttonStyle(.zen(offersTrial ? AppTheme.primaryDark : AppTheme.primary))
        .disabled(storeKit.isPurchasing)
        .accessibilityIdentifier("paywall.purchase")
        .accessibilityLabel(String(localized: "Purchase Emuqu", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "Buy the full app — one time purchase, no subscriptions", bundle: LanguageManager.appBundle))
        .alert(
            String(localized: "Purchase", bundle: LanguageManager.appBundle),
            isPresented: Binding(
                get: { storeKit.purchaseNotice != nil },
                set: { if !$0 { storeKit.purchaseNotice = nil } }
            ),
            presenting: storeKit.purchaseNotice
        ) { _ in
            Button(String(localized: "OK", bundle: LanguageManager.appBundle)) { storeKit.purchaseNotice = nil }
        } message: { Text($0) }
    }

    private var purchaseButtonLabel: some View {
        Group {
            if storeKit.isPurchasing {
                ProgressView()
                    .tint(.white)
            } else if let price = storeKit.product?.displayPrice {
                Text(String(localized: "Unlock for \(price)", bundle: LanguageManager.appBundle))
            } else {
                Text(String(localized: "Purchase", bundle: LanguageManager.appBundle))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var restoreButton: some View {
        Button(String(localized: "Restore Purchases", bundle: LanguageManager.appBundle)) {
            Task { restoreNotice = await storeKit.restore() }
        }
        .font(.subheadline)
        .foregroundColor(AppTheme.textSecondary)
        .disabled(storeKit.isPurchasing)
        .accessibilityLabel(String(localized: "Restore Purchases", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "Restore a previous purchase from your Apple ID", bundle: LanguageManager.appBundle))
        .accessibilityIdentifier("paywall.restore")
        .alert(
            String(localized: "Restore Purchases", bundle: LanguageManager.appBundle),
            isPresented: Binding(
                get: { restoreNotice != nil },
                set: { if !$0 { restoreNotice = nil } }
            ),
            presenting: restoreNotice
        ) { _ in
            Button(String(localized: "OK", bundle: LanguageManager.appBundle)) { restoreNotice = nil }
        } message: { Text($0) }
    }

    /// A visible escape for anyone who still has access.
    /// Swipe-to-dismiss alone is not discoverable, and the user who lands here
    /// from "Unlock Now" during a live trial has done nothing wrong: they
    /// looked at the price and decided to keep trialling. It covers everyone
    /// with access: trial, purchased, beta tester, developer install.
    @ViewBuilder
    private var continueWithAccessButton: some View {
        if storeKit.hasActiveAccess {
            Button(String(localized: "Continue", bundle: LanguageManager.appBundle)) {
                dismiss()
            }
            .font(.subheadline)
            .foregroundColor(AppTheme.textSecondary)
            .accessibilityIdentifier("paywall.continue")
        }
    }
}

// MARK: - Purchase Status (Settings)

/// Compact view shown in Settings to show purchase status.
struct PurchaseStatusView: View {
    @Environment(StoreKitManager.self) private var storeKit

    /// Entire section hidden when the paywall is
    /// fenced off (pre-launch). Avoids both a misleading "Owned"
    /// row and a dead-end navigation link to a no-op paywall.
    @ViewBuilder
    var body: some View {
        if StoreKitManager.paywallEnabled {
            Section {
                purchaseStatusRow
            } header: {
                Text(String(localized: "Purchase", bundle: LanguageManager.appBundle))
            }
        }
    }

    /// Keys off `hasPurchasedProduct`, NOT `isPurchased`.
    ///
    /// `isPurchased` means "has access by any route", so it is true
    /// throughout the trial. Keying "Owned" off it tells a
    /// trialing user they already own the app and removes their
    /// only route to buy it — and does the same to App Review, which
    /// downloads a fresh build, lands in the trial, and then cannot
    /// exercise the in-app purchase it is there to review.
    ///
    /// Beta testers and developer installs also have access without
    /// a purchase; none of them should see "Owned" either.
    @ViewBuilder
    private var purchaseStatusRow: some View {
        if storeKit.hasPurchasedProduct {
            ownedRow
        } else {
            purchaseLink
        }
    }

    private var ownedRow: some View {
        HStack {
            Label(String(localized: "Purchase", bundle: LanguageManager.appBundle), systemImage: "checkmark.seal.fill")
                .foregroundColor(AppTheme.sage)
            Spacer()
            Text(String(localized: "Owned", bundle: LanguageManager.appBundle))
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    private var purchaseLink: some View {
        NavigationLink {
            PaywallView(isGate: false)
        } label: {
            purchaseLinkLabel
        }
    }

    private var purchaseLinkLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(String(localized: "Purchase", bundle: LanguageManager.appBundle), systemImage: "star.fill")
                .foregroundColor(AppTheme.softGold)
            // Reuses the two trial strings the reminder sheet
            // already ships, so this adds no new keys to
            // translate across the 16 shipping locales.
            trialRemainingNote
        }
    }

    @ViewBuilder
    private var trialRemainingNote: some View {
        if PaywallGatePolicy.showsTrialClock(
            hasPermanentAccess: storeKit.hasPermanentAccess, isTrialActive: StoreKitManager.isTrialActive) {
            let days = StoreKitManager.trialDaysRemaining
            Text(
                String(localized: "Free Trial", bundle: LanguageManager.appBundle)
                    + " · "
                    + String(localized: "\(days) days remaining", bundle: LanguageManager.appBundle)
            )
            .font(.caption)
            .foregroundColor(AppTheme.textSecondary)
        }
    }
}

#Preview("Paywall") {
    PaywallView()
        .environment(AppDependencies.current.services.storeKitManager)
}

#Preview("Status - Active") {
    NavigationStack {
        List {
            PurchaseStatusView()
                .environment(AppDependencies.current.services.storeKitManager)
        }
    }
}
