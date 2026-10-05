import CoreLocation
import Foundation

/// Reconstructs a complete `HRVSession` for an interrupted workout from
/// the on-disk backups (`RawRRBackup` for HR + `WorkoutTrackBackup` for
/// GPS / per-tick samples / barometer) so the user doesn't lose the
/// minutes of motion they captured before a crash, force-quit, or
/// strap battery death.
///
/// The non-recovery path of this work lives in
/// `WorkoutRecorder.finalizeSession` — that function is the authoritative
/// source for "given live session inputs, produce a `WorkoutMetadata`."
/// Keeping the recovery path in a separate service means one bug-fix in
/// the analyzer flow has to land in two places, but the alternative —
/// re-instantiating the entire `WorkoutRecorder` graph just to re-run
/// finalize — is far worse: it would auto-start sensors, request
/// HealthKit auth, allocate background-audio sessions, etc. just to
/// finish a recording that's already over.
///
/// The split is therefore: live-recorder owns the live path; this
/// service owns the cold-recovery path; both call into `WorkoutAnalyzer`
/// (the pure-value engine) so the actual metric math is shared.
@MainActor
enum WorkoutRecoveryService {
    /// Outcome of a recovery attempt. The `session` is what the caller
    /// surfaces. `wasArchived` is false when the local archive write threw:
    /// nothing was saved and no iCloud upload was started, and the backups
    /// are kept so the workout can still be recovered from Lost Sessions.
    struct Outcome {
        let session: HRVSession
        let wasArchived: Bool
        /// User-facing reason copy, suitable for the launch alert
        /// success message ("Recovered 24 min, 1.28 mi at TRIMP 87.").
        let summaryLine: String
    }

    /// Run the same analyzer the live path uses. It's pure-value, so
    /// the result is identical to what would have come out of
    /// `WorkoutRecorder.finalizeSession` if the user had tapped Stop
    /// at the moment of interruption.
    private static func runAnalyzer(
        sport: Sport,
        rrPoints: [RRPoint],
        startDate: Date,
        track: [CLLocation],
        settings: UserSettings,
        unitsPreference: UnitsPreference
    ) -> WorkoutMetadata {
        let banisterSex: WorkoutAnalyzer.BanisterSex = settings.biologicalSex == .female ? .female : .male
        return WorkoutAnalyzer.analyze(
            sport: sport,
            rrPoints: rrPoints,
            startDate: startDate,
            track: track,
            userMaxHR: settings.effectiveMaxHR,
            userRestingHR: settings.effectiveRestingHR,
            userLTHR: settings.effectiveLTHR,
            sex: banisterSex,
            splitDistanceMeters: unitsPreference == .imperial ? 1609.344 : 1000.0
        )
    }

    /// The on-disk raw-RR backup for a session, or nil when it cannot be
    /// read. A missing or unreadable backup is a normal recovery outcome —
    /// the strap or override points may still carry the workout — so this
    /// logs and degrades rather than propagating.
    private static func loadRRBackup(
        _ rawBackup: RawRRBackup,
        sessionId: UUID
    ) -> RawRRBackup.BackupEntry? {
        do {
            return try rawBackup.retrieve(sessionId)
        } catch {
            debugLog("[WorkoutRecovery] RR backup retrieve failed for \(sessionId.uuidString.prefix(8)): \(error)")
            return nil
        }
    }

    /// Assembles the recovered `HRVSession` from the rebuilt beat series and
    /// metadata.
    ///
    /// Note: `HRVSession.sport` is a computed property derived from
    /// `workoutMetadata.sport`, so the sport choice flows through metadata —
    /// there is no separate `session.sport = ...` assignment to make.
    private static func buildRecoveredSession(
        sessionId: UUID,
        startDate: Date,
        endDate: Date,
        rrPoints: [RRPoint],
        metadata: WorkoutMetadata
    ) -> HRVSession {
        let series: RRSeries? = rrPoints.isEmpty
            ? nil
            : RRSeries(points: rrPoints, sessionId: sessionId, startDate: startDate)

        var session = HRVSession(
            id: sessionId,
            startDate: startDate,
            endDate: endDate,
            // Recovered sessions surface as complete so they reach the
            // dashboard + iCloud. The `partialDataReason` flag tells the UI
            // to render the "Estimated" badge.
            state: .complete,
            sessionType: .workout,
            rrSeries: series,
            analysisResult: nil,
            artifactFlags: nil
        )
        session.workoutMetadata = metadata
        return session
    }

    /// Saved-route TRIMP extrapolation. Same path the live finalize uses —
    /// `RouteTRIMPEstimator` covers crash-recovery and live-strap-dropout
    /// cases identically. A recovered recording stopped when the app did, so
    /// its distance may fall short of the route the user finished
    /// (`distanceMayBeTruncated`).
    private static func attachRouteExtrapolation(
        to metadata: inout WorkoutMetadata,
        track: [CLLocation],
        sport: Sport,
        archive: SessionArchive,
        savedRouteStore: SavedRouteStore
    ) {
        guard let extrap = RouteTRIMPEstimator.estimate(
            track: track,
            sport: sport,
            recordedTRIMP: metadata.luciaTRIMP,
            recordedDistance: metadata.distanceMeters,
            distanceMayBeTruncated: true,
            archive: archive,
            savedRouteStore: savedRouteStore
        ) else { return }
        metadata.extrapolatedTRIMP = extrap.estimatedTRIMP
        metadata.extrapolationConfidence = extrap.confidence
        metadata.extrapolationRouteName = extrap.routeName
    }

    /// Builds the analysis snapshot the post-summary expects, so recovered
    /// workouts open the same way as live-finalized ones.
    private static func attachAnalysisSnapshot(
        to metadata: inout WorkoutMetadata,
        sport: Sport,
        durationSec: TimeInterval,
        rrPoints: [RRPoint],
        settings: UserSettings
    ) {
        let snapshotInputs = WorkoutAnalysisSnapshotBuilder.Inputs(
            sport: sport,
            durationSec: durationSec,
            distanceMeters: metadata.distanceMeters,
            elevationGainMeters: metadata.elevationGainMeters,
            elevationLossMeters: metadata.elevationLossMeters,
            meanHR: rrPoints.isEmpty ? nil : 60_000.0 / (rrPoints.reduce(0.0) { $0 + Double($1.rr_ms) } / Double(rrPoints.count)),
            userMaxHR: settings.effectiveMaxHR,
            bodyWeightKg: settings.effectiveBodyWeightKg,
            samples: metadata.samples ?? [],
            splits: metadata.splits ?? [],
            trimp: metadata.luciaTRIMP,
            decouplingPercent: metadata.decouplingPercent
        )
        metadata.analysisSnapshot = WorkoutAnalysisSnapshotBuilder.build(snapshotInputs)
    }

    /// Recover an interrupted workout. Returns `nil` if there's nothing
    /// usable on disk for the session (no RR backup AND no track
    /// backup) — the caller can then fall through to the existing
    /// HRV-style `recoverFromBackup` path.
    ///
    /// The `.shared` defaults resolve INSIDE the function body. The
    /// `@MainActor enum WorkoutRecoveryService` declaration forces any
    /// default-arg expression to be evaluated in a nonisolated context — Swift
    /// 6 strict-concurrency rejects that for `@MainActor`-isolated singletons.
    /// The same workaround is documented on `WorkoutRecorder.init`'s
    /// `AppDependencies.current.collection.footPodManager` resolution; using `nil` defaults here keeps the
    /// call-site ergonomics identical.
    static func recover(
        sessionId: UUID,
        reason: PartialDataReason,
        archive: SessionArchive,
        rawBackup: RawRRBackup,
        cloudSyncManager: CloudKitSyncManager,
        savedRouteStore: SavedRouteStore? = nil,
        settingsManager: SettingsManager? = nil,
        unitsPreference: UnitsPreference? = nil,
        strapRRPoints: [RRPoint]? = nil,
        /// When set, rebuild from EXACTLY these RR points (already merged +
        /// clipped by the caller) instead of re-merging disk + strap. Used by
        /// the review/trim flow to re-finalize a recovered workout at a
        /// user-chosen end without re-pulling the (already-cleared) strap.
        overrideRRPoints: [RRPoint]? = nil,
        /// Whether to DELETE the on-disk GPS/track backup after archiving.
        /// Default false: an unreviewed recovery KEEPS its backups so the
        /// session is always re-recoverable until the user accepts it. The
        /// review's Save passes true (the user confirmed — safe to clean up).
        discardBackupsOnAccept: Bool = false,
        /// When set, use THIS GPS track instead of the on-disk one — the path
        /// for recovering a route from the Apple Watch (HealthKit) when the
        /// phone's GPS died mid-workout. Distance/splits recompute from it.
        overrideTrack: [CLLocation]? = nil,
        /// Apply the trailing-rest auto-trim to `overrideRRPoints` too. Used by
        /// the strap-augment path (the merged strap recording still has the
        /// post-workout tail). The manual trim/Save passes false — the user
        /// already chose the exact end.
        autoTrimOverride: Bool = false,
        /// Force the workout distance (meters) instead of computing it from the
        /// track — used to recover a crash-shortened distance from HealthKit's
        /// passive walking/running total (Watch/iPhone log it without GPS).
        overrideDistanceMeters: Double? = nil
    ) async -> Outcome? {
        let deps = Dependencies(
            archive: archive, rawBackup: rawBackup, cloudSyncManager: cloudSyncManager,
            savedRouteStore: savedRouteStore ?? AppDependencies.current.location.savedRouteStore,
            settingsManager: settingsManager ?? AppDependencies.current.app.settingsManager,
            unitsPreference: unitsPreference ?? UnitsPreferenceStore.current.resolved
        )
        let overrides = Overrides(
            strapRRPoints: strapRRPoints, rrPoints: overrideRRPoints, track: overrideTrack,
            autoTrim: autoTrimOverride, distanceMeters: overrideDistanceMeters,
            discardBackupsOnAccept: discardBackupsOnAccept
        )
        guard let prepared = Self.prepare(sessionId: sessionId, reason: reason, deps: deps, overrides: overrides) else {
            return nil
        }
        return Self.rebuild(sessionId: sessionId, reason: reason, prepared: prepared, overrides: overrides, deps: deps)
    }

    /// The stores one recovery reads and writes.
    struct Dependencies {
        let archive: SessionArchive
        let rawBackup: RawRRBackup
        let cloudSyncManager: CloudKitSyncManager
        let savedRouteStore: SavedRouteStore
        let settingsManager: SettingsManager
        let unitsPreference: UnitsPreference
    }

    /// The caller-supplied steering for a re-finalize, grouped so the
    /// rebuild stages can pass them along as one value.
    struct Overrides {
        let strapRRPoints: [RRPoint]?
        let rrPoints: [RRPoint]?
        let track: [CLLocation]?
        let autoTrim: Bool
        let distanceMeters: Double?
        let discardBackupsOnAccept: Bool
    }

    /// What was found on disk for this session.
    struct Prepared {
        let workoutRecord: WorkoutTrackBackup.Recovered?
        let rrEntry: RawRRBackup.BackupEntry?
        let existingSession: HRVSession?
    }

    /// Pull the workout-side artefacts and the RR data. Both are file reads
    /// with no dependency on each other, and keeping them on the MainActor is
    /// fine: each is a single bounded I/O. Nil means nothing is recoverable —
    /// the caller falls back to the HRV path.
    ///
    /// When re-finalizing an already-recovered session (the trim/Save path),
    /// its on-disk GPS backup may already be gone — the archived session is
    /// loaded as a fallback so a trim never loses sport/start/distance.
    private static func prepare(
        sessionId: UUID, reason: PartialDataReason, deps: Dependencies, overrides: Overrides
    ) -> Prepared? {
        let workoutRecord = AppDependencies.current.storage.workoutTrackBackup.retrieve(sessionId)
        let rrEntry = Self.loadRRBackup(deps.rawBackup, sessionId: sessionId)
        debugLog("[WorkoutRecovery] start sessionId=\(sessionId.uuidString.prefix(8)) reason=\(reason.rawValue) hasTrack=\(workoutRecord != nil) hasRR=\(rrEntry != nil) trackPoints=\(workoutRecord?.track.count ?? 0) rrPoints=\(rrEntry?.points.count ?? 0)")
        // Both empty AND no strap recording = nothing to recover.
        if workoutRecord == nil, rrEntry == nil,
           overrides.strapRRPoints?.isEmpty ?? true, overrides.rrPoints?.isEmpty ?? true {
            debugLog("[WorkoutRecovery] aborting — no on-disk backup or strap recording for session", level: .warning)
            return nil
        }
        return Prepared(
            workoutRecord: workoutRecord,
            rrEntry: rrEntry,
            existingSession: overrides.rrPoints != nil ? deps.archive.retrieveOrLog(sessionId) : nil
        )
    }

    private static func rebuild(
        sessionId: UUID, reason: PartialDataReason, prepared: Prepared,
        overrides: Overrides, deps: Dependencies
    ) -> Outcome? {
        let recovered = Self.resolveRecovered(sessionId: sessionId, prepared: prepared, overrides: overrides)
        guard Self.hasRecoverableData(recovered) else {
            debugLog("[WorkoutRecovery] aborting — the backup holds no beats, track points or samples past the start", level: .warning)
            return nil
        }
        let metadata = Self.assembleMetadata(
            recovered: recovered, reason: reason, overrides: overrides, prepared: prepared, deps: deps
        )
        var session = Self.buildRecoveredSession(
            sessionId: sessionId, startDate: recovered.startDate, endDate: recovered.endDate,
            rrPoints: recovered.rrPoints, metadata: metadata
        )
        if deps.archive.exists(sessionId), let archived = deps.archive.retrieveOrLog(sessionId) {
            Self.carryForward(from: archived, into: &session)
        }
        return Self.persist(session, metadata: session.workoutMetadata ?? metadata, recovered: recovered, overrides: overrides, deps: deps)
    }

    /// Something to save: a crash seconds into a workout leaves a header with
    /// no beats, track points or samples, and saving it made a completed
    /// 0-minute workout.
    private static func hasRecoverableData(_ recovered: RecoveredWorkout) -> Bool {
        let hasData = !recovered.rrPoints.isEmpty || !recovered.track.isEmpty || !recovered.liveSamples.isEmpty
        return hasData && recovered.endDate > recovered.startDate
    }

    /// The timeline and sample streams the rebuild works from.
    struct RecoveredWorkout {
        let sport: Sport
        let startDate: Date
        let endDate: Date
        let durationSec: TimeInterval
        let rrPoints: [RRPoint]
        let track: [CLLocation]
        let rawTrackWasEmpty: Bool
        /// Offsets the backup marked as rows whose heart rate came from Apple
        /// Health, including rows past a trimmed end.
        let backupHealthKitHROffsets: [Int]
        let liveSamples: [WorkoutSample]
        let baroSamples: [WorkoutTrackBackup.PersistedBaro]
    }

    /// A trim moves the end in; the per-tick and barometer streams are cut to
    /// it like the beats and the track, so charts and elevation stop there.
    private static func resolveRecovered(
        sessionId: UUID, prepared: Prepared, overrides: Overrides
    ) -> RecoveredWorkout {
        let record = prepared.workoutRecord
        let sport = record?.header.sport ?? prepared.existingSession?.workoutMetadata?.sport ?? .run
        let startDate = record?.header.startDate ?? prepared.existingSession?.startDate ?? prepared.rrEntry?.captureDate ?? Date()
        let rawTrack: [CLLocation] = overrides.track ?? record?.track ?? []
        let liveSamples: [WorkoutSample] = record?.samples ?? []
        let baroSamples = record?.barometricSamples ?? []
        let rrPoints = Self.resolveRRPoints(
            diskPoints: prepared.rrEntry?.points ?? [], strapPoints: overrides.strapRRPoints, overridePoints: overrides.rrPoints,
            autoTrimOverride: overrides.autoTrim, sessionId: sessionId, startDate: startDate)
        let track = Self.clipTrack(rawTrack, isOverride: overrides.track != nil, rrPoints: rrPoints, startDate: startDate)
        let endDate = Self.resolveEndDate(
            startDate: startDate, rrPoints: rrPoints, track: track, liveSamples: liveSamples, baroSamples: baroSamples
        )
        let durationSec = max(1, endDate.timeIntervalSince(startDate))
        return RecoveredWorkout(
            sport: sport, startDate: startDate, endDate: endDate, durationSec: durationSec, rrPoints: rrPoints,
            track: track, rawTrackWasEmpty: rawTrack.isEmpty, backupHealthKitHROffsets: record?.healthKitHROffsets ?? [],
            liveSamples: liveSamples.filter { Double($0.offsetSec) <= durationSec },
            baroSamples: baroSamples.filter { $0.timestamp <= endDate }
        )
    }

    /// The marked offsets that name a kept row, sorted, or nil when none do:
    /// a trim drops the markers of the rows it cuts.
    static func healthKitHROffsets(_ offsets: [Int], in samples: [WorkoutSample]) -> [Int]? {
        let kept = Set(samples.map(\.offsetSec)).intersection(offsets)
        return kept.isEmpty ? nil : kept.sorted()
    }

    /// Run the analyzer and dress the result up as stored metadata.
    ///
    /// The rows the crash backup marked as heart rate from Apple Health keep
    /// their markers, so the iCloud upload leaves that heart rate out.
    ///
    /// Re-finalizing with the GPS backup already gone (a trim of an
    /// already-recovered session) keeps the distance/route the original
    /// recovery computed. The off-body tail we trim away had no GPS, so a trim
    /// must not zero a real distance.
    private static func assembleMetadata(
        recovered: RecoveredWorkout, reason: PartialDataReason, overrides: Overrides,
        prepared: Prepared, deps: Dependencies
    ) -> WorkoutMetadata {
        let settings = deps.settingsManager.settings
        let computed = Self.runAnalyzer(
            sport: recovered.sport, rrPoints: recovered.rrPoints, startDate: recovered.startDate,
            track: recovered.track, settings: settings, unitsPreference: deps.unitsPreference
        )
        var metadata = Self.buildMetadata(
            sport: recovered.sport, computed: computed, baroSamples: recovered.baroSamples,
            liveSamples: recovered.liveSamples, reason: reason,
            overrideDistanceMeters: overrides.distanceMeters
        )
        metadata.healthKitHROffsets = Self.healthKitHROffsets(recovered.backupHealthKitHROffsets, in: recovered.liveSamples)
        Self.attachRouteExtrapolation(to: &metadata, track: recovered.track, sport: recovered.sport, archive: deps.archive, savedRouteStore: deps.savedRouteStore)
        if recovered.rawTrackWasEmpty, let existing = prepared.existingSession?.workoutMetadata {
            Self.backfillRouteFields(into: &metadata, from: existing)
        }
        Self.attachAnalysisSnapshot(to: &metadata, sport: recovered.sport, durationSec: recovered.durationSec, rrPoints: recovered.rrPoints, settings: settings)
        return metadata
    }

    /// Archive synchronously so we know we succeeded before clearing the
    /// persisted-state guard. Best-effort iCloud upload runs detached.
    ///
    /// The GPS/track backup survives until the user ACCEPTS the recovered
    /// session (review Save). Discarding it here on an unreviewed recovery
    /// leaves a wrong/over-long recovery with nothing to re-recover from.
    ///
    /// On archive failure the backups are NOT cleared — the data is the last
    /// thing we have — and the half-built session is surfaced so the user at
    /// least sees what was captured.
    private static func persist(
        _ session: HRVSession, metadata: WorkoutMetadata, recovered: RecoveredWorkout,
        overrides: Overrides, deps: Dependencies
    ) -> Outcome {
        let summary = summaryLine(
            for: metadata, durationSec: recovered.durationSec, unitsPreference: deps.unitsPreference
        )
        do {
            try deps.archive.archive(session, skipSameNightMerge: false, requestingReupload: true)
            deps.rawBackup.markAsArchived(session.id)
            if overrides.discardBackupsOnAccept {
                AppDependencies.current.storage.workoutTrackBackup.discard(session.id)
            }
            debugLog("[WorkoutRecovery] archived session \(session.id.uuidString.prefix(8)) sport=\(recovered.sport.rawValue) duration=\(Int(recovered.durationSec))s distance=\(Int(metadata.distanceMeters ?? 0))m TRIMP=\(Int(metadata.luciaTRIMP ?? 0))" + (metadata.extrapolatedTRIMP.map { " extrap=\(Int($0))" } ?? ""))
            let cloudSyncManager = deps.cloudSyncManager
            Task(priority: .utility) { await cloudSyncManager.uploadSession(session) }
            return Outcome(session: session, wasArchived: true, summaryLine: summary)
        } catch {
            debugLog("[WorkoutRecovery] Archive failed for \(session.id.uuidString.prefix(8)): \(error.localizedDescription)", level: .warning)
            return Outcome(session: session, wasArchived: false, summaryLine: summary)
        }
    }

    // MARK: - Metadata assembly

    /// Assemble `WorkoutMetadata` from the analyzer output.
    ///
    /// Extracted from `recover`. Pure apart from `Date()` for the
    /// recovery stamp, so the mapping from analyzer result to stored metadata
    /// can be checked directly.
    ///
    /// Two rules here are not obvious from the field names:
    ///
    ///   • `overrideDistanceMeters` beats the GPS-derived distance. It carries
    ///     HealthKit's passive walking/running total, which the Watch or phone
    ///     logs even when the app's own GPS track was cut short by the crash.
    ///     Guarded on `> 0` so a zero never overwrites a real distance.
    ///   • Elevation comes from the barometer, not the track. A pressure
    ///     sensor keeps working when GPS does not, and it is the more accurate
    ///     source for gain/loss regardless.
    private static func applyBarometricElevation(
        to metadata: inout WorkoutMetadata, baroSamples: [WorkoutTrackBackup.PersistedBaro]
    ) {
        guard !baroSamples.isEmpty else { return }
        let tuples: [(timestamp: Date, altitudeMeters: Double)] =
            baroSamples.map { (timestamp: $0.timestamp, altitudeMeters: $0.altitudeMeters) }
        let processed = BarometricAltitudeProcessor.process(samples: tuples)
        metadata.elevationGainMeters = processed.gainMeters
        metadata.elevationLossMeters = processed.lossMeters
    }

    static func buildMetadata(
        sport: Sport,
        computed: WorkoutMetadata,
        baroSamples: [WorkoutTrackBackup.PersistedBaro],
        liveSamples: [WorkoutSample],
        reason: PartialDataReason,
        overrideDistanceMeters: Double?
    ) -> WorkoutMetadata {
        var metadata = WorkoutMetadata(sport: sport)
        metadata.distanceMeters = computed.distanceMeters
        if let forced = overrideDistanceMeters, forced > 0 {
            metadata.distanceMeters = forced
        }
        applyBarometricElevation(to: &metadata, baroSamples: baroSamples)
        metadata.gpsPolyline = computed.gpsPolyline
        metadata.splits = computed.splits
        metadata.luciaTRIMP = computed.luciaTRIMP
        metadata.hrTSS = computed.hrTSS
        metadata.decouplingPercent = computed.decouplingPercent
        metadata.efficiencyFactor = computed.efficiencyFactor
        metadata.samples = liveSamples.isEmpty ? nil : liveSamples
        metadata.partialDataReason = reason
        metadata.recoveredAt = Date()
        return metadata
    }

    /// Carry route fields forward from an earlier recovery when re-finalizing
    /// with the GPS backup already deleted.
    ///
    /// This is the trim path: the user trims an already-recovered session, and
    /// its on-disk track is long gone. The off-body tail being cut had no GPS,
    /// so a trim must never zero a distance the first recovery legitimately
    /// computed. Each field is filled only when the new value is absent —
    /// a real recomputed value always wins.
    static func backfillRouteFields(into metadata: inout WorkoutMetadata, from existing: WorkoutMetadata) {
        if (metadata.distanceMeters ?? 0) == 0 { metadata.distanceMeters = existing.distanceMeters }
        if metadata.splits?.isEmpty ?? true { metadata.splits = existing.splits }
        if metadata.gpsPolyline == nil { metadata.gpsPolyline = existing.gpsPolyline }
        if metadata.elevationGainMeters == nil { metadata.elevationGainMeters = existing.elevationGainMeters }
        if metadata.elevationLossMeters == nil { metadata.elevationLossMeters = existing.elevationLossMeters }
    }

    // MARK: - Pure resolution steps
    //
    // Extracted from `recover`, where each was an inline closure inside a
    // 155-line, complexity-26 function; each is a pure function of its inputs
    // with no I/O, so pulling them out makes the recovery decisions testable
    // without a simulator, a strap, or a disk backup. `recover` keeps the
    // orchestration; these hold the rules.

    static func resolveRRPoints(
        diskPoints: [RRPoint],
        strapPoints: [RRPoint]?,
        overridePoints: [RRPoint]?,
        autoTrimOverride: Bool,
        sessionId: UUID,
        startDate: Date
    ) -> [RRPoint] {
        if let override = overridePoints {
            return autoTrimOverride ? trimTrailingRest(override) : override
        }
        let merged = mergedPoints(
            diskPoints: diskPoints, strapPoints: strapPoints,
            sessionId: sessionId, startDate: startDate
        )
        let trimmed = trimTrailingRest(merged)
        if trimmed.count < merged.count {
            debugLog("[WorkoutRecovery] trimmed \(merged.count - trimmed.count) trailing rest beats (\(merged.count) → \(trimmed.count))")
        }
        return trimmed
    }

    /// Prefer the merged strap + disk series; fall back to whichever side has
    /// more beats when the selector can't reconcile them.
    private static func mergedPoints(
        diskPoints: [RRPoint], strapPoints: [RRPoint]?, sessionId: UUID, startDate: Date
    ) -> [RRPoint] {
        guard let strap = strapPoints, !strap.isEmpty else { return diskPoints }
        if diskPoints.isEmpty { return strap }
        if let selection = DataSourceSelector.selectBestSource(
            streamingPoints: diskPoints,
            internalPoints: strap,
            sessionId: sessionId,
            sessionStart: startDate
        ) {
            debugLog("[WorkoutRecovery] merged strap(\(strap.count)) + disk(\(diskPoints.count)) → \(selection.points.count) [\(selection.normalizedSource)]")
            return selection.points
        }
        return strap.count > diskPoints.count ? strap : diskPoints
    }

    /// Clips the GPS track to the RR end so a trimmed workout's distance
    /// matches its (shorter) duration.
    ///
    /// A Watch route is the authoritative full route and is returned whole —
    /// it did not come from the phone GPS that the crash truncated.
    static func clipTrack(
        _ rawTrack: [CLLocation],
        isOverride: Bool,
        rrPoints: [RRPoint],
        startDate: Date
    ) -> [CLLocation] {
        if isOverride { return rawTrack }
        guard let lastT = rrPoints.last?.t_ms else { return rawTrack }
        let endTime = startDate.addingTimeInterval(Double(lastT) / 1000.0)
        return rawTrack.filter { $0.timestamp <= endTime }
    }

    /// When the workout actually ended.
    ///
    /// The last RR beat is the most reliable "we still had a signal" anchor.
    /// The fallbacks let an indoor workout with no track still get a real
    /// duration. Returning `startDate` is the last resort; `rebuild` then
    /// saves nothing (see `hasRecoverableData`).
    static func resolveEndDate(
        startDate: Date,
        rrPoints: [RRPoint],
        track: [CLLocation],
        liveSamples: [WorkoutSample],
        baroSamples: [WorkoutTrackBackup.PersistedBaro]
    ) -> Date {
        if let last = rrPoints.last {
            return startDate.addingTimeInterval(Double(last.t_ms) / 1000.0)
        }
        if let last = track.last { return last.timestamp }
        if let last = liveSamples.last {
            return startDate.addingTimeInterval(Double(last.offsetSec))
        }
        if let last = baroSamples.last { return last.timestamp }
        return startDate
    }

    // MARK: - Trailing-rest trim

    /// Rest vs working HR come from percentiles (robust to off-body noise and a
    /// few wild beats): the 10th percentile ≈ resting / strap-on-a-chair, the
    /// 90th ≈ working HR. "Clearly above rest" marks a window as active, and
    /// the line the HR drops below at the end of the workout is where the
    /// trailing rest begins.
    ///
    /// Only trims when the drop is SUSTAINED — matching "HR drops clearly for
    /// 1–2 minutes". ~4 windows of 20 beats ≈ 80+ beats of trailing rest.
    static func trimTrailingRest(_ points: [RRPoint]) -> [RRPoint] {
        let windowBeats = 20
        guard points.count > windowBeats * 8 else { return points }
        let windows = windowedHeartRates(points, windowBeats: windowBeats)
        let valid = windows.filter { $0 > 0 }.sorted()
        guard valid.count > 8 else { return points }
        let restHR = valid[Int(Double(valid.count) * 0.10)]
        let peakHR = valid[min(valid.count - 1, Int(Double(valid.count) * 0.90))]
        guard peakHR - restHR >= 10 else { return points } // too flat to call
        let threshold = restHR + (peakHR - restHR) * 0.35
        var lastActiveWindow = -1
        for (idx, hr) in windows.enumerated() where hr >= threshold { lastActiveWindow = idx }
        guard lastActiveWindow >= 0, lastActiveWindow < windows.count - 1 else { return points }
        guard windows.count - 1 - lastActiveWindow >= 4 else { return points }
        let cutWindow = min(windows.count, lastActiveWindow + 1 + 2) // short cooldown
        return Array(points[0 ..< min(points.count, cutWindow * windowBeats)])
    }

    /// Windowed HR across the whole recording.
    private static func windowedHeartRates(_ points: [RRPoint], windowBeats: Int) -> [Double] {
        var windows: [Double] = []
        var i = 0
        while i + windowBeats <= points.count {
            windows.append(meanHeartRate(points[i ..< i + windowBeats]))
            i += windowBeats
        }
        return windows
    }

    private static func meanHeartRate(_ slice: ArraySlice<RRPoint>) -> Double {
        let valid = slice.map { Double($0.rr_ms) }.filter { $0 >= 300 && $0 <= 2000 }
        guard !valid.isEmpty else { return 0 }
        let meanRR = valid.reduce(0, +) / Double(valid.count)
        return meanRR > 0 ? 60_000.0 / meanRR : 0
    }

    // MARK: - User-facing copy

    private static func summaryLine(
        for metadata: WorkoutMetadata,
        durationSec: TimeInterval,
        unitsPreference: UnitsPreference
    ) -> String {
        let minutes = Int(durationSec / 60)
        var parts = [String(localized: "Recovered \(minutes) min", bundle: LanguageManager.appBundle)]
        if let m = metadata.distanceMeters, m > 0 {
            parts.append(CoachReportGenerator.formatDistance(m, units: unitsPreference))
        }
        if let t = metadata.luciaTRIMP, t > 0 {
            parts.append(String(localized: "TRIMP \(Int(t))", bundle: LanguageManager.appBundle))
        }
        return listFormatter.string(from: parts) ?? parts.joined(separator: ", ")
    }

    /// Joins the summary in the app's language ("A, B and C", "A、B、C").
    private static var listFormatter: ListFormatter {
        let formatter = ListFormatter()
        formatter.locale = LanguageManager.appLocale
        return formatter
    }
}
