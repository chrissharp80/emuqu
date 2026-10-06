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

    /// The free trial, as App Review Guideline 3.1.1 asks a paid-unlock app to
    /// offer one: a non-consumable at price tier 0 named "30-day Trial".
    /// Owning it grants nothing by itself. Its purchase date is the trial
    /// start, held by the App Store against the Apple ID, which makes it the
    /// one copy of the clock a reinstall or a new phone cannot lose.
    static let trialProductId = "com.chrissharp.flowrecovery.trial30day"

    // MARK: - Published State

    /// The product fetched from the App Store.
    private(set) var product: Product?

    /// The free trial product fetched from the App Store. Nil until loaded,
    /// and nil for good when the product is not available in this storefront.
    /// `startFreeTrial()` loads it on the tap if it has not loaded yet.
    private(set) var trialProduct: Product?

    /// Whether the user has purchased the app.
    ///
    /// Initial value comes from UserDefaults (the last purchase StoreKit
    /// confirmed). This way a paid user is never gated on the async StoreKit
    /// refresh — they get into the app instantly on every launch, and the
    /// live verification runs in the background to confirm. Every other
    /// route in is re-derived synchronously at launch, so only the purchase
    /// is cached.
    ///
    /// Why the persisted cache: StoreKit's `Transaction.currentEntitlements`
    /// is async and the paywall gate fires synchronously, so without it a
    /// buyer was shown the paywall on every launch. Persisted caching means
    /// the gate sees the LAST-KNOWN-GOOD purchase state instantly.
    private(set) var isPurchased: Bool = {
        // Escape hatch. While `paywallEnabled` is `false` this answers and
        // the cache below is not read. It exists so switching the paywall off
        // is a one-line change:
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
    /// Purchase keyed off `isPurchased`, so a user inside their trial
    /// was shown "Owned" and given no way to buy — and so was App Review,
    /// which downloads a fresh build, lands in the trial, and then cannot
    /// exercise the IAP it is there to review. That is the standard
    /// "we were unable to locate the in-app purchases" rejection.
    ///
    /// This value comes ONLY from `Transaction.currentEntitlements`. No
    /// bypass writes it.
    ///
    /// It starts from the last purchase StoreKit confirmed, which is the same
    /// value, saved. Starting from false, the launch gate ran before the
    /// first sweep and gave a buyer in the last week of their trial the daily
    /// "N days remaining" reminder.
    private(set) var hasPurchasedProduct = UserDefaults.standard.bool(forKey: StoreKitManager.lastKnownPurchasedKey)

    /// Whether a purchase or restore operation is in flight.
    private(set) var isPurchasing = false

    /// User-facing error message from the most recent failed operation.
    var errorMessage: String?

    /// A purchase that is waiting on someone else — Ask to Buy — rather than
    /// failed. Said once, so the buyer knows the tap registered.
    var purchaseNotice: String?

    /// The last product fetch failed, so the paywall can offer a retry instead
    /// of a price spinner that never stops.
    private(set) var productsUnavailable = false

    /// The last product fetch finished without the free trial product, so the
    /// paywall can offer a retry in place of a trial button that cannot work.
    private(set) var trialUnavailable = false

    /// Whether StoreKit holds a free-trial transaction for this Apple ID. Nil
    /// until the first entitlement check has run. The paywall offers the
    /// trial product whenever this is false, even when this device keeps a
    /// trial start from another Apple ID or an earlier build: buying it
    /// records a new transaction, whose purchase date becomes the trial
    /// start, so the trial runs the full thirty days. See
    /// `PaywallGatePolicy.canStartTrial`.
    private(set) var hasTrialTransaction: Bool?

    /// Bumped by every `refreshStatus()`. A refresh that finds a newer one
    /// started while it awaited StoreKit drops its answer, so a slow sweep
    /// begun before a purchase cannot overwrite the result of one begun after.
    @ObservationIgnored private var refreshGeneration = 0

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
    // ON: the paid launch. Besides a purchase, these routes keep the gate
    // off the path of anyone who should not see it:
    //
    //   • DEBUG builds        → `isDebugBuild` ⇒ `isDeveloperInstall`
    //   • Xcode installs      → `isDeveloperInstall` (verified by AppTransaction)
    //   • Beta testers        → `EntitlementAnchor.isBetaTester`, permanent,
    //                           on an install verified as production
    //   • Everyone else       → the free trial, started from the paywall
    //
    // A sandbox install (TestFlight, App Review) is none of these, even for an
    // Apple ID recorded as a beta tester: it meets the same paywall a customer
    // does, and its trial and purchase are free sandbox transactions. The
    // simulator and every UI-test run land in the first bucket, which is why
    // turning this on does not gate the XCUITest suite.
    static let paywallEnabled = true

    // MARK: - Persisted-cache keys
    //
    // `nonisolated` so they can be read from any context (e.g. the
    // detached `Task` in `check()` that runs `AppTransaction.shared` off
    // MainActor — Swift 6 strict mode would otherwise flag the access).
    // String literals are inherently safe to share.
    nonisolated private static let lastKnownPurchasedKey = "storekit.lastKnownPurchased"
    nonisolated private static let lastKnownTestFlightKey = "storekit.lastKnownTestFlight"
    /// Set when Apple has verified this install as an Xcode build. See
    /// `isDeveloperInstall`.
    nonisolated private static let verifiedXcodeInstallKey = "storekit.verifiedXcodeInstall"
    /// Set when Apple has verified this install as an App Store (production)
    /// build. See `isGrandfatheredBetaTester`.
    nonisolated private static let verifiedProductionInstallKey = "storekit.verifiedProductionInstall"

    // MARK: - Private

    @ObservationIgnored private var transactionListener: Task<Void, Never>?

    private init() {
        // Cold-start: init is a no-op. The
        // StoreKit wiring (transactionListener / refreshStatus / AppTransaction
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
    ///
    /// Reconciles the durable entitlement anchor across every tier before
    /// anything reads it. This is the step that lands a beta tester who has
    /// just restored onto a brand-new phone on the grandfathered path instead
    /// of the paywall: the keychain item is synchronizable, so it arrives with
    /// their iCloud Keychain.
    ///
    /// A sandbox receipt is not recorded as a beta tester. The beta cohort is
    /// closed, and App Review installs carry the same receipt. An anchor that
    /// earlier builds wrote on a sandbox receipt grants nothing on a sandbox
    /// install either; see `isGrandfatheredBetaTester`.
    func boot() {
        guard transactionListener == nil else { return }
        guard Self.paywallEnabled else { return }
        let now = Date()
        EntitlementAnchor.resolve(wallClock: now)
        migrateLegacyTestFlightFlag(now: now)
        transactionListener = listenForTransactions()
        Task { await refreshStatus() }
        // Background `AppTransaction` check — records an Xcode install off
        // the splash path. See `recordVerifiedEnvironment`.
        verifyAppTransactionInBackground()
    }

    /// Grandfathers anyone whose device already holds sessions the first
    /// time a non-Debug build looks, which can only mean they ran the app
    /// before it was on the store: the beta cohort. See
    /// `EntitlementAnchor.evaluatedHistory`.
    ///
    /// Sandbox builds (TestFlight, App Review) take the same one-time look as
    /// a store build: a fresh review install has no sessions and so meets the
    /// customer's paywall. Debug builds are developer installs, and the UI
    /// suites seed history on purpose, so they skip it.
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
    /// The legacy key is left in place rather than deleted. Nothing else
    /// reads it, and leaving it costs nothing
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
    /// builds (a tester's case) because StoreKit wants a signed-
    /// in Apple ID to look up products. Skipping the call entirely
    /// avoids the prompt.
    func loadProducts() async {
        guard Self.paywallEnabled else { return }
        do {
            let products = try await Product.products(for: [Self.productId, Self.trialProductId])
            product = products.first { $0.id == Self.productId }
            trialProduct = products.first { $0.id == Self.trialProductId }
            productsUnavailable = product == nil
            trialUnavailable = trialProduct == nil
        } catch {
            productsUnavailable = true
            trialUnavailable = true
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
                errorMessage = String(localized: "Unable to load product. Check your connection and try again.", bundle: LanguageManager.appBundle)
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
            try await handle(product.purchase())
        } catch StoreKitError.userCancelled {
            // Backing out of the Apple ID sign-in the purchase can raise.
            return
        } catch {
            errorMessage = String(localized: "Purchase failed. Please try again.", bundle: LanguageManager.appBundle)
            debugLog("[StoreKit] Purchase error: \(error)")
        }
    }

    private func handle(_ result: Product.PurchaseResult) async throws {
        switch result {
        case let .success(verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            await refreshStatus()
        case .pending:
            // Ask to Buy: nothing to finish yet. The approval arrives
            // through `Transaction.updates`, which refreshes access.
            purchaseNotice = String(localized: "Your purchase is waiting for approval. Emuqu unlocks as soon as it's approved.", bundle: LanguageManager.appBundle)
        case .userCancelled:
            return
        @unknown default:
            return
        }
    }

    // MARK: - Free trial

    /// Starts the free trial by "buying" the free trial product, so the App
    /// Store records when it began.
    ///
    /// Guideline 3.1.1 sanctions a time-based trial for a paid-unlock app only
    /// as that $0 non-consumable, so there is no other way in: a trial product
    /// that cannot be loaded, or a purchase that fails, is reported like any
    /// other failed purchase and starts nothing.
    func startFreeTrial() async {
        guard Self.paywallEnabled, let trialProduct = await loadedTrialProduct() else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            try await handleTrial(trialProduct.purchase())
        } catch StoreKitError.userCancelled {
            // Backing out of the Apple ID sign-in the purchase can raise.
            return
        } catch {
            errorMessage = String(localized: "Purchase failed. Please try again.", bundle: LanguageManager.appBundle)
            debugLog("[StoreKit] Trial purchase error: \(error)")
        }
    }

    /// `.userCancelled` starts nothing. `.pending` (Ask to Buy) starts nothing
    /// yet, and says so: the approval arrives through `Transaction.updates`,
    /// and `refreshStatus` adopts the trial's start from it.
    ///
    /// The App Store sells the trial once per Apple ID. When StoreKit had not
    /// yet said this Apple ID already owns it (signed out until the tap), the
    /// purchase hands back the original transaction, whose start may be long
    /// past; the buyer is then told the trial has ended rather than left
    /// looking at a purchase that did nothing.
    private func handleTrial(_ result: Product.PurchaseResult) async throws {
        if case .pending = result {
            purchaseNotice = String(localized: "Your free trial is waiting for approval. It starts as soon as it's approved.", bundle: LanguageManager.appBundle)
        }
        guard case let .success(verification) = result else { return }
        let transaction = try checkVerified(verification)
        Self.adoptStoreTrialStart(transaction.purchaseDate)
        await transaction.finish()
        await refreshStatus()
        if !hasActiveAccess {
            purchaseNotice = String(localized: "Your free trial has ended. Unlock Emuqu to keep recording and to see your scores and history again. Everything you recorded is kept.", bundle: LanguageManager.appBundle)
        }
    }

    /// The App Store's trial start becomes the trial clock: recorded in the
    /// anchor, where it replaces a start an earlier build kept on this device,
    /// then mirrored into the synced settings.
    private static func adoptStoreTrialStart(_ start: Date) {
        EntitlementAnchor.recordStoreTrialStart(start, wallClock: Date())
        AppDependencies.current.app.settingsManager.adoptTrialStart(start)
    }

    /// The trial product, fetched on the tap if the paywall has not loaded it.
    /// Nil, with the reason already shown, when the App Store has no answer.
    private func loadedTrialProduct() async -> Product? {
        if trialProduct == nil { await loadProducts() }
        if trialProduct == nil {
            errorMessage = String(localized: "Unable to load product. Check your connection and try again.", bundle: LanguageManager.appBundle)
        }
        return trialProduct
    }

    // MARK: - Restore

    /// What the Restore tap found, for the screen that started it to show: a
    /// Restore that answered silently read as a dead button. Nil when there is
    /// nothing to say — the paywall is off, or the user cancelled the Apple ID
    /// sign-in themselves.
    func restore() async -> String? {
        // Pre-launch: paywall fenced off, no restore needed.
        guard Self.paywallEnabled else { return nil }
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            try await AppStore.sync()
            await refreshStatus()
            return hasPurchasedProduct
                ? String(localized: "Your purchase has been restored.", bundle: LanguageManager.appBundle)
                : String(localized: "No purchase of Emuqu was found for this Apple ID.", bundle: LanguageManager.appBundle)
        } catch StoreKitError.userCancelled {
            return nil
        } catch {
            debugLog("[StoreKit] Restore error: \(error)")
            return String(localized: "Could not restore purchases. Please try again.", bundle: LanguageManager.appBundle)
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
        refreshGeneration += 1
        let generation = refreshGeneration
        let sweep = await entitlementSweep()
        guard generation == refreshGeneration else { return }
        apply(sweep)
    }

    /// Writes one entitlement sweep's answer into the published state.
    private func apply(_ sweep: EntitlementSweep) {
        if let trialStart = sweep.trialStart {
            Self.adoptStoreTrialStart(trialStart)
        }
        hasTrialTransaction = sweep.hasTrialTransaction
        guard sweep.storeKitAnswered else {
            // Inconclusive: StoreKit had nothing to say (signed out of Media &
            // Purchases, another Apple ID, Family Sharing withdrawn). The last
            // purchase it confirmed still stands — for this session as well as
            // the next launch, or a buyer meets the undismissible gate — while
            // every other route is re-derived now, so an ended trial still ends.
            isPurchased = Self.lastConfirmedPurchase || hasBypassGrant
            debugLog("[StoreKit] entitlement sweep inconclusive — keeping last-known purchase state", level: .warning)
            return
        }
        // Snapshot the REAL purchase state before any bypass widens it.
        // Everything after this point grants access; none of it constitutes a
        // purchase.
        hasPurchasedProduct = sweep.hasEntitlement
        isPurchased = sweep.hasEntitlement || hasBypassGrant
        UserDefaults.standard.set(sweep.hasEntitlement, forKey: Self.lastKnownPurchasedKey)
    }

    /// The last purchase StoreKit confirmed on this device.
    private static var lastConfirmedPurchase: Bool {
        UserDefaults.standard.bool(forKey: lastKnownPurchasedKey)
    }

    /// `storeKitAnswered` tracks whether StoreKit actually
    /// answered. An EMPTY sweep is ambiguous: it means "never purchased" AND
    /// it means "offline / signed out of the Apple ID / StoreKit
    /// unreachable". `refreshStatus` keeps the last confirmed purchase when it is.
    ///
    /// `trialStart` is the purchase date of the free trial product, when this
    /// Apple ID has one: the trial clock as the App Store recorded it.
    /// `hasTrialTransaction` is whether StoreKit knows of any trial
    /// transaction for this Apple ID.
    private func entitlementSweep() async -> EntitlementSweep {
        var sweep = EntitlementSweep()
        for await result in Transaction.currentEntitlements {
            sweep.storeKitAnswered = true
            sweep.hasEntitlement = sweep.hasEntitlement || grantsEntitlement(result)
            sweep.trialStart = sweep.trialStart ?? trialStartDate(result)
        }
        // A refunded purchase leaves `currentEntitlements`, so a buyer who never
        // took the trial would look exactly like someone StoreKit cannot reach.
        // The unlock's latest transaction tells the two apart: StoreKit knows
        // this Apple ID bought it, and the entitlement is gone.
        if !sweep.storeKitAnswered, await Transaction.latest(for: Self.productId) != nil {
            sweep.storeKitAnswered = true
        }
        if sweep.trialStart != nil {
            sweep.hasTrialTransaction = true
        } else {
            sweep.hasTrialTransaction = await Transaction.latest(for: Self.trialProductId) != nil
        }
        return sweep
    }

    /// One entitlement check's answer. See `entitlementSweep`.
    private struct EntitlementSweep {
        var hasEntitlement = false
        var storeKitAnswered = false
        var trialStart: Date?
        var hasTrialTransaction = false
    }

    private func trialStartDate(_ result: VerificationResult<StoreKit.Transaction>) -> Date? {
        guard case let .verified(transaction) = result, transaction.productID == Self.trialProductId else { return nil }
        return transaction.purchaseDate
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
    /// Beta testers, permanently, through the anchor — on the App Store
    /// build, after a reinstall, or on a new phone restored from their Apple
    /// ID. See `isGrandfatheredBetaTester`.
    ///
    /// Developer-installed builds (DEBUG, or an Xcode install Apple has
    /// verified) auto-grant — see `isDeveloperInstall` docs for the
    /// tester-on-DEBUG case this fixes. That path deliberately does NOT write
    /// the beta anchor: a developer install is not a beta tester, and
    /// stamping a permanent entitlement from it would follow that Apple ID
    /// onto the App Store build forever.
    ///
    /// The free trial is measured against the anchor's high-water mark, so
    /// winding the device clock back does not extend it. Resolved via
    /// `Self.isTrialActive` so this agrees with the launch gate and the
    /// paywall — reading the anchor alone here is what let those three
    /// disagree.
    ///
    /// `-UITests-ForcePaywall` removes every route but the Skip (Debug) grant,
    /// as the launch gate does. Without it the launch refresh re-derived the
    /// developer-install route, flipped `isPurchased`, and the purchase
    /// handler took the gate down before it ever drew.
    private var hasBypassGrant: Bool {
        if hasPermanentGrant { return true }
        return !UITestLaunchArguments.forcesPaywall && Self.isTrialActive
    }

    /// The routes in that need no purchase and never expire: a grandfathered
    /// beta tester, a developer install, the debug grant. Honors
    /// `-UITests-ForcePaywall` the same way `hasBypassGrant` does.
    private var hasPermanentGrant: Bool {
        #if DEBUG
            if hasDebugGrant { return true }
        #endif
        if UITestLaunchArguments.forcesPaywall { return false }
        return Self.isGrandfatheredBetaTester || Self.isDeveloperInstall
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

    // MARK: - Trial

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

    /// When the free trial started, as this device keeps it: the durable
    /// anchor first, the synced settings as fallback. Nil when no trial
    /// start is kept here.
    static var localTrialStart: Date? {
        EntitlementAnchor.cached().trialStartDate
            ?? AppDependencies.current.app.settingsManager.settings.trialStartDate
    }

    /// Whether this device keeps a trial start, by any route.
    static var hasTrialStarted: Bool {
        localTrialStart != nil
    }

    /// The time the trial clock reads: the wall clock, never earlier than the
    /// anchor's high-water mark, so winding the device clock back does not
    /// stretch the trial.
    static var trialClockNow: Date {
        EntitlementAnchor.effectiveNow(EntitlementAnchor.cached(), wallClock: Date())
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
        isPurchased || hasBypassGrant
    }

    /// Access that does not expire: a real purchase, a grandfathered beta
    /// tester, a developer install, or the debug grant. The trial is
    /// deliberately absent. `PaywallGatePolicy` uses this to keep the trial
    /// countdown away from people who will never pay. It does not end the
    /// paywall's offer: only `hasPurchasedProduct` does.
    var hasPermanentAccess: Bool {
        hasPurchasedProduct || hasPermanentGrant
    }

    /// Whether this Apple ID is a grandfathered beta tester on an install
    /// where that grants access.
    ///
    /// Reads the fast UserDefaults tier of `EntitlementAnchor` so it is
    /// safe on the launch path; `boot()` reconciles it against the
    /// keychain (and therefore against every other device on this Apple
    /// ID) immediately after the first frame.
    ///
    /// Honoured only once `AppTransaction` has verified this install as an
    /// App Store (production) build. App Review and TestFlight both run in
    /// the sandbox environment and no API tells them apart, so a sandbox
    /// install, where earlier builds anchored App Review's Apple IDs, meets
    /// the customer's paywall. A tester's first launch of the App Store build
    /// shows the paywall until that check lands a moment later and the
    /// entitlement refresh takes it down.
    static var isGrandfatheredBetaTester: Bool {
        PaywallGatePolicy.grantsBetaTesterAccess(
            isAnchoredBetaTester: EntitlementAnchor.cached().isBetaTester,
            isVerifiedProductionInstall: UserDefaults.standard.bool(forKey: verifiedProductionInstallKey))
    }

    /// Background sweep of `AppTransaction.shared` to learn which
    /// environment signed this build. Off the splash path entirely — fires
    /// from `boot()`.
    ///
    /// On `.unverified` this clears the LEGACY TestFlight flag so a
    /// tampered device cannot have it migrated into the durable anchor on
    /// a later launch. It deliberately does NOT revoke an anchor that is
    /// already established.
    ///
    /// That asymmetry is the intended trade. The anchor is only ever
    /// written on positive proof of beta use, whereas
    /// `.unverified` also fires for transient reasons that have nothing to
    /// do with tampering. Revoking on it would mean a genuine beta tester
    /// can permanently lose their grandfathered access to a bad network
    /// day — a far worse outcome, for a one-time purchase, than the marginal
    /// piracy it would prevent on an already-jailbroken device.
    ///
    /// An Xcode install is recorded as a developer install, and only a
    /// production install clears that record. A production install is
    /// recorded as one, which is what lets a grandfathered beta tester in;
    /// a sandbox or Xcode install clears it.
    private static func recordVerifiedEnvironment(_ appTransaction: AppTransaction) {
        let environment = appTransaction.environment
        if let isXcode = verifiedXcodeInstall(for: environment) {
            setVerifiedFlag(isXcode, forKey: verifiedXcodeInstallKey)
        }
        if let isProduction = verifiedProductionInstall(for: environment) {
            setVerifiedFlag(isProduction, forKey: verifiedProductionInstallKey)
        }
    }

    private static func setVerifiedFlag(_ verified: Bool, forKey key: String) {
        if verified {
            UserDefaults.standard.set(true, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// What a verified environment says about the beta-tester route: true for
    /// production, false for sandbox and Xcode, nil for an environment this
    /// build does not know.
    nonisolated static func verifiedProductionInstall(for environment: AppStore.Environment) -> Bool? {
        switch environment {
        case .production: true
        case .sandbox, .xcode: false
        default: nil
        }
    }

    /// What a verified environment says about the developer-install route:
    /// true for Xcode, false for production, nil for no change. Sandbox
    /// (TestFlight and App Review alike) is nil: it grants nothing, so a
    /// reviewer meets the paywall a customer meets. No API tells a reviewer
    /// from a tester, and the beta cohort is already anchored.
    nonisolated static func verifiedXcodeInstall(for environment: AppStore.Environment) -> Bool? {
        switch environment {
        case .xcode: true
        case .production: false
        default: nil
        }
    }

    private func verifyAppTransactionInBackground() {
        Task.detached(priority: .utility) { await Self.verifyAppTransaction() }
    }

    /// A network / sandbox failure leaves state as-is — next launch's check
    /// retries. A verified environment can open a route the launch gate
    /// could not see yet, so the entitlement is refreshed after it; the
    /// `isPurchased` flip then takes down a paywall that no longer applies.
    private static func verifyAppTransaction() async {
        do {
            switch try await AppTransaction.shared {
            case let .verified(appTransaction):
                recordVerifiedEnvironment(appTransaction)
                await AppDependencies.current.services.storeKitManager.refreshStatus()
            case .unverified:
                UserDefaults.standard.set(false, forKey: lastKnownTestFlightKey)
                debugLog("[StoreKit] AppTransaction unverified — legacy TestFlight flag cleared", level: .warning)
            }
        } catch {
            debugLog("[StoreKit] AppTransaction lookup failed: \(error)", level: .warning)
        }
    }

    /// Compile-time flag for Xcode/debug runs.
    private static var isDebugBuild: Bool {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }

    /// Synchronous launch-gate bypass for developer-installed builds.
    ///
    /// True for DEBUG builds (Xcode Run) and any install Apple has verified as
    /// an Xcode build. A sandbox receipt is not one: TestFlight and App Review
    /// installs carry it, and both meet the customer's paywall. This is
    /// the case of a tester who had a DEBUG build pushed to their phone
    /// via Xcode, no receipt, no TestFlight, no purchase → paywall blocked their
    /// launch + the StoreKit `loadProducts()` call asked them to sign in to
    /// Apple. Both wrong.
    ///
    /// Every route here is positive evidence. A missing App Store receipt is
    /// not: StoreKit 2 does not promise the file exists, so reading its
    /// absence as a sideload handed the app to any App Store customer whose
    /// receipt had not landed.
    static var isDeveloperInstall: Bool {
        if isDebugBuild { return true }
        return UserDefaults.standard.bool(forKey: verifiedXcodeInstallKey)
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
