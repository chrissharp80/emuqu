import StoreKit
import SwiftUI

/// Manages StoreKit 2 in-app purchase for Emuqu.
/// Listens for transaction updates, verifies entitlements, and exposes
/// reactive state that views can observe.
@Observable
@MainActor
final class StoreKitManager {
    static let shared = StoreKitManager()

    // MARK: - Product IDs

    /// Non-consumable product ID configured in App Store Connect.
    static let productId = "com.chrissharp.flowrecovery.lifetime"

    // MARK: - Published State

    /// The product fetched from the App Store.
    private(set) var product: Product?

    /// Whether the user has purchased the app.
    ///
    /// Initial value comes from UserDefaults (last-known state from
    /// previous launch). This way a paid user is never gated on the
    /// async StoreKit refresh — they get into the app instantly on
    /// every launch, and the live verification runs in the background
    /// to confirm. Same for TestFlight: once we know it's a TestFlight
    /// build, we remember.
    ///
    /// Why the persisted cache: a TestFlight user (the
    /// developer's wife) was being shown the paywall on every launch
    /// because StoreKit's `Transaction.currentEntitlements` /
    /// `AppTransaction.shared` are async and the paywall gate fires
    /// synchronously off the cached `false` initial value. Persisted
    /// caching means the gate sees the LAST-KNOWN-GOOD purchase state
    /// instantly — paid users + TestFlight users sail past the gate
    /// without ever seeing the paywall.
    private(set) var isPurchased: Bool = {
        // Dormant escape hatch. `paywallEnabled` is `true`, so this line is
        // inert and the cache below is what answers. It is kept because
        // flipping the flag back is a one-line rollback if review forces it:
        // pre-launch, the paywall flow made life hard for testers (Apple
        // sign-in prompts on DEBUG builds, launch-blocking covers on
        // TestFlight) for zero return while the app was not on the store.
        if !StoreKitManager.paywallEnabled { return true }
        return UserDefaults.standard.bool(forKey: StoreKitManager.lastKnownPurchasedKey)
    }()

    /// Whether the user has actually BOUGHT the product.
    ///
    /// Deliberately distinct from `isPurchased`, which answers
    /// "does this person have access by ANY route" and is therefore true
    /// during the free trial, for grandfathered beta testers, and on
    /// developer installs.
    ///
    /// Conflating the two made the in-app purchase unreachable. Settings →
    /// Purchase keyed off `isPurchased`, so a user inside their 7-day trial
    /// was shown "Owned" and given no way to buy — and so was App Review,
    /// which downloads a fresh build, lands in the trial, and then cannot
    /// exercise the IAP it is there to review. That is the standard
    /// "we were unable to locate the in-app purchases" rejection.
    ///
    /// This value comes ONLY from `Transaction.currentEntitlements`. No
    /// bypass writes it.
    private(set) var hasPurchasedProduct = false

    /// Whether a purchase or restore operation is in flight.
    private(set) var isPurchasing = false

    /// User-facing error message from the most recent failed operation.
    var errorMessage: String?

    // MARK: - Paywall feature flag
    //
    // Master switch. False = the paywall is fully disabled across the
    // app:
    //   - `isPurchased` stays true forever
    //   - `refreshStatus()` short-circuits and grants entitlement
    //   - `loadProducts()` is a no-op (no Apple sign-in prompt)
    //   - `purchase()` / `restore()` are no-ops
    //   - The launch gate never picks `.paywall` as the activeModal
    //   - PaywallView still exists in code but isn't routed to
    //
    // ON for the $9.99 launch. Four independent
    // bypasses keep this off the path of anyone who should not see it:
    //
    //   • DEBUG builds        → `isDebugBuild` ⇒ `isDeveloperInstall`
    //   • Xcode / sideload    → `isDeveloperInstall` (no App Store receipt)
    //   • Beta testers        → `EntitlementAnchor.isBetaTester`, permanent
    //   • Everyone else       → 7-day free trial via `TrialPolicy`
    //
    // The simulator and every UI-test run land in the first bucket, which
    // is why turning this on does not gate the XCUITest suite.
    static let paywallEnabled = true

    // MARK: - Persisted-cache keys
    //
    // `nonisolated` so they can be read from any context (e.g. the
    // detached `Task` in `check()` that runs `AppTransaction.shared` off
    // MainActor — Swift 6 strict mode would otherwise flag the access).
    // String literals are inherently safe to share.
    nonisolated private static let lastKnownPurchasedKey = "storekit.lastKnownPurchased"
    nonisolated private static let lastKnownTestFlightKey = "storekit.lastKnownTestFlight"

    // MARK: - Private

    @ObservationIgnored private var transactionListener: Task<Void, Never>?

    private init() {
        // Cold-start: init is a no-op. The
        // StoreKit wiring (transactionListener / refreshStatus / TestFlight
        // verification) is deferred to boot() so it can't run on the
        // synchronous launch path even if paywallEnabled flips on later.
        // Belt + suspenders: when paywallEnabled is false, boot() also
        // returns early, so no StoreKit calls fire and no Apple-ID prompt
        // can land on a developer build.
    }

    /// Post-first-frame StoreKit initialisation.
    /// Kept idempotent — second call short-circuits on the listener
    /// already being installed. Called from `RootView.task` after the
    /// first frame paints, so the StoreKit framework is touched off the
    /// launch critical path.
    @MainActor
    /// Reconciles the durable entitlement anchor across every tier before
    /// anything reads it. This is the step that lands a beta tester who has
    /// just restored onto a brand-new phone on the grandfathered path instead
    /// of the paywall: the keychain item is synchronizable, so it arrives with
    /// their iCloud Keychain.
    func boot() {
        guard transactionListener == nil else { return }
        guard Self.paywallEnabled else { return }
        let now = Date()
        EntitlementAnchor.resolve(wallClock: now)
        migrateLegacyTestFlightFlag(now: now)
        // A TestFlight build is a tester: record it now, locally, so the
        // grandfather record does not depend on the background
        // `AppTransaction` round-trip succeeding on some launch before the
        // tester moves to the App Store build. That verification still runs
        // and records too; this is the copy that cannot be lost to a bad
        // network day. App Review's sandbox receipt is anchored as well, which
        // costs nothing (see `recordBetaTesterIfInstallPredatesThisBuild`).
        if Self.isTestFlight {
            EntitlementAnchor.recordBetaTester(wallClock: now)
        }
        transactionListener = listenForTransactions()
        Task { await refreshStatus() }
        // Background TestFlight verification — confirms the bundle
        // signature off the splash path. See `isTestFlight` docs.
        verifyAppTransactionInBackground()
    }

    /// Grandfathers anyone whose device already holds sessions the first
    /// time this install looks, which on a store build can only mean they ran
    /// the app before it was on the store: the beta cohort. Skipped on debug
    /// builds, which are developer installs and where the UI suites seed
    /// history on purpose. See `EntitlementAnchor.evaluatedHistory`.
    func grandfatherExistingUserIfNeeded(hasHistory: Bool, now: Date) {
        guard !Self.isDebugBuild else { return }
        EntitlementAnchor.recordHistoryCheck(hasHistory: hasHistory, wallClock: now)
    }

    /// Carries the legacy `storekit.lastKnownTestFlight` flag into
    /// the durable anchor.
    ///
    /// That flag was only ever written on a genuine sandbox receipt, so a
    /// `true` value is real evidence that this install ran a TestFlight
    /// build — exactly the fact the anchor wants. Migrating it is what
    /// keeps the EXISTING beta cohort grandfathered; without this, every
    /// current tester would be handed a paywall the first time they opened
    /// the launch build.
    ///
    /// The legacy key is left in place rather than deleted. It is inert
    /// (`isTestFlight` does not read it), and leaving it costs nothing
    /// while letting a user who downgrades to an older build keep working.
    /// Internal, not private, so `AppLaunchTasks` can run it
    /// BEFORE the launch gate. `boot()` fires from the second root `.task`,
    /// but the gate that reads `isGrandfatheredBetaTester` runs in the first,
    /// so running it from `boot()` lands a returning tester's migration one
    /// beat too late.
    @MainActor
    func migrateLegacyTestFlightFlag(now: Date) {
        guard UserDefaults.standard.bool(forKey: Self.lastKnownTestFlightKey) else { return }
        guard !EntitlementAnchor.cached().isBetaTester else { return }
        EntitlementAnchor.recordBetaTester(wallClock: now)
        debugLog("[StoreKit] migrated legacy TestFlight flag into entitlement anchor", level: .info)
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Product Loading

    /// Fetch the product from the App Store.
    ///
    /// **No-op when `paywallEnabled` is false.** This call
    /// triggers an Apple sign-in prompt on developer-installed
    /// builds (the user's wife's case) because StoreKit wants a signed-
    /// in Apple ID to look up products. Skipping the call entirely
    /// avoids the prompt.
    func loadProducts() async {
        guard Self.paywallEnabled else { return }
        do {
            let products = try await Product.products(for: [Self.productId])
            product = products.first
        } catch {
            debugLog("[StoreKit] Failed to load products: \(error)")
        }
    }

    // MARK: - Purchase

    func purchase() async {
        // Pre-launch: paywall fenced off, no purchases possible.
        guard Self.paywallEnabled else { return }
        guard let product else {
            await loadProducts()
            guard let product else {
                errorMessage = "Unable to load product. Check your connection and try again."
                return
            }
            return await purchaseProduct(product)
        }
        await purchaseProduct(product)
    }

    private func purchaseProduct(_ product: Product) async {
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            // `.userCancelled` and `.pending` (Ask to Buy) both leave the
            // entitlement untouched — nothing to finish or refresh.
            guard case let .success(verification) = try await product.purchase() else { return }
            let transaction = try checkVerified(verification)
            await transaction.finish()
            await refreshStatus()
        } catch {
            errorMessage = "Purchase failed. Please try again."
            debugLog("[StoreKit] Purchase error: \(error)")
        }
    }

    // MARK: - Restore

    func restore() async {
        // Pre-launch: paywall fenced off, no restore needed.
        guard Self.paywallEnabled else { return }
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            try await AppStore.sync()
            await refreshStatus()
        } catch {
            errorMessage = "Could not restore purchases. Please try again."
            debugLog("[StoreKit] Restore error: \(error)")
        }
    }

    // MARK: - Entitlement Check

    /// Refresh purchase status from verified transactions.
    ///
    /// Pre-launch the paywall is fenced off, so entitlement is always true;
    /// skipping the `Transaction.currentEntitlements` sweep also avoids any
    /// chance of triggering Apple sign-in prompts on developer builds with no
    /// signed-in Apple ID.
    func refreshStatus() async {
        guard Self.paywallEnabled else {
            isPurchased = true
            return
        }
        let sweep = await entitlementSweep()
        // Snapshot the REAL purchase state before any bypass widens it.
        // Everything after this point grants access; none of it constitutes a
        // purchase.
        hasPurchasedProduct = sweep.hasEntitlement
        let hasEntitlement = sweep.hasEntitlement || hasBypassGrant
        isPurchased = hasEntitlement
        persistPurchaseState(hasEntitlement, storeKitAnswered: sweep.storeKitAnswered)
    }

    /// `storeKitAnswered` tracks whether StoreKit actually
    /// answered. An EMPTY sweep is ambiguous: it means "never purchased" AND
    /// it means "offline / signed out of the Apple ID / StoreKit
    /// unreachable". See `persistPurchaseState` for why that matters.
    private func entitlementSweep() async -> (hasEntitlement: Bool, storeKitAnswered: Bool) {
        var hasEntitlement = false
        var storeKitAnswered = false
        for await result in Transaction.currentEntitlements {
            storeKitAnswered = true
            hasEntitlement = hasEntitlement || grantsEntitlement(result)
        }
        return (hasEntitlement, storeKitAnswered)
    }

    /// A revoked transaction, a different product, or an unverified payload all
    /// count as "no entitlement from this one".
    private func grantsEntitlement(_ result: VerificationResult<StoreKit.Transaction>) -> Bool {
        do {
            let transaction = try checkVerified(result)
            return transaction.productID == Self.productId && transaction.revocationDate == nil
        } catch {
            debugLog("[StoreKit] Unverified transaction skipped: \(error)")
            return false
        }
    }

    /// Every way access is granted without a purchase.
    ///
    /// Beta testers, permanently: `isTestFlight` covers a tester who is on a
    /// TestFlight build right now; the anchor covers that same person
    /// afterwards — on the paid App Store build, after a reinstall, or on a
    /// new phone restored from their Apple ID. Recording it here as well as in
    /// `boot()` catches the case where an entitlement refresh wins the race
    /// against boot.
    ///
    /// Developer-installed builds (Xcode Run, ad-hoc sideload, no App Store
    /// receipt) auto-grant — see `isDeveloperInstall` docs for the
    /// wife-on-DEBUG case this fixes. That path deliberately does NOT write
    /// the beta anchor: "no receipt" is a far weaker signal than "sandbox
    /// receipt", and stamping a permanent entitlement from it would
    /// grandfather every sideload and every transient first-launch receipt gap
    /// forever.
    ///
    /// The free trial is measured against the anchor's high-water mark, so
    /// winding the device clock back does not extend it. Resolved via
    /// `Self.isTrialActive` so this agrees with the launch gate and the
    /// paywall — reading the anchor alone here is what let those three
    /// disagree.
    private var hasBypassGrant: Bool {
        #if DEBUG
            if hasDebugGrant { return true }
        #endif
        return Self.isTestFlight
            || EntitlementAnchor.cached().isBetaTester
            || Self.isDeveloperInstall
            || Self.isTrialActive
    }

    /// Persist the resolved state so next launch's gate sees the
    /// last-known-good answer instantly (no need to wait for the async
    /// StoreKit refresh on the splash screen). See `isPurchased` docs for the
    /// wife-on-TestFlight bug this fixes.
    ///
    /// Never DOWNGRADE the cache on an inconclusive sweep.
    /// `isPurchased` seeds from this key on the next launch, and the hard
    /// launch gate keys off it. Writing `false` after an empty sweep means a
    /// PAYING user who opens the app offline has "not purchased" persisted,
    /// and meets a non-dismissible paywall for an app they own.
    ///
    /// Only write when the answer is trustworthy: either we found an
    /// entitlement, or StoreKit demonstrably responded (it yielded at least
    /// one transaction, so an absent entitlement is a real answer — which is
    /// how a refund still revokes access, since the revoked transaction is
    /// itself yielded).
    private func persistPurchaseState(_ hasEntitlement: Bool, storeKitAnswered: Bool) {
        guard hasEntitlement || storeKitAnswered else {
            debugLog("[StoreKit] entitlement sweep inconclusive — keeping last-known purchase state", level: .warning)
            return
        }
        UserDefaults.standard.set(hasEntitlement, forKey: Self.lastKnownPurchasedKey)
    }

    // MARK: - Transaction Listener

    /// Listen for transaction updates (refunds, family sharing changes).
    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                await self?.finishVerifiedUpdate(result)
            }
        }
    }

    /// An unverified update is skipped rather than trusted.
    private func finishVerifiedUpdate(_ result: VerificationResult<StoreKit.Transaction>) async {
        do {
            let transaction = try checkVerified(result)
            await transaction.finish()
            await refreshStatus()
        } catch {
            debugLog("[StoreKit] Unverified transaction update skipped: \(error)")
        }
    }

    // MARK: - TestFlight Detection

    /// Returns `true` when the app is running as a TestFlight beta build.
    ///
    /// **Fully synchronous, never blocks the main thread.** Calling
    /// `AppTransaction.shared` (async) on a background `Task.detached`
    /// while blocking the calling thread on a `DispatchSemaphore` for
    /// up to 500 ms would harden this (jailbreak resistance), but
    /// in practice it gates the paywall flow and on slow first launches
    /// can time out — so a legitimate TestFlight user is shown the
    /// paywall every launch (the developer's wife reported this). The
    /// risk/reward does not justify a 500ms blocking
    /// call on the splash screen.
    ///
    /// Trusts the bundle receipt URL synchronously (the standard
    /// Apple-recommended check).
    ///
    /// **No UserDefaults cache here.**
    /// A cache would conflate two different facts under one name:
    ///
    ///   • "is THIS build a TestFlight build" — a property of the running
    ///     binary, true only while a sandbox receipt is present;
    ///   • "was this Apple ID ever a beta tester" — a durable historical
    ///     fact that must outlive the TestFlight build itself.
    ///
    /// Caching the first produced the second by accident, and produced it
    /// wrongly: installing the App Store build over a TestFlight install
    /// keeps the app's data container, so the cached `true` survived into
    /// the paid build and granted a permanent free entitlement through a
    /// path with no proof behind it. `verifyAppTransactionInBackground()`
    /// could not catch it either — it only clears on `.unverified`, and a
    /// genuine App Store build verifies just fine.
    ///
    /// The two facts are now separate. This property is a pure, uncached
    /// answer about the current binary. The durable one lives in
    /// `EntitlementAnchor.isBetaTester`, is written ONLY on proof of a
    /// sandbox receipt, and is what actually grandfathers beta testers.
    static var isTestFlight: Bool {
        // Synchronous answer first — no I/O, no actor hop.
        if isDebugBuild { return false }
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    /// Whether the free trial is currently running.
    ///
    /// Single source of truth. This resolution (anchor first,
    /// settings as fallback) must not be duplicated: when `refreshStatus`
    /// read the anchor ALONE, a user whose trial start
    /// survived only in the CloudKit-mirrored settings passed the
    /// launch gate but computed `isPurchased = false`, which is one half of
    /// how a trial user can end up staring at a hard paywall.
    static var isTrialActive: Bool {
        let anchor = EntitlementAnchor.cached()
        let start = anchor.trialStartDate ?? AppDependencies.current.app.settingsManager.settings.trialStartDate
        return TrialPolicy.isActive(
            start: start,
            now: EntitlementAnchor.effectiveNow(anchor, wallClock: Date())
        )
    }

    /// Days left in the free trial, or 0 when it is not running. Resolved the
    /// same way `isTrialActive` is, so the two cannot disagree.
    static var trialDaysRemaining: Int {
        let anchor = EntitlementAnchor.cached()
        let start = anchor.trialStartDate ?? AppDependencies.current.app.settingsManager.settings.trialStartDate
        return TrialPolicy.daysRemaining(
            start: start,
            now: EntitlementAnchor.effectiveNow(anchor, wallClock: Date())
        )
    }

    /// Whether the user has access right now, by ANY route.
    ///
    /// The launch gate, `refreshStatus`, and the paywall's dismissability all
    /// have to agree on this. When they did not, tapping "Unlock Now" on the
    /// trial reminder — with days still left — presented a NON-dismissible
    /// paywall offering only Purchase and Restore, and the only ways out were
    /// buying or force-quitting the app.
    var hasActiveAccess: Bool {
        isPurchased
            || Self.isTestFlight
            || Self.isGrandfatheredBetaTester
            || Self.isDeveloperInstall
            || Self.isTrialActive
    }

    /// Access that does not expire: a real purchase, a TestFlight or
    /// grandfathered beta install, a developer install, or the debug grant.
    /// The trial is deliberately absent. `PaywallGatePolicy` uses this to keep
    /// the trial countdown away from people who will never pay.
    var hasPermanentAccess: Bool {
        #if DEBUG
            if hasDebugGrant { return true }
        #endif
        return hasPurchasedProduct
            || Self.isTestFlight
            || Self.isGrandfatheredBetaTester
            || Self.isDeveloperInstall
    }

    /// Whether this Apple ID is a grandfathered beta tester.
    ///
    /// Reads the fast UserDefaults tier of `EntitlementAnchor` so it is
    /// safe on the launch path; `boot()` reconciles it against the
    /// keychain (and therefore against every other device on this Apple
    /// ID) immediately after the first frame.
    static var isGrandfatheredBetaTester: Bool {
        EntitlementAnchor.cached().isBetaTester
    }

    /// Background sweep of `AppTransaction.shared` to confirm the build's
    /// signature. Off the splash path entirely — fires from `boot()`.
    ///
    /// On `.unverified` this clears the LEGACY TestFlight flag so a
    /// tampered device cannot have it migrated into the durable anchor on
    /// a later launch. It deliberately does NOT revoke an anchor that is
    /// already established.
    ///
    /// That asymmetry is the intended trade. The anchor is only ever
    /// written on positive proof of a sandbox receipt, whereas
    /// `.unverified` also fires for transient reasons that have nothing to
    /// do with tampering. Revoking on it would mean a genuine beta tester
    /// can permanently lose their grandfathered access to a bad network
    /// day — a far worse outcome, for a $9.99 app, than the marginal
    /// piracy it would prevent on an already-jailbroken device.
    /// Records permanent beta status ONLY for an install that originated on
    /// an earlier build than the one now running.
    ///
    /// **Not an unconditional
    /// `if isTestFlight { recordBetaTester() }`.** `isTestFlight` is a
    /// filename check for `sandboxReceipt`, and **App Review runs against a
    /// sandbox receipt too**. So the reviewer would satisfy it, be auto-granted
    /// the entitlement, and — worse — have a permanent, iCloud-Keychain-synced
    /// grandfather record written against their Apple ID.
    ///
    /// `AppTransaction.originalAppVersion` separates the two cleanly: it is
    /// the build the Apple ID FIRST obtained. App Review downloads the build
    /// under review fresh, so for them it equals the running build. A
    /// returning TestFlight tester obtained an earlier one.
    ///
    /// Compared as strings rather than parsed as numbers on purpose. Build
    /// numbers here are `run_number.run_attempt`, and a parse failure would
    /// silently drop a genuine tester's grandfathering; plain inequality has
    /// no failure mode. A tester who somehow downgrades still reads as "not
    /// this build", which is correct — they are still a tester.
    ///
    /// Record beta status for anyone running a TestFlight build.
    ///
    /// ## Why there is no build comparison
    ///
    /// Requiring `originalAppVersion != currentBuild`, on the reasoning that a
    /// first-time tester "is recorded on the next launch" and the error is
    /// self-correcting, does not work. Relaunching the same build does not
    /// change that comparison, so a tester who installs one beta, uses only
    /// that build, and then moves to the App Store never gets an anchor — and
    /// the App Store install does not satisfy `isTestFlight`, so there is no
    /// later chance to record it. README promises those people permanent free
    /// access.
    ///
    /// `isTestFlight` is the condition that actually matters: a sandbox receipt
    /// on a TestFlight build means this person is a tester. App Review also
    /// runs sandbox builds and would be anchored too — which costs nothing,
    /// since a reviewer is not a paying customer and the alternative is
    /// breaking a promise to real testers to avoid a free entitlement for a
    /// reviewer.
    @available(iOS 16.0, *)
    @MainActor
    private static func recordBetaTesterIfInstallPredatesThisBuild(_ appTransaction: AppTransaction) {
        guard isTestFlight else { return }
        _ = appTransaction
        EntitlementAnchor.recordBetaTester(wallClock: Date())
    }

    private func verifyAppTransactionInBackground() {
        guard #available(iOS 16.0, *) else { return }
        Task.detached(priority: .utility) { await Self.verifyAppTransaction() }
    }

    /// A network / sandbox failure leaves state as-is — next launch's check
    /// retries.
    @available(iOS 16.0, *)
    private static func verifyAppTransaction() async {
        do {
            switch try await AppTransaction.shared {
            case let .verified(appTransaction):
                recordBetaTesterIfInstallPredatesThisBuild(appTransaction)
            case .unverified:
                UserDefaults.standard.set(false, forKey: lastKnownTestFlightKey)
                debugLog("[StoreKit] AppTransaction unverified — legacy TestFlight flag cleared", level: .warning)
            }
        } catch {
            debugLog("[StoreKit] AppTransaction lookup failed: \(error)", level: .warning)
        }
    }

    /// Compile-time flag so `isTestFlight` excludes Xcode/debug runs.
    private static var isDebugBuild: Bool {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }

    /// Synchronous launch-gate bypass for developer-installed builds.
    ///
    /// Returns `true` for any build that's NOT a real App Store
    /// distribution — DEBUG (Xcode Run), TestFlight (sandbox receipt),
    /// or sideloaded ad-hoc (no receipt at all). The point is: if we
    /// can't prove this is a paying user from the App Store, but we
    /// also can't prove they SHOULD be paying (no receipt = not from
    /// App Store), default to "trust." This is the developer's wife
    /// case: she had a DEBUG build pushed to her phone
    /// via Xcode, no receipt, no TestFlight, no purchase → paywall
    /// blocked her launch + the StoreKit `loadProducts()` call asked
    /// her to sign in to Apple. Both wrong.
    ///
    /// In production, every paying user has a receipt → this returns
    /// `false` for them only when they're trying to use the app
    /// without paying. That case still gates correctly.
    static var isDeveloperInstall: Bool {
        if isDebugBuild { return true }
        if isTestFlight { return true }
        // No receipt at all = not from App Store + not TestFlight =
        // sideloaded developer build. Trust it.
        if Bundle.main.appStoreReceiptURL == nil { return true }
        // Receipt URL exists but the file doesn't = receipt was never
        // issued (rare, happens during App Store transitions or on
        // first launch of a freshly downloaded build before receipt
        // sync). Trust it temporarily; the cached `isPurchased` will
        // correct once `refreshStatus()` confirms.
        if let url = Bundle.main.appStoreReceiptURL,
           !FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        return false
    }

    // MARK: - Debug

    #if DEBUG
        private static let debugPurchasedKey = "debug_isPurchased"

        /// Bypass the paywall in debug builds for development testing.
        /// Persisted to UserDefaults so the flag survives app relaunches.
        func debugGrantAccess() {
            isPurchased = true
            UserDefaults.standard.set(true, forKey: Self.debugPurchasedKey)
        }

        /// Check for a persisted debug purchase flag. Called from refreshStatus()
        /// so the debug grant isn't overwritten by the StoreKit entitlement check.
        private var hasDebugGrant: Bool {
            UserDefaults.standard.bool(forKey: Self.debugPurchasedKey)
        }
    #endif

    // MARK: - Verification

    nonisolated private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case let .unverified(_, error):
            throw error
        case let .verified(value):
            return value
        }
    }
}
