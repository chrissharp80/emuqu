import CoreLocation
import Foundation
import HealthKit

// Normalized power and METs estimation (per-tick derived values) and the
// post-workout Coach Report. Recording-state persistence lives in
// `WorkoutSessionLifecycle+Start.swift`, the workout-start alert in `WorkoutStartCue`,
// and finalize in `WorkoutFinalizer+Finalize.swift`.

extension WorkoutSessionLifecycle {
    // MARK: - Normalized power
    //
    // TrainingPeaks-style NP: 30-second rolling mean → raise to the 4th
    // power per window → take the mean → 4th root. Captures how
    // physiologically stressful a variable-intensity effort was (intervals,
    // hills) vs. the raw arithmetic mean, which understates the cost.
    // NP = (mean of [30-s rolling-avg power]^4)^0.25 — Allen & Coggan, Training
    // and Racing with a Power Meter.
    // Samples are one per second of moving time, keyed by whole-second
    // `offsetSec`. A run is a stretch of rows with power at consecutive
    // offsets, so 30 rows of a run are exactly 30 seconds. A row without
    // power (a dropout) or an offset that is not the previous one plus a
    // second (the recorder jumps the clock after a suspension, leaving those
    // seconds unsampled) ends the run, and windows are taken within runs
    // only, so no window splices seconds from either side of a gap. A
    // repeated offset is the same second again and is skipped. A 0 W
    // reading (coasting) is a reading and stays in the run.
    static func computeNormalizedPower(samples: [WorkoutSample]) -> Double? {
        let windowMeans = powerRuns(samples).flatMap { Self.rollingThirtySampleMeans($0) }
        guard !windowMeans.isEmpty else { return nil }  // need at least one full window
        let meanFourth = windowMeans.reduce(0) { $0 + pow($1, 4) } / Double(windowMeans.count)
        return pow(meanFourth, 0.25)
    }

    /// Runs of rows that carry power at consecutive one-second offsets, in
    /// order. The first row for an offset is the one kept.
    private static func powerRuns(_ samples: [WorkoutSample]) -> [[Double]] {
        var runs: [[Double]] = []
        var current: [Double] = []
        var previousOffset: Int?
        for sample in samples where sample.offsetSec != previousOffset {
            let watts = sample.powerWatts.map(Double.init)
            let continuesRun = watts != nil && previousOffset.map { sample.offsetSec == $0 + 1 } == true
            if !continuesRun, !current.isEmpty {
                runs.append(current)
                current = []
            }
            if let watts { current.append(watts) }
            previousOffset = sample.offsetSec
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// The mean of every 30-second window in one run; empty under 30 seconds.
    private static func rollingThirtySampleMeans(_ watts: [Double]) -> [Double] {
        guard watts.count >= 30 else { return [] }
        return (29 ..< watts.count).map { i in watts[(i - 29) ... i].reduce(0, +) / 30.0 }
    }

    // MARK: - METs estimation
    //
    /// Rough energy-expenditure proxy. REQUIRES confirmed movement. There is
    /// no HR-only fallback: METs estimated from %-of-max HR badly overclaim
    /// when the user is sitting still — HR of 100 bpm at rest (caffeine,
    /// stress, digestion, normal variability) reads as ~3.5 METs by %HR, which
    /// is wrong. METs is mechanical work, not sympathetic tone. If we don't
    /// have motion, we return nil and the charts/exports drop the value rather
    /// than lie.
    ///
    /// Motion confirmation — the caller passes the live pace
    /// (`LivePaceEstimator`), which is nil until movement is measured and once
    /// the user is slower than a stroll. Indoor sports without a pedometer
    /// signal → nil; that's honest.
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

    /// These 25 optional fields as 25 `if let` lines would count as
    /// cyclomatic complexity 25 for SwiftLint. There is no logic here,
    /// only a field table, and SPLITTING a serializer like this makes it
    /// worse (branch count is field count, so the halves just inherit it).
    ///
    /// Expressing it as a table removes every branch instead of moving
    /// them, keeps all 25 fields readable in one column-aligned block, and
    /// makes adding a field a one-row edit that cannot forget the nil
    /// check. Output is byte-identical: same keys, same format specs, same
    /// omit-when-nil behaviour.
    static func optionalSnapshotFields(
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
            ("today_tsb", num(snap.todayTSB, "%.2f")),
            ("hr_source", snap.heartRateFromWatch.map(CloudSessionPayload.heartRateSource)),
            ("peak_hr_source", snap.peakHRFromWatch.map(CloudSessionPayload.heartRateSource))
        ]
    }

    /// Publish to HealthKit as an HKWorkout so the session appears in
    /// Apple Fitness / Health and is visible to third-party apps
    /// linked through HealthKit (TrainingPeaks, Athlytic, Zones), when
    /// "Export to Apple Health" is on. Best-effort: if auth isn't granted or
    /// the API call fails, the in-app session is canonical and unaffected.
    func exportToHealthKitIfAvailable(_ session: HRVSession) {
        guard services.settingsManager.settings.exportsToAppleHealth else { return }
        let healthStore = core.healthAccess.store
        let sampleStore = core.healthSampleStore
        let weight = settingsProvider().effectiveBodyWeightKg
        let archive = core.archive
        let writesHeartRate = HealthKitWorkoutExport.writesHeartRate(with: services.settingsManager.settings)
        Task(priority: .utility) {
            await Self.exportWorkoutToHealthKit(
                session: session, healthStore: healthStore, sampleStore: sampleStore,
                options: (bodyWeightKg: weight, writesHeartRate: writesHeartRate), archive: archive
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
        healthStore: HKHealthStore,
        sampleStore: any HealthSampleStore,
        options: (bodyWeightKg: Double, writesHeartRate: Bool),
        archive: SessionArchive
    ) async {
        guard HealthExportClaims.claim(session.id) else { return }
        defer { HealthExportClaims.release(session.id) }
        do {
            try await HealthKitWorkoutExport.export(
                session: session, healthStore: healthStore, sampleStore: sampleStore,
                bodyWeightKg: options.bodyWeightKg, writesHeartRate: options.writesHeartRate
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
    /// workout on the next backfill pass, so it gets a log line.
    @available(iOS 17.0, *)
    private static func stampHealthKitExport(sessionId: UUID, archive: SessionArchive) {
        do {
            // In place, under the archive lock: the heart-rate-recovery save
            // runs on another thread, and a read-then-write here could put
            // back a copy without its samples. A routine stamp: no re-upload
            // and no `modifiedAt`, so a copy older than another device's edit
            // cannot overwrite it in iCloud; the stamp rides the next real
            // upload, and the sync identifiers stop a duplicate export.
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
    /// drawing + MKMapSnapshotter are off-main-actor friendly, and a
    /// 6-page render on the main actor would pin the UI.
    /// The bridge stage call hops back to MainActor at the end.
    ///
    /// Returns the render task, whose value says whether the staged draft
    /// carries the PDF: the post-summary button waits on it to show the
    /// outcome and offer a retry; the auto path ignores it.
    /// The view passes the settings it reads; the recorder passes its
    /// injected provider's.
    @MainActor
    @discardableResult
    static func scheduleCoachReportEmail(
        for session: HRVSession, settings: UserSettings, services: WorkoutServices
    ) -> Task<Bool, Never> {
        let inputs = coachReportInputs(for: session, settings: settings, archive: services.sessionArchive)
        let (metrics, emailBridge) = (services.trainingMetricsCache, services.assistantEmailBridge)
        return Task.detached(priority: .userInitiated) {
            await renderAndStageCoachReport(inputs, metrics: metrics, emailBridge: emailBridge)
        }
    }

    /// Everything the detached render needs, snapshotted on the MainActor.
    /// `HRVSession` is Codable / value-typed; settings are plain Ints.
    struct CoachReportInputs {
        let session: HRVSession
        let subject: String
        let recipient: String?
        /// Cc for the staged email: the training-category Cc, else the
        /// recovery and general defaults (`UserSettings.resolvedTrainingEmailCC`).
        let ccRecipients: [String]
        let units: UnitsPreference
        let maxHR: Int
        let restingHR: Int
        let lthr: Int
        let bodyWeightKg: Double
        let temperatureUnit: TemperatureUnit
        /// Assigns overnights to nights for the daily report's baseline.
        let sleepSchedule: SleepSchedule
        let pdfURL: URL
        let todayOvernight: HRVSession?
        let recentOvernight: [HRVSession]
        /// The newest earlier workouts, by id, capped at
        /// `CoachReportGenerator.historyLimit` like `recentPastWorkouts`:
        /// decoding them is left to the detached render so the main actor
        /// only filters the index.
        let pastWorkoutIds: [UUID]
        let archive: SessionArchive
        /// The FTPs the daily report reads a workout's power TSS at.
        let loadFTP: TrainingLoadPrecedence.FTPAnchors
    }

    /// Pulls today's overnight session plus the overnight sessions before it
    /// for baseline computation. Runs on the MainActor, where the report is
    /// staged; `SessionArchive` itself is not actor-bound, and the detached
    /// render reads it too.
    ///
    /// Today's overnight is the reported night only when it ended today
    /// (the rule `todaysMorningSession` uses at workout start): a morning
    /// with no recording must not present the previous night, ~30 h old,
    /// as today's recovery in the Holistic report. The 36 h window still
    /// picks the reported night for the baseline list.
    ///
    /// Past workouts are only picked here, from the index. Decoding every
    /// one on the MainActor takes seconds for archives with many sessions
    /// and blocks the AI chat (also on MainActor) for the duration, so the
    /// detached render decodes them.
    ///
    /// Recipient and Cc: the training-category default, then the recovery
    /// and general defaults, blank fields skipped
    /// (`UserSettings.resolvedTrainingEmailRecipient` / `resolvedTrainingEmailCC`).
    @MainActor
    private static func coachReportInputs(
        for session: HRVSession, settings: UserSettings, archive: SessionArchive
    ) -> CoachReportInputs {
        let dayCutoff = Calendar.current.date(byAdding: .hour, value: -36, to: Date()) ?? Date.distantPast
        let recentOvernight = recentOvernightSessions(archive: archive, reportedNightCutoff: dayCutoff, sleepSchedule: settings.sleepSchedule)
        return CoachReportInputs(
            session: session, subject: coachReportSubject(for: session),
            recipient: settings.resolvedTrainingEmailRecipient,
            ccRecipients: settings.resolvedTrainingEmailCC,
            units: UnitsPreferenceStore.current.resolved, maxHR: settings.effectiveMaxHR,
            restingHR: settings.effectiveRestingHR, lthr: settings.effectiveLTHR,
            bodyWeightKg: settings.effectiveBodyWeightKg, temperatureUnit: settings.temperatureUnit, sleepSchedule: settings.sleepSchedule,
            pdfURL: coachReportPDFURL(for: session),
            todayOvernight: todaysOvernight(in: recentOvernight, reportedNightCutoff: dayCutoff),
            recentOvernight: recentOvernight,
            pastWorkoutIds: archive.store.entries
                .filter { $0.sessionType == .workout && $0.sessionId != session.id }
                .sorted { $0.date > $1.date }
                .prefix(CoachReportGenerator.historyLimit)
                .map(\.sessionId),
            archive: archive, loadFTP: .current(settings)
        )
    }

    /// The reported night (the newest overnight session since
    /// `reportedNightCutoff`, first when there is one) followed by the
    /// sessions before it, newest first, until they hold 60 baseline nights:
    /// distinct nights before the reported one with a session
    /// `BaselineTracker.isBaselineCandidate` admits. That is the window
    /// `BaselineTracker` scores a night against, and the Daily Loop picks its
    /// nights from these with the score's own rule
    /// (`BaselineTracker.baselineRMSSDs`), so its HRV baseline in the report
    /// is the recovery score's. A night that cannot be read still takes its
    /// place in the window, as it keeps its reading in the score's baseline.
    @MainActor
    private static func recentOvernightSessions(
        archive: SessionArchive, reportedNightCutoff: Date, sleepSchedule: SleepSchedule
    ) -> [HRVSession] {
        let entries = archive.store.entries.filter { $0.sessionType == .overnight }.sorted { $0.date > $1.date }
        let reported = entries.first { $0.date >= reportedNightCutoff }
        var nights = reported.flatMap { archive.retrieveLightweightOrLog($0.sessionId, caller: "CoachReport.reportedNight") }
            .map { [$0] } ?? []
        let reportedNight = reported.map { sleepSchedule.nightKey(for: $0.date) } ?? .distantFuture
        var baselineNights = Set<Date>()
        for entry in entries where entry.date < (reported?.date ?? .distantFuture) {
            guard baselineNights.count < baselineNightLimit else { break }
            let night = archive.retrieveLightweightOrLog(entry.sessionId, caller: "CoachReport.baselineNights")
            if let night { nights.append(night) }
            if let key = baselineNightKey(entry, read: night, sleepSchedule: sleepSchedule, before: reportedNight) {
                baselineNights.insert(key)
            }
        }
        return nights
    }

    /// The night `entry` adds to the baseline window, if any: the read
    /// session's when the baseline admits it. An unreadable night the score's
    /// baseline still holds keeps its place, by its index entry, so the report
    /// does not reach further back than the score does.
    private static func baselineNightKey(
        _ entry: SessionArchiveEntry, read night: HRVSession?, sleepSchedule: SleepSchedule, before reportedNight: Date
    ) -> Date? {
        let key = sleepSchedule.nightKey(for: night?.startDate ?? entry.date)
        guard key < reportedNight else { return nil }
        guard let night else { return entry.hrvDataQuality == .insufficient ? nil : key }
        return BaselineTracker.isBaselineCandidate(night) ? key : nil
    }

    /// The reported night when it ended today, else nil.
    private static func todaysOvernight(in nights: [HRVSession], reportedNightCutoff: Date) -> HRVSession? {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return nights.first { $0.startDate >= reportedNightCutoff && ($0.endDate ?? $0.startDate) >= startOfToday }
    }

    /// Nights in the recovery score's HRV baseline (`BaselineTracker`).
    private static let baselineNightLimit = BaselineTracker.recoveryWindowNights

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
    /// the conversational body is then a pure function of them. Returns
    /// whether the PDF was attached (false: the draft was staged with the
    /// summary only, because the render failed).
    private static func renderAndStageCoachReport(
        _ inputs: CoachReportInputs, metrics: TrainingMetricsCache, emailBridge: AssistantEmailBridge
    ) async -> Bool {
        let liveLoadSnapshot = await TrainingLoadRegistry.liveRefreshed(from: metrics)
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
            emailBridge.stage(AssistantEmailDraft(
                subject: inputs.subject, body: emailBody, recipient: inputs.recipient,
                ccRecipients: inputs.ccRecipients, attachmentURL: attachment
            ))
            debugLog("[CoachReport] staged email draft for session \(inputs.session.id.uuidString.prefix(8)) (body \(body.count) chars, pdf=\(attachment != nil ? "yes" : "no"))")
        }
        return attachment != nil
    }

    /// Holistic report (workout + recovery + the loop) when today has an
    /// overnight session (`todayOvernight`, one that ended today); otherwise the upgraded standalone workout PDF with
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
                    userRestingHR: inputs.restingHR, userLTHR: inputs.lthr,
                    userBodyWeightKg: inputs.bodyWeightKg, units: inputs.units
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
            userBodyWeightKg: inputs.bodyWeightKg, units: inputs.units, sleepSchedule: inputs.sleepSchedule,
            temperatureUnit: inputs.temperatureUnit, liveLoadSnapshot: liveLoadSnapshot, loadFTP: inputs.loadFTP
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
