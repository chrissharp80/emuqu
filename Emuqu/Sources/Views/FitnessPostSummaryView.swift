import Charts
import CoreLocation
import MapKit
import MessageUI
import SwiftUI

// MARK: - Post-summary Sheet

struct FitnessPostSummaryView: View {
    @Environment(\.dependencies) var dependencies
    /// Initial session as passed in from the parent. Kept as the identity
    /// of this sheet (its id drives the `.onChange` observer). For actual
    /// rendering we compute `session` (below) which prefers the refreshed
    /// archive copy — so Re-analyze α1 / Look up real elevation rewrites
    /// land immediately in the open sheet without a reopen.
    let initialSession: HRVSession
    @State var refreshedSession: HRVSession?

    /// The session the view actually renders from. Reloaded from the
    /// archive on every `collector.archiveVersion` bump so elevation /
    /// α1 rewrites propagate everywhere (hero, headline, charts, PDF
    /// export) without relying on snapshot-at-sheet-open state.
    /// `internal` so the `+EpicReport` extension can reach it.
    var session: HRVSession {
        refreshedSession ?? initialSession
    }

    init(session: HRVSession, onDone: @escaping () -> Void, onDelete: (() -> Void)? = nil) {
        self.initialSession = session
        self.onDone = onDone
        self.onDelete = onDelete
    }
    let onDone: () -> Void
    /// Optional delete hook — wired by parents that can perform the deletion
    /// (Fitness tab, History). When nil the delete option is hidden.
    var onDelete: (() -> Void)?

    @Environment(SettingsManager.self) var settingsManager
    /// Needed so Re-smooth Elevation / Re-analyze α1 can bump the
    /// archive change signal — the fitness tab's hero card reacts to
    /// that bump, refreshing without the user reopening the tab.
    @Environment(RRCollector.self) var collector
    @Environment(ArchiveSignal.self) var archiveSignal
    @State var showDeleteConfirm = false

    // Export URLs are pre-generated in `.task` on first appear. Two reasons:
    //
    //   1. Decoding the GPS polyline is non-trivial for long tracks. The
    //      previous computed-property version re-decoded on EVERY SwiftUI
    //      body pass (the `if !track.isEmpty` check alone triggered it in
    //      mapCard, elevationCard, and all three export handlers), so a
    //      500-point track got decoded 5–10× per render.
    //   2. iOS's share-sheet path through UIViewControllerRepresentable +
    //      .sheet(item:) has a notorious 1–2 minute cold-start stall while
    //      iOS enumerates every share extension installed on the device.
    //      SwiftUI's native `ShareLink` bypasses this — the share sheet
    //      comes up instantly when the URL is ready ahead of time.
    //
    // Track is cached too. Generated once off the main thread.
    @State var cachedTrack: [CLLocation] = []
    @State var gpxURL: URL?
    @State var csvURL: URL?
    @State var tcxURL: URL?
    @State var exportsReady = false
    @State var exportError: String?
    @State var pdfURL: URL?
    @State var pdfGenerating = false
    /// BP §3.16 / §F5 line 985 — Recap Card image, generated lazily on
    /// tap. We render to PNG (1080×1920) including the route map snapshot,
    /// then hand to ShareLink for the system share sheet. Generation is
    /// off-main; presentation is a Bool gate so we can show progress.
    @State var recapImage: UIImage?
    /// Write the rendered recap PNG to a temp file with a
    /// meaningful name so the share-sheet attachment doesn't show up
    /// as "Image" in Photos / Mail / Strava. Set in `generateRecapCard`.
    @State var recapImageURL: URL?
    @State var recapGenerating = false
    @State var recapSharePresented = false

    /// State for the "Save to my route library" prompt. Free-form name
    /// the user types ("Daily 1", "Long loop"); the store keys by ID so
    /// duplicates are allowed and overwrite isn't an issue.
    @State var showSaveRouteSheet = false
    @State var newRouteName = ""
    @State var savedRouteIDForThisSession: UUID?
    var savedRouteStore: SavedRouteStore { dependencies.location.savedRouteStore }
    /// Drives the share-sheet presentation right after PDF generation
    /// succeeds, so the user gets a single-tap flow instead of the
    /// previous "generate, then tap ShareLink" two-step.
    @State var pdfSharePresented = false
    /// Drives the direct mail-composer sheet (separate from
    /// `pdfSharePresented` which goes through the system share sheet).
    /// Pre-fills To / Cc from the user's training-email defaults so
    /// "Email this report" is a single tap when defaults are set.
    @State var pdfMailPresented = false
    /// Set to a non-nil error string when generating-for-mail fails so
    /// the same alert path used for share errors can surface it.
    @State var pdfMailError: String?
    /// Shown once α1 has been re-analysed on this session (sessions
    /// recorded before the artifact-filter fix had inflated α1 values;
    /// this button regenerates them from the stored RR data using the
    /// current filter).
    @State var reanalyzedSession: HRVSession?
    @State var reanalyzing = false
    @State var reanalyzeError: String?
    @State var elevResmoothing = false
    @State var elevResmoothPreview: (gain: Double, loss: Double)?
    @State var elevResmoothError: String?
    /// Route-history baseline summary, loaded async by
    /// `loadRouteHistorySummary()` (FitnessPostSummaryView+Cards.swift).
    /// The summary walk does synchronous archive disk reads
    /// (`retrieveLightweight` per prior workout entry), so it must not run
    /// inside `routeHistoryBaselineCard`'s body path on every SwiftUI
    /// render. nil while loading — which renders exactly what a nil
    /// summary always rendered (no card), so there's no new UI state.
    @State var routeHistory: FitnessSummaryCards.RouteHistorySummary?

    var track: [CLLocation] { cachedTrack }

    var body: some View {
        summaryScroll
            .navigationTitle(String(localized: "Workout Summary", bundle: LanguageManager.appBundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { summaryToolbar }
            .confirmationDialog(
                String(localized: "Delete this workout?", bundle: LanguageManager.appBundle),
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) { deleteWorkoutActions } message: { deleteWorkoutMessage }
            .task(id: session.id) { await prepareSummary() }
            // Pull the latest version of this session from the archive every
            // time the archive-change signal fires. This is what lets
            // Re-analyze α1 / Look up real elevation take effect *immediately*
            // in the open sheet — the hero number, the headline stats, the
            // charts, and the PDF export all read through `session` (which
            // resolves to `refreshedSession` when available), so a single
            // refresh here propagates everywhere.
            .onChange(of: archiveSignal.version) { _, _ in reloadFromArchive() }
            .onAppear { primeSummary() }
    }

    private var summaryScroll: some View {
        ScrollView {
            // Wider inter-card spacing (20pt) to match the Morning Results
            // cadence. Previous layout used 16pt which made cards feel
            // crammed; morning uses 20pt between major cards.
            VStack(alignment: .leading, spacing: 20) {
                summaryTopCards
                summaryChartCards
                summaryDetailCards
                summaryFooter
            }
            .padding()
        }
    }

    @ViewBuilder
    private var summaryTopCards: some View {
        summaryBanners
        summaryHeroCards
        summaryMapCard
        summaryFeelingAndAlpha1
    }

    /// Hero card
    /// Single focal point at the top: sport, distance, duration,
    /// α1 band pill, route trace, plain-English narrative.
    /// Replaces the previous sportHeader + 15-row headlineCard
    /// combo, which front-loaded users with a dense table
    /// before any story.
    /// "How you did" — session analysis narrative
    /// Synthesizes α1 band distribution, HR zones, TRIMP,
    /// HRR, decoupling, and elevation into 2-3 sentences a
    /// coach would write. Tells the user HOW this session
    /// compares to what they were going for, not just what
    /// the numbers were. Mirrors Morning Results'
    /// physician-language analysis block.
    /// Key stats grid
    /// Six curated tiles.
    /// Secondary metrics (normalized power, peak power, max
    /// speed, RMSSD, METs, calories) live in the detailed
    /// cards further down.
    @ViewBuilder
    private var summaryHeroCards: some View {
        heroCard
            .padding(.top, 4)

        sessionAnalysisCard

        keyStatsCard

    }

    /// Reserve the map slot immediately when the session has
    /// a polyline stored — prevents layout shift when the
    /// async polyline decode finishes and the real map
    /// appears. Users were complaining that α1 would load,
    /// then get shoved down when the map popped in.
    /// BP §F5 line 953 — "How did that feel?" 5-emoji rater
    /// (also at top below verdict pill; user fills once,
    /// both sync). Same `feelingSection` view rendered twice
    /// (top + bottom) — they share `feelingEditing` @State
    /// and read/write the same `session.workoutMetadata`
    /// backing field, so a tap on either site updates both
    /// immediately. The bottom rendering stays in place
    /// below as the "data-first flow" anchor; the top one
    /// is the spec-mandated near-the-verdict position.
    @ViewBuilder
    private var summaryMapCard: some View {
        if session.workoutMetadata?.gpsPolyline != nil {
            if !track.isEmpty { mapCard } else { mapPlaceholder }
        }

    }

    /// Banners that must sit above the hero: the HRR capture prompt and the
    /// recovered / partial-data notice.
    @ViewBuilder
    private var summaryBanners: some View {
        // MARK: - HRR capture banner (top of sheet, ABOVE hero)
        // Surfaces the "keep your strap on for the next 2 minutes
        // — capturing HRR" prompt as a prominent, hard-to-miss
        // banner at the very top of the post-summary. The HRR
        // card lower down already has the same message but it's
        // easy to scroll past; people walked away before the
        // capture window finished. Auto-dismisses when capture
        // completes (samples present) or fails (samples == []).
        hrrCaptureBanner
        // Recovered / partial-data banner. Sits above the hero so
        // the user can't miss it — every metric below is being
        // shown with that context. nil for clean live workouts;
        // populated by the launch-time `WorkoutRecoveryService`
        // and by the live finalize when HR data fell below the
        // 60-beat usefulness floor.
        if let partial = session.workoutMetadata?.partialDataReason {
            partialDataBanner(reason: partial)
        }
    }

    /// The subjective rater and the α1 block below it.
    @ViewBuilder
    private var summaryFeelingAndAlpha1: some View {
        feelingSection

        // α1 — the physiological centerpiece below the hero.
        alpha1ReportCard
        alpha1LT1EstimateCard
        if !track.isEmpty { alpha1RouteColoredCard(track: track) }
        alpha1CrossingsCard

        // HRR (autonomic recovery rate).
        hrrCard
    }

    /// Time-series charts, each rendered only when the recording actually
    /// carries that channel.
    @ViewBuilder
    private var summaryChartCards: some View {
        if let samples = session.workoutMetadata?.samples, !samples.isEmpty {
            if samples.contains(where: { $0.heartRate != nil }) {
                hrChartCard(samples: samples)
            }
            if samples.contains(where: { $0.paceSecPerKm != nil }) {
                paceChartCard(samples: samples)
            }
            if samples.contains(where: { $0.cadenceStepsPerMin != nil && ($0.cadenceStepsPerMin ?? 0) > 0 }) {
                cadenceChartCard(samples: samples)
            }
            if samples.contains(where: { ($0.powerWatts ?? 0) > 0 }) {
                powerChartCard(samples: samples)
            }
        }
        if !track.isEmpty { elevationCard }
    }

    @ViewBuilder
    private var summaryDetailCards: some View {
        // HR zone distribution and derived metrics.
        hrZoneDistributionCard
        derivedMetricsCard
        physiologyCard
        environmentCard
        summarySplitsAndActions
    }

    @ViewBuilder
    private var summarySplitsAndActions: some View {
        // Splits. If the stored splits don't match the user's
        // current unit preference (e.g. session was recorded in
        // km-split mode before the unit-aware split-generator
        // shipped, but the user is on imperial), recompute from
        // the GPS track on the fly so the summary always matches
        // what the user expects to see.
        if let splits = resolvedSplits() {
            splitsCard(splits: splits)
        }
        // Route history baseline. Only renders
        // when this workout was bound to a saved-library route
        // AND there are prior sessions on the same route to
        // compare against. First-time runs of a route get
        // nothing — we don't fabricate a baseline from one
        // datapoint.
        routeHistoryBaselineCard
        summaryActionCards
    }

    @ViewBuilder
    private var summaryActionCards: some View {
        coachReportCard
        reanalyzeAlpha1Card
        resmoothElevationCard
        saveRouteCard
        recoverWorkoutSection
        exportCard
    }

    @ViewBuilder
    private var summaryFooter: some View {
        // MARK: - "How did that feel?" subjective prompt
        // Parallel to the morning report's pre-score feeling
        // question — captures the user's own perception
        // *separately* from the objective TRIMP / HRR / α1
        // numbers (Saw et al. 2016 — subjective and objective
        // measures capture different constructs, should be
        // tracked in parallel, not blended). Appears last so
        // it doesn't interrupt the data-first flow above.
        feelingSection

        Text(String(localized: "Tomorrow's overnight recovery will show how you recovered from this session.", bundle: LanguageManager.appBundle))
            .font(.caption)
            .foregroundStyle(AppTheme.textTertiary)
            .padding(.top, 4)
    }

    @ToolbarContentBuilder
    private var summaryToolbar: some ToolbarContent {
        deleteWorkoutToolbarItem
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(String(localized: "Done", bundle: LanguageManager.appBundle), action: onDone)
        }
    }

    @ToolbarContentBuilder
    private var deleteWorkoutToolbarItem: some ToolbarContent {
        if onDelete != nil {
            ToolbarItem(placement: .navigationBarLeading) { deleteWorkoutButton }
        }
    }

    private var deleteWorkoutButton: some View {
        Button {
            showDeleteConfirm = true
        } label: {
            Image(systemName: "trash")
                .foregroundStyle(.red)
        }
        .accessibilityLabel(String(localized: "Delete Workout", bundle: LanguageManager.appBundle))
    }

    @ViewBuilder
    private var deleteWorkoutActions: some View {
        Button(String(localized: "Delete Workout", bundle: LanguageManager.appBundle), role: .destructive) {
            onDelete?()
        }
        Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
    }

    private var deleteWorkoutMessage: some View {
        Text(String(localized: "This removes the session from history and iCloud.", bundle: LanguageManager.appBundle))
    }

    /// Pre-decode the track + write all three export files off the main
    /// thread, then walk the route-history baseline (also off-main — it used
    /// to run synchronously in the card’s body path). Running during `.task`
    /// keeps the UI responsive and gives ShareLink a pre-generated URL.
    private func prepareSummary() async {
        await generateExportsInBackground()
        await loadRouteHistorySummary()
    }

    /// Prime the refresh so any saved-while-open changes from a previous open
    /// of this session take effect immediately, and kick the one-shot legacy
    /// snapshot backfill (a no-op once the session has a snapshot).
    private func primeSummary() {
        reloadFromArchive()
        Task { await backfillAnalysisSnapshotIfNeeded() }
    }

    /// Fired both from `.onAppear` and from every
    /// `.onChange(of: archiveSignal.version)` bump. With the archive
    /// cascade-coalescing that's once per logical
    /// morning event, but each `retrieve(...)` still SHA256s the whole file and
    /// decodes rrSeries. Detached so it runs off the main
    /// thread; `refreshedSession` lands on the next render.
    func reloadFromArchive() {
        let archive = collector.archive
        let id = initialSession.id
        Task { @MainActor in
            let latest = await Task.detached(priority: .userInitiated) {
                archive.retrieveOrLog(id, caller: "FitnessPostSummary.reload")
            }.value
            guard let latest else { return }
            refreshedSession = latest
            invalidateCachedExports()
        }
    }

    /// Critical: invalidate every cached export URL. Without this, tapping
    /// "PDF Report" after Re-smooth Elevation / Re-analyze α1 reshares the OLD
    /// PDF because `pdfURL` still points to the pre-update file. The same
    /// problem applies to GPX / CSV / TCX, which were written before the
    /// archive rewrite. Clearing forces a regenerate on the next tap.
    ///
    /// The route-history baseline is refreshed here too: the card loads
    /// async rather than recomputing on the body eval this archive refresh
    /// triggers, so reloading here keeps that freshness.
    @MainActor
    private func invalidateCachedExports() {
        pdfURL = nil
        gpxURL = nil
        csvURL = nil
        tcxURL = nil
        exportsReady = false
        Task { await generateExportsInBackground() }
        Task { await loadRouteHistorySummary() }
    }

    /// Decode the track once and write GPX/CSV/TCX to temp files on a
    /// utility-priority detached task. State publishes when all three are
    /// ready so the export rows switch from disabled → active.
    func generateExportsInBackground() async {
        let session = self.session
        let polyline = session.workoutMetadata?.gpsPolyline
        let startDate = session.startDate
        let result = await Task.detached(priority: .utility) {
            let track: [CLLocation] = polyline.map {
                GPXExporter.decode(polyline: $0, startDate: startDate, duration: session.duration)
            } ?? []
            return Self.writeExports(session: session, track: track)
        }.value
        await MainActor.run {
            self.cachedTrack = result.track
            self.gpxURL = result.gpx
            self.csvURL = result.csv
            self.tcxURL = result.tcx
            self.exportError = result.error
            self.exportsReady = (result.gpx != nil || result.csv != nil || result.tcx != nil)
        }
    }

    /// Each writer is attempted independently — one failing format must not
    /// deny the user the other two, so failures accumulate into one message.
    nonisolated private static func writeExports(session: HRVSession, track: [CLLocation]) -> ExportOutcome {
        var out = ExportOutcome(track: track)
        do {
            out.gpx = try GPXExporter.writeToTempFile(session: session, track: track)
        } catch { out.error = "GPX failed: \(error.localizedDescription)" }
        do {
            out.csv = try CSVExporter.writeToTempFile(session: session, track: track)
        } catch { out.error = (out.error ?? "") + " CSV failed: \(error.localizedDescription)" }
        do {
            out.tcx = try TCXExporter.writeToTempFile(session: session, track: track)
        } catch { out.error = (out.error ?? "") + " TCX failed: \(error.localizedDescription)" }
        return out
    }

    struct ExportOutcome {
        let track: [CLLocation]
        var gpx: URL?
        var csv: URL?
        var tcx: URL?
        var error: String?
    }

    @State var feelingEditing = false
}
