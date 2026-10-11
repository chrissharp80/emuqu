import CoreLocation
import MapKit
import SwiftUI

// The subjective-feeling section, snapshot migration, the session-analysis
// narrative, the hero card, the recover/fix controls, the partial-data
// banner, the key-stats grid and the route map. The HRR banner is
// `WorkoutStatsCards.hrrCaptureBanner`.

extension FitnessPostSummaryView {
    // MARK: - "How did that feel?" subjective section

    @ViewBuilder
    var feelingSection: some View {
        if let rating = session.workoutMetadata?.workoutFeeling, !feelingEditing {
            feelingBadge(rating)
        } else {
            feelingPrompt
        }
    }

    private var feelingPrompt: some View {
        WorkoutFeelingPrompt(
            onSelect: { rating, note in
                Task { await saveWorkoutFeeling(rating: rating, note: note) }
            },
            onSkip: { skipFeeling() },
            existing: session.workoutMetadata?.workoutFeeling,
            existingNote: session.workoutMetadata?.workoutFeelingNote
        )
    }

    /// Skip without rating — stays unrated; "Cancel" when editing bails
    /// without changing.
    private func skipFeeling() {
        feelingEditing = false
    }

    private func feelingBadge(_ rating: Int) -> some View {
        WorkoutFeelingBadge(
            feeling: rating,
            note: session.workoutMetadata?.workoutFeelingNote,
            onTap: { feelingEditing = true }
        )
    }

    /// Retrieve + mutate + archive all run on a detached
    /// task so the archiveLock (full decode + SHA256 + write + re-hash) never
    /// blocks the main thread on save. A save that didn't happen keeps the
    /// prompt open and raises the "Couldn't save how you felt" alert.
    func saveWorkoutFeeling(rating: Int, note: String?) async {
        let archive = dependencies.storage.sessionArchive
        let id = session.id
        let updated: HRVSession? = await Task.detached(priority: .userInitiated) {
            Self.persistFeeling(rating: rating, note: note, id: id, archive: archive)
        }.value
        guard let updated else {
            feelingSaveFailed = true
            return
        }
        refreshedSession = updated
        feelingEditing = false
        collector.notifyArchiveChanged()
    }

    /// Nil on any failure — the rating simply isn't persisted and the UI stays
    /// in edit mode rather than claiming a save that didn't happen. That
    /// includes an archived copy with no workout metadata, where there is
    /// nowhere to store the rating.
    nonisolated private static func persistFeeling(
        rating: Int,
        note: String?,
        id: UUID,
        archive: SessionArchive
    ) -> HRVSession? {
        do {
            let updated = try FitnessSummaryCards.updateArchived(id, in: archive) { stored in
                stored.workoutMetadata?.workoutFeeling = rating
                stored.workoutMetadata?.workoutFeelingNote = note
            }
            guard let updated, updated.workoutMetadata != nil else { return nil }
            return updated
        } catch {
            debugLog("[WorkoutFeeling] save failed: \(error)", level: .warning)
            return nil
        }
    }

    // MARK: - Background snapshot migration (legacy sessions)

    /// If the session was recorded before `analysisSnapshot` existed OR
    /// was computed under an older schema version, recompute it
    /// asynchronously on first open and persist. Subsequent opens become
    /// pure field reads — no per-render iteration over thousands of
    /// samples.
    ///
    /// The schema-version guard (not just nil-check) is what makes
    /// corrective fixes in `WorkoutAnalysisSnapshotBuilder` retro-apply
    /// to historical sessions. Each time you view an old workout, if the
    /// stored snapshot is older than `currentVersion`, it silently
    /// rebuilds with current math and writes back — so history "heals"
    /// one visit at a time.
    ///
    /// The build and the archive read-modify-write both run detached, like
    /// the feeling save, so the archiveLock never blocks the main thread.
    func backfillAnalysisSnapshotIfNeeded() async {
        let stored = session.workoutMetadata?.analysisSnapshot
        let needsRebuild = stored?.needsRebuild ?? true
        guard needsRebuild, let inputs = snapshotInputs(), !inputs.samples.isEmpty else { return }
        let archive = dependencies.storage.sessionArchive
        let id = session.id
        let updated = await Task.detached(priority: .userInitiated) {
            Self.persistAnalysisSnapshot(WorkoutAnalysisSnapshotBuilder.build(inputs), builtFrom: inputs, id: id, archive: archive)
        }.value
        guard let updated else { return }
        refreshedSession = updated
        collector.notifyArchiveChanged()
    }

    /// Builder inputs from the rendered session, with max HR and weight from
    /// the injected `settingsManager` the view renders with. Nil without
    /// workout metadata or a duration; `samples` may be empty.
    private func snapshotInputs() -> WorkoutAnalysisSnapshotBuilder.Inputs? {
        guard let meta = session.workoutMetadata, let duration = session.duration else { return nil }
        let settings = settingsManager.settings
        return WorkoutAnalysisSnapshotBuilder.Inputs(
            sport: meta.sport,
            durationSec: duration,
            distanceMeters: meta.distanceMeters,
            elevationGainMeters: meta.elevationGainMeters,
            elevationLossMeters: meta.elevationLossMeters,
            meanHR: session.meanHR,
            userMaxHR: settings.effectiveMaxHR,
            bodyWeightKg: settings.effectiveBodyWeightKg,
            samples: meta.samples ?? [],
            splits: meta.splits ?? [],
            trimp: meta.luciaTRIMP,
            decouplingPercent: meta.decouplingPercent
        )
    }

    /// Stores the snapshot only when the archived copy still has the samples
    /// and duration it was built from. A retrim or re-analysis that landed
    /// while it was building is left alone, so a snapshot of the old samples
    /// is never stamped current (the next open rebuilds from the new ones).
    /// Nil when nothing was written.
    nonisolated private static func persistAnalysisSnapshot(
        _ snapshot: WorkoutAnalysisSnapshot,
        builtFrom inputs: WorkoutAnalysisSnapshotBuilder.Inputs,
        id: UUID,
        archive: SessionArchive
    ) -> HRVSession? {
        var written = false
        do {
            let updated = try FitnessSummaryCards.updateArchived(id, in: archive) { stored in
                written = store(snapshot, in: &stored, ifBuiltFrom: inputs)
            }
            guard written, let updated else { return nil }
            debugLog("[SnapshotBackfill] wrote snapshot for \(id)")
            return updated
        } catch {
            debugLog("[SnapshotBackfill] failed: \(error)", level: .warning)
            return nil
        }
    }

    /// Writes the snapshot into the archived copy when it still has the
    /// samples and duration the snapshot was built from; false otherwise.
    nonisolated private static func store(
        _ snapshot: WorkoutAnalysisSnapshot,
        in stored: inout HRVSession,
        ifBuiltFrom inputs: WorkoutAnalysisSnapshotBuilder.Inputs
    ) -> Bool {
        guard stored.workoutMetadata?.samples == inputs.samples, stored.duration == inputs.durationSec else { return false }
        stored.workoutMetadata?.analysisSnapshot = snapshot
        return true
    }

    // MARK: - Session Analysis ("How you did")

    /// 2-3 sentence coach-style narrative synthesising the session's
    /// key physiological signals — time in each α1 band, decoupling,
    /// training load against fixed bands (not the user's typical load),
    /// elevation context. Mirrors Morning
    /// Results' `recoveryScoreCard` breakdown message: "everything is
    /// clicking", "this walk pushed you past aerobic threshold", etc.
    /// Only renders when there's enough data to say something useful.
    @ViewBuilder
    var sessionAnalysisCard: some View {
        let text = generateSessionAnalysis()
        if !text.isEmpty {
            sessionAnalysisBody(text)
        }
    }

    private func sessionAnalysisBody(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sessionAnalysisHeader
            Text(text)
                .font(.callout)
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    private var sessionAnalysisHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.fitnessAccent)
            Text(String(localized: "HOW YOU DID", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    /// The "how you did" narrative: the stored snapshot's, one field read
    /// with no sample iteration, which is what keeps summary reloads fast.
    /// Sessions saved before snapshots existed show the same builder's text
    /// until the backfill lands (`displayedAnalysis`).
    func generateSessionAnalysis() -> String {
        displayedAnalysis?.howYouDidNarrative ?? ""
    }

    /// The analysis the summary shows: the stored snapshot, or — for a
    /// session saved before snapshots existed, until the backfill lands — one
    /// built on the fly by `WorkoutAnalysisSnapshotBuilder`, so the hero and
    /// "how you did" text read the same before and after the backfill. Nil
    /// without workout metadata or a duration.
    var displayedAnalysis: WorkoutAnalysisSnapshot? {
        if let stored = session.workoutMetadata?.analysisSnapshot { return stored }
        return snapshotInputs().map { WorkoutAnalysisSnapshotBuilder.build($0) }
    }

    // MARK: - Hero (new, morning-parity)

    /// Builds the inputs for the WorkoutHeroCard from the session and
    /// delegates rendering to the dedicated card component. Keeps data
    /// shaping in one place and the card pure. The dominant α1 band and the
    /// narrative are the analysis snapshot's fields, not re-derived from the
    /// samples on each render.
    var heroCard: some View {
        let meta = session.workoutMetadata
        let sport = meta?.sport ?? .walk
        let distance = meta?.distanceMeters
        let distanceLabel = distance.map { units.formatDistance(meters: $0) } ?? "—"
        let durationLabel = heroDurationLabel
        let paceLabel = heroPaceLabel(distance: distance)
        let analysis = displayedAnalysis
        let dominantBand = analysis?.dominantAlpha1BandRaw.flatMap { LiveDFAAnalyzer.Band(rawValue: $0) }
        let coords: [CLLocationCoordinate2D] = track.map(\.coordinate)
        return WorkoutHeroCard(
            sport: sport,
            distanceLabel: distanceLabel,
            durationLabel: durationLabel,
            paceLabel: paceLabel,
            endDate: session.endDate,
            dominantAlpha1Band: dominantBand,
            narrative: analysis?.heroNarrative ?? "",
            routeCoordinates: coords
        )
    }

    private var heroDurationLabel: String {
        guard let d = session.duration else { return "—" }
        let s = Int(d)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    private func heroPaceLabel(distance: Double?) -> String? {
        guard let dist = distance, dist > 100,
              let dur = session.duration, dur > 10
        else { return nil }
        return units.formatPace(elapsedSec: Int(dur), distanceMeters: dist)
    }

    // MARK: - Recover / fix workout

    /// Always-available recovery controls for any workout — recover the full
    /// session from the strap, correct the distance from Apple Health, or trim
    /// the end. Sits with the other action buttons at the bottom of the summary.
    @ViewBuilder
    var recoverWorkoutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Recover / fix this workout", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            RecoverSessionFromStrapButton(session: session)
            RecoveredRouteFromWatchButton(session: session)
            retrimControl
        }
    }

    private var retrimControl: some View {
        RecoveredWorkoutTrimControl(session: session) { endSec in
            await collector.retrimRecoveredWorkout(sessionId: session.id, endSec: endSec)
        }
        .id(session.endDate)
    }

    // MARK: - Partial / recovered banner
    //
    // Displayed at the top of the summary when this workout was
    // reconstructed by `WorkoutRecoveryService` from on-disk backups,
    // or when the live finalize flagged it for low HR coverage. The
    // copy explains *why* the data is partial so the user understands
    // that a "TRIMP 87" on a recovered session isn't the same as 87
    // on a clean one. Tap-target for tooltip kept off — the message
    // is short enough to read in place.
    @ViewBuilder
    func partialDataBanner(reason: PartialDataReason) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(reason.displayLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            Text(partialBannerExplainer(reason: reason, recoveredAt: session.workoutMetadata?.recoveredAt))
                .font(.footnote)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PartialBannerChrome())
    }

    private struct PartialBannerChrome: ViewModifier {
        func body(content: Content) -> some View {
            content
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.orange.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                )
        }
    }

    func partialBannerExplainer(reason: PartialDataReason, recoveredAt: Date?) -> String {
        switch reason {
        case .appCrashed:
            let when = recoveredAt.map { " " + $0.formatted(date: .omitted, time: .shortened) } ?? ""
            return String(localized: "Recovered from on-device backup\(when). Metrics cover only the captured portion of the workout.", bundle: LanguageManager.appBundle)
        case .strapDisconnected:
            return String(localized: "Heart-rate strap dropped out before the end. TRIMP and zones are computed only from the beats that were recorded.", bundle: LanguageManager.appBundle)
        case .userInterrupted:
            return String(localized: "Saved as partial after an interrupted session. You're seeing what was captured before the interruption.", bundle: LanguageManager.appBundle)
        }
    }

    /// Curated key stats — the six numbers that tell a reader "how hard,
    /// how far, how much climb, how fast" at a glance.
    var keyStatsCard: some View {
        WorkoutKeyStatsCard(stats: keyStatTiles)
    }

    /// The tiles are assembled rather than laid out: each `append…` adds its
    /// tile only when the underlying metric exists, so the card shrinks to
    /// whatever this workout actually recorded.
    private var keyStatTiles: [WorkoutKeyStatsCard.Stat] {
        var tiles: [WorkoutKeyStatsCard.Stat] = []
        appendHeartRateTiles(&tiles)
        appendElevationTile(&tiles)
        appendLoadTile(&tiles)
        appendSecondaryLoadTile(&tiles)
        appendBestSplitTile(&tiles)
        return tiles
    }

    private func appendHeartRateTiles(_ tiles: inout [WorkoutKeyStatsCard.Stat]) {
        let meta = session.workoutMetadata
        // Avg HR + peak HR
        if let mean = session.meanHR {
            tiles.append(.init(
                label: String(localized: "AVG HR", bundle: LanguageManager.appBundle),
                value: "\(Int(mean))",
                sub: String(localized: "bpm", bundle: LanguageManager.appBundle),
                icon: "heart.fill",
                tint: AppTheme.fitnessAccent
            ))
        }
        if let peak = meta?.samples?.compactMap({ $0.heartRate }).max() {
            tiles.append(.init(
                label: String(localized: "PEAK HR", bundle: LanguageManager.appBundle),
                value: "\(peak)",
                sub: String(localized: "bpm", bundle: LanguageManager.appBundle),
                icon: "flame.fill",
                tint: .orange
            ))
        }
    }

    private func appendElevationTile(_ tiles: inout [WorkoutKeyStatsCard.Stat]) {
        let meta = session.workoutMetadata
        // Elevation gain
        if let gain = meta?.elevationGainMeters, gain > 2 {
            tiles.append(.init(
                label: String(localized: "ELEV GAIN", bundle: LanguageManager.appBundle),
                value: units.formatElevation(meters: gain),
                sub: String(localized: "climb", bundle: LanguageManager.appBundle),
                icon: "mountain.2.fill",
                tint: AppTheme.sage
            ))
        }
    }

    /// Primary "LOAD" tile uses `preferredTrainingLoad`, which
    /// prefers powerTSS over hrTSS over luciaTRIMP. Per published research
    /// (TrainingPeaks, Stryd RSS): power-based TSS is the canonical
    /// training-load number when a power meter contributed, not a fallback for
    /// missing HR. The sub-line names the source so the user can tell at a
    /// glance which metric backs this number.
    private func appendLoadTile(_ tiles: inout [WorkoutKeyStatsCard.Stat]) {
        let meta = session.workoutMetadata
        if let load = meta?.preferredTrainingLoad {
            let sub = loadTileSubtitle(load, meta: meta)
            let label = loadTileLabel(load.source)
            let icon: String = load.source == .power ? "bolt.fill" : "waveform.path"
            let tint: Color = load.source == .power ? .yellow : AppTheme.dustyRose
            tiles.append(.init(
                label: label,
                // Round (not truncate) so this tile matches the Load &
                // Trajectory row for the same workout; truncating shows
                // 110 here vs 111 there on the same value.
                value: "\(Int(load.value.rounded()))",
                sub: sub,
                icon: icon,
                tint: tint
            ))
        }
    }

    /// The sub-line names the load's source. The strap-dropped case needs no
    /// comparison here: `preferredTrainingLoad` already makes the route
    /// estimate the load (`.routeHistory`) when `routeEstimateReplacesHRLoad`,
    /// and a route estimate (TRIMP scale) is never set against a power,
    /// HRSS or METs load on another scale.
    private func loadTileSubtitle(_ load: (value: Double, source: WorkoutMetadata.TrainingLoadSource), meta: WorkoutMetadata?) -> String {
        switch load.source {
        case .power: return meta?.partialDataReason != nil ? String(localized: "Coggan · power · partial HR", bundle: LanguageManager.appBundle) : String(localized: "Coggan · power", bundle: LanguageManager.appBundle)
        case .hr: return meta?.partialDataReason != nil ? String(localized: "HR · partial", bundle: LanguageManager.appBundle) : String(localized: "1-hour threshold = 100 pts", bundle: LanguageManager.appBundle)
        case .mets: return meta?.partialDataReason != nil ? String(localized: "METs · pace+grade · HR lost", bundle: LanguageManager.appBundle) : String(localized: "METs · pace+grade", bundle: LanguageManager.appBundle)
        case .banister: return meta?.partialDataReason != nil ? String(localized: "Banister · partial", bundle: LanguageManager.appBundle) : "Banister"
        case .routeHistory: return String(localized: "est · route history", bundle: LanguageManager.appBundle)
        }
    }

    private func loadTileLabel(_ source: WorkoutMetadata.TrainingLoadSource) -> String {
        switch source {
        case .power, .hr, .mets: return String(localized: "LOAD", bundle: LanguageManager.appBundle)
        case .banister, .routeHistory: return "TRIMP"
        }
    }

    private func appendSecondaryLoadTile(_ tiles: inout [WorkoutKeyStatsCard.Stat]) {
        let meta = session.workoutMetadata
        // HRSS (the HR-based load) — a secondary tile only when the
        // power-based load is the primary (stored or derived at read time,
        // as `preferredTrainingLoad` resolves it), so power-equipped users
        // still see the HR-side number for comparison without it competing
        // as the headline.
        if meta?.preferredTrainingLoad?.source == .power, let tss = meta?.hrTSS {
            tiles.append(.init(
                label: "HRSS",
                value: "\(Int(tss))",
                sub: String(localized: "1-hour threshold = 100 pts", bundle: LanguageManager.appBundle),
                icon: "speedometer",
                tint: .blue
            ))
        }
    }

    private func appendBestSplitTile(_ tiles: inout [WorkoutKeyStatsCard.Stat]) {
        // Best split
        if let best = bestSplitDisplay {
            tiles.append(.init(
                label: String(localized: "BEST SPLIT", bundle: LanguageManager.appBundle),
                value: best.pace,
                sub: best.caption,
                icon: "stopwatch.fill",
                tint: .purple
            ))
        }
    }

    /// Session map. Non-interactive (`interactionModes: []`) because the
    /// summary is a static report, not a map browser — previous version
    /// allowed pan/zoom gestures which ate CPU + GPU the moment the
    /// sheet appeared and made the whole view feel sluggish. Flat
    /// `elevation: .flat` instead of `.realistic` for the same reason:
    /// realistic elevation pulls 3D terrain tiles in the background.
    var mapCard: some View {
        let coordinates = track.map(\.coordinate)
        return VStack(alignment: .leading, spacing: 0) {
            routeMap(coordinates)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func routeMap(_ coordinates: [CLLocationCoordinate2D]) -> some View {
        Map(
            initialPosition: .region(regionForTrack(coordinates)),
            interactionModes: []
        ) {
            MapPolyline(coordinates: coordinates)
                .stroke(AppTheme.fitnessAccent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            if let start = coordinates.first {
                Marker(String(localized: "Start", bundle: LanguageManager.appBundle), coordinate: start).tint(AppTheme.sage)
            }
            if let end = coordinates.last {
                Marker(String(localized: "End", bundle: LanguageManager.appBundle), coordinate: end).tint(AppTheme.fitnessAccent)
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .frame(height: 260)
    }

    /// Placeholder shown in the same 260pt slot WHILE the track is
    /// decoding from the stored polyline. Without this, the map card
    /// pops in after ~50-100 ms of decode work and shoves α1 + every
    /// card below it down — a jarring layout shift. Reserving the same
    /// height up front means the sheet opens with a stable layout and
    /// the map fills its slot when ready.
    var mapPlaceholder: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text(String(localized: "Loading route…", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    var units: UnitsPreference { UnitsPreferenceStore.current }
}
