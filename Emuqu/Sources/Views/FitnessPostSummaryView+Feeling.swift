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
            guard var session = try archive.retrieve(id) else { return nil }
            session.workoutMetadata?.workoutFeeling = rating
            session.workoutMetadata?.workoutFeelingNote = note
            _ = try archive.archive(session)
            return session
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
        let needsRebuild = stored == nil || (stored?.schemaVersion ?? 0) < WorkoutAnalysisSnapshot.currentVersion
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
            guard var updated = try archive.retrieve(session.id) else { return }
            updated.workoutMetadata?.analysisSnapshot = snapshot
            _ = try archive.archive(updated)
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
        var easy = 0, thr = 0, hard = 0
        var prev = 0
        for s in samples {
            guard let a = s.alpha1 else { continue }
            let dt = max(1, s.offsetSec - prev)
            prev = s.offsetSec
            if a >= HRVConstants.DFA.alpha1AerobicThreshold {
                easy += dt
            } else if a >= HRVConstants.DFA.alpha1AnaerobicThreshold {
                thr += dt
            } else {
                hard += dt
            }
        }
        guard easy + thr + hard > 0 else { return nil }
        return regimeWording(easy: easy, thr: thr, hard: hard, totalMin: totalMin)
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
        let pct = String(format: "%+.1f %%", locale: .current, decoupling)
        if decoupling < 5 {
            return String(localized: "Pa:Hr decoupling stayed at \(pct) — strong aerobic efficiency, no signs of fatigue mid-session.", bundle: LanguageManager.appBundle)
        }
        if decoupling < 8 {
            return String(localized: "Pa:Hr decoupling \(pct) — mild drift in the second half; worth watching for hydration / fueling.", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Pa:Hr decoupling \(pct) — significant efficiency loss over the session. Heat, fatigue, or nutrition likely factors.", bundle: LanguageManager.appBundle)
    }

    /// Below 30 TRIMP there is nothing worth saying, so this stays silent.
    private func trimpSentence(meta: WorkoutMetadata?) -> String? {
        guard let trimp = meta?.luciaTRIMP else { return nil }
        if trimp >= 150 {
            return String(localized: "TRIMP \(Int(trimp)) — a heavy session on your recent load.", bundle: LanguageManager.appBundle)
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
            narrative: heroNarrative(samples: meta?.samples ?? [], durationSec: session.duration ?? 0),
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
            Task { await collector.retrimRecoveredWorkout(sessionId: session.id, endSec: endSec) }
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
                sub: "bpm",
                icon: "heart.fill",
                tint: AppTheme.fitnessAccent
            ))
        }
        if let peak = meta?.samples?.compactMap({ $0.heartRate }).max() {
            tiles.append(.init(
                label: String(localized: "PEAK HR", bundle: LanguageManager.appBundle),
                value: "\(peak)",
                sub: "bpm",
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
        case .hr: return meta?.partialDataReason != nil ? String(localized: "HR · partial", bundle: LanguageManager.appBundle) : "1hr@LT = 100"
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
                sub: "1hr@LT = 100",
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
        var prev = 0
        for s in samples {
            guard let a = s.alpha1 else { continue }
            let dt = max(1, s.offsetSec - prev)
            prev = s.offsetSec
            secs[Self.alpha1Band(a), default: 0] += dt
        }
        guard let top = secs.max(by: { $0.value < $1.value }), top.value > 0 else { return nil }
        return top.key
    }

    /// The published α1 thresholds: ≥0.85 below AeT, 0.65–0.85 near AeT,
    /// 0.45–0.65 near VT2, below that above VT2.
    private static func alpha1Band(_ a: Double) -> LiveDFAAnalyzer.Band {
        switch a {
        case 0.85...: .belowAeT
        case 0.65 ..< 0.85: .nearAeT
        case 0.45 ..< 0.65: .nearVT2
        default: .aboveVT2
        }
    }

    /// Plain-English narrative for the hero. Generated from real data
    /// (no guesses): first AT1 crossing, dominant band, total minutes.
    func heroNarrative(samples: [WorkoutSample], durationSec: TimeInterval) -> String {
        let totalMin = Int(durationSec / 60)
        guard totalMin > 0 else { return "" }
        guard samples.contains(where: { $0.alpha1 != nil }) else {
            return String(localized: "\(totalMin) minutes of movement. α1 not captured — strap data unavailable for this session.", bundle: LanguageManager.appBundle)
        }
        let bands = Self.alpha1BandTotals(samples: samples)
        if bands.between == 0, bands.above == 0 {
            return String(localized: "\(totalMin) min aerobic-base work — α1 stayed above threshold the whole time. Ideal Zone-2 session.", bundle: LanguageManager.appBundle)
        }
        if bands.below == 0, bands.between == 0 {
            return String(localized: "\(totalMin) min above anaerobic threshold — very high physiological cost. Short, intense efforts.", bundle: LanguageManager.appBundle)
        }
        if let c = bands.firstCross {
            return crossingNarrative(cross: c, bands: bands)
        }
        return String(localized: "\(totalMin) min · Easy \(bands.below / 60)m · Threshold \(bands.between / 60)m · Hard \(bands.above / 60)m.", bundle: LanguageManager.appBundle)
    }

    /// Seconds spent in each α1 band, plus the first downward AT1 crossing.
    /// (Names read inverted — `below` counts time BELOW aerobic threshold in
    /// effort terms, which is α1 ABOVE 0.75 — kept as-is to match the callers.)
    struct HeroBands {
        var below = 0
        var between = 0
        var above = 0
        var firstCross: (Int, Int?)?

        mutating func add(alpha1 a: Double, dt: Int) {
            if a >= HRVConstants.DFA.alpha1AerobicThreshold {
                below += dt
            } else if a >= HRVConstants.DFA.alpha1AnaerobicThreshold {
                between += dt
            } else {
                above += dt
            }
        }
    }

    private static func alpha1BandTotals(samples: [WorkoutSample]) -> HeroBands {
        var bands = HeroBands()
        var last: Double?
        var prev = 0
        for s in samples {
            guard let a = s.alpha1 else { continue }
            let dt = max(1, s.offsetSec - prev)
            prev = s.offsetSec
            bands.add(alpha1: a, dt: dt)
            if bands.firstCross == nil, let p = last,
               p >= HRVConstants.DFA.alpha1AerobicThreshold, a < HRVConstants.DFA.alpha1AerobicThreshold {
                bands.firstCross = (s.offsetSec, s.heartRate)
            }
            last = a
        }
        return bands
    }

    private func crossingNarrative(cross c: (Int, Int?), bands: HeroBands) -> String {
        let mm = c.0 / 60, ss = c.0 % 60
        let hrPart = c.1.map { String(localized: " at \($0) bpm", bundle: LanguageManager.appBundle) } ?? ""
        let hardMin = bands.above / 60
        if hardMin > 0 {
            return String(localized: "Crossed aerobic threshold at \(mm):\(String(format: "%02d", ss))\(hrPart). \(hardMin) min above anaerobic threshold. Mixed-intensity session.", bundle: LanguageManager.appBundle)
        }
        return String(localized: "Crossed aerobic threshold at \(mm):\(String(format: "%02d", ss))\(hrPart). \(bands.between / 60) min at threshold, \(bands.below / 60) min easy.", bundle: LanguageManager.appBundle)
    }

    // MARK: - Legacy cards (kept for reference sections below the hero)

    var sportHeader: some View {
        HStack(spacing: 12) {
            if let sport = session.sport {
                Image(systemName: sport.icon)
                    .font(.title2)
                    .foregroundStyle(AppTheme.fitnessAccent)
                Text(sport.displayName)
                    .font(.title2.weight(.semibold))
            }
            Spacer()
            if let duration = session.duration {
                Text(formatDuration(duration))
                    .font(.title3.weight(.medium).monospacedDigit())
                    .foregroundStyle(AppTheme.textSecondary)
            }
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

    var headlineCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            distanceRows
            effortRows
            powerRows
            rowingRows
            energyRows
            loadRows
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var distanceRows: some View {
        if let distance = session.workoutMetadata?.distanceMeters, distance > 0 {
            headlineRow(String(localized: "Distance", bundle: LanguageManager.appBundle), value: units.formatDistance(meters: distance))
        }
        if let duration = session.duration {
            headlineRow(String(localized: "Duration", bundle: LanguageManager.appBundle), value: formatDuration(sec: Int(duration)))
        }
        if let paceStr = avgPaceDisplay {
            headlineRow(String(localized: "Average Pace", bundle: LanguageManager.appBundle), value: paceStr)
        }
        if let maxSpeedStr = maxSpeedDisplay {
            headlineRow(String(localized: "Top Speed", bundle: LanguageManager.appBundle), value: maxSpeedStr)
        }
        if let gain = session.workoutMetadata?.elevationGainMeters, gain > 0 {
            headlineRow(String(localized: "Elevation Gain", bundle: LanguageManager.appBundle), value: units.formatElevation(meters: gain))
        }
    }

    @ViewBuilder
    private var effortRows: some View {
        if let hr = session.meanHR {
            headlineRow(String(localized: "Average HR", bundle: LanguageManager.appBundle), value: "\(Int(hr)) bpm")
        }
        if let peakHRStr = peakHRDisplay {
            headlineRow(String(localized: "Peak HR", bundle: LanguageManager.appBundle), value: peakHRStr)
        }
        if let avgCad = avgCadenceDisplay {
            headlineRow(String(localized: "Average Cadence", bundle: LanguageManager.appBundle), value: avgCad)
        }
    }

    @ViewBuilder
    private var powerRows: some View {
        if let np = session.workoutMetadata?.normalizedPowerWatts {
            let caption = normalizedPowerCaption
            headlineRow(String(localized: "Normalized Power", bundle: LanguageManager.appBundle), value: "\(Int(np.rounded())) W", caption: caption)
        }
        if let avgP = session.workoutMetadata?.averagePowerWatts {
            headlineRow(String(localized: "Average Power", bundle: LanguageManager.appBundle), value: "\(Int(avgP.rounded())) W", caption: String(localized: "foot pod", bundle: LanguageManager.appBundle))
        }
        if let peakP = session.workoutMetadata?.peakPowerWatts {
            headlineRow(String(localized: "Peak Power", bundle: LanguageManager.appBundle), value: "\(peakP) W")
        }
        if let tss = session.workoutMetadata?.powerTSS,
           let ftp = session.workoutMetadata?.ftpAtTimeOfSession {
            headlineRow(String(localized: "Power TSS", bundle: LanguageManager.appBundle), value: String(format: "%.0f", locale: .current, tss), caption: String(localized: "FTP \(ftp) W · 1 hr at FTP = 100 pts", bundle: LanguageManager.appBundle))
        }
        if let vi = session.workoutMetadata?.variabilityIndex {
            let label = variabilityLabel(vi)
            headlineRow(String(localized: "Variability", bundle: LanguageManager.appBundle), value: String(format: "%.2f", locale: .current, vi), caption: label)
        }
    }

    @ViewBuilder
    private var rowingRows: some View {
        // Rowing-specific rows (PM5). Only render for rowing sessions —
        // these fields stay nil for everything else.
        if let split = session.workoutMetadata?.averageSplitSecPer500m {
            let mins = Int(split) / 60
            let secs = Int(split) % 60
            headlineRow(String(localized: "Avg Split", bundle: LanguageManager.appBundle), value: String(format: "%d:%02d /500m", mins, secs), caption: String(localized: "rower split pace", bundle: LanguageManager.appBundle))
        }
        if let strokes = session.workoutMetadata?.strokeCount {
            headlineRow(String(localized: "Strokes", bundle: LanguageManager.appBundle), value: "\(strokes)")
        }
        if let drag = session.workoutMetadata?.dragFactor {
            headlineRow(String(localized: "Drag Factor", bundle: LanguageManager.appBundle), value: "\(drag)", caption: String(localized: "PM5 fan damper calibration", bundle: LanguageManager.appBundle))
        }
    }

    @ViewBuilder
    private var energyRows: some View {
        if let mets = avgMETsDisplay {
            headlineRow(String(localized: "Avg METs (est)", bundle: LanguageManager.appBundle), value: mets, caption: String(localized: "rough energy proxy", bundle: LanguageManager.appBundle))
        }
        if let calories = estimatedCaloriesDisplay {
            headlineRow(String(localized: "Calories (est)", bundle: LanguageManager.appBundle), value: calories)
        }
    }

    @ViewBuilder
    private var loadRows: some View {
        if let rmssd = session.rmssd {
            headlineRow("RMSSD", value: String(format: "%.0f ms", locale: .current, rmssd))
        }
        if let trimp = session.workoutMetadata?.luciaTRIMP {
            headlineRow("TRIMP", value: String(format: "%.0f", locale: .current, trimp), caption: String(localized: "Banister exponential · HRR-based", bundle: LanguageManager.appBundle))
        }
        if let tss = session.workoutMetadata?.hrTSS {
            headlineRow("hrTSS", value: String(format: "%.0f", locale: .current, tss), caption: String(localized: "1-hour threshold = 100 pts", bundle: LanguageManager.appBundle))
        }
        if let bestSplit = bestSplitDisplay {
            headlineRow(String(localized: "Best split", bundle: LanguageManager.appBundle), value: bestSplit.pace, caption: bestSplit.caption)
        }
    }

    /// Normalized Power is the meaningful "training stress" power metric
    /// (4th-root smoothing penalises surges) — promote it ahead of avg / peak
    /// so it's the headline number rather than a mid-list row. The caption
    /// pulls double duty: explains what NP is the first time you see it AND
    /// surfaces the IF when an FTP is set.

    /// Doubles as an explainer the first time the row is seen and, once an
    /// FTP is set, as the place the intensity factor surfaces.
    private var normalizedPowerCaption: String {
        if let intensityFactor = session.workoutMetadata?.intensityFactor {
            return String(format: NSLocalizedString("IF %.2f · 30s rolling, surge-weighted", bundle: LanguageManager.appBundle, comment: ""), intensityFactor)
        }
        return String(localized: "30s rolling, surge-weighted (vs raw average)", bundle: LanguageManager.appBundle)
    }

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
        return String(localized: "1-min HR recovery \(one.drop) bpm — healthy recovery response.", bundle: LanguageManager.appBundle)
    }
    if one.drop >= 8 {
        return String(localized: "1-min HR recovery \(one.drop) bpm — a touch sluggish; could reflect accumulated fatigue.", bundle: LanguageManager.appBundle)
    }
    return String(localized: "1-min HR recovery \(one.drop) bpm — low. Worth watching over the next few sessions; may indicate you need more rest.", bundle: LanguageManager.appBundle)
}

/// The variability index is a ratio; the user reads the word, not the
/// number, so the row leads with the description.
private func variabilityLabel(_ vi: Double) -> String {
    if vi < 1.05 { return String(localized: "steady effort", bundle: LanguageManager.appBundle) }
    if vi < 1.15 { return String(localized: "rolling / mixed effort", bundle: LanguageManager.appBundle) }
    return String(localized: "interval / surge effort", bundle: LanguageManager.appBundle)
}
