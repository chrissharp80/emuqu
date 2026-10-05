import StoreKit
import SwiftUI

/// Full-screen paywall presented when the user hasn't purchased the app.
struct PaywallView: View {
    @Environment(StoreKitManager.self) private var storeKit
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Whether this is being shown as a mandatory gate (no dismiss) vs from Settings.
    var isGate: Bool = true

    @State private var showPrivacyPolicy = false
    @State private var showTermsOfUse = false
    @State private var showYourData = false
    /// What the last Restore tap found.
    @State private var restoreNotice: String?

    /// One coherent state: the trial and the unlock for someone who has never
    /// started the trial, the unlock alone once it has started, and for anyone
    /// whose access never expires (a purchase, a grandfathered beta tester, a
    /// developer install) a plain "already active" with Restore and Done.
    /// App Review installs have none of those routes, so a reviewer sees the
    /// offer a customer sees.
    private var offer: PaywallOffer {
        PaywallGatePolicy.offer(
            hasPermanentAccess: storeKit.hasPermanentAccess,
            hasTrialStarted: StoreKitManager.hasTrialStarted)
    }

    private var offersTrial: Bool { offer == .trialAndUnlock }

    private var offersUnlock: Bool { offer != .unlocked }

    /// The trial ran out and nothing else lets this person in.
    private var trialHasEnded: Bool {
        !storeKit.hasActiveAccess && StoreKitManager.hasTrialStarted
    }

    var body: some View {
        withPaywallChrome(paywallStack)
    }

    /// The buttons and the trial terms stay pinned under the scrolling
    /// feature list, so the terms sit beside "Start Free Trial". At
    /// accessibility text sizes the pinned part alone can outgrow the screen,
    /// so there the whole page scrolls as one.
    @ViewBuilder
    private var paywallStack: some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView { wholePage }
        } else {
            pinnedLayout
        }
    }

    private var pinnedLayout: some View {
        VStack(spacing: 0) {
            ScrollView { paywallContent }
            bottomSection.layoutPriority(1)
        }
    }

    private var wholePage: some View {
        VStack(spacing: 0) {
            paywallContent
            bottomContent
        }
    }

    private var paywallContent: some View {
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
                title: String(localized: "Optional Encrypted Sync", bundle: LanguageManager.appBundle),
                subtitle: String(localized: "Off unless you turn it on. Syncs between your devices through your private iCloud account.", bundle: LanguageManager.appBundle)
            )
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                .fill(AppTheme.cardBackground)
        )
    }

    /// The icon has a fixed square frame, aligned with the title, so a long
    /// translated title cannot squeeze it.
    private func featureRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            featureIcon(icon, color: color)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle)
    }

    private func featureIcon(_ icon: String, color: Color) -> some View {
        Image(systemName: icon)
            .font(.title3)
            .foregroundColor(color)
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
    }

    // MARK: - Pricing

    @ViewBuilder
    private var pricingSection: some View {
        if offersUnlock {
            unlockPricing
        }
    }

    private var unlockPricing: some View {
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

    /// The store price, a spinner while it loads, or — when the App Store did
    /// not return the unlock — a way to try again. The spinner used to wait forever,
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

    /// Said the same whether the network failed or the App Store returned no
    /// product: the screen cannot tell the two apart, and both clear on a
    /// retry when they clear at all.
    private var retryProductsButton: some View {
        Button(String(localized: "Purchases aren't available right now. Try Again", bundle: LanguageManager.appBundle)) {
            Task { await storeKit.loadProducts() }
        }
        .font(.subheadline)
        .multilineTextAlignment(.center)
        .disabled(storeKit.isPurchasing)
        .accessibilityIdentifier("paywall.retryProducts")
    }

    /// What Guideline 3.1.1 asks be said before a trial starts: how long it
    /// lasts, what stops working when it ends, and what it costs to continue.
    /// It sits with the buttons, not in the scrolling feature list, so it is
    /// on screen beside "Start Free Trial" on the smallest iPhone, and wraps
    /// to as many lines as it needs in every language and text size. Without
    /// the store price it cannot say the last of those, so it waits for it,
    /// and so does the button.
    @ViewBuilder
    private var trialTerms: some View {
        if offersTrial, let price = storeKit.product?.displayPrice {
            bottomCaption(trialTermsText(price: price))
                .accessibilityIdentifier("paywall.trialTerms")
        } else if trialHasEnded {
            bottomCaption(String(localized: "Your free trial has ended. Unlock Emuqu to keep recording and to see your scores and history again. Everything you recorded is kept.", bundle: LanguageManager.appBundle))
        }
    }

    private func bottomCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(AppTheme.textSecondary)
            .multilineTextAlignment(.center)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func trialTermsText(price: String) -> String {
        let days = TrialPolicy.durationDays
        return String(localized: "Try everything free for \(days) days. When the trial ends, the app locks until you buy the one-time unlock for \(price). Your recordings are kept. The trial never charges you.", bundle: LanguageManager.appBundle)
    }

    // MARK: - Bottom (CTA + Legal)

    /// Its own content when that fits under the feature list; scrolling when
    /// a long translation at a large text size would otherwise be clipped.
    private var bottomSection: some View {
        ViewThatFits(in: .vertical) {
            bottomContent
            ScrollView { bottomContent }
        }
    }

    private var bottomContent: some View {
        VStack(spacing: 12) {
            unlockedNote
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
            legalLink(String(localized: "Terms of Use", bundle: LanguageManager.appBundle), id: "paywall.termsOfUse") {
                showTermsOfUse = true
            }
            legalLink(String(localized: "Privacy Policy", bundle: LanguageManager.appBundle), id: "paywall.privacyPolicy") {
                showPrivacyPolicy = true
            }

            yourDataLink
        }
        .sheet(isPresented: $showTermsOfUse) { termsOfUseSheet }
        .sheet(isPresented: $showPrivacyPolicy) { privacyPolicySheet }
        .sheet(isPresented: $showYourData) { yourDataSheet }
    }

    /// On the gate only. After the trial the gate covers the whole app, and
    /// the privacy policy promises export and deletion at any time; with
    /// only Purchase and Restore on screen, someone who did not buy could do
    /// neither.
    @ViewBuilder
    private var yourDataLink: some View {
        if isGate {
            legalLink(String(localized: "Your Data", bundle: LanguageManager.appBundle), id: "paywall.yourData") {
                showYourData = true
            }
        }
    }

    /// Caption-sized text with a 44 pt-tall hit area.
    private func legalLink(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.caption2)
            .foregroundColor(AppTheme.textTertiary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityIdentifier(id)
    }

    private var yourDataSheet: some View {
        NavigationStack {
            yourDataList
            .navigationTitle(Text(String(localized: "Your Data", bundle: LanguageManager.appBundle)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { yourDataDoneItem }
        }
    }

    private var yourDataList: some View {
        List {
            NavigationLink(String(localized: "Export Data", bundle: LanguageManager.appBundle)) { ExportDataView() }
            NavigationLink(String(localized: "Delete All My Data", bundle: LanguageManager.appBundle)) { DeleteAllDataPage() }
        }
    }

    private var yourDataDoneItem: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle)) { showYourData = false }
        }
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

    /// A purchase, a grandfathered beta tester or a developer install: access
    /// that never ends. Said plainly, in place of the offer, so nobody buys
    /// something they already have.
    @ViewBuilder
    private var unlockedNote: some View {
        if offer == .unlocked {
            Text(String(localized: "Full access is already active on this device.", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.medium))
                .foregroundColor(AppTheme.sageText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("paywall.accessNote")
        }
    }

    /// The trial button, once the unlock price (for the terms) and the trial
    /// product (for the tap) have both loaded. When the fetch came back
    /// without the trial product, a retry takes its place; when it came back
    /// without the unlock, the retry is already on screen in the price line.
    @ViewBuilder
    private var trialButton: some View {
        if offersTrial {
            if storeKit.trialUnavailable, !storeKit.productsUnavailable {
                retryProductsButton
            } else {
                startTrialButton
            }
        }
    }

    private var startTrialButton: some View {
        Button {
            Task { await startTrial() }
        } label: {
            trialButtonLabel
        }
        .buttonStyle(.zen(AppTheme.primary))
        .disabled(storeKit.isPurchasing || storeKit.product == nil || storeKit.trialProduct == nil)
        .accessibilityIdentifier("paywall.startTrial")
    }

    private var trialButtonLabel: some View {
        Text(String(localized: "Start \(TrialPolicy.durationDays)-Day Free Trial", bundle: LanguageManager.appBundle))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    /// Leaves the paywall once the purchase lands. During the trial access
    /// was already on, so nothing else changed to close it, and the screen
    /// stayed up offering the unlock just bought.
    private func purchaseAndLeave() async {
        await storeKit.purchase()
        if storeKit.hasPurchasedProduct { dismiss() }
    }

    /// Leaves the paywall once the trial is running. From the launch gate the
    /// `isPurchased` flip already closes it; from Settings this pops back.
    private func startTrial() async {
        await storeKit.startFreeTrial()
        if storeKit.hasActiveAccess { dismiss() }
    }

    @ViewBuilder
    private var purchaseButtons: some View {
        if offersUnlock {
            purchaseButton
        }
        restoreButton
        continueWithAccessButton
    }

    private var purchaseButton: some View {
        Button {
            Task { await purchaseAndLeave() }
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
                    .multilineTextAlignment(.center)
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
    /// with access: trial, purchased, beta tester, developer install. With
    /// nothing on offer it reads "Done".
    @ViewBuilder
    private var continueWithAccessButton: some View {
        if storeKit.hasActiveAccess {
            Button(continueTitle) {
                dismiss()
            }
            .font(.subheadline)
            .foregroundColor(AppTheme.textSecondary)
            .accessibilityIdentifier("paywall.continue")
        }
    }

    private var continueTitle: String {
        offer == .unlocked
            ? String(localized: "Done", bundle: LanguageManager.appBundle)
            : String(localized: "Continue", bundle: LanguageManager.appBundle)
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
