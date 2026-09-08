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

    /// Beta testers never purchase — neither the tester who is on a
    /// TestFlight build right now, nor the one who has since moved to the
    /// paid App Store build. The second case is what `EntitlementAnchor`
    /// exists for; without it a tester would meet a purchase button the
    /// day the app shipped. See `StoreKitManager.isGrandfatheredBetaTester`.
    private var isBetaTester: Bool {
        StoreKitManager.isTestFlight || StoreKitManager.isGrandfatheredBetaTester
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
                subtitle: String(localized: "Continuous monitoring while you sleep", bundle: LanguageManager.appBundle)
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
                subtitle: String(localized: "Deep, core, REM and awake detection", bundle: LanguageManager.appBundle)
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
                subtitle: String(localized: "Acute vs chronic workload balance", bundle: LanguageManager.appBundle)
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

            if let product = storeKit.product {
                Text(String(localized: "\(product.displayPrice) — one-time purchase", bundle: LanguageManager.appBundle))
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textSecondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .padding(.vertical, 2)
            }

            Text(String(localized: "Pay once, own it forever. No subscriptions.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Bottom (CTA + Legal)

    private var bottomSection: some View {
        VStack(spacing: 12) {
            if isBetaTester {
                betaContinue
            } else {
                purchaseButtons
            }

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
    private var betaContinue: some View {
        Text(String(localized: "Beta Access — No Purchase Required", bundle: LanguageManager.appBundle))
            .font(.subheadline.weight(.medium))
            .foregroundColor(AppTheme.sage)

        Button(String(localized: "Continue", bundle: LanguageManager.appBundle)) {
            dismiss()
        }
        .buttonStyle(.zen(AppTheme.primary))
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
        .buttonStyle(.zen(AppTheme.primary))
        .disabled(storeKit.isPurchasing)
        .accessibilityLabel(String(localized: "Purchase Emuqu", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "Buy the full app — one time purchase, no subscriptions", bundle: LanguageManager.appBundle))
    }

    private var purchaseButtonLabel: some View {
        Group {
            if storeKit.isPurchasing {
                ProgressView()
                    .tint(.white)
            } else {
                Text(String(localized: "Purchase", bundle: LanguageManager.appBundle))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var restoreButton: some View {
        Button(String(localized: "Restore Purchase", bundle: LanguageManager.appBundle)) {
            Task { await storeKit.restore() }
        }
        .font(.subheadline)
        .foregroundColor(AppTheme.textSecondary)
        .accessibilityLabel(String(localized: "Restore Purchase", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "Restore a previous purchase from your Apple ID", bundle: LanguageManager.appBundle))
        .accessibilityIdentifier("paywall.restore")
    }

    /// A visible escape for anyone who still has access.
    /// Swipe-to-dismiss alone is not discoverable, and the user who lands here
    /// from "Unlock Now" during a live trial has done nothing wrong: they
    /// looked at the price and decided to keep trialling. Beta testers get
    /// their own Continue elsewhere; this covers trial and already-purchased.
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
    /// throughout the 7-day trial. Keying "Owned" off it tells a
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
