import CoreLocation
import MapKit
import SwiftUI

// The subjective-feeling section, snapshot migration and session-analysis
// narrative. The hero, HRR banner and key-stats grid live in
// `FitnessPostSummaryView.swift`.

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
    /// blocks the main thread on save.
    func saveWorkoutFeeling(rating: Int, note: String?) async {
        let archive = dependencies.storage.sessionArchive
        let id = session.id
        let updated: HRVSession? = await Task.detached(priority: .userInitiated) {
            Self.persistFeeling(rating: rating, note: note, id: id, archive: archive)
        }.value
        guard let updated else { return }
        refreshedSession = updated
        feelingEditing = false
        collector.notifyArchiveChanged()
    }

    /// Nil on any failure — the rating simply isn't persisted and the UI stays
    /// in edit mode rather than claiming a save that didn't happen.
    nonisolated private static func persistFeeling(
        rating: Int,
        note: String?,
        id: UUID,
        archive: SessionArchive
    ) -> HRVSession? {
        do {
            return try FitnessSummaryCards.updateArchived(id, in: archive) { stored in
                stored.workoutMetadata?.workoutFeeling = rating
                stored.workoutMetadata?.workoutFeelingNote = note
            }
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
    func backfillAnalysisSnapshotIfNeeded() async {
        let stored = session.workoutMetadata?.analysisSnapshot
        let needsRebuild = stored?.needsRebuild ?? true
        guard needsRebuild, let inputs = snapshotInputs() else { return }
        let snapshot = await Task.detached(priority: .userInitiated) {
            WorkoutAnalysisSnapshotBuilder.build(inputs)
        }.value
        persistAnalysisSnapshot(snapshot)
    }

    private func snapshotInputs() -> WorkoutAnalysisSnapshotBuilder.Inputs? {
        guard let meta = session.workoutMetadata,
              let samples = meta.samples, !samples.isEmpty,
              let duration = session.duration
        else { return nil }
        let settings = UserSettingsBridge.snapshot()
        return WorkoutAnalysisSnapshotBuilder.Inputs(
            sport: meta.sport,
            durationSec: duration,
            distanceMeters: meta.distanceMeters,
            elevationGainMeters: meta.elevationGainMeters,
            elevationLossMeters: meta.elevationLossMeters,
            meanHR: session.meanHR,
            userMaxHR: settings.userMaxHR,
            bodyWeightKg: settings.weightKg,
            samples: samples,
            splits: meta.splits ?? [],
            trimp: meta.luciaTRIMP,
            decouplingPercent: meta.decouplingPercent
        )
    }

    private func persistAnalysisSnapshot(_ snapshot: WorkoutAnalysisSnapshot) {
        do {
            let archive = dependencies.storage.sessionArchive
            guard let updated = try FitnessSummaryCards.updateArchived(session.id, in: archive, { stored in
                stored.workoutMetadata?.analysisSnapshot = snapshot
            }) else { return }
            refreshedSession = updated
            collector.notifyArchiveChanged()
            debugLog("[SnapshotBackfill] wrote snapshot for \(session.id)")
        } catch {
            debugLog("[SnapshotBackfill] failed: \(error)", level: .warning)
        }
    }

    // MARK: - Session Analysis ("How you did")

    /// 2-3 sentence coach-style narrative synthesising the session's
    /// key physiological signals — α1 dominant band, HR zone
    /// distribution, TRIMP relative to the user's typical load,
    /// decoupling, HRR quality, elevation context. Mirrors Morning
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

    /// Assemble the "how you did" narrative. Prefers the pre-computed
    /// snapshot stored on WorkoutMetadata (written once at session
    /// finalize) and falls back to an on-demand computation only for
    /// sessions without a snapshot. One field read, no sample iteration,
    /// is what keeps summary reloads fast.
    func generateSessionAnalysis() -> String {
        if let cached = session.workoutMetadata?.analysisSnapshot?.howYouDidNarrative,
           !cached.isEmpty {
            return cached
        }
        return legacyGenerateSessionAnalysis()
    }

    func legacyGenerateSessionAnalysis() -> String {
        let meta = session.workoutMetadata
        let totalMin = Int((session.duration ?? 0) / 60)
        guard totalMin > 0 else { return "" }
        return [
            alpha1RegimeSentence(samples: meta?.samples ?? [], totalMin: totalMin),
            decouplingSentence(meta: meta),
            hrrSentence(meta: meta),
            trimpSentence(meta: meta),
            elevationSentence(meta: meta)
        ].compactMap { $0 }.joined(separator: " ")
    }

    /// Time in each α1 band, worded as the shape of the session.
    private func alpha1RegimeSentence(samples: [WorkoutSample], totalMin: Int) -> String? {
        guard samples.contains(where: { $0.alpha1 != nil }) else { return nil }
        let bands = Self.alpha1BandTotals(samples: samples)
        guard bands.belowAT1 + bands.between + bands.aboveAT2 > 0 else { return nil }
        return regimeWording(easy: bands.belowAT1, thr: bands.between, hard: bands.aboveAT2, totalMin: totalMin)
    }

    private func regimeWording(easy: Int, thr: Int, hard: Int, totalMin: Int) -> String {
        if thr == 0, hard == 0 {
            return String(localized: "Solid aerobic-base effort — α1 stayed above threshold for the full \(totalMin) min.", bundle: LanguageManager.appBundle)
        }
        if easy == 0, thr == 0 {
            return String(localized: "Hard session — you were above anaerobic threshold the whole time (\(hard / 60) min at α1 < 0.50).", bundle: LanguageManager.appBundle)
        }
        if hard > 0 {
            return String(localized: "Mixed-intensity: \(easy / 60) min easy, \(thr / 60) min threshold, \(hard / 60) min above anaerobic threshold.", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Threshold workout — you pushed into the LT1-LT2 band for \(thr / 60) min, easy the remaining \(easy / 60) min.", bundle: LanguageManager.appBundle)
    }

    /// Pa:Hr decoupling — aerobic efficiency across the session. Only
    /// meaningful on efforts of 10 min or more.
    private func decouplingSentence(meta: WorkoutMetadata?) -> String? {
        guard let decoupling = meta?.decouplingPercent, (session.duration ?? 0) >= 600 else { return nil }
        let pct = String(format: "%+.1f %%", locale: LanguageManager.appLocale, decoupling)
        if decoupling < 5 {
            return String(localized: "Pa:Hr decoupling stayed at \(pct) — strong aerobic efficiency, no signs of fatigue mid-session.", bundle: LanguageManager.appBundle)
        }
        if decoupling < 8 {
            return String(localized: "Pa:Hr decoupling \(pct) — mild drift in the second half; worth watching for hydration / fueling.", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Pa:Hr decoupling \(pct) — significant efficiency loss over the session. Heat, fatigue, or nutrition likely factors.", bundle: LanguageManager.appBundle)
    }

    /// Fixed Lucia TRIMP bands (150 / 80 / 30), not a comparison with the
    /// user's usual load. Below 30 there is nothing worth saying, so this
    /// stays silent.
    private func trimpSentence(meta: WorkoutMetadata?) -> String? {
        guard let trimp = meta?.luciaTRIMP else { return nil }
        if trimp >= 150 {
            return String(localized: "TRIMP \(Int(trimp)) — a heavy session.", bundle: LanguageManager.appBundle)
        }
        if trimp >= 80 {
            return String(localized: "TRIMP \(Int(trimp)) — moderate aerobic stimulus.", bundle: LanguageManager.appBundle)
        }
        if trimp >= 30 {
            return String(localized: "TRIMP \(Int(trimp)) — light maintenance effort.", bundle: LanguageManager.appBundle)
        }
        return nil
    }

    private func elevationSentence(meta: WorkoutMetadata?) -> String? {
        guard let gain = meta?.elevationGainMeters, gain >= 30 else { return nil }
        return String(localized: "You climbed \(units.formatElevation(meters: gain)).", bundle: LanguageManager.appBundle)
    }

    // MARK: - Hero (new, morning-parity)

    /// Builds the inputs for the WorkoutHeroCard from the session and
    /// delegates rendering to the dedicated card component. Keeps data
    /// shaping in one place and the card pure.
    var heroCard: some View {
        let meta = session.workoutMetadata
        let sport = meta?.sport ?? .walk
        let distance = meta?.distanceMeters
        let distanceLabel = distance.map { units.formatDistance(meters: $0) } ?? "—"
        let durationLabel = heroDurationLabel
        let paceLabel = heroPaceLabel(distance: distance)
        let dominantBand = heroDominantAlpha1Band(samples: meta?.samples ?? [])
        let coords: [CLLocationCoordinate2D] = track.map(\.coordinate)
        return WorkoutHeroCard(
            sport: sport,
            distanceLabel: distanceLabel,
            durationLabel: durationLabel,
            paceLabel: paceLabel,
            endDate: session.endDate,
            dominantAlpha1Band: dominantBand,
            narrative: meta?.analysisSnapshot?.heroNarrative
                ?? heroNarrative(samples: meta?.samples ?? [], durationSec: session.duration ?? 0),
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

    /// Route-history extrapolation wins the sub-line when it is meaningfully
    /// higher than what was recorded — that is the strap-dropped case.
    private func loadTileSubtitle(_ load: (value: Double, source: WorkoutMetadata.TrainingLoadSource), meta: WorkoutMetadata?) -> String {
        // Route-history extrapolation still wins the sub-line
        // when it's meaningfully higher than the recorded value
        // (the strap-dropped case).
        if let est = meta?.extrapolatedTRIMP,
           let conf = meta?.extrapolationConfidence,
           est > load.value + 1 {
            if let routeName = meta?.extrapolationRouteName, conf >= 0.55 {
                return String(localized: "~\(Int(est)) est · \(routeName)", bundle: LanguageManager.appBundle)
            }
            return String(localized: "~\(Int(est)) est for full route", bundle: LanguageManager.appBundle)
        }
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
        // hrTSS — surface AS A SECONDARY tile only when powerTSS is the
        // primary, so power-equipped users still see the HR-side number
        // for comparison without it competing as the headline.
        if meta?.powerTSS != nil, let tss = meta?.hrTSS {
            tiles.append(.init(
                label: "hrTSS",
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

    /// Summarise α1 into the band the user spent the most time in. Null
    /// when no samples or α1 never resolved.
    func heroDominantAlpha1Band(samples: [WorkoutSample]) -> LiveDFAAnalyzer.Band? {
        var secs: [LiveDFAAnalyzer.Band: Int] = [:]
        for reading in Self.alpha1Readings(samples) {
            secs[LiveDFAAnalyzer.Band.display(alpha1: reading.alpha1), default: 0] += reading.dt
        }
        guard let top = secs.max(by: { $0.value < $1.value }), top.value > 0 else { return nil }
        return top.key
    }

    /// Each α1 reading with the seconds it stands for, timed as the α1 card
    /// times them (`Alpha1ReportCards.sampleSeconds(at:previous:)`: the gap
    /// since the previous reading, capped at 5 s; 1 s for the first). Readings
    /// inside a beat-artifact dip (`Alpha1ReportCards.ectopicShadows(in:)`)
    /// are left out.
    static func alpha1Readings(_ samples: [WorkoutSample]) -> [(sample: WorkoutSample, alpha1: Double, dt: Int)] {
        let shadows = Alpha1ReportCards.ectopicShadows(in: samples)
        var readings: [(sample: WorkoutSample, alpha1: Double, dt: Int)] = []
        var prev: Int?
        for s in samples {
            guard let a = s.alpha1 else { continue }
            let dt = Alpha1ReportCards.sampleSeconds(at: s.offsetSec, previous: prev)
            prev = s.offsetSec
            guard !shadows.contains(where: { $0.contains(offsetSec: s.offsetSec) }) else { continue }
            readings.append((s, a, dt))
        }
        return readings
    }

    /// Plain-English narrative for the hero, for a workout saved before the
    /// analysis snapshot carried one. Generated from real data (no guesses):
    /// first sustained AT1 crossing, dominant band, total minutes.
    func heroNarrative(samples: [WorkoutSample], durationSec: TimeInterval) -> String {
        let totalMin = Int(durationSec / 60)
        guard totalMin > 0 else { return "" }
        guard samples.contains(where: { $0.alpha1 != nil }) else {
            return String(localized: "\(totalMin) minutes of movement. α1 not captured — strap data unavailable for this session.", bundle: LanguageManager.appBundle)
        }
        let bands = Self.alpha1BandTotals(samples: samples)
        if bands.between == 0, bands.aboveAT2 == 0 {
            return String(localized: "\(totalMin) min aerobic-base work — α1 stayed above threshold the whole time. Ideal Zone-2 session.", bundle: LanguageManager.appBundle)
        }
        if bands.belowAT1 == 0, bands.between == 0 {
            return String(localized: "\(totalMin) min above anaerobic threshold — very high physiological cost. Short, intense efforts.", bundle: LanguageManager.appBundle)
        }
        if let c = bands.firstCrossing {
            return crossingNarrative(cross: c, bands: bands)
        }
        return String(localized: "\(totalMin) min · Easy \(bands.belowAT1 / 60)m · Threshold \(bands.between / 60)m · Hard \(bands.aboveAT2 / 60)m.", bundle: LanguageManager.appBundle)
    }

    /// Seconds spent in each α1 band, plus the first AT1 crossing that holds
    /// (after the 2-minute warm-up and sustained for 3 minutes), from
    /// `Alpha1ReportCards.alpha1BandTotals`, the calculation the α1 card, the
    /// stored snapshot and the PDF share: 5 s sample cap and beat-artifact dips
    /// left out, so one ectopic dip can't name a threshold.
    private static func alpha1BandTotals(samples: [WorkoutSample]) -> Alpha1ReportCards.Alpha1Bands {
        Alpha1ReportCards.alpha1BandTotals(samples: samples, shadows: Alpha1ReportCards.ectopicShadows(in: samples))
    }

    private func crossingNarrative(cross c: (Int, Int?), bands: Alpha1ReportCards.Alpha1Bands) -> String {
        let mm = c.0 / 60, ss = c.0 % 60
        let hrPart = c.1.map { String(localized: " at \($0) bpm", bundle: LanguageManager.appBundle) } ?? ""
        let hardMin = bands.aboveAT2 / 60
        if hardMin > 0 {
            return String(localized: "Crossed aerobic threshold at \(mm):\(String(format: "%02d", ss))\(hrPart). \(hardMin) min above anaerobic threshold. Mixed-intensity session.", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Crossed aerobic threshold at \(mm):\(String(format: "%02d", ss))\(hrPart). \(bands.between / 60) min at threshold, \(bands.belowAT1 / 60) min easy.", bundle: LanguageManager.appBundle)
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

// MARK: - File-scope helpers
//
// Each touches none of the view's members — including its private
// statics — and calls nothing inside it. `private` at file scope is
// fileprivate, so every call site in this file resolves.

private func hrrSentence(meta: WorkoutMetadata?) -> String? {
    guard let one = meta?.hrrSamples?.bestAtOneMinute else { return nil }
    if one.drop >= 18 {
        return String(localized: "1-min HR recovery \(one.drop) bpm — excellent vagal reactivation.", bundle: LanguageManager.appBundle)
    }
    if one.drop >= 12 {
        return String(localized: "1-min HR recovery \(one.drop) bpm — at or above the 12 bpm convention.", bundle: LanguageManager.appBundle)
    }
    if one.drop >= 8 {
        return String(localized: "1-min HR recovery \(one.drop) bpm — a touch sluggish; could reflect accumulated fatigue.", bundle: LanguageManager.appBundle)
    }
    return String(localized: "1-min HR recovery \(one.drop) bpm — low. Worth watching over the next few sessions; may indicate you need more rest.", bundle: LanguageManager.appBundle)
}
