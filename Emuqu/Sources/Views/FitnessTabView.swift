import Charts
import CoreLocation
import MapKit
import SwiftUI

// MARK: - Fitness Tab

/// Container for the Fitness feature. In default state shows a history-first
/// dashboard with recent workouts and quick-start controls. When a session is
/// active it routes to FitnessRecordingView. When a session just ended it
/// routes to FitnessPostSummaryView.
///
/// Owns the WorkoutRecorder as a @State so the recorder lives only while
/// the tab is on screen (matches the LazyView pattern used by other tabs).
/// Single presentation item for the workout-summary sheet, so there's exactly
/// ONE `.sheet(item:)` (two stacked ones dropped the second — see FitnessTabView).
/// `isJustCompleted` distinguishes the post-recording flow (which acknowledges
/// the finished recorder on dismiss) from tapping an old workout in Recent.
struct WorkoutSummaryItem: Identifiable {
    let session: HRVSession
    let isJustCompleted: Bool
    var id: UUID { session.id }
}

struct FitnessTabView: View {
    @Environment(\.dependencies) var dependencies
    @Environment(RRCollector.self) var collector
    @Environment(ArchiveSignal.self) var archiveSignal
    @Environment(VoiceConversationController.self) var voiceChat
    @Environment(SettingsManager.self) var settingsManager
    let scrollToTopToken: UUID

    // Shared singleton instead of local @State so the
    // app-level Watch event listeners (EmuquApp) reference the
    // same recorder this view does. Pre-binding happens at app launch.
    var recorderBox: RecorderBox { dependencies.app.recorderBox }
    // Observe the training-load cache so the inline trajectory
    // trend on the Fitness home re-renders when the daily series lands.
    var trainingCache: TrainingMetricsCache { dependencies.analysis.trainingMetricsCache }
    @State var startError: String?
    /// **Single source of truth for the pre-flight planning UI.** Owned
    /// by the tab root via `@State` (NOT @State — it's `@Observable`,
    /// not `ObservableObject`). Survives every parent re-render that
    /// the previous inline-Plan implementation kept losing state to.
    /// Injected into WorkoutPreflightView via `.environment(_:)`.
    @State var planModel = WorkoutPlanModel()
    /// GPX import state. Drives the `.fileImporter` modal + the post-import
    /// success/failure alert. Imported workouts go straight into the archive
    /// and appear in History alongside native recordings.
    @State var showImporter = false
    @State var importMessage: String?
    /// GPX export problems, under their own "Export" alert so they never
    /// appear under the import alert's title.
    @State var exportMessage: String?
    /// Presents `HealthWorkoutImportSheet` — the list of workouts Apple Health
    /// has that Emuqu does not.
    @State var showHealthImport = false
    /// Recordings that died before capturing anything, newest first. Drives
    /// `interruptedRecordingCard` — the app telling the user its own recording
    /// failed and can be rebuilt, instead of waiting to be asked.
    @State var interruptedRecordings: [HealthWorkoutImporter.InterruptedSession] = []
    /// Trailing GPX-download share state. Generated
    /// on demand off-main; presented via system share sheet so the
    /// user can save / mail / AirDrop the latest workout track.
    @State var gpxShareURL: URL?
    @State var gpxSharePresented: Bool = false
    /// User-requested GPX preview before the
    /// share sheet. Holds the decoded track + temp-file URL while
    /// the preview sheet is up; the sheet's "Send" button dismisses
    /// itself and triggers the system share.
    @State var gpxPreviewPayload: GPXPreviewPayload?
    /// Last 7 days of passive steps / distance from CMPedometer. Populated
    /// on tab appear. Separate from recorded workouts — this is the walking
    /// the user did without explicitly recording.
    @State var passiveSteps: [PedometerHistoryImporter.DailySteps] = []
    /// Workout elevation gain in meters
    /// (today + 7-day), summed across recorded workouts.
    /// Convertible to floors at 3.05 m / floor for outdoor gradient
    /// climbs that CMPedometer's stair-burst detector misses.
    @State var todayWorkoutElevationMeters: Double = 0
    @State var weekWorkoutElevationMeters: Double = 0
    /// HealthKit-aggregated daily activity (phone + watch + 3rd
    /// party). Replaces CMPedometer-only totals so a user who walks
    /// with the Watch but leaves the phone behind still gets credit.
    /// Most-recent first; index 0 is today.
    @State var dailyActivity: [HealthKitManager.DailyActivity] = []
    /// Today's workout-attributed split. Populated by querying HK
    /// for steps/distance/flights within recorded workout time
    /// ranges. Passive = total (`dailyActivity[0]`) - workout.
    @State var todayWorkoutAttributedSteps: Int = 0
    @State var todayWorkoutAttributedDistanceMeters: Double = 0
    @State var todayWorkoutAttributedFlights: Int = 0
    /// Mean HRR@1m for the summary tile, computed off the render path in
    /// `loadWorkoutElevationTotals` so the grid body doesn't re-decrypt a
    /// week of workouts on every render.
    @State var meanHRR1m7d: Double?
    @State var lastCompletedSession: HRVSession?
    @State var selectedHistorySession: HRVSession?
    @State var unitsPreference: UnitsPreference = UnitsPreferenceStore.current
    // Get Me Back state. Disclaimer modal fires on first
    // engage of the session; sheet routes to `GetMeBackView`. Persisted
    // "user has seen the disclaimer" lives in UserDefaults so we don't
    // hassle them every time.
    @State var showGetMeBackSheet = false
    @State var showGetMeBackDisclaimer = false
    var breadcrumbRecorder: BreadcrumbRecorder { dependencies.location.breadcrumbRecorder }
    static let getMeBackDisclaimerSeenKey = "fitness.getMeBack.disclaimerSeenV1"
    /// Fully-loaded latest workout session powering the hero card. The
    /// archive index only carries HRV-flavoured fields — distance,
    /// elevation, sport, α1, TRIMP live on `workoutMetadata`, which
    /// requires loading the full session blob. Cached here and
    /// refreshed on tab appear + archive-change notifications so the
    /// hero picks up "Re-smooth elevation" / "Re-analyze α1" rewrites
    /// without the user having to close and reopen the tab.
    @State var latestWorkoutSession: HRVSession?
    @State var latestWorkoutLoadFailed = false

    /// Unit preference shortcut. The @State copy above is used for
    /// refresh triggering; this computed form is what views actually
    /// call into for formatting, so updates to UnitsPreferenceStore
    /// propagate instantly without needing a restart.
    var units: UnitsPreference { UnitsPreferenceStore.current }

    @ViewBuilder
    var body: some View {
        withWorkoutSummarySheet(recorderGatedBody)
            .alert(String(localized: "Can't start workout", bundle: LanguageManager.appBundle), isPresented: startErrorBinding) {
                Button(String(localized: "OK", bundle: LanguageManager.appBundle), role: .cancel) { startError = nil }
            } message: {
                Text(startError ?? "")
            }
            .onChange(of: recorderBox.recorder?.phase) { _, newPhase in
                captureFinishedSession(phase: newPhase)
            }
            // Watch start / stop / pause / resume are handled once, app-wide,
            // by `AppLaunchTasks.runAppLevelWatchWorkoutListeners`; the tab
            // only closes its own summary sheet on Save & Done.
            .task { await listenForWatchAcknowledge() }
            .onChange(of: recorderBox.recorder?.finishedSession?.workoutMetadata?.hrrSamples?.count ?? -1) { _, _ in
                refreshOpenSummaryWithHRR()
            }
    }

    @ViewBuilder
    private var recorderGatedBody: some View {
        if let recorder = recorderBox.recorder {
            stateBody(for: recorder)
        } else {
            defaultStateBody
                .onAppear { bindRecorderOffTabSwap() }
        }
    }

    /// First appearance — instantiate the recorder with the live
    /// RRCollector as the shared recording substrate.
    ///
    /// Not a synchronous
    /// `recorderBox.bind(...)` inside `.onAppear`: that freezes
    /// the entire app for ~2 s on first Fitness-tab tap because
    /// `WorkoutRecorder.init` is a 2,151-LOC class that sets up
    /// BLE managers, threshold engine, GPS subscriptions, audio
    /// session prep, and three @State sub-managers — all
    /// synchronously on the main thread. By dispatching through
    /// a `Task { @MainActor in ... }` the tab-swap animation
    /// completes first; the recorder finishes initializing on
    /// the next runloop tick. Tab feels instant; the recorder
    /// appears ~half a second later under defaultStateBody
    /// (which already renders without it).
    private func bindRecorderOffTabSwap() {
        Task { @MainActor in
            recorderBox.bind(core: collector, conversation: voiceChat)
        }
    }

    /// The inline `WorkoutPreflightView` in `defaultStateBody`
    /// owns its picker state via the `WorkoutPlanModel @Observable`
    /// singleton on the tab root, which survives parent re-renders
    /// — picker state held in the inline view itself is lost on
    /// re-render.
    /// ONE sheet, not two. Two stacked `.sheet(item:)` modifiers
    /// (just-completed + tapped-from-history) silently drop the SECOND on
    /// present, so tapping a recent workout opens nothing ("recent efforts
    /// don't open"). Both present the same FitnessPostSummaryView, so derive a
    /// single item from the two states and keep the just-completed vs history
    /// behavior via `isJustCompleted`. The two @State vars are preserved
    /// because the recorder/HRR-swap flow still drives `lastCompletedSession`.
    private func withWorkoutSummarySheet(_ content: some View) -> some View {
        content
            .sheet(item: workoutSummaryBinding) { workoutSummarySheet($0) }
    }

    private var workoutSummaryBinding: Binding<WorkoutSummaryItem?> {
        Binding<WorkoutSummaryItem?>(
        get: {
            if let s = lastCompletedSession { return WorkoutSummaryItem(session: s, isJustCompleted: true) }
            if let s = selectedHistorySession { return WorkoutSummaryItem(session: s, isJustCompleted: false) }
            return nil
        },
        set: { newValue in
            if newValue == nil {
                lastCompletedSession = nil
                selectedHistorySession = nil
            }
        }
        )
    }

    private func workoutSummarySheet(_ item: WorkoutSummaryItem) -> some View {
        NavigationStack {
            FitnessPostSummaryView(
                session: item.session,
                onDone: { dismissSummary(item) },
                onDelete: { deleteFromSummary(item) }
            )
        }
    }

    private func dismissSummary(_ item: WorkoutSummaryItem) {
        lastCompletedSession = nil
        selectedHistorySession = nil
        if item.isJustCompleted { recorderBox.recorder?.acknowledgeFinished() }
    }

    private func deleteFromSummary(_ item: WorkoutSummaryItem) {
        deleteWorkout(item.session.id)
        if item.isJustCompleted { recorderBox.recorder?.acknowledgeFinished() }
    }

    private var startErrorBinding: Binding<Bool> {
        Binding(
            get: { startError != nil },
            set: { if !$0 { startError = nil } }
        )
    }

    private func captureFinishedSession(phase: WorkoutRecorder.Phase?) {
        if phase == .finished, let session = recorderBox.recorder?.finishedSession {
            lastCompletedSession = session
        }
    }

    /// Propagate the recorder's `finishedSession` updates to the open
    /// summary sheet. WITHOUT this, the HRR capture task's re-archive
    /// (populating `hrrSamples` ~60-120 s after stop) would land in the
    /// archive but the sheet — which holds the stop-time snapshot —
    /// would keep showing "capturing…" forever. Keyed on the hrrSamples
    /// count (HRVSession isn't Equatable) so the closure fires exactly
    /// when the HRR detached task writes the samples back, and we push
    /// the refreshed session into the sheet's bound state.
    private func refreshOpenSummaryWithHRR() {
        guard let newSession = recorderBox.recorder?.finishedSession,
              let currentId = lastCompletedSession?.id,
              newSession.id == currentId
        else { return }
        lastCompletedSession = newSession
    }

    /// Wrapper that observes the recorder's `lifecycle` so phase
    /// transitions trigger an IMMEDIATE re-render. Without this wrapper
    /// the FitnessTabView reads `recorder.phase` (a computed forwarder
    /// to `lifecycle.phase`) but doesn't observe the lifecycle —
    /// SwiftUI only re-evaluates the switch when something ELSE causes
    /// the body to refresh, leaving a 100ms-to-multi-second gap between
    /// `lifecycle.phase = .recording` and the FitnessRecordingView
    /// actually rendering.
    @ViewBuilder
    func stateBody(for recorder: WorkoutRecorder) -> some View {
        PhaseObservingStateBody(
            recorder: recorder,
            recordingBody: { rec in
                FitnessRecordingView(recorder: rec, onStop: { Self.stopAction(for: rec) })
            },
            defaultBody: { defaultStateBody }
        )
    }

    /// The stop button hands off to the recorder's async finalize.
    @MainActor
    private static func stopAction(for recorder: WorkoutRecorder) {
        Task { await recorder.stop() }
    }

    // MARK: - Default state

    @ViewBuilder
    /// Read directly — `collector.archive.entries` is loaded at
    /// RRCollector init (app launch), so this is just an array
    /// access + filter + sort over the in-memory list. Cheap for
    /// typical session counts. The earlier attempt to cache via
    /// @State broke the "workouts visible immediately on tab open"
    /// behavior because the cache was populated by a `.task` that
    /// ran AFTER the first body render — so users saw an empty
    /// workout list flash before the cache populated.
    var defaultStateBody: some View {
        withFitnessImports(withGPXSheets(withFitnessChrome(fitnessHomeScroll)))
    }

    /// Single ScrollView. No nested ScrollView. Pre-flight UI sits
    /// at the top — it's why the user opened the tab. Past-workout
    /// surfaces follow.
    private var fitnessHomeScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                preflightSurface
                fitnessHomeCards
                Spacer(minLength: 24)
            }
            .padding()
        }
    }

    /// Fitness home order: nav header →
    /// sport chips → Today's Route card → Coaching row →
    /// Start button → Recent workout hero → 2x2 stats →
    /// Passive Activity → Get Me Back → Recent list. The
    /// first four belong to WorkoutPreflightView; the
    /// rest follow below.
    ///
    /// No `fitnessStatusPill` + sources row pinned
    /// above the preflight surface: the pill duplicates
    /// what `dailyActivityCard` already shows. The
    /// `trajectoryLinkCard` sits between the hero and the
    /// stats (`fitnessHomeCards`).
    @ViewBuilder
    private var preflightSurface: some View {
        if let recorder = recorderBox.recorder {
            WorkoutPreflightView(
                collector: collector,
                recorder: recorder,
                onStart: { sport, targetZone, source, plan, thresholds, route in
                    startWorkout(
                        sport: sport,
                        targetZone: targetZone,
                        source: source,
                        plan: plan,
                        thresholds: thresholds,
                        route: route
                    )
                }
            )
            .environment(planModel)
        }
    }

    @ViewBuilder
    private var fitnessHomeCards: some View {
        // Above the hero deliberately: the hero shows the most recent workout,
        // and after a crash the most recent workout IS the one-second stub the
        // card is about. Explaining it under the thing it explains is backwards.
        interruptedRecordingCard
        heroCard(latest: recentWorkoutEntries().first)
        trajectoryLinkCard
        summaryTileGrid(entries: recentWorkoutEntries())
        heatAcclimationCard
        dailyActivitySurfaces
        recentWorkoutsList(entries: recentWorkoutEntries())
    }

    /// Heat acclimatization — a rolling adaptation state that
    /// belongs with the fitness readouts, not buried at the
    /// bottom of the Load & Trajectory sub-page. Self-explaining:
    /// shows the level, or why it can't yet (no outdoor workouts /
    /// location / network).
    private var heatAcclimationCard: some View {
        HeatAcclimationCard(
            temperatureUnit: settingsManager.settings.temperatureUnit
        )
    }

    /// Deliberately kept alongside the pill: the
    /// pill at top is the at-a-glance today number; this
    /// card is the 7-day picture WITH the workout-vs-
    /// passive split.
    @ViewBuilder
    private var dailyActivitySurfaces: some View {
        dailyActivityCard
        getMeBackCard
    }

    /// Title, accessibility handle, toolbar, and the two tab-lifecycle hooks.
    private func withFitnessChrome(_ content: some View) -> some View {
        content
            .sheet(isPresented: Bindable(planModel).sensorSheetPresented) { sensorSheet }
            .task { await loadFitnessHomeData() }
            .navigationTitle(String(localized: "Fitness", bundle: LanguageManager.appBundle))
            .accessibilityIdentifier("fitness.root")
            .toolbar { fitnessToolbar }
    }

    /// Sensor-management sheet — opens when the user taps the
    /// strap status pill in WorkoutPreflightView. Never blocks
    /// anything; just a place to manage Polar / foot-pod / PM5
    /// pairings without leaving the tab.
    private var sensorSheet: some View {
        NavigationStack {
            SensorManagementSheet(
                polarManager: collector.polarManager,
                onDismiss: { planModel.sensorSheetPresented = false }
            )
        }
        .presentationDetents([.medium, .large])
    }

    /// First-load work for the tab. The cached snapshot paints instantly, the
    /// training-load warm is fire-and-forget, and the HealthKit aggregates are
    /// awaited last.
    /// `reloadInterruptedRecordings()` runs FIRST, before any `await`. It is a
    /// local archive read with no HealthKit or CoreMotion dependency, and it
    /// drives the card that tells a user their recording died. Ordering it after
    /// the awaits below made it the one thing on this screen that a slow
    /// HealthKit query — or a tab switch cancelling the `.task` mid-await —
    /// could silently stop from ever appearing. The cheapest and most important
    /// readout does not queue behind the most expensive ones.
    private func loadFitnessHomeData() async {
        paintCachedFitnessSnapshot()
        reloadInterruptedRecordings()
        // Warm the training-load cache so the inline
        // trajectory trend + Weekly TRIMP tile have data on the Fitness
        // home. Fire-and-forget (NOT awaited) so the tab's other
        // first-load work isn't serialized behind the 180-day fetch; the
        // inline trend fills reactively when the observable series lands.
        Task { await trainingCache.refresh() }
        // CMPedometer fallback (iPhone-only). Used when HK
        // hasn't authorized step / distance / flights reads yet,
        // or in dev builds without HK access.
        passiveSteps = await PedometerHistoryImporter.importRecent(days: 7)
        // HK aggregates (phone + watch + 3rd
        // party), workout-vs-passive split via time-windowing
        // recorded workouts. This is the data the pill + the
        // daily-activity card render off.
        await loadWorkoutElevationTotals()
    }

    /// Instant paint from the cached fitness snapshot so the elevation
    /// / activity pills aren't blank while the refresh below reconciles
    /// (and rewrites the cache). Additive — the live values overwrite.
    private func paintCachedFitnessSnapshot() {
        if let f = dependencies.storage.uiStateCache.fitness {
            todayWorkoutElevationMeters = f.todayElevationMeters
            weekWorkoutElevationMeters = f.weekElevationMeters
            todayWorkoutAttributedSteps = f.todayAttributedSteps
            todayWorkoutAttributedDistanceMeters = f.todayAttributedDistanceMeters
            todayWorkoutAttributedFlights = f.todayAttributedFlights
        }
    }

    /// A stable handle for "the Fitness surface rendered".
    /// Asserting instead on a sport chip / Start / Get Me Back
    /// label, all of which live inside `WorkoutPreflightView` and only
    /// render once `recorderBox.recorder` is non-nil, makes the UI test
    /// fail on timing on a cold simulator rather than on anything being
    /// wrong with the tab.
    @ToolbarContentBuilder
    private var fitnessToolbar: some ToolbarContent {
        // Trailing toolbar: ⬇ download GPX. The unit
        // dropdown was removed from legacy and moved to
        // Settings → Profile. So:
        // no unit picker in this toolbar (Settings → Profile
        // & Health is its canonical home), GPX-download takes the
        // trailing slot per spec.
        ToolbarItem(placement: .topBarTrailing) { fitnessDataMenu }
    }

    private func withGPXSheets(_ content: some View) -> some View {
        content
            .sheet(isPresented: $gpxSharePresented) { gpxShareSheet }
            // GPX preview sheet (user-requested
            // "I'm not able to preview first"). Shows the decoded route
            // on a map + summary stats; "Send" inside the sheet opens
            // the system share. Dismissing without tapping Send keeps
            // the temp .gpx file on disk for next time (cleaned up by
            // the OS on temp-dir purge).
            .sheet(item: $gpxPreviewPayload) { gpxPreviewSheet($0) }
            .alert(String(localized: "Export", bundle: LanguageManager.appBundle), isPresented: Binding(
                get: { exportMessage != nil },
                set: { if !$0 { exportMessage = nil } }
            )) {
                Button(String(localized: "OK", bundle: LanguageManager.appBundle), role: .cancel) { exportMessage = nil }
            } message: {
                if let m = exportMessage { Text(m) }
            }
    }

    @ViewBuilder
    private var gpxShareSheet: some View {
        if let url = gpxShareURL {
            ShareSheet(activityItems: [url])
        }
    }

    private func gpxPreviewSheet(_ payload: GPXPreviewPayload) -> some View {
        GPXPreviewSheet(payload: payload) { shareGPXAfterPreview(payload) }
    }

    /// Dismiss the preview, then share the URL — with a slight delay so the
    /// preview sheet finishes its dismissal animation before the share sheet
    /// pops.
    private func shareGPXAfterPreview(_ payload: GPXPreviewPayload) {
        gpxPreviewPayload = nil
        gpxShareURL = payload.url
        Task { @MainActor in
            await sleepQuietly(300_000_000, context: "defaultStateBody")
            gpxSharePresented = true
        }
    }

    private func withFitnessImports(_ content: some View) -> some View {
        content
            .sheet(isPresented: $showHealthImport) { healthImportSheet }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.xml, .data],
                allowsMultipleSelection: false
            ) { result in
                handleImportResult(result)
            }
            .alert(String(localized: "Import", bundle: LanguageManager.appBundle), isPresented: Binding(
                get: { importMessage != nil },
                set: { if !$0 { importMessage = nil } }
            )) {
                Button(String(localized: "OK", bundle: LanguageManager.appBundle), role: .cancel) { importMessage = nil }
            } message: {
                if let m = importMessage { Text(m) }
            }
    }

    // MARK: - Data helpers

    func recentWorkoutEntries() -> [SessionArchiveEntry] {
        collector.archive.entries
            .filter { $0.sessionType == .workout }
            .sorted { $0.date > $1.date }
    }

    func withinDays(_ date: Date, _ days: Int) -> Bool {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else {
            return false
        }
        return date >= cutoff
    }

    /// In the app language, not the phone's, so an in-app language switch
    /// takes effect without a relaunch.
    func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = LanguageManager.appLocale
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    func formattedDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(LanguageManager.appLocale))
    }

    // MARK: - Session kick-off

    func deleteWorkout(_ id: UUID) {
        do {
            try collector.archive.delete(id)
            collector.notifyArchiveChanged()
            Task { await dependencies.storage.cloudKitSyncManager.uploadDeletion(id) }
            // If the summary sheet was open on this session, close it.
            if selectedHistorySession?.id == id { selectedHistorySession = nil }
            if lastCompletedSession?.id == id { lastCompletedSession = nil }
        } catch {
            debugLog("[Fitness] Failed to delete workout \(id): \(error)", level: .warning)
        }
    }

    /// Trailing toolbar GPX download. Pulls the
    /// latest workout with a GPS polyline, writes it to a temp file
    /// via `GPXExporter`, and presents the share sheet. Generation is
    /// off-main; the share sheet trigger flips on the main actor.
    ///
    /// The user explicitly asked for a preview BEFORE the
    /// share sheet. The sheet shows the route on a map + summary stats; sharing
    /// happens from a Send button inside it. A direct-to-share flow
    /// gives users zero way to verify what they are about to send to Strava /
    /// WhatsApp / wherever.
    @MainActor
    func exportLatestGPX() async {
        let entries = recentWorkoutEntries()
        guard !entries.isEmpty else {
            exportMessage = String(localized: "No workouts yet. Record one to enable GPX export.", bundle: LanguageManager.appBundle)
            return
        }
        guard let (session, polyline) = await latestTrackedWorkout(entries: entries) else {
            exportMessage = String(localized: "None of your recent workouts have a GPS track. Indoor / treadmill workouts can't export GPX.", bundle: LanguageManager.appBundle)
            return
        }
        let (track, urlOpt) = await Self.writeGPX(session: session, polyline: polyline)
        guard let url = urlOpt else {
            exportMessage = String(localized: "Couldn't decode GPS track for export.", bundle: LanguageManager.appBundle)
            return
        }
        gpxPreviewPayload = GPXPreviewPayload(url: url, track: track, session: session)
    }

    /// Not `retrieveFullSessionAsync` x20
    /// sequentially: full retrieve decrypts + JSON-decodes the ENTIRE session
    /// including the rrSeries blob (overnight sessions ship 17K+ RR points =
    /// ~100 KB JSON each). 20 of those sequentially on slow flash + AES = 10–30 s
    /// of "down arrow waits forever." Lightweight retrieve skips rrSeries
    /// entirely (the polyline is on `workoutMetadata`, which the lightweight
    /// path keeps), and the lookup moves off the main actor so the UI doesn't
    /// block.
    @MainActor
    private func latestTrackedWorkout(entries: [SessionArchiveEntry]) async -> (HRVSession, Data)? {
        let archive = collector.archive
        return await Task.detached(priority: .userInitiated) { () -> (HRVSession, Data)? in
            Self.firstEntryWithPolyline(entries, archive: archive)
        }.value
    }

    /// The newest of the last 20 entries that actually carries a route.
    nonisolated private static func firstEntryWithPolyline(
        _ entries: [SessionArchiveEntry],
        archive: SessionArchive
    ) -> (HRVSession, Data)? {
        for entry in entries.prefix(20) {
            guard let session = try? archive.retrieveLightweight(entry.sessionId),
                  let polyline = session.workoutMetadata?.gpsPolyline, !polyline.isEmpty
            else { continue }
            return (session, polyline)
        }
        return nil
    }

    private static func writeGPX(session: HRVSession, polyline: Data) async -> ([CLLocation], URL?) {
        let startDate = session.startDate
        let duration = session.duration
        return await Task.detached(priority: .userInitiated) { () -> ([CLLocation], URL?) in
            let track = GPXExporter.decode(polyline: polyline, startDate: startDate, duration: duration)
            guard !track.isEmpty else { return ([], nil) }
            return (track, attempt("FitnessTabView.write") { try GPXExporter.writeToTempFile(session: session, track: track) })
        }.value
    }

    /// Handle a GPX file picked via `.fileImporter`. Parses → builds an
    /// HRVSession → writes to the archive so the imported workout appears
    /// in History. HR / cadence / altitude samples are reconstructed if the
    /// GPX had them (Strava / Garmin exports usually do).
    func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            importGPX(from: url)
        case .failure(let error):
            importMessage = String(localized: "Couldn't open file: \(error.localizedDescription)", bundle: LanguageManager.appBundle)
        }
    }

    /// `.fileImporter` returns a security-scoped URL; the read must be wrapped
    /// in start/stopAccessingSecurityScopedResource.
    private func importGPX(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let parsed = try GPXImporter.parse(data: try Data(contentsOf: url))
            let session = GPXImporter.buildSession(from: parsed)
            _ = try collector.archive.archive(session)
            collector.notifyArchiveChanged()
            let dur = Int(parsed.endDate.timeIntervalSince(parsed.startDate)) / 60
            importMessage = String(localized: "Imported \(parsed.sport.localizedName) (\(dur) min, \(parsed.track.count) GPS points).", bundle: LanguageManager.appBundle)
        } catch {
            importMessage = String(localized: "Import failed: \(error.localizedDescription)", bundle: LanguageManager.appBundle)
        }
    }

    /// Listener for Watch → iOS Save & Done confirmations. The app-level
    /// listener acknowledges the recorder; this one dismisses the iPhone
    /// summary sheet so the workout lifecycle fully closes no matter which
    /// screen the user completed it on.
    @MainActor
    func listenForWatchAcknowledge() async {
        let stream = NotificationCenter.default.notifications(named: .watchAcknowledgedFinished)
        for await _ in stream {
            lastCompletedSession = nil
        }
    }

    func startWorkout(
        sport: Sport,
        targetZone: Int? = nil,
        source: WorkoutRecorder.HRSource = .strap,
        plan: IntervalPlan? = nil,
        thresholds: [WorkoutThreshold] = [],
        route: Route? = nil
    ) {
        guard let recorder = recorderBox.recorder else {
            startError = String(localized: "Recorder not ready yet.", bundle: LanguageManager.appBundle)
            return
        }
        // Set target zone BEFORE start() so the first tick's context build
        // already has the target populated and zone-drift rules can
        // immediately start their elapsed-time gates.
        recorder.targetZone = targetZone
        do {
            try recorder.start(sport: sport, source: source, intervalPlan: plan, thresholds: thresholds, route: route)
        } catch let error as WorkoutRecorderError {
            startError = error.errorDescription
        } catch {
            startError = error.localizedDescription
        }
    }
}

// MARK: - PhaseObservingStateBody
//
// The body wrapper that explicitly observes `recorder.lifecycle` so a
// `lifecycle.phase` change triggers an immediate re-render.
//
// The `recorder` itself isn't enough — it has zero `@Published`
// properties (the comment in `WorkoutLifecycle.swift` calls this
// out). All published state lives
// on `lifecycle`, `motion`, `workoutHR`. To switch the FitnessTab's
// body the moment phase flips, we have to observe `lifecycle`.
//
// Generic over the two body builders so the parent's @State + @Environment
// captured by the trailing closures aren't lost (which would happen if
// we used AnyView).
private struct PhaseObservingStateBody<Recording: View, Default: View>: View {
    let recorder: WorkoutRecorder
    var lifecycle: WorkoutLifecycle
    let recordingBody: (WorkoutRecorder) -> Recording
    let defaultBody: () -> Default

    init(
        recorder: WorkoutRecorder,
        @ViewBuilder recordingBody: @escaping (WorkoutRecorder) -> Recording,
        @ViewBuilder defaultBody: @escaping () -> Default
    ) {
        self.recorder = recorder
        // Observe the lifecycle directly — phase changes will now
        // invalidate this view's body and immediately switch
        // recording/idle.
        lifecycle = recorder.lifecycle
        self.recordingBody = recordingBody
        self.defaultBody = defaultBody
    }

    var body: some View {
        switch lifecycle.phase {
        case .recording, .finalizing:
            recordingBody(recorder)
        case .idle, .finished, .failed:
            defaultBody()
        }
    }
}

// MARK: - Recorder Box
//
// @State requires a parameterless init, but WorkoutRecorder needs a
// RecordingCore. This tiny holder lets the tab bind the recorder once the
// environment is available, while still owning its lifecycle.
@MainActor
/// `final` with a shared
/// instance so the app-level Watch event listeners (registered in
/// `EmuquApp`) and the FitnessTabView both reference the SAME
/// recorder. With the listener tied to the FitnessTabView's lifecycle,
/// the Watch's "Start Workout" only
/// worked if the user had opened the iPhone Fitness tab at least once
/// in the current app session. The listener mounts at app
/// launch and the recorder pre-binds in the background, so the Watch
/// can start a workout cold.
@Observable
final class RecorderBox {
    static let shared = RecorderBox()
    var recorder: WorkoutRecorder?

    func bind(core: RecordingCore, conversation: VoiceConversationController) {
        guard recorder == nil else { return }
        recorder = WorkoutRecorder(core: core, conversation: conversation)
    }
}
