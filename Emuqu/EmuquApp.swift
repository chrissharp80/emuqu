import AVFoundation
import CoreLocation
import os.signpost
import SwiftUI

/// Cold-start signpost log: makes the launch-path
/// init cost measurable in Instruments → App Launch / Logging templates.
/// Hardware and network work is kept out of those inits and deferred to each
/// singleton's `boot()`; see the cold-launch note above `EmuquApp`.
private let coldStartLog = OSLog(subsystem: "com.chrissharp.flowrecovery", category: "ColdStart")

@inline(__always)
private func signpostStart(_ name: StaticString) -> OSSignpostID {
    let id = OSSignpostID(log: coldStartLog)
    os_signpost(.begin, log: coldStartLog, name: name, signpostID: id)
    return id
}

@inline(__always)
private func signpostEnd(_ name: StaticString, _ id: OSSignpostID) {
    os_signpost(.end, log: coldStartLog, name: name, signpostID: id)
}

/// Which full-screen modal is currently presented (only one at a time).
enum LaunchModal: Identifiable {
    case disclaimer
    case onboarding
    case paywall
    case trialReminder
    /// One-time disclosure for the recovery-score
    /// architecture change (HRV/Sleep/Training → HRV/Sleep/Vitals).
    /// Triggered once for upgrading users via the
    /// `hasAcknowledgedScoreArchitectureChange` flag in UserSettings.
    case scoreArchitectureChange

    var id: String {
        switch self {
        case .disclaimer: return "disclaimer"
        case .onboarding: return "onboarding"
        case .paywall: return "paywall"
        case .trialReminder: return "trialReminder"
        case .scoreArchitectureChange: return "scoreArchitectureChange"
        }
    }
}

/// Info about a session that was in progress when the app was killed.
struct InterruptedSessionInfo {
    let sessionId: UUID
    let startTime: Date
    let sessionType: SessionType

    /// Resume only makes sense if the session is recent enough to continue.
    /// After the threshold, the recording gap is too large to produce a meaningful merged result.
    ///
    /// Workouts always route to the non-resumable alert: true resume
    /// would require re-binding live sensors (Polar reconnect, GPS
    /// restart, background audio, foot-pod, voice coach), which the
    /// post-crash launch path can't reliably reconstruct without going
    /// through the live `WorkoutRecorder.start()` pipeline. The user is
    /// offered "Save what was captured" instead — a much smaller
    /// surface area, and the partial session lands in the dashboard
    /// the same way a normal completion would.
    var isResumable: Bool {
        guard sessionType != .workout else { return false }
        return Date().timeIntervalSince(startTime) < SessionConstants.maxResumableSessionAge
    }
}

// Cold-launch init strategy: the heavy singletons do no I/O in `init()`. Each
// has a lightweight `init()` (assign properties; no BLE / CloudKit / StoreKit /
// WCSession work) plus a `func boot()` that performs the hardware / network
// setup AFTER the first frame paints. `boot()` is fired from the root `.task`
// in `body` (see the boot cascade lower down): `watchBridge`, `collector`,
// `syncManager`, `storeKitManager`, `voiceChat`. `PolarManager` defers its
// CoreBluetooth build to `ensureApiReady()`, which runs on the first scan or
// connect — never at launch (see `RRCollector.boot()` for why). `collector`,
// `settingsManager`, and `languageManager` stay eager because the first frame
// needs them.
//
// Synchronous BLE / CKContainer / WCSession work inside a singleton init would
// hold the launch before first paint; the `os_signpost` instrumentation on
// every init (category `ColdStart`) is the measurement surface for
// time-to-first-frame.
//
// Every service below comes from the composition root,
// `AppDependencies.current`, so a substitute a test installs there is the one
// the app holds.
struct EmuquApp: App {
    @State var collector = launchStep("collector", "init.collector") { RRCollector.makeDefault() }
    /// Saved-session reanalysis, built at launch so its rescore, CloudKit
    /// backfill and HealthKit-sleep listeners are installed before any
    /// notification they answer can arrive. It shares the collector's
    /// baseline tracker, archive signal and scoring context.
    @State var reanalysis = launchStep("reanalysis", "init.reanalysis") {
        AppDependencies.current.collection.sessionReanalysis
    }
    @State var syncManager = launchStep("syncManager", "init.cloudKitSyncManager") {
        AppDependencies.current.storage.cloudKitSyncManager
    }
    @State var settingsManager = launchStep("settingsManager", "init.settingsManager") {
        AppDependencies.current.app.settingsManager
    }
    @State var storeKitManager = launchStep("storeKitManager", "init.storeKitManager") {
        AppDependencies.current.services.storeKitManager
    }
    @State var languageManager = launchStep("languageManager", "init.languageManager") {
        AppDependencies.current.services.languageManager
    }
    /// App-wide voice chat controller. Lives at the root so any surface
    /// (Fitness, Assistant tab, Dashboard) can invoke the same conversation.
    /// One instance for the process — the class owns hardware resources (mic,
    /// synth) that can't be duplicated, and the Watch-trigger path targets
    /// it by design.
    @State var voiceChat = launchStep("voiceChat", "init.voiceChat") {
        AppDependencies.current.assistant.voiceConversationController
    }
    /// Watch bridge — held here so the Watch-triggered voice-chat
    /// closure is wired before any Watch message can arrive.
    @State var watchBridge = launchStep("watchBridge", "init.watchBridge") {
        AppDependencies.current.services.watchConnectivityBridge
    }
    /// Observed at app root so the auto Coach Report
    /// (and any other staged email draft) pops the composer no matter
    /// which tab is active. AssistantChatView still observes for the
    /// chat-tab-local case; the sheet item binding is single-fire and
    /// the bridge is shared, so two `.sheet(item:)` modifiers across
    /// the tree behave correctly — only one presents at a time.
    @State private var emailBridge = AppDependencies.current.assistant.assistantEmailBridge
    /// The services the launch work in `AppLaunchTasks.swift` uses. Taking
    /// them resolves nothing: each is built when that work first reaches it.
    let launchServices = AppDependencies.current.launchServices
    @State var isLoading = true
    @State var activeModal: LaunchModal?
    /// Set by onboarding's "Take a reading", taken by `MainTabView`.
    @State var requestedTab: MainTabView.Tab?
    @State var dataLoaded = false
    @State var interruptedSessionAlert: InterruptedSessionInfo?
    @State var recoveryResultMessage: String?
    /// Set when the scene goes to the background, cleared once it is active
    /// again. A return goes background → inactive → active, so the
    /// transition `handleScenePhaseChange` sees on arrival starts at
    /// `.inactive`; this remembers where it came from.
    @State private var returningFromBackground = false
    @Environment(\.scenePhase) private var scenePhase

    // MARK: Launch diagnostics

    /// Builds one root-level `@State` object, logging entry and exit and
    /// bracketing it with a `ColdStart` signpost, so a launch that stalls in
    /// one of these initialisers shows in the log which step ran last.
    ///
    /// NSLog so the lines survive TestFlight builds, which drop the print() in
    /// `debugLog`; `debugLog` still buffers them in memory, and on disk when
    /// persistent logging is on.
    private static func launchStep<Service>(
        _ name: String, _ signpost: StaticString, build: () -> Service
    ) -> Service {
        let id = signpostStart(signpost)
        NSLog("[App][launch] @State %@ — start", name)
        debugLog("[App][launch] @State \(name) init starting", level: .info)
        let service = build()
        NSLog("[App][launch] @State %@ — done", name)
        debugLog("[App][launch] @State \(name) init complete", level: .info)
        signpostEnd(signpost, id)
        return service
    }

    init() {
        // First-line log so we have a known starting point for the
        // launch trace even when the app hangs before the body renders.
        // NSLog (vs debugLog's print) so it survives Release builds and
        // shows up in Console.app for TestFlight diagnostics.
        NSLog("[App][launch] EmuquApp.init() — entry")
        debugLog("[App][launch] EmuquApp.init() entry", level: .info)
        Self.observeMemoryWarnings()
        // A share sheet from the previous run may have left its export file
        // (`ShareLink` reports no completion); nothing can still read it now.
        // A few files in tmp, removed before any export of this run exists.
        ExportFile.removeLeftovers()
        NSLog("[App][launch] EmuquApp.init() — exit")
        debugLog("[App][launch] EmuquApp.init() exit; the stored-property singletons are already built", level: .info)
    }

    /// Crash and system-diagnostics handlers, installed from `EmuquMain.main()`
    /// before any stored-property initialiser builds a singleton, so a crash
    /// while those load (the "hung on splash" family) still leaves a crash
    /// log for the next launch.
    ///
    /// `SystemDiagnosticsManager` wires up MetricKit plus
    /// memory/thermal sampling, so the next time iOS SIGKILLs the app we know
    /// exactly which budget was exceeded (memory pressure vs background-task
    /// assertion timeout vs CPU resource limit vs watchdog) instead of
    /// guessing. Payloads from previous terminations land here on the next
    /// launch via MXMetricManager's daily delivery.
    static func installDiagnostics() {
        let utilities = AppDependencies.current.app
        utilities.crashLogManager.install()
        utilities.systemDiagnosticsManager.install()
    }

    /// Drop the DFT cache under memory pressure.
    private static func observeMemoryWarnings() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            FrequencyDomainAnalyzer.teardownDFTCache()
        }
    }

    var body: some Scene {
        WindowGroup {
            appRootView
        }
    }

    /// The app's root view, assembled in stages.
    ///
    /// ## Why this is split up
    ///
    /// The root is `MainTabView(…)` followed by ten environment injections,
    /// two presentation modifiers, five `onChange` handlers, three alerts and
    /// five `task`s. Swift type-checks a member chain as a single constraint
    /// system, and the cost grows super-linearly in its length: as one chain
    /// it costs seconds of every incremental build, and a little longer it
    /// fails with "unable to type-check this expression in reasonable time".
    ///
    /// Each stage below is its own statement, so the type-checker solves five
    /// small systems instead of one large one. `stage(x)` applies precisely
    /// the modifiers `x.…` would, in the same order, so the concrete view type
    /// — and therefore SwiftUI's view identity and modifier order — is the
    /// same as the single chain's.
    private var appRootView: some View {
        let environment = environmentInjected(rootTabView)
        let presented = modalPresentations(environment)
        let observed = stateChangeHandlers(presented)
        let alerting = interruptedSessionAlerts(observed)
        return launchTasks(alerting)
    }

    /// The tab bar itself, seeded from the synchronously-loaded archive index.
    ///
    /// Always `MainTabView`, never a SwiftUI splash in front of it. A body of
    /// the form `if isLoading { splash } else { MainTabView() }` failed to
    /// swap views on a tester's iPhone 11 (iOS 18, Japanese locale): the
    /// `@State` mutation ran, but neither the splash's `onDisappear` nor the
    /// tab view's `onAppear` ever fired, and the cause was never isolated.
    /// iOS already shows the Info.plist launch image during cold launch,
    /// which is the splash from the user's perspective; the disclaimer and
    /// onboarding covers present over the tab view for new users, and the
    /// dashboard renders its own loading states for slow data.
    ///
    /// `isLoading` drives only the launch-trace logging and the safety
    /// timeout; nothing in the view tree branches on it.
    private var rootTabView: some View {
        MainTabView(
            initialSessionCount: collector.archive.entries.count,
            // Cold-start hero-score seed from the synchronously-loaded
            // index, so the ring paints the last score immediately instead
            // of blank until the async session decrypt lands.
            initialSeedScore: DashboardSessionPolicy.latestOvernightScore(
                inEntries: collector.archive.entries, calendar: .current
            ),
            // Cold-start seed for the rest of the summary (HRV/Sleep chips,
            // Recent strip) from the same synchronous index.
            initialSeedSummary: DashboardSessionPolicy.dashboardSummarySeed(
                inEntries: collector.archive.entries, today: Date(), calendar: .current
            ),
            requestedTab: $requestedTab
        )
    }

    /// Shared objects every screen reads, plus locale and colour scheme.
    private func environmentInjected(_ content: some View) -> some View {
        content
            .environment(collector)
            .environment(collector.archiveSignal)
            .environment(collector.deviceStatus)
            .environment(collector.streamingLifecycle)
            .environment(collector.morningCoordination)
            .environment(collector.sessionState)
            .environment(syncManager)
            .environment(languageManager)
            .environment(settingsManager)
            .environment(voiceChat)
            .environment(\.locale, languageManager.currentLocale)
            .environment(\.layoutDirection, languageManager.layoutDirection)
            .preferredColorScheme(settingsManager.settings.appearanceTheme == .light ? .light : .dark)
    }

    /// Full-screen onboarding/paywall flow and the app-level mail composer.
    private func modalPresentations(_ content: some View) -> some View {
        content
            // The cover sits outside `environmentInjected`, so it gets the
            // shared objects and the app language here. The paywall gate's
            // Your Data sheet opens Export and Delete All Data, which read
            // the collector and settings.
            .fullScreenCover(item: $activeModal) { environmentInjected(launchModal($0)) }
            .environment(storeKitManager)
            // App-root observer for the email bridge.
            // Lets the auto Coach Report pop the composer no
            // matter which tab is active.
            .sheet(item: $emailBridge.pendingDraft) { mailComposer(for: $0) }
    }

    /// The view behind each full-screen launch modal.
    @ViewBuilder
    private func launchModal(_ modal: LaunchModal) -> some View {
        switch modal {
        case .disclaimer:
            HealthDisclaimerView()
                .environment(settingsManager)
        case .onboarding:
            OnboardingView(onTakeReading: { requestedTab = .record })
                .environment(collector)
                .environment(settingsManager)
        case .paywall:
            PaywallView(isGate: true)
        case .trialReminder:
            TrialReminderView()
                .environment(settingsManager)
        case .scoreArchitectureChange:
            ScoreArchitectureChangeSheet(isPresented: scoreArchitectureChangeBinding)
                .environment(settingsManager)
        }
    }

    /// Presentation state for the score-architecture sheet.
    ///
    /// Dismissal is where the work happens, so this is a `Binding` rather than
    /// a plain `$activeModal` comparison: acknowledging the change has to be
    /// recorded whichever way the sheet closes.
    private var scoreArchitectureChangeBinding: Binding<Bool> {
        Binding(
            get: { activeModal == .scoreArchitectureChange },
            set: { isPresented in
                guard !isPresented else { return }
                settingsManager.settings.hasAcknowledgedScoreArchitectureChange = true
                activeModal = nil
            }
        )
    }

    /// The mail composer the assistant's email bridge raises.
    private func mailComposer(for draft: AssistantEmailDraft) -> some View {
        MailComposerView(
            subject: draft.subject,
            body: draft.body,
            recipients: draft.recipients,
            ccRecipients: draft.ccRecipients,
            attachmentURL: draft.attachmentURL,
            onDismiss: { emailBridge.clear() }
        )
    }

    /// Reactions to state owned elsewhere: disclaimer, onboarding, purchase,
    /// and the scene phase transitions that drive sync and prewarming.
    private func stateChangeHandlers(_ content: some View) -> some View {
        content
            .onChange(of: settingsManager.hasAcceptedDisclaimer) { _, accepted in
                handleDisclaimerAcceptance(accepted)
            }
            .onChange(of: settingsManager.settings.hasCompletedOnboarding) { _, completed in
                handleOnboardingCompletion(completed)
            }
            .onChange(of: storeKitManager.isPurchased) { _, purchased in
                handlePurchaseChange(purchased)
            }
            .onChange(of: activeModal) { oldModal, newModal in
                handleLaunchModalChange(from: oldModal, to: newModal)
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                handleScenePhaseChange(from: oldPhase, to: newPhase)
            }
    }

    private func handleDisclaimerAcceptance(_ accepted: Bool) {
        guard accepted else { return }
        NSLog("[App][launch] disclaimer accepted — calling loadDataAndContinue()")
        debugLog("[App][launch] disclaimer accepted — dismissing modal, calling loadDataAndContinue()", level: .info)
        // Disclaimer just accepted — dismiss it, then load data + check onboarding
        activeModal = nil
        loadDataAndContinue()
    }

    /// A new user with no other route in goes straight from onboarding to
    /// the paywall, where "Start Free Trial" is the first button. Everyone
    /// else (a beta tester re-onboarding, a developer install) lands in the
    /// app.
    private func handleOnboardingCompletion(_ completed: Bool) {
        guard completed else { return }
        guard StoreKitManager.paywallEnabled, !storeKitManager.hasActiveAccess else {
            activeModal = nil
            return
        }
        activeModal = .paywall
    }

    private func handlePurchaseChange(_ purchased: Bool) {
        guard StoreKitManager.paywallEnabled else { return }
        if purchased && activeModal == .paywall {
            activeModal = nil
        }
    }

    /// The launch gate stops at the paywall or the trial reminder before it
    /// checks for an interrupted recording, and the check holds its alert
    /// while the score-architecture disclosure is on screen, so that check
    /// runs once the gate closes instead: when any of those is dismissed with
    /// nothing after it.
    private func handleLaunchModalChange(from oldModal: LaunchModal?, to newModal: LaunchModal?) {
        guard newModal == nil,
              oldModal == .paywall || oldModal == .trialReminder || oldModal == .scoreArchitectureChange else { return }
        checkForInterruptedSession()
    }

    /// Everything the app does on a foreground/background transition.
    ///
    /// Each step is its own method below; they are unrelated to one another and
    /// share only a trigger. The return-from-background steps (sync, the
    /// entitlement re-check) key off `returningFromBackground`, not
    /// `oldPhase`, which is `.inactive` by the time the scene is active.
    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        if newPhase == .background {
            returningFromBackground = true
            autoArchivePendingSession()
            AppDependencies.current.location.ambientLocationService.stop()
        }
        if newPhase == .active && oldPhase != .active {
            startAmbientLocationOnForeground()
        }
        guard newPhase == .active else { return }
        rescheduleMorningNotification()
        if settingsManager.settings.hasCompletedOnboarding {
            refreshHealthKitWriteAuthorization()
        }
        if returningFromBackground {
            resumeAfterBackground()
        }
    }

    /// The first active phase after a background: clears the mark, resumes
    /// sync and re-checks the entitlement.
    private func resumeAfterBackground() {
        returningFromBackground = false
        resumeSyncOnForeground()
        recheckEntitlementOnForeground()
    }

    /// A trial ends, or a refund lands, while the process stays alive: an
    /// overnight recording or a workout keeps it running for hours, and the
    /// launch gate was the only thing that ever locked the app. Checked again
    /// on every return from the background — never over a recording in
    /// progress, which would lose the user their night or their workout.
    private func recheckEntitlementOnForeground() {
        guard StoreKitManager.paywallEnabled, dataLoaded, !isRecordingInProgress else { return }
        refreshPurchaseEntitlementsInBackground()
    }

    private var isRecordingInProgress: Bool {
        collector.isCollecting || isWorkoutInProgress
    }

    /// A workout is recording or still being saved on the phone.
    private var isWorkoutInProgress: Bool {
        switch AppDependencies.current.app.recorderBox.recorder?.phase {
        case .recording?, .finalizing?: return true
        default: return false
        }
    }

    /// Ambient location starts at foreground, not lazily on Coach
    /// open, so the cache is warm by the time the AI assistant is asked about
    /// location, during workouts or outside them.
    ///
    /// The cold-launch cost this gets blamed for is the geocoder prewarm, not
    /// `startUpdatingLocation()` itself. The geocoder path uses MKLocalSearch
    /// map tiles first (sub-second) with CLGeocoder only as fallback, and
    /// respects the cross-call 1 s rate floor. Net cost of starting the stream
    /// at foreground is the same 100 mW the workout / Get-Me-Back paths already
    /// pay — negligible. Backgrounding still tears down.
    ///
    /// Never prompts, and runs only for a feature that uses the fix. A
    /// foreground transition is not a user action: `start()` here would show the
    /// location permission prompt on first launch, over onboarding, with
    /// nothing on screen saying what it was for. The prompt comes from the
    /// features that need it (an assistant question that needs a fix, Get Me
    /// Back, workouts); this only resumes a permission already given, and only
    /// for the assistant. Heat tracking reads the weather saved with each
    /// workout, so it needs no location of its own.
    private func startAmbientLocationOnForeground() {
        let settings = settingsManager.settings
        guard settings.hasCompletedOnboarding,
              settings.enableAIAssistant else { return }
        AppDependencies.current.location.ambientLocationService.startIfAuthorized()
    }

    /// Auto-archive a pending session when the app goes to the background, so
    /// the recording is not lost if the user forgets to accept it. Acceptance
    /// runs HealthKit reads, analysis and archive writes after the app has left
    /// the screen, so it holds a background-task assertion until it finishes;
    /// running out of budget suspends the app instead of getting it killed.
    private func autoArchivePendingSession() {
        guard collector.needsAcceptance else { return }
        let backgroundTask = BackgroundTaskAssertion(name: "EmuquApp.autoArchivePendingSession")
        Task {
            defer { backgroundTask.end() }
            do {
                try await collector.acceptSession()
                debugLog("[App] Auto-archived pending session on background")
            } catch {
                debugLog("[App] Failed to auto-archive on background: \(error)")
            }
        }
    }

    /// Retry sync when returning to the foreground.
    ///
    /// Skipped in Low Power Mode. The user explicitly told iOS to
    /// conserve power; pulling CloudKit on every foreground transition would
    /// burn battery for housekeeping the user can trigger manually if they
    /// care.
    private func resumeSyncOnForeground() {
        guard !AppDependencies.current.services.powerStatePolicy.shouldSkipPeriodicRefresh else { return }
        Task { await syncManager.performFullSyncIfNeeded(minInterval: 10 * 60) }
    }

    /// Morning notification scheduler.
    ///
    /// Rescheduled on every foreground so the next firing's payload reflects
    /// the latest overnight reading and the user's current toggle state. Cheap
    /// (no network, no disk beyond a single archive index read), so it is safe
    /// to run on every foreground transition.
    private func rescheduleMorningNotification() {
        Task { @MainActor in
            await AppDependencies.current.services.morningNotificationScheduler.rescheduleIfNeeded()
        }
    }

    /// Probe HealthKit write permissions.
    ///
    /// The single-prompt-at-onboarding model missed any write type added in a
    /// later release — `workoutType`, `activeEnergy` and `distance` all stayed
    /// `.notDetermined` for users who onboarded before those types were added
    /// to the auth set. iOS only shows the prompt for genuinely undecided
    /// types, so existing users see at most a small supplementary sheet on the
    /// next launch.
    private func refreshHealthKitWriteAuthorization() {
        Task { @MainActor in
            await collector.healthKit.ensureWriteAuthorizationFresh()
            // After (re-)granting permission, back-publish any workouts that
            // were archived locally but never reached HealthKit. Idempotent —
            // uses a per-session `healthKitExportedAt` flag to skip
            // already-published sessions. Runs in the background; the user
            // sees nothing.
            let weight = settingsManager.settings.effectiveBodyWeightKg
            _ = await collector.healthKit.backfillWorkoutsToHealthKit(
                archive: collector.archive,
                bodyWeightKg: weight
            )
        }
    }

    /// Recovery prompts for a session that ended without being accepted.
    ///
    /// Three separate alerts rather than one with a variable button set: the
    /// resumable and non-resumable cases offer different actions and different
    /// wording, and SwiftUI cannot swap an alert's buttons while it is up.
    private func interruptedSessionAlerts(_ content: some View) -> some View {
        let resumable = resumableInterruptionAlert(content)
        let unresumable = unresumableInterruptionAlert(resumable)
        return recoveryCompleteAlert(unresumable)
    }

    /// The session can be picked back up, so offer that first.
    private func resumableInterruptionAlert(_ content: some View) -> some View {
        content.alert(String(localized: "Session Interrupted", bundle: LanguageManager.appBundle), isPresented: resumableInterruptionBinding) {
            Button(String(localized: "Resume", bundle: LanguageManager.appBundle)) { resumeInterruptedSession() }
            Button(String(localized: "Save as Complete", bundle: LanguageManager.appBundle)) { recoverInterruptedSession() }
            Button(String(localized: "Dismiss", bundle: LanguageManager.appBundle), role: .cancel) { dismissInterruptedSession() }
        } message: {
            if let info = interruptedSessionAlert {
                Text(String(localized: "\(info.sessionType.displayName) session from \(info.startTime.formatted(date: .abbreviated, time: .shortened)) was interrupted. Your data was backed up — you can resume recording or save what was captured.", bundle: LanguageManager.appBundle))
            }
        }
    }

    /// The session cannot be resumed; saving what was captured is the only
    /// thing left to offer.
    private func unresumableInterruptionAlert(_ content: some View) -> some View {
        content.alert(String(localized: "Session Interrupted", bundle: LanguageManager.appBundle), isPresented: unresumableInterruptionBinding) {
            Button(String(localized: "Save to Archive", bundle: LanguageManager.appBundle)) { recoverInterruptedSession() }
            Button(String(localized: "Dismiss", bundle: LanguageManager.appBundle), role: .cancel) { dismissInterruptedSession() }
        } message: {
            if let info = interruptedSessionAlert {
                Text(String(localized: "\(info.sessionType.displayName) session from \(info.startTime.formatted(date: .abbreviated, time: .shortened)) was interrupted. Your data was backed up and can be saved to your archive.", bundle: LanguageManager.appBundle))
            }
        }
    }

    /// Reports the outcome of whichever recovery the user chose above.
    private func recoveryCompleteAlert(_ content: some View) -> some View {
        content.alert(String(localized: "Recovery Complete", bundle: LanguageManager.appBundle), isPresented: recoveryResultBinding) {
            Button(String(localized: "OK", bundle: LanguageManager.appBundle)) { recoveryResultMessage = nil }
        } message: {
            if let msg = recoveryResultMessage {
                Text(msg)
            }
        }
    }

    private var resumableInterruptionBinding: Binding<Bool> {
        Binding(
            get: { interruptedSessionAlert?.isResumable == true },
            set: { if !$0 { interruptedSessionAlert = nil } }
        )
    }

    private var unresumableInterruptionBinding: Binding<Bool> {
        Binding(
            get: { interruptedSessionAlert != nil && interruptedSessionAlert?.isResumable == false },
            set: { if !$0 { interruptedSessionAlert = nil } }
        )
    }

    private var recoveryResultBinding: Binding<Bool> {
        Binding(
            get: { recoveryResultMessage != nil },
            set: { if !$0 { recoveryResultMessage = nil } }
        )
    }

    /// Work deferred until after the first frame has paint-committed.
    private func launchTasks(_ content: some View) -> some View {
        content
            .task { await runLaunchTask() }
            .task { await runPostFirstFrameSetup() }
            .task { await observeTrialPaywallRequests() }
            .task { await rescheduleMorningPushOnSettingsChange() }
            // Watch-initiated workout control. The Watch's
            // Start/Stop/Pause/Resume/Acknowledge gestures post these
            // notifications via WCSession → onStart/Stop/etc closures
            // wired above. They live at app level, not on FitnessTabView, so
            // they listen from launch: a Watch gesture made before the user
            // opens the Fitness tab still reaches a listener. The shared `RecorderBox` is pre-bound at launch (next
            // Task) so the Watch's first Start gesture has a recorder
            // ready to go. These are the only start/stop/pause/resume
            // handlers; FitnessTabView listens only to the
            // acknowledge-finished notification, to clear its summary.
            .task { await runWatchAndSyncWiring() }
    }

    /// Setup that must wait until the first frame is on screen.
    ///
    /// These steps are independent of one another; they are gathered here only
    /// because they share that timing constraint.
    private func runPostFirstFrameSetup() async {
        installGlobalKeyboardDismissal()
        // Cold start: kick off the deferred
        // boot() methods on the heavy singletons now that the first
        // frame has paint-committed. Each call is idempotent and
        // does work kept out of init so it does not delay first paint.
        // Per-boot timing lives in `runDeferredBoot()` (below) so slow
        // main-thread work on cold launch shows up in the log. Kept OUT of this closure to avoid tripping the
        // Swift type-checker on an already-huge `.task` body.
        runDeferredBoot()
        bootArchiveOffMain()
        prewarmSpeechVoices()
        wireWatchBridgeCallbacks()
    }

    /// Install the window-level tap recognizer that dismisses the keyboard.
    ///
    /// Global tap-outside-to-dismiss. SwiftUI's default dismissal does not
    /// reach every screen (Profile, the Reports email field, the contact
    /// list), so this installs a window-level
    /// tap recognizer that resigns the first responder on any tap that is NOT
    /// inside a text field. Works on every screen with no per-view modifier.
    ///
    /// 600 ms after launch it also prewarms the keyboard, warm-and-release: an
    /// offscreen field takes first responder and resigns on the next runloop,
    /// so it never holds the responder slot and no keyboard appears.
    private func installGlobalKeyboardDismissal() {
        Task { @MainActor in
            await sleepQuietly(600_000_000, context: "keyboard dismissal install")
            let keyboardDismissal = AppDependencies.current.app.globalKeyboardDismissal
            keyboardDismissal.install()
            keyboardDismissal.prewarmKeyboard()
        }
    }

    private func bootArchiveOffMain() {
        // Archive orphan reconcile + tombstone walk, run here rather
        // than in SessionArchive.init (the first @State,
        // built synchronously before first paint) so a full-directory
        // scan + per-orphan decode does not block launch. Runs
        // off-main; SessionArchive is a plain class (not @MainActor).
        LaunchArchiveBoot.start(collector.archive)
    }

    /// Prewarm `AVSpeechSynthesisVoice.speechVoices()` on a detached task.
    /// The first call after launch IPCs into the speech daemon and has been
    /// seen to block ~14 s; `WorkoutStartCue.prewarm` runs it off the main
    /// actor, so launch never waits on it and the first workout cue finds the
    /// voice cached. Keyed by the app language's code — the same key the start
    /// cue and the workout coach look up.
    private func prewarmSpeechVoices() {
        WorkoutStartCue.prewarm(forLanguage: LanguageManager.appLocale.language.languageCode?.identifier ?? "en")
    }

    /// Wire every Watch → iOS trigger once, at launch, and mirror the phone's
    /// strap to the Watch. In display-only mode the phone owns the strap, so
    /// the Watch's Start button tint and hint can only come from this mirror.
    /// It follows `PolarManager.connectionState`, which hears a strap taken
    /// off the body only when the Polar SDK reports the disconnect, and that
    /// can lag by up to a minute; the Watch's own direct link
    /// (`WatchStrapConnector`, legacy mode) is not affected.
    private func wireWatchBridgeCallbacks() {
        watchBridge.mirrorStrapState(from: collector.polarManager)
        wireWatchVoiceChatTrigger()
        wireWatchWorkoutStartTrigger()
        wireWatchWorkoutTransportTriggers()
    }

    /// Uses the shared controllers so the closure reaches the same instance
    /// every surface (Fitness view, Assistant tab) talks to. `toggle()` is used
    /// instead of `start()` so a second tap on the Watch can also end the
    /// conversation. The return value is the refusal the Watch shows (nil =
    /// accepted), as for a Watch Start.
    private func wireWatchVoiceChatTrigger() {
        watchBridge.onStartVoiceChatFromWatch = { toggleVoiceChatFromWatch() }
    }

    /// Refused with `.needsUnlock` for a user the paywall would stop on the
    /// phone, the same check a Watch Start meets: voice chat must not run
    /// behind the paywall. Never before the AI disclaimer either; the bridge
    /// tells the Watch that one.
    private func toggleVoiceChatFromWatch() -> WatchControlRefusal? {
        if let refusal = watchAccessRefusal() { return refusal }
        guard AppDependencies.current.assistant.assistantViewModel.hasAcceptedDisclaimer else { return nil }
        voiceChat.toggle()
        return nil
    }

    /// `.needsUnlock` when the paywall would stop this user on the phone.
    /// Every Watch request that starts something on the phone asks this.
    private func watchAccessRefusal() -> WatchControlRefusal? {
        StoreKitManager.paywallEnabled && !hasAccess ? .needsUnlock : nil
    }

    /// When the user taps Start on the wrist, iOS wakes (if suspended, not
    /// force-quit), delivers the message, and we post a notification that the
    /// app-level listener (`appLevelWatchStartListener`) turns into a start on
    /// the one shared `WorkoutRecorder`. The sport string comes from the Watch
    /// UI as `Sport.rawValue`.
    ///
    /// The return value is the refusal the Watch words in its own language
    /// (nil = success). A user the paywall would stop on the phone gets
    /// `.needsUnlock`, which the Watch shows as a prompt to open Emuqu on the
    /// iPhone; a workout already recording or saving on the phone gets
    /// `.strapBusy`, since the listener would ignore the start. Otherwise nil
    /// is returned once the Sport string parses: the
    /// start itself runs asynchronously and any throw there is logged on the
    /// phone, not reported back to the Watch.
    private func wireWatchWorkoutStartTrigger() {
        watchBridge.onStartWorkoutFromWatch = { sportRaw, targetZone in
            if let refusal = watchStartRefusal(sportRaw: sportRaw) { return refusal }
            var userInfo: [AnyHashable: Any] = ["sport": sportRaw]
            if let targetZone { userInfo["targetZone"] = targetZone }
            NotificationCenter.default.post(
                name: .watchRequestedWorkoutStart,
                object: nil,
                userInfo: userInfo
            )
            return nil
        }
    }

    /// Why a Watch Start can't go ahead, answered before the start runs so
    /// the Watch shows the reason. The Watch starts with the strap as its
    /// source, and the start refuses a strap that is mid-recording
    /// (`WorkoutHRSourceResolver`), and a start while a workout is already
    /// recording or finalizing on the phone (`startWorkoutFromWatch` ignores
    /// one), each with its own reason.
    private func watchStartRefusal(sportRaw: String) -> WatchControlRefusal? {
        guard Sport(rawValue: sportRaw) != nil else { return .unknownSport }
        if let refusal = watchAccessRefusal() { return refusal }
        guard !collector.polarManager.isRecordingOnDevice else { return .strapBusy }
        guard !isWorkoutInProgress else { return .workoutInProgress }
        return nil
    }

    /// Stop, pause, resume and acknowledge-finished each post the notification
    /// the app-level listeners (`runAppLevelWatchWorkoutListeners`) act on;
    /// FitnessTabView also hears acknowledge-finished, to clear its summary.
    private func wireWatchWorkoutTransportTriggers() {
        watchBridge.onStopWorkoutFromWatch = { postWatchTransport(.watchRequestedWorkoutStop) }
        watchBridge.onPauseWorkoutFromWatch = { postWatchTransport(.watchRequestedWorkoutPause) }
        watchBridge.onResumeWorkoutFromWatch = { postWatchTransport(.watchRequestedWorkoutResume) }
        watchBridge.onAcknowledgeFinishedFromWatch = { postWatchTransport(.watchAcknowledgedFinished) }
    }

    /// Forward one Watch transport gesture to the app-level listeners.
    ///
    /// The `WatchControlRefusal?` return is the refusal shown back on the Watch.
    /// Posting a notification cannot fail, so it is always nil — the four
    /// transport gestures differ only in which name they post.
    private func postWatchTransport(_ name: Notification.Name) -> WatchControlRefusal? {
        NotificationCenter.default.post(name: name, object: nil)
        return nil
    }

    /// Show the paywall when the trial reminder's "Unlock Now" is tapped.
    private func observeTrialPaywallRequests() async {
        // Listen for trial reminder "Unlock Now" → show paywall
        for await _ in NotificationCenter.default.notifications(named: .showPaywallFromTrial).map({ _ in () }) {
            // Brief delay so fullScreenCover dismissal finishes first
            await sleepQuietly(400_000_000, context: "paywall after trial reminder")
            activeModal = .paywall
        }
    }

    /// Bind the recorder and push settings to iCloud, off the launch path,
    /// then install the app-level Watch workout listeners.
    private func runWatchAndSyncWiring() async {
        prebindWorkoutRecorder()
        pushSettingsToCloudAfterLaunch()
        await runAppLevelWatchWorkoutListeners()
    }

    /// Pre-bind the recorder in a separate main-actor task. `WorkoutRecorder.init`
    /// is heavy (BLE, audio session, threshold engine); deferring it past the
    /// launch frame means the Watch's first Start gesture is instant.
    private func prebindWorkoutRecorder() {
        Task { @MainActor in
            AppDependencies.current.app.recorderBox.bind(core: collector, conversation: voiceChat)
        }
    }

    /// Push the user's settings to iCloud on launch so the cloud
    /// copy stays current even if the user only edits settings on a single
    /// device per session. Backed up so a crash that wipes the local file can
    /// be recovered from
    /// Settings → Diagnostics → "Restore from iCloud".
    ///
    /// Pauses briefly first so the launch critical path is not contending with
    /// CloudKit setup; the push itself is fire-and-forget after that.
    ///
    /// Runs on every launch, including the first, while onboarding is still on
    /// screen. `performPush` is what refuses to upload before onboarding is
    /// finished or with iCloud sync off, so this call and the debounced
    /// per-change push share one gate.
    private func pushSettingsToCloudAfterLaunch() {
        Task { @MainActor in
            await sleepQuietly(5_000_000_000, context: "settings push after launch")
            await AppDependencies.current.storage.cloudKitSettingsSync.pushImmediately()
        }
    }
}

/// The process entry point. The UI-test fresh-install wipe and the crash
/// handlers must run before any stored-property initialiser of `EmuquApp`
/// builds a singleton that reads the settings file (the collector's default
/// arguments do exactly that), so they live here rather than in
/// `EmuquApp.init`, which runs after them.
@main
enum EmuquMain {
    static func main() {
        MainActor.assumeIsolated {
            EmuquApp.resetUITestStateIfRequested()
            EmuquApp.installDiagnostics()
        }
        EmuquApp.main()
    }
}
