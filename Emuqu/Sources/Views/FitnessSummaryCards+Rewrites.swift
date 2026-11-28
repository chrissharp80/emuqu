import CoreLocation
import SwiftUI

// The two cards that rewrite the archived workout in place: re-smooth
// elevation from terrain data and re-analyze α1 from the stored RR series.

extension FitnessSummaryCards {
    /// Action card offering to recompute elevation using real terrain data
    /// from a DEM (Digital Elevation Model) lookup service — the same
    /// approach Strava and Garmin use when barometer data is missing.
    /// Replaces the previous GPS-altitude smoothing heuristics (which
    /// either inflated gain or undercounted it depending on threshold;
    /// no amount of smoothing the noise gives the right answer).
    ///
    /// Service: OpenTopoData only, NED 10 m for US routes and SRTM 30 m
    /// elsewhere; a failed lookup shows its error. Threshold: `TopoElevationService`'s
    /// default 15 m sustained climb. The copy says the route points leave
    /// the device.
    @ViewBuilder
    var resmoothElevationCard: some View {
        if !track.isEmpty {
            resmoothElevationBody
        }
    }

    private var resmoothElevationBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            resmoothElevationHeader
            let storedGain = session.workoutMetadata?.elevationGainMeters ?? 0
            Text(String(localized: "Current: \(units.formatElevation(meters: storedGain)). Looks up real terrain elevation along your route from OpenTopoData, a public elevation map (10 m data in the US, 30 m elsewhere), and counts only sustained climbs of 15 m or more. Up to 100 of your route's points, rounded to about 11 m, are sent to that service. Requires network.", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            resmoothPreviewNote
            resmoothErrorNote
            resmoothElevationButton
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var resmoothElevationButton: some View {
        Button {
            Task { await runResmoothElevation() }
        } label: {
            Text(elevResmoothing
                ? String(localized: "Querying map & saving…", bundle: LanguageManager.appBundle)
                : String(localized: "Look up and save real elevation", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(AppTheme.fitnessAccent.opacity(elevResmoothing ? 0.35 : 1))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(elevResmoothing)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var resmoothErrorNote: some View {
        if let err = elevResmoothError {
            Text(err)
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var resmoothPreviewNote: some View {
        if let preview = elevResmoothPreview {
            Text(String(localized: "Map-derived: \(units.formatElevation(meters: preview.gain)) gain · \(units.formatElevation(meters: preview.loss)) loss", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.sageText)
        }
    }

    private var resmoothElevationHeader: some View {
        HStack {
            Text(String(localized: "Recompute elevation (topo map)", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            if elevResmoothing { ProgressView().scaleEffect(0.7) }
        }
    }

    /// Single atomic action: fetch DEM + save. No preview / second-tap dance.
    /// A two-phase flow shows the right number in the preview and leaves the
    /// user wondering why it hasn't saved, not realising a second tap is
    /// needed.
    ///
    /// Default 15 m sustained-climb threshold (calibrated against iSmoothRun /
    /// Apple Fitness / FITIV — all barometer-based on iPhone, all agreed at
    /// ~395 ft on one rolling-hills test loop). Retroactive DEM-based recomputes will
    /// never match a barometer-recorded session exactly, but with NED 10 m +
    /// 15 m threshold the numbers land within ~5 %.
    func runResmoothElevation() async {
        elevResmoothing = true
        elevResmoothError = nil
        defer { elevResmoothing = false }
        do {
            let result = try await TopoElevationService.elevations(for: track, maxSamples: 100)
            elevResmoothPreview = (gain: result.gainMeters, loss: result.lossMeters)
            await saveResmoothedElevation(gain: result.gainMeters, loss: result.lossMeters)
        } catch let error as TopoElevationService.ServiceError {
            elevResmoothError = String(localized: "Elevation lookup failed — \(describe(error))", bundle: LanguageManager.appBundle)
        } catch {
            elevResmoothError = String(localized: "Elevation lookup failed — \(error.localizedDescription)", bundle: LanguageManager.appBundle)
        }
    }

    /// Read-modify-write of the archived copy under the archive lock, so a
    /// concurrent writer can't be overwritten, with an iCloud re-upload
    /// requested. Returns the stored result, or nil when the session isn't
    /// in the archive.
    nonisolated static func updateArchived(
        _ id: UUID,
        in archive: SessionArchive,
        _ change: (inout HRVSession) -> Void
    ) throws -> HRVSession? {
        var saved: HRVSession?
        do {
            try archive.update(id) { stored in
                change(&stored)
                saved = stored
            }
        } catch SessionArchive.ArchiveError.fileNotFound {
            return nil
        }
        return saved
    }

    func describe(_ error: TopoElevationService.ServiceError) -> String {
        switch error {
        case .badResponse(let msg):
            // The service's own message is technical English; it goes to the
            // log, and the user gets a translated summary.
            debugLog("[ResmoothElevation] bad response: \(msg)", level: .warning)
            return String(localized: "unexpected response from the elevation service", bundle: LanguageManager.appBundle)
        case .emptyTrack: return String(localized: "no GPS track", bundle: LanguageManager.appBundle)
        case .networkError(let inner): return inner.localizedDescription
        }
    }

    /// Directly updates our own @State so the UI refreshes unconditionally, and
    /// also bumps the archive-change signal so the fitness tab's hero reloads
    /// behind us. Relying solely on the archive observer to close the loop is
    /// fragile — if it doesn't fire (timing quirks, view-lifecycle edge cases)
    /// the user sees "saved" but the number doesn't change on screen — so
    /// both paths run. The archive write runs on a detached task.
    func saveResmoothedElevation(gain: Double, loss: Double) async {
        elevResmoothing = true
        defer { elevResmoothing = false }
        let (id, archive) = (session.id, self.archive)
        let settings = UserSettingsBridge.snapshot(of: settingsManager)
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.writeResmoothedElevation(id, gain: gain, loss: loss, archive: archive, settings: settings)
        }.value
        switch outcome {
        case .success(let updated?):
            refreshedSession = updated
            collector.archiveSignal.notifyChanged()
            elevResmoothPreview = nil
            debugLog("[ResmoothElevation] rewrote gain=\(Int(gain)) loss=\(Int(loss)) for session \(id)")
        case .success(nil):
            elevResmoothError = String(localized: "Session not found in archive.", bundle: LanguageManager.appBundle)
        case .failure(let error):
            elevResmoothError = String(localized: "Couldn't save: \(error.localizedDescription)", bundle: LanguageManager.appBundle)
        }
    }

    /// Stores the new gain / loss on the archived session and rebuilds its
    /// analysis snapshot (VAM, grade-adjusted pace, narratives) from them;
    /// nil when the session is no longer in the archive, the error when the
    /// write threw.
    nonisolated private static func writeResmoothedElevation(
        _ id: UUID, gain: Double, loss: Double, archive: SessionArchive, settings: UserSettingsBridge
    ) -> Result<HRVSession?, Error> {
        Result {
            try updateArchived(id, in: archive) { stored in
                stored.workoutMetadata?.elevationGainMeters = gain
                stored.workoutMetadata?.elevationLossMeters = loss
                rebuildAnalysisSnapshot(&stored, settings: settings)
            }
        }
    }

    /// Action card offering to re-run α1 analysis with the current
    /// artifact filter. Sessions recorded without `LiveDFAAnalyzer.cleanRRForDFA`
    /// had unfiltered RR fed into DFA — producing α1 values
    /// stuck at 1.5-2.0 (Brownian range) regardless of effort. This
    /// button regenerates α1 from the stored RRSeries using the current
    /// filter + DFA and writes it back to the archive; the open sheet
    /// refreshes in place with the new values.
    @ViewBuilder
    var reanalyzeAlpha1Card: some View {
        // Shown whenever the session has α1 samples and enough stored RR
        // (64+ beats) to recompute them.
        let samples = session.workoutMetadata?.samples ?? []
        let hasAlpha1 = samples.contains { $0.alpha1 != nil }
        let hasRR = (session.rrSeries?.points.count ?? 0) >= 64
        if hasAlpha1, hasRR {
            reanalyzeAlpha1Body
        }
    }

    private var reanalyzeAlpha1Body: some View {
        VStack(alignment: .leading, spacing: 8) {
            reanalyzeAlpha1Header
            Text(String(
                localized: "Old sessions may carry inflated α1 readings (values stuck near 1.6) because the raw RR stream wasn't filtered for ectopic beats before DFA. Tap below to regenerate α1 using the current Kubios-style filter — your HR / pace / TRIMP stay unchanged.",
                bundle: LanguageManager.appBundle
            ))
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            reanalyzeErrorNote
            reanalyzeAlpha1Button
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var reanalyzeAlpha1Button: some View {
        Button {
            Task { await runReanalyze() }
        } label: {
            Text(reanalyzing
                ? String(localized: "Re-analysing…", bundle: LanguageManager.appBundle)
                : String(localized: "Re-analyze α1 for this session", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(AppTheme.fitnessAccent.opacity(reanalyzing ? 0.35 : 1))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .disabled(reanalyzing)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var reanalyzeErrorNote: some View {
        if let err = reanalyzeError {
            Text(err)
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }

    private var reanalyzeAlpha1Header: some View {
        HStack {
            Text(String(localized: "Re-analyze α1", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            if reanalyzing {
                ProgressView().scaleEffect(0.7)
            }
        }
    }

    func runReanalyze() async {
        reanalyzing = true
        reanalyzeError = nil
        defer { reanalyzing = false }
        let basis = session
        let (refreshedSamples, readings) = await recomputeAlpha1(of: basis)
        guard refreshedSamples != nil else {
            reanalyzeError = String(localized: "Not enough RR data to re-analyze.", bundle: LanguageManager.appBundle)
            return
        }
        await persistReanalyzedSamples(readings, computedFrom: basis)
    }

    /// Off-thread: the DFA pass over a ~60-min RR series is a few hundred
    /// log-log regressions; fast enough that we don't need chunking but
    /// definitely shouldn't block the main thread.
    ///
    /// The `HRVSession` snapshot is taken by the caller on the MainActor so the
    /// detached task doesn't reach back into main-isolated state, which Swift 6
    /// strict concurrency rejects. `HRVSession` is Codable +
    /// value-semantic, so the copy is cheap and safe to move across isolation.
    private func recomputeAlpha1(of sessionSnapshot: HRVSession) async -> ([WorkoutSample]?, [WorkoutAlpha1Reanalyzer.Reading]) {
        await Task.detached(priority: .userInitiated) { () -> ([WorkoutSample]?, [WorkoutAlpha1Reanalyzer.Reading]) in
            let rs = WorkoutAlpha1Reanalyzer.reanalyze(session: sessionSnapshot)
            guard !rs.isEmpty, let samples = sessionSnapshot.workoutMetadata?.samples else {
                return (nil, rs)
            }
            return (WorkoutAlpha1Reanalyzer.applyReadings(rs, to: samples), rs)
        }.value
    }

    /// Write back through the shared archive, then update our own @State AND
    /// bump the archive signal — both paths, so the open sheet refreshes
    /// unconditionally and the fitness tab behind us reloads too. The splits'
    /// mean α1 is recomputed from the new samples so the splits table agrees
    /// with the re-analysed trace. The archive write runs on a detached task
    /// (`storeReanalyzedSamples`), not the main actor.
    private func persistReanalyzedSamples(_ readings: [WorkoutAlpha1Reanalyzer.Reading], computedFrom basis: HRVSession) async {
        let updated: HRVSession
        switch await storeReanalyzedSamples(readings, computedFrom: basis) {
        case .success(let session?):
            updated = session
        case .success(nil):
            reanalyzeError = String(localized: "Session not found in archive.", bundle: LanguageManager.appBundle)
            return
        case .failure(let error):
            reanalyzeError = String(localized: "Couldn't save re-analyzed α1: \(error.localizedDescription)", bundle: LanguageManager.appBundle)
            return
        }
        refreshedSession = updated
        // The α1 stats cache key covers the values too, so the new samples
        // miss it anyway; clearing it here also frees the old entry at once.
        alpha1StatsCache.cachedKey = nil
        collector.archiveSignal.notifyChanged()
        debugLog("[Alpha1Reanalyze] rewrote \(readings.count) α1 readings for session \(session.id)")
    }

    /// Stores the re-analysed α1 on the archived session's samples, with its
    /// α1-enriched splits, and rebuilds its analysis snapshot (α1 mean / min /
    /// max, band seconds, narratives) from them; nil when the session is no
    /// longer in the archive, the error when the write threw.
    private func storeReanalyzedSamples(
        _ readings: [WorkoutAlpha1Reanalyzer.Reading], computedFrom basis: HRVSession
    ) async -> Result<HRVSession?, Error> {
        let archive = self.archive
        let settings = UserSettingsBridge.snapshot(of: settingsManager)
        return await Task.detached(priority: .userInitiated) {
            Self.writeReanalysis(readings, computedFrom: basis, archive: archive, settings: settings)
        }.value
    }

    /// The write, off the main actor, under the archive's lock.
    nonisolated private static func writeReanalysis(
        _ readings: [WorkoutAlpha1Reanalyzer.Reading], computedFrom basis: HRVSession,
        archive: SessionArchive, settings: UserSettingsBridge
    ) -> Result<HRVSession?, Error> {
        Result {
            try updateArchived(basis.id, in: archive) { stored in
                applyReanalysis(readings, computedFrom: basis, to: &stored)
                rebuildAnalysisSnapshot(&stored, settings: settings)
            }
        }
    }

    /// Puts the readings on the samples as they are stored at the write, not
    /// as they were read before the recompute: a retrim, or a pull that kept
    /// iCloud's copy, may have rewritten them meanwhile, and writing the
    /// samples derived from the older copy would undo that. Readings computed
    /// from beats the stored copy no longer holds are computed again from
    /// it. The splits' mean α1 is then taken from the samples written.
    nonisolated static func applyReanalysis(
        _ readings: [WorkoutAlpha1Reanalyzer.Reading], computedFrom basis: HRVSession, to stored: inout HRVSession
    ) {
        guard let samples = stored.workoutMetadata?.samples else { return }
        let current = stored.rrSeries?.points == basis.rrSeries?.points
            ? readings : WorkoutAlpha1Reanalyzer.reanalyze(session: stored)
        stored.workoutMetadata?.samples = WorkoutAlpha1Reanalyzer.applyReadings(current, to: samples)
        guard let metadata = stored.workoutMetadata, metadata.splits != nil else { return }
        let (startDate, duration) = (stored.startDate, stored.duration)
        stored.workoutMetadata?.splits = WorkoutAnalyzer.splitsEnrichedWithAlpha1(
            metadata, startDate: startDate, duration: duration
        ) ?? metadata.splits
    }
}

// MARK: - File-scope helpers (no FitnessSummaryCards state)

/// Replaces the stored analysis snapshot with one built from `stored` as
/// it now stands, so the figures and narratives the assistant and the PDF
/// read follow an in-place edit of samples, splits or elevation. Leaves the
/// old snapshot when the workout has no samples or no duration to build from.
private func rebuildAnalysisSnapshot(_ stored: inout HRVSession, settings: UserSettingsBridge) {
    guard let meta = stored.workoutMetadata,
          let samples = meta.samples, !samples.isEmpty,
          let duration = stored.duration
    else { return }
    let snapshot = WorkoutAnalysisSnapshotBuilder.build(.init(
        sport: meta.sport, durationSec: duration, distanceMeters: meta.distanceMeters,
        elevationGainMeters: meta.elevationGainMeters, elevationLossMeters: meta.elevationLossMeters,
        meanHR: stored.meanHR, userMaxHR: settings.userMaxHR, bodyWeightKg: settings.weightKg,
        samples: samples, splits: meta.splits ?? [],
        load: meta.preferredTrainingLoad(ftp: settings.ftp, heartRate: WorkoutLoadRestingHR.anchors)?.value,
        decouplingPercent: meta.decouplingPercent
    ))
    stored.workoutMetadata?.analysisSnapshot = snapshot
}
