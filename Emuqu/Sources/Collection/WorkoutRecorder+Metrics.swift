import CoreLocation
import Foundation
import HealthKit

// Normalized power and METs estimation (per-tick derived values) and the
// post-workout Coach Report. Recording-state persistence lives in
// `WorkoutRecorder+Start.swift`, the workout-start alert in `WorkoutStartCue`,
// and finalize in `WorkoutRecorder+Lifecycle.swift`.

extension WorkoutSessionLifecycle {
    // MARK: - Normalized power
    //
    // TrainingPeaks-style NP: 30-second rolling mean → raise to the 4th
    // power per window → take the mean → 4th root. Captures how
    // physiologically stressful a variable-intensity effort was (intervals,
    // hills) vs. the raw arithmetic mean, which understates the cost. At
    // ~1 Hz sample rate, we use a 30-sample rolling window.
    // NP = (mean of [30-s rolling-avg power]^4)^0.25 — Allen & Coggan, Training
    // and Racing with a Power Meter.
    // NOTE: 30-SAMPLE window assumes ~1 Hz power sampling = Coggan's 30 s; if
    // sample cadence differs, derive window length from cadence.
    static func computeNormalizedPower(samples: [WorkoutSample]) -> Double? {
        let watts: [Double] = samples.compactMap { $0.powerWatts.map(Double.init) }
        guard watts.count >= 30 else { return nil }  // need at least one full window
        var windowMeans: [Double] = []
        windowMeans.reserveCapacity(watts.count - 29)
        for i in 29 ..< watts.count {
            let slice = watts[(i - 29) ... i]
            let mean = slice.reduce(0, +) / 30.0
            windowMeans.append(mean)
        }
        let fourths = windowMeans.map { pow($0, 4) }
        let meanFourth = fourths.reduce(0, +) / Double(fourths.count)
        return pow(meanFourth, 0.25)
    }

    // MARK: - METs estimation
    //
    /// Rough energy-expenditure proxy. REQUIRES confirmed movement. Earlier
    /// versions had an HR-only fallback: when no speed was available we
    /// estimated METs from %-of-max HR. That badly overclaimed when the user
    /// was sitting still — HR of 100 bpm at rest (caffeine, stress, digestion,
    /// normal variability) reads as ~3.5 METs by %HR, which is wrong. METs is
    /// mechanical work, not sympathetic tone. If we don't have motion, we
    /// return nil and the charts/exports drop the value rather than lie.
    ///
    /// Motion confirmation — the caller only passes paceSecPerKm when the
    /// sample-capture gate clears (both time-delta > 0 AND distance-delta
    /// above the GPS-jitter floor). Indoor sports without a pedometer signal
    /// → nil; that's honest, not a regression.
    ///
    /// Flagged as "(est)" in UI so users understand the confidence level.
    ///
    /// A published MET lookup table expressed as pace bands
    /// per sport (Ainsworth Compendium). The branches are table rows.
    nonisolated static func estimateMETs(sport: Sport, paceSecPerKm: Double?, heartRate _: Int?, userMaxHR _: Int) -> Double? {
        guard let pace = paceSecPerKm, pace > 0 else { return nil }
        // The tables live in `METLookup` — pure data with no recorder state, so
        // they can be exercised directly by tests. `METLookup.mets` applies the
        // walking-crawl floor: a kmh value below it means the pace calc was on
        // the edge of the GPS-jitter gate, and a METs number that close to
        // zero-motion would be noise.
        return METLookup.mets(sport: sport, speedKmh: 3600.0 / pace)
    }

    /// Build a flat string→string snapshot of what the AI was reasoning
    /// over at the end of the session. Keys
    /// are simple, self-describing, machine-readable; values are
    /// stringified primitives for portable JSON export. Not surfaced
    /// in the UI; included in the data export so third-party
    /// integrators see the same view of the session the Coach did.
    func buildAiContextSnapshot(
        _ snap: AssistantContext.LiveWorkoutSnapshot,
        sport: Sport,
        stopDate: Date
    ) -> [String: String] {
        var ctx = Self.requiredSnapshotFields(snap, sport: sport, stopDate: stopDate)
        for (key, value) in Self.optionalSnapshotFields(snap) {
            ctx[key] = value
        }
        return ctx
    }

    /// The fields that are always present, so the export has a stable spine
    /// even for a session that captured nothing else.
    private static func requiredSnapshotFields(
        _ snap: AssistantContext.LiveWorkoutSnapshot,
        sport: Sport,
        stopDate: Date
    ) -> [String: String] {
        let iso = ISO8601DateFormatter()
        return [
            "schema_version": "1",
            "captured_at": iso.string(from: stopDate),
            "sport": sport.rawValue,
            "session_started_at": iso.string(from: snap.sessionStartAt),
            "snapshot_at": iso.string(from: snap.snapshotAt),
            "elapsed_sec": String(snap.elapsedSeconds),
            "distance_meters": String(format: "%.1f", snap.distanceMeters),
            "elevation_gain_meters": String(format: "%.1f", snap.elevationGainMeters),
            "user_max_hr": String(snap.userMaxHR),
            "peak_hr": String(snap.peakHR),
            "alpha1_band": snap.alpha1Band,
            "alpha1_status": snap.alpha1Status,
            "units_preference": snap.unitsPreference,
            "strap_connected": String(snap.strapConnected),
            "beat_count": String(snap.beatCount),
            "step_count": String(snap.stepCount),
            "gps_fix_count": String(snap.gpsFixCount)
        ]
    }

    /// These 23 optional fields as 23 `if let` lines would count as
    /// cyclomatic complexity 23 for SwiftLint. There is no logic here,
    /// only a field table, and SPLITTING a serializer like this makes it
    /// worse (branch count is field count, so the halves just inherit it).
    ///
    /// Expressing it as a table removes every branch instead of moving
    /// them, keeps all 23 fields readable in one column-aligned block, and
    /// makes adding a field a one-row edit that cannot forget the nil
    /// check. Output is byte-identical: same keys, same format specs, same
    /// omit-when-nil behaviour.
    private static func optionalSnapshotFields(
        _ snap: AssistantContext.LiveWorkoutSnapshot
    ) -> [(String, String?)] {
        func num(_ value: Double?, _ spec: String) -> String? { value.map { String(format: spec, $0) } }
        return [
            ("hr", snap.heartRate.map { String($0) }), ("cadence_spm", num(snap.cadenceStepsPerMin, "%.1f")),
            ("alpha1", num(snap.alpha1, "%.3f")), ("alpha1_fit_r2", num(snap.alpha1FitQualityR2, "%.3f")),
            ("current_pace_sec_per_km", num(snap.currentPaceSecPerKm, "%.1f")),
            ("current_speed_m_per_s", num(snap.currentSpeedMS, "%.2f")), ("power_watts", snap.powerWatts.map { String($0) }),
            ("current_mets", num(snap.currentMETs, "%.2f")), ("latitude", num(snap.currentLatitude, "%.6f")),
            ("longitude", num(snap.currentLongitude, "%.6f")), ("altitude_meters", num(snap.currentAltitudeMeters, "%.1f")),
            ("heading_degrees", num(snap.currentHeadingDegrees, "%.1f")), ("grade_percent", num(snap.currentGradePercent, "%.1f")),
            ("gps_accuracy_meters", num(snap.gpsAccuracyMeters, "%.1f")), ("target_zone", snap.targetZone.map { String($0) }),
            ("hr_drift_percent", num(snap.liveHRDriftPercent, "%.2f")),
            ("aerobic_decoupling_percent", num(snap.aerobicDecouplingPercent, "%.2f")),
            ("grade_adjusted_pace_sec_per_km", num(snap.gradeAdjustedPaceSecPerKm, "%.1f")),
            ("today_recovery_score", num(snap.todayRecoveryScore, "%.1f")),
            ("today_training_readiness", num(snap.todayTrainingReadiness, "%.1f")),
            ("today_atl", num(snap.todayATL, "%.2f")), ("today_ctl", num(snap.todayCTL, "%.2f")),
            ("today_tsb", num(snap.todayTSB, "%.2f"))
        ]
    }

    /// Persist the finished workout, then fan out the redundant-backup cleanup,
    /// cloud upload and HealthKit export.
    ///
    /// archive success is logged explicitly so the
    /// user's debug log shows the workout actually persisted. The
    /// failure path logs ("Archive failed: …"); with a silent happy
    /// path, when the AI claims "no workout history" and the log
    /// lacks any "archived" line, we can't tell whether the write
    /// succeeded silently or never ran. Both paths are visible.
    ///
    /// On failure the persisted state + unarchived raw backup stay in place so
    /// the next app launch can recover via SessionRecoveryService. The
    /// session is still shown in .finished state so the user sees
    /// what was captured; recovery is a safety net, not the primary path.
    func archive(session: HRVSession) async {
        do {
            _ = try recorder.core.archive.archive(session)
            debugLog("[WorkoutRecorder] archived session id=\(session.id.uuidString.prefix(8)) sport=\(session.workoutMetadata?.sport.rawValue ?? "?") type=\(session.sessionType.rawValue)")
            recorder.core.notifyArchiveChanged()
            retireRedundantBackups(for: session)
            Task(priority: .utility) {
                await recorder.core.cloudSyncManager.uploadSession(session)
            }
            exportToHealthKitIfAvailable(session)
        } catch {
            debugLog("[WorkoutRecorder] Archive failed: \(error) — leaving raw backup for recovery", level: .warning)
        }
    }

    /// A successful archive makes the raw backup redundant. Marking it stops
    /// SessionRecoveryService offering to "recover" a session that already
    /// lives in history, and clearing persisted state stops the next app
    /// launch prompting the user to recover.
    ///
    /// The workout-side track + samples + baro backups are redundant too (the
    /// same data lives inside the session's `WorkoutMetadata`), so they're
    /// dropped rather than left to accumulate as stale per-session files in
    /// the App Group.
    private func retireRedundantBackups(for session: HRVSession) {
        recorder.core.rawBackup.markAsArchived(session.id)
        AppDependencies.current.storage.workoutTrackBackup.discard(session.id)
        PersistedRecordingState.clear()
    }

    /// Publish to HealthKit as an HKWorkout so the session appears in
    /// Apple Fitness / Health and is visible to third-party apps
    /// linked through HealthKit (TrainingPeaks, Athlytic, Zones).
    /// Best-effort — if auth isn't granted or the API call fails,
    /// the in-app session is canonical and unaffected.
    private func exportToHealthKitIfAvailable(_ session: HRVSession) {
        guard #available(iOS 17.0, *) else { return }
        let healthStore = recorder.core.healthKit.healthStore
        let weight = recorder.settingsProvider().effectiveBodyWeightKg
        let archive = recorder.core.archive
        Task(priority: .utility) {
            await Self.exportWorkoutToHealthKit(
                session: session, store: healthStore, bodyWeightKg: weight, archive: archive
            )
        }
    }

    /// The failure log is default (info) level, not `.warning`. At
    /// warning it appears in Recent Problems as
    /// "[WorkoutRecorder] HealthKit export failed: Authorization is not
    /// determined", prompting "why didn't you check auth up front?". The
    /// truthful answer is: HK returns `.notDetermined` for the workout write
    /// type until the user grants it explicitly via Settings → Health, and
    /// Apple gives apps no API to differentiate "user hasn't seen the prompt
    /// yet" from "user denied." Surfacing it as a "Problem" each workout is
    /// noisier than useful — the session still lands in our own archive
    /// regardless of whether Apple Health gets a copy. Kept in the diagnostic
    /// log for support purposes.
    ///
    /// Success is recorded on the session so the back-fill
    /// scanner doesn't re-publish duplicates next time auth flips through
    /// `.notDetermined → .authorized`.
    @available(iOS 17.0, *)
    private static func exportWorkoutToHealthKit(
        session: HRVSession,
        store: HKHealthStore,
        bodyWeightKg: Double,
        archive: SessionArchive
    ) async {
        guard HealthExportClaims.claim(session.id) else { return }
        defer { HealthExportClaims.release(session.id) }
        do {
            try await HealthKitWorkoutExport.export(
                session: session, store: store, bodyWeightKg: bodyWeightKg
            )
            stampHealthKitExport(sessionId: session.id, archive: archive)
        } catch {
            debugLog("[WorkoutRecorder] HealthKit export failed: \(error.localizedDescription)")
        }
    }

    /// Mark the archived copy as exported so backfill does not export it twice.
    ///
    /// The archive write's error must not be discarded: export
    /// succeeding while the stamp fails is the shape of a duplicate HealthKit
    /// workout on the next backfill pass, so it gets a log line. Extracted
    /// rather than nested so the error handling stays inside the spec nesting
    /// limit.
    @available(iOS 17.0, *)
    private static func stampHealthKitExport(sessionId: UUID, archive: SessionArchive) {
        do {
            // In place, under the archive lock: the heart-rate-recovery save
            // runs on another thread, and a read-then-write here could put
            // back a copy without its samples.
            try archive.update(sessionId, requestingReupload: false) { $0.healthKitExportedAt = Date() }
        } catch {
            debugLog("[WorkoutRecorder] HealthKit export stamp not persisted: \(error.localizedDescription)", level: .warning)
        }
    }

    /// Generate the comprehensive Coach Report and
    /// stage an email draft via `AssistantEmailBridge`. Called from
    /// the HRR-completion handler when `enableAutoCoachReport` is on.
    ///
    /// Email shape:
    ///   • Body — short conversational coaching summary (cause-and-
    ///     effect prose, "your pace is slower for the same HR
    ///     because…").
    ///   • Attachment — the full epic multi-page WorkoutPDFReport
    ///     (map, charts, splits, methodology). Same PDF the user
    ///     gets from the Share / Email PDF buttons in the post-
    ///     summary view.
    ///
    /// Render runs on a detached background task — CoreGraphics
    /// drawing + MKMapSnapshotter are off-main-actor friendly and
    /// pinning UI for a 6-page render was the previous pain point.
    /// The bridge stage call hops back to MainActor at the end.
    @MainActor
    /// `settings` defaults to the shared store so the view call site is
    /// unchanged; the recorder passes its own injected provider.
    static func scheduleCoachReportEmail(for session: HRVSession, settings: UserSettings = AppDependencies.current.app.settingsManager.settingsSnapshot) {
        let inputs = coachReportInputs(for: session, settings: settings)
        Task.detached(priority: .userInitiated) {
            await renderAndStageCoachReport(inputs)
        }
    }

    /// Everything the detached render needs, snapshotted on the MainActor.
    /// `HRVSession` is Codable / value-typed; settings are plain Ints.
    struct CoachReportInputs {
        let session: HRVSession
        let subject: String
        let recipient: String?
        let units: UnitsPreference
        let maxHR: Int
        let restingHR: Int
        let lthr: Int
        let temperatureUnit: TemperatureUnit
        let pdfURL: URL
        let todayOvernight: HRVSession?
        let recentOvernight: [HRVSession]
        /// The newest earlier workouts, by id, capped at
        /// `CoachReportGenerator.historyLimit` like `recentPastWorkouts`:
        /// decoding them is left to the detached render so the main actor
        /// only filters the index.
        let pastWorkoutIds: [UUID]
        let archive: SessionArchive
    }

    /// Pulls today's overnight session plus the overnight sessions before it
    /// for baseline computation. Done on MainActor because SessionArchive is
    /// MainActor-bound.
    ///
    /// Past workouts are only picked here, from the index. Decoding every
    /// one on the MainActor takes seconds for archives with many sessions
    /// and blocks the AI chat (also on MainActor) for the duration, so the
    /// detached render decodes them.
    @MainActor
    private static func coachReportInputs(for session: HRVSession, settings: UserSettings) -> CoachReportInputs {
        let archive = AppDependencies.current.storage.sessionArchive
        let dayCutoff = Calendar.current.date(byAdding: .hour, value: -36, to: Date()) ?? Date.distantPast
        let recentOvernight = recentOvernightSessions(archive: archive, reportedNightCutoff: dayCutoff)
        return CoachReportInputs(
            session: session, subject: coachReportSubject(for: session),
            // Pull the user's training-category default recipient if set.
            recipient: settings.defaultTrainingEmailRecipient ?? settings.defaultRecoveryEmailRecipient ?? settings.defaultEmailRecipient,
            units: UnitsPreferenceStore.current.resolved, maxHR: settings.effectiveMaxHR,
            restingHR: settings.effectiveRestingHR, lthr: settings.effectiveLTHR,
            temperatureUnit: settings.temperatureUnit,
            pdfURL: coachReportPDFURL(for: session),
            todayOvernight: recentOvernight.first(where: { $0.startDate >= dayCutoff }),
            recentOvernight: recentOvernight,
            pastWorkoutIds: archive.entries
                .filter { $0.sessionType == .workout && $0.sessionId != session.id }
                .sorted { $0.date > $1.date }
                .prefix(CoachReportGenerator.historyLimit)
                .map(\.sessionId),
            archive: archive
        )
    }

    /// The reported night (the newest overnight session since
    /// `reportedNightCutoff`, first when there is one) followed by the nights
    /// before it, newest first, until 60 of them are reliable for HRV
    /// aggregates: the window `BaselineTracker` scores a night against
    /// (`BaselineTracker.recoveryBaselineStats(excludingNightOf:)`), so the
    /// Daily Loop's HRV baseline in the report is the recovery score's.
    @MainActor
    private static func recentOvernightSessions(archive: SessionArchive, reportedNightCutoff: Date) -> [HRVSession] {
        let entries = archive.entries.filter { $0.sessionType == .overnight }.sorted { $0.date > $1.date }
        let reported = entries.first { $0.date >= reportedNightCutoff }
        var nights = reported.flatMap { archive.retrieveLightweightOrLog($0.sessionId, caller: "CoachReport.reportedNight") }
            .map { [$0] } ?? []
        var baselineNights = 0
        for entry in entries where entry.date < (reported?.date ?? .distantFuture) {
            guard baselineNights < baselineNightLimit else { break }
            guard let night = archive.retrieveLightweightOrLog(entry.sessionId, caller: "CoachReport.baselineNights") else { continue }
            nights.append(night)
            if night.isReliableForHRVAggregates { baselineNights += 1 }
        }
        return nights
    }

    /// Nights in the recovery score's HRV baseline (`BaselineTracker`).
    private static let baselineNightLimit = 60

    /// The email subject the user sends, in the app's language.
    private static func coachReportSubject(for session: HRVSession) -> String {
        let bundle = LanguageManager.appBundle
        let dateFormatter = DateFormatter()
        dateFormatter.locale = LanguageManager.appLocale
        dateFormatter.dateStyle = .medium
        let sport = session.workoutMetadata?.sport.localizedName ?? String(localized: "Workout", bundle: bundle)
        return String(localized: "\(sport) Coach Report — \(dateFormatter.string(from: session.startDate))", bundle: bundle)
    }

    private static func coachReportPDFURL(for session: HRVSession) -> URL {
        let base = "emuqu-coach-report-\(Int(session.startDate.timeIntervalSince1970))"
        return FileManager.default.temporaryDirectory.appendingPathComponent("\(base).pdf")
    }

    /// Refresh + capture the canonical live
    /// training-load INSIDE the detached task so the report
    /// reflects the workout just archived. The archive write
    /// already invalidated the cache; `liveRefreshed()` recomputes
    /// before capture (plain `live()` would freeze the pre-workout
    /// TSB/ACWR). `await` hops to MainActor safely — no
    /// `assumeIsolated` trap. See liveRefreshed() doc-comment.
    ///
    /// The past workouts are decoded on a detached task, off the MainActor;
    /// the conversational body is then a pure function of them.
    private static func renderAndStageCoachReport(_ inputs: CoachReportInputs) async {
        let liveLoadSnapshot = await TrainingLoadRegistry.liveRefreshed()
        let (archive, ids) = (inputs.archive, inputs.pastWorkoutIds)
        let pastWorkouts = await Task.detached(priority: .userInitiated) {
            ids.compactMap { archive.retrieveLightweightOrLog($0, caller: "CoachReport.pastWorkouts") }
        }.value
        let body = CoachReportGenerator.renderConversationalSummary(
            session: inputs.session, pastWorkouts: pastWorkouts, units: inputs.units,
            userMaxHR: inputs.maxHR, userRestingHR: inputs.restingHR
        )
        let attachment = await renderCoachReportPDF(inputs, liveLoadSnapshot: liveLoadSnapshot)
        await MainActor.run {
            let emailBody = attachment == nil ? body : body + "\n\n" + CoachReportGenerator.pdfFootnote
            AppDependencies.current.assistant.assistantEmailBridge.stage(AssistantEmailDraft(
                subject: inputs.subject, body: emailBody, recipient: inputs.recipient,
                ccRecipients: [], attachmentURL: attachment
            ))
            debugLog("[CoachReport] staged email draft for session \(inputs.session.id.uuidString.prefix(8)) (body \(body.count) chars, pdf=\(attachment != nil ? "yes" : "no"))")
        }
    }

    /// Holistic report (workout + recovery + the loop) when today has an
    /// overnight session; otherwise the upgraded standalone workout PDF with
    /// hero verdict + status arrows + What This Means page. A render failure
    /// stages the email without an attachment rather than dropping it.
    private static func renderCoachReportPDF(
        _ inputs: CoachReportInputs,
        liveLoadSnapshot: TrainingLoadRegistry.TrainingLoad?
    ) async -> URL? {
        let track = coachReportTrack(for: inputs.session)
        do {
            if inputs.todayOvernight != nil {
                try await holisticReport(inputs, track: track, liveLoadSnapshot: liveLoadSnapshot).generate(to: inputs.pdfURL)
                debugLog("[CoachReport] generated HOLISTIC report (workout + overnight + loop)")
            } else {
                try await WorkoutPDFReport(
                    session: inputs.session, track: track, userMaxHR: inputs.maxHR,
                    userRestingHR: inputs.restingHR, userLTHR: inputs.lthr, units: inputs.units
                ).generate(to: inputs.pdfURL)
                debugLog("[CoachReport] generated standalone workout PDF (no overnight session for today)")
            }
            return inputs.pdfURL
        } catch {
            debugLog("[CoachReport] PDF render failed: \(error.localizedDescription) — staging email without attachment", level: .warning)
            return nil
        }
    }

    private static func holisticReport(
        _ inputs: CoachReportInputs,
        track: [CLLocation],
        liveLoadSnapshot: TrainingLoadRegistry.TrainingLoad?
    ) -> HolisticDailyReport {
        HolisticDailyReport(
            workoutSession: inputs.session, workoutTrack: track,
            overnightSession: inputs.todayOvernight, recentOvernightSessions: inputs.recentOvernight,
            userMaxHR: inputs.maxHR, userRestingHR: inputs.restingHR, userLTHR: inputs.lthr,
            units: inputs.units, temperatureUnit: inputs.temperatureUnit, liveLoadSnapshot: liveLoadSnapshot
        )
    }

    private static func coachReportTrack(for session: HRVSession) -> [CLLocation] {
        guard let polyline = session.workoutMetadata?.gpsPolyline else { return [] }
        return GPXExporter.decode(polyline: polyline, startDate: session.startDate, duration: session.duration)
    }
}

// MARK: - Errors

enum WorkoutRecorderError: LocalizedError {
    case alreadyRecording
    case strapBusy

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: String(localized: "A workout is already in progress.", bundle: LanguageManager.appBundle)
        case .strapBusy: String(localized: "The strap is currently used by another session. Stop it first.", bundle: LanguageManager.appBundle)
        }
    }
}
