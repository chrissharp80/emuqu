import Foundation
import HealthKit
import UIKit

// MARK: - Overnight Streaming Mode (bluetooth-central driven)

extension OvernightStreamingCoordinator {
    /// Result of gathering overnight data — the chosen RR points and metadata
    struct OvernightDataResult {
        let points: [RRPoint]
        let baseSession: HRVSession
        let streamingBeats: Int
        let deviceBeats: Int?
        let dataSource: String
        let reconnectCount: Int
        /// The strap's beats as downloaded, when the gather downloaded any:
        /// the stream's backup does not hold them, so a pause that cannot be
        /// archived backs them up whichever source was chosen.
        var downloadedPoints: [RRPoint]?
    }

    /// Whether the session's device is a Verity Sense (streaming-only, no internal recording).
    /// Checks device provenance first (persisted), falls back to live connection state.
    func isVeritySenseDevice(_ session: HRVSession) -> Bool {
        if let model = session.deviceProvenance?.deviceModel.lowercased() {
            return model.contains("verity") || model.contains("sense")
        }
        return collector.polarManager.connectedDeviceType == .veritySense
    }

    /// Create a failed session and update collector state.
    ///
    /// When the strap gate has just reported that the strap still holds this
    /// night (`reportDeviceFetchMiss`), that stays the error: it is what the
    /// user has to act on before the next recording clears the strap, and
    /// "not enough beats" would hide it. `lastError` is cleared when a night
    /// or a resumed segment starts, so the error found here is this night's.
    func failSession(from baseSession: HRVSession) async -> HRVSession {
        let failed = HRVSession(
            id: baseSession.id, startDate: baseSession.startDate, endDate: Date(),
            state: .failed, sessionType: baseSession.sessionType,
            rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        await MainActor.run {
            collector.sessionState.currentSession = failed
            // Nothing is being analysed any more; the failed session is shown.
            collector.sessionState.recordingPhase = .idle
            if !Self.reportsStrapStillHoldsNight(collector.sessionState.lastError) {
                collector.sessionState.lastError = RRCollector.CollectorError.insufficientData
            }
            collector.morningCoordination.morningStatus = nil
        }
        // Overnight holds no audio session (App Store 2.5.4); nothing to
        // release on the failure path.
        return failed
    }

    private static func reportsStrapStillHoldsNight(_ error: Error?) -> Bool {
        guard case .strapStillHoldsNight? = error as? RRCollector.CollectorError else { return false }
        return true
    }

    /// Start overnight streaming. Background execution rides on the
    /// `bluetooth-central` mode (incoming Polar packets wake the app) —
    /// see the note below; no keep-alive sessions are held.
    ///
    /// Neither overnight keep-alive is used (App Store 2.5.4): background
    /// location would be a pure keep-alive with no location feature, and silent
    /// background audio all night is the textbook 2.5.4 abuse pattern reviewers
    /// screen for (audio mode must serve AUDIBLE content). Overnight
    /// execution is carried by `bluetooth-central` instead, which is
    /// the sanctioned architecture for BLE heart-rate apps:
    ///   • every incoming Polar packet (~1 Hz while streaming) wakes
    ///     the process, and the awake runloop fires the due 1 Hz
    ///     timers — so the 60 s incremental backup gate is evaluated
    ///     on every wake (`RawRRBackup.incrementalBackup` is
    ///     internally throttled and safe to over-call);
    ///   • a strap dropout means no data is arriving, so there is
    ///     nothing to back up while suspended; the reconnect handler
    ///     forces a flush on resume;
    ///   • the resign/background/terminate forced flush plus
    ///     SessionRecoveryService remain the kill-recovery net;
    ///   • morning processing holds a UIApplication background-task
    ///     assertion (see MorningProcessingService) instead of
    ///     leaning on the audio session.
    /// Workouts activate audio only around each spoken cue
    /// (`BackgroundAudioManager.beginCue()`).
    ///
    /// The diagnostics sampler is armed here. If iOS kills the
    /// app during overnight streaming we need the memory/thermal trace to
    /// diagnose why. See SystemDiagnosticsManager doc.
    ///
    /// `useDeviceInternalBackup` configures whether overnight streaming
    /// includes device-internal backup. Verity Sense can't record internally
    /// while streaming, so it always streams only.
    ///
    /// A night is refused while an earlier night's ending is still in
    /// progress (`refuseWhileEndingInProgress`).
    ///
    /// - Parameter sessionType: .overnight or .nap
    @MainActor
    func startOvernightStreaming(sessionType: SessionType = .overnight, useDeviceInternalBackup: Bool = true) throws {
        try refuseWhileEndingInProgress()
        guard collector.polarManager.connectionState == .connected else { throw RRCollector.CollectorError.notConnected }
        guard !collector.polarManager.isStreaming else { throw RRCollector.CollectorError.alreadyRecording }
        let session = HRVSession(sessionType: sessionType, deviceProvenance: .streaming(from: collector.polarManager))
        collector.useDeviceBackupForOvernight = useDeviceInternalBackup
        try collector.polarManager.startStreaming()  // primary data source
        // Only once streaming started: a failed start must not leave it sampling.
        AppDependencies.current.app.systemDiagnosticsManager.startSamplingDuringRecording()
        if useDeviceInternalBackup, collector.polarManager.connectedDeviceType != .veritySense {
            launchDeviceRecordingLoop()  // H10-only internal-recording backup
        }
        resetOvernightStreamingState(session: session)
        startOvernightHealthKitObservers()
        collector.persistRecordingState(sessionId: session.id, startTime: Date(), sessionType: sessionType)
        logOvernightStreamingStart(session: session, sessionType: sessionType)
        startOvernightStreamingTimer()
    }

    /// `collector.overnightDeviceBackupActive` is cleared here; the async backup-start Task
    /// flips it true once the H10's internal recording actually begins. This runs
    /// synchronously before that Task's `startRecording` completes, so it can't
    /// clobber it.
    @MainActor
    private func resetOvernightStreamingState(session: HRVSession) {
        collector.sessionState.currentSession = session
        collector.sessionState.collectedPoints = []
        collector.sessionStartTime = Date()
        collector.streamingLifecycle.isStreamingMode = true
        collector.streamingLifecycle.isOvernightStreaming = true
        collector.sessionState.recordingPhase = .overnightStreaming
        collector.streamingLifecycle.streamingTargetSeconds = Int.max
        collector.streamingLifecycle.streamingElapsedSeconds = 0
        collector.sessionState.isCollecting = true
        collector.streamingLifecycle.pausedBeatCount = 0
        collector.lastSeenReconnectCount = 0
        collector.overnightDeviceBackupActive = false
        collector.isOvernightEnding = false
        // A Skip from an earlier morning never reaches this night's download,
        // and an earlier session's error is not this night's.
        collector.deviceFetchPolicy = .automatic
        collector.sessionState.lastError = nil
    }

    /// A night or a resumed segment may start only once no earlier ending
    /// owns the recorder: the ending's download, analysis and publish would
    /// otherwise overwrite the new night's session and phase. While one is in
    /// progress the start throws `alreadyRecording` (the strap's recording is
    /// still being taken off it) and the claim stays held. A claim left
    /// behind by a caller that never returned, older than
    /// `StreamingLifecycle.staleEndingClaimAge`, is dropped and logged.
    @MainActor
    func refuseWhileEndingInProgress() throws {
        switch collector.streamingLifecycle.clearEndingForNewNight() {
        case .clear:
            return
        case let .droppedStale(ageSeconds):
            debugLog("[RRCollector] ⚠️ An earlier night's ending never released its claim (held \(Int(ageSeconds / 60)) min) — dropped for the new night", level: .warning)
        case .endingInProgress:
            debugLog("[RRCollector] Not starting: an earlier night's ending is still in progress", level: .warning)
            throw RRCollector.CollectorError.alreadyRecording
        }
    }

    /// Start observing HealthKit for sleep data so we catch Apple Watch sync.
    /// Same for vitals — the Watch syncs respiratory rate, SpO2, wrist temp,
    /// and resting HR well after sleep ends. Without this observer the
    /// SleepDetail card stays empty for "most nights" until the next
    /// launch happens to coincide with the Watch having synced.
    private func startOvernightHealthKitObservers() {
        collector.healthKit.writes.startObservingSleepData()
        collector.healthKit.vitals.startObservingVitalsData()
    }

    private func logOvernightStreamingStart(session: HRVSession, sessionType: SessionType) {
        warnIfStrapBatteryMayRefuse()
        debugLog("[RRCollector] ✅ Started overnight streaming (H10 internal recording, the primary source: \(collector.useDeviceBackupForOvernight ? "will arm" : "OFF"))")
        debugLog("[RRCollector] Session ID: \(session.id)")
        debugLog("[RRCollector] Session type: \(sessionType.rawValue)")
        debugLog("[RRCollector] Connected device: \(collector.polarManager.connectedDeviceId ?? "unknown")")
    }

    /// Timer for overnight streaming - tracks elapsed time and performs incremental backups.
    ///
    /// Tolerance = 0.25s lets iOS coalesce this long-running 1Hz wakeup with
    /// other timers overnight, reducing CPU + battery cost without changing UX.
    func startOvernightStreamingTimer() {
        collector.streamingTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak collector] _ in
            Task { @MainActor in
                collector?.overnightStreaming.overnightStreamingTick()
            }
        }
        timer.tolerance = 0.25
        collector.streamingTimer = timer
    }

    /// One 1 Hz overnight tick: elapsed clock, strap keep-alive, and the
    /// incremental backup (time-based, or forced by a detected reconnection).
    /// The elapsed clock is the wall clock's (`streamingElapsedNow`), and the
    /// battery is checked on the first tick of each 30 s of it, so a tick
    /// missed while the app was suspended skips neither.
    @MainActor
    private func overnightStreamingTick() {
        guard collector.streamingLifecycle.isOvernightStreaming, collector.streamingTimer != nil else { return }
        let previousElapsed = collector.streamingLifecycle.streamingElapsedSeconds
        collector.streamingLifecycle.streamingElapsedSeconds = collector.streamingElapsedNow
        if collector.streamingLifecycle.streamingElapsedSeconds / 30 != previousElapsed / 30 {
            collector.polarManager.checkBatteryStaleness()
        }
        let currentReconnectCount = collector.polarManager.streamingReconnectCount
        let reconnectionOccurred = currentReconnectCount > collector.lastSeenReconnectCount
        if reconnectionOccurred {
            debugLog("[RRCollector] Streaming reconnection detected (\(collector.lastSeenReconnectCount) → \(currentReconnectCount)) - forcing backup")
            collector.lastSeenReconnectCount = currentReconnectCount
        }
        guard let session = collector.sessionState.currentSession else { return }
        runOvernightIncrementalBackup(session: session, force: reconnectionOccurred)
    }

    @MainActor
    private func runOvernightIncrementalBackup(session: HRVSession, force: Bool) {
        let buffer = collector.polarManager.streamedRRPoints
        let deviceId = collector.polarManager.connectedDeviceId
        let didBackup = collector.rawBackup.incrementalBackup(
            points: buffer,
            sessionId: session.id,
            deviceId: deviceId,
            force: force
        )
        guard didBackup else { return }
        let sessionId = session.id
        let cloudSyncManager = collector.cloudSyncManager
        Task(priority: .utility) {
            await cloudSyncManager.uploadLiveBackup(sessionId: sessionId, points: buffer, deviceId: deviceId)
        }
    }

    /// Merge parent session RR data with current child session's data when resumed.
    func mergeParentSessionData(data: OvernightDataResult) -> (points: [RRPoint], baseSession: HRVSession) {
        guard let parentIds = data.baseSession.linkedSessionIds,
              let parentId = parentIds.first,
              let parentSession = collector.archive.retrieveOrLog(parentId),
              let parentSeries = parentSession.rrSeries,
              !parentSeries.points.isEmpty
        else {
            return (data.points, data.baseSession)
        }
        debugLog("[RRCollector] Merging parent session \(parentId.uuidString.prefix(8)): \(parentSeries.points.count) parent beats + \(data.points.count) resumed beats")
        guard let offsetChildPoints = Self.childPointsOffsetToParent(data: data, parentSession: parentSession) else {
            return (data.points, data.baseSession)
        }
        return (parentSeries.points + offsetChildPoints, Self.mergedBaseSession(data: data, parentSession: parentSession))
    }

    /// Offset the child (resumed) session's timestamps so they are relative
    /// to the parent's startDate. Without this, the child's t_ms starts from 0
    /// and overlaps with the parent's data instead of appearing after the gap.
    ///
    /// A non-positive offset means the child's `startDate` is at or before
    /// the parent's — impossible under normal pause/resume (the resume
    /// action has to happen after the pause). Returning nil (skipping the merge
    /// entirely) is safer than silently dropping the offset and overlapping the
    /// two segments, which silently corrupts the chart and the analysis.
    /// Re-anchors a child segment onto its parent's timeline. See `MillisecondOffset` for why the conversion is guarded.
    static func childPointsOffsetToParent(data: OvernightDataResult, parentSession: HRVSession) -> [RRPoint]? {
        guard let offsetMs = MillisecondOffset.between(data.baseSession.startDate, and: parentSession.startDate), offsetMs > 0 else {
            debugLog("[RRCollector] Refusing merge: child startDate \(data.baseSession.startDate) is not after parent startDate \(parentSession.startDate), or the interval is unrepresentable. Using child segment alone.", level: .warning)
            return nil
        }
        debugLog("[RRCollector] Offset child timestamps by \(offsetMs / 60000) minutes")
        return data.points.map { point in
            RRPoint(
                t_ms: point.t_ms + offsetMs,
                rr_ms: point.rr_ms,
                wallClockMs: point.wallClockMs.map { $0 + offsetMs },
                hr: point.hr
            )
        }
    }

    /// The child's identity and metadata, re-anchored to the parent's start.
    private static func mergedBaseSession(data: OvernightDataResult, parentSession: HRVSession) -> HRVSession {
        HRVSession(
            id: data.baseSession.id,
            startDate: parentSession.startDate,
            endDate: data.baseSession.endDate ?? Date(),
            state: .analyzing,
            sessionType: data.baseSession.sessionType,
            rrSeries: nil,
            analysisResult: nil,
            artifactFlags: nil,
            deviceProvenance: data.baseSession.deviceProvenance,
            linkedSessionIds: data.baseSession.linkedSessionIds,
            pausedDate: data.baseSession.pausedDate
        )
    }

    /// Minimum beats for one source to stand on its own as a usable night:
    /// the source selector's own bar.
    private static let minimumUsableBeats = DataSourceSelector.minimumValidBeats

    /// Whether the night has enough data to finalize.
    ///
    /// A resumed CHILD session is held to a lower bar deliberately: its beats
    /// are merged into the parent night rather than standing alone, so "some
    /// data" is enough. A standalone night needs a real sample from at least
    /// one source.
    static func hasSufficientOvernightData(
        streamingCount: Int,
        internalCount: Int,
        isResumedChild: Bool
    ) -> Bool {
        let hasValidStreaming = streamingCount >= minimumUsableBeats
        let hasValidInternal = internalCount >= minimumUsableBeats
        let hasAnyData = streamingCount > 0 || internalCount > 0
        return hasValidStreaming || hasValidInternal || (isResumedChild && hasAnyData)
    }

    /// Stop overnight streaming and produce the recovery score.
    ///
    /// The morning blocks on the strap download for one accurate score: a
    /// quick streaming score that later shifts under a background refinement
    /// is worse than one accurate score. HealthKit sleep is polled IN PARALLEL
    /// so the 1-2 min download time isn't wasted.
    /// An H10 the link dropped overnight is reconnected first, within a
    /// bounded window and not at all when it is still connected (see
    /// `fetchDeviceAndSleepConcurrently`). Insufficient-streaming nights take
    /// the blocking `fallbackToDeviceFetch`.
    ///
    /// The stop claims the night's ending before its first suspension and
    /// holds it until the night is on the review card or has failed, so a
    /// Stop tapped again, or one that lands while a pause or a discard is
    /// ending the night, returns nil and leaves the night to that one. The
    /// brief "complete" status and the baseline update that follow run
    /// without it (`releaseEndingOnceShown`).
    func stopOvernightStreaming() async -> HRVSession? {
        guard let claim = collector.streamingLifecycle.claimOvernightEnding() else { return nil }
        defer { collector.streamingLifecycle.releaseOvernightEnding(claim) }
        // From the tap on, not only once analysis starts: the strap stop,
        // reconnect and download come first, and without an assertion a
        // trip to the home screen suspends the app mid-download. On expiry
        // the work is suspended, not cut short; it resumes on return.
        let bgTask = BackgroundTaskAssertion.forRecordingStop(named: "OvernightStop")
        defer { bgTask.end() }
        await endDeviceRecordingArming()
        let (baseSession, streamingPoints, reconnectCount) = await stopStreamingInfrastructure()
        await backupStreamingData(streamingPoints, sessionId: baseSession.id)
        let isVeritySense = isVeritySenseDevice(baseSession)
        let finalSession = await scoreStoppedNight(
            baseSession: baseSession, streamingPoints: streamingPoints,
            reconnectCount: reconnectCount, isVeritySense: isVeritySense
        )
        disconnectVeritySenseAfterNight(isVeritySense: isVeritySense)
        return finalSession
    }

    /// The good-streaming morning, or the device-only fallback when the
    /// stream is too short.
    private func scoreStoppedNight(
        baseSession: HRVSession, streamingPoints: [RRPoint], reconnectCount: Int, isVeritySense: Bool
    ) async -> HRVSession? {
        guard Self.hasValidStreaming(streamingPoints, baseSession: baseSession) else {
            debugLog("[RRCollector] Insufficient streaming data (\(streamingPoints.count) beats) — attempting device fetch")
            return await fallbackToDeviceFetch(
                baseSession: baseSession, streamingPoints: streamingPoints,
                reconnectCount: reconnectCount, isVeritySense: isVeritySense
            )
        }
        return await downloadMergeAndScoreNight(
            baseSession: baseSession, streamingPoints: streamingPoints,
            reconnectCount: reconnectCount, isVeritySense: isVeritySense
        )
    }

    /// A resumed child only needs *some* new beats — its parent already holds the
    /// bulk of the night. A fresh night needs enough to analyse on its own.
    private static func hasValidStreaming(_ streamingPoints: [RRPoint], baseSession: HRVSession) -> Bool {
        let isResumedChild = baseSession.linkedSessionIds?.isEmpty == false
        return streamingPoints.count >= minimumUsableBeats || (isResumedChild && !streamingPoints.isEmpty)
    }

    /// A Verity Sense night is scored from the stream alone (the morning never
    /// downloads from it), so nothing is left to pull and the sensor is
    /// released once the night is scored, or has failed for too short a stream.
    /// A night started on it since the stop let go of the ending keeps it.
    private func disconnectVeritySenseAfterNight(isVeritySense: Bool) {
        guard isVeritySense, !collector.streamingLifecycle.isOvernightStreaming else { return }
        debugLog("[RRCollector] Auto-disconnecting Verity Sense after overnight session")
        collector.polarManager.disconnect()
    }

    /// The good-streaming morning: pull the strap file (and sleep) concurrently,
    /// pick the winning source, then analyse and archive the night.
    private func downloadMergeAndScoreNight(
        baseSession: HRVSession,
        streamingPoints: [RRPoint],
        reconnectCount: Int,
        isVeritySense: Bool
    ) async -> HRVSession {
        let fetched = await fetchDeviceAndSleepConcurrently(
            baseSession: baseSession, streamingPoints: streamingPoints, isVeritySense: isVeritySense
        )
        let (finalPoints, dataSource, finalDeviceBeats) = selectBestDataSource(
            streamingPoints: streamingPoints, devicePoints: fetched.devicePoints, baseSession: baseSession
        )
        return await analyzeAndFinalizeOvernight(
            finalPoints: finalPoints, baseSession: baseSession,
            streamingBeats: streamingPoints.count, deviceBeats: finalDeviceBeats,
            dataSource: dataSource, reconnectCount: reconnectCount,
            prefetchedSleepData: fetched.sleep
        )
    }

    /// ALWAYS pull and merge the strap's internal recording on an H10 "both"
    /// night — no density-based skip. The strap file is REDUNDANCY and the
    /// source of truth, so a dropped connection can never lose a night;
    /// skipping the download when streaming looks nearly complete would trade
    /// that guarantee for a faster morning.
    /// `fetchNightFromStrap` decides whether this night downloads at all and
    /// reconnects a strap the link dropped overnight; its phases are
    /// hard-timeout-guarded, so an unresponsive strap still falls back to the
    /// streamed night.
    ///
    /// The sleep poll is a quick fast-path for sleep that ALREADY synced by wake
    /// (short — the HKObserverQuery auto-rescores when Apple Watch sleep
    /// lands later), and runs concurrently with the download.
    private func fetchDeviceAndSleepConcurrently(
        baseSession: HRVSession,
        streamingPoints: [RRPoint],
        isVeritySense: Bool
    ) async -> (devicePoints: [RRPoint]?, sleep: SleepData?) {
        async let earlySleepData = pollSleepDuringDeviceFetch(sessionStart: baseSession.startDate)
        let devicePoints = await fetchNightFromStrap(
            baseSession: baseSession, streamingPoints: streamingPoints, isVeritySense: isVeritySense
        )
        return (devicePoints, await earlySleepData)
    }

    /// Poll HealthKit for last night's sleep in parallel with the device fetch
    /// (part of the blocking morning). Cache-first,
    /// bails immediately on locked-phone protected-data errors.
    ///
    /// SHORT fast-path only (not a 2-minute poll). Apple
    /// Watch sleep syncs to HealthKit on the system's own schedule (typically
    /// ~90s AFTER wake, no API to expedite — Apple DTS), so a long blocking
    /// poll just makes the morning crawl waiting for data that usually isn't
    /// there yet. The app already has an `HKObserverQuery` +
    /// `enableBackgroundDelivery(.immediate)` that fires the auto-rescore the
    /// moment the Watch sleep lands (even minutes later, even backgrounded) —
    /// that IS the mechanism. So we only do a couple of quick attempts to grab
    /// sleep that ALREADY synced by wake, then show the score immediately and
    /// let the observer reconcile. (Matches how AutoSleep/Bevel/etc. work.)
    ///
    /// The cache is read first — the sleep observer warms it as the Watch syncs,
    /// so most mornings hit there and skip the poll loop entirely.
    ///
    /// The cache answers within a day either side of the recording, so when
    /// tonight's entry is missing it can hand back the previous night. The
    /// entry is used only when it overlaps this recording, the check every
    /// other cache reader makes; otherwise the poll runs as if it had missed.
    private static func warmSleepCacheHit(sessionStart: Date) -> SleepData? {
        guard let cached = SleepDataCache.read(coveringRecordingStart: sessionStart),
              cached.nightSleepMinutes > 0,
              cached.plausiblyBelongsToRecording(start: sessionStart, end: Date())
        else { return nil }
        debugLog("[RRCollector] ✅ Parallel sleep poll: cache hit \(cached.nightSleepMinutes) min — skipping poll loop")
        return cached
    }

    private func pollSleepDuringDeviceFetch(
        sessionStart: Date
    ) async -> SleepData? {
        let maxAttempts = 3 // 3 × 2s = ~6s fast path; observer handles late arrival
        if let cached = Self.warmSleepCacheHit(sessionStart: sessionStart) { return cached }
        debugLog("[RRCollector] Starting parallel sleep poll during device fetch...")
        for attempt in 1 ... maxAttempts {
            switch await attemptParallelSleepFetch(sessionStart: sessionStart, attempt: attempt) {
            case .found(let sleepData): return sleepData
            case .abort: return nil
            case .retry: break
            }
            guard attempt < maxAttempts else { break }
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            } catch {
                break // Task cancelled
            }
        }
        debugLog("[RRCollector] Parallel sleep poll: no sleep found after \(maxAttempts) attempts")
        return nil
    }

    private enum SleepPollOutcome {
        case found(SleepData)
        case retry
        case abort
    }

    /// One attempt of the parallel sleep poll.
    ///
    /// Locked-phone protected-data short-circuits to `.abort`: that data only
    /// becomes readable after first-unlock, so don't burn retries — the
    /// observer re-triggers after unlock.
    private func attemptParallelSleepFetch(sessionStart: Date, attempt: Int) async -> SleepPollOutcome {
        do {
            let sleepData = try await collector.healthKit.fetchSleepData(for: sessionStart, recordingEnd: Date())
            guard sleepData.nightSleepMinutes > 0 else { return .retry }
            debugLog("[RRCollector] ✅ Parallel sleep poll: found \(sleepData.nightSleepMinutes) min on attempt \(attempt)")
            return .found(sleepData)
        } catch {
            debugLog("[RRCollector] Parallel sleep poll attempt \(attempt) error: \(error)")
            let nsError = error as NSError
            guard nsError.domain == HKErrorDomain,
                  nsError.code == HKError.Code.errorDatabaseInaccessible.rawValue
            else { return .retry }
            debugLog("[RRCollector] Protected health data — aborting parallel poll; observer will re-trigger after unlock", level: .warning)
            return .abort
        }
    }

    // MARK: - The one overnight fetch gate

    /// The strap's copy of the night, for the morning, its streaming-short
    /// fallback and a pause alike. H10 only (a Verity Sense night is scored
    /// from the stream), only when this night armed the strap, and never
    /// after the user tapped Skip — checked before the download and again
    /// after it, since Skip can land while it runs. A link that dropped
    /// overnight is brought back first (bounded; Skip ends the wait). Only a
    /// recording that started since the night began is taken, and its beats
    /// are placed on the night's clock.
    ///
    /// The Skip is this night's alone: it is cleared when the gate finishes
    /// and again when the next night starts. So is the night's arming
    /// (`overnightDeviceBackupActive`), which the gate reads and then clears.
    func fetchNightFromStrap(baseSession: HRVSession, streamingPoints: [RRPoint], isVeritySense: Bool) async -> [RRPoint]? {
        collector.polarManager.beginTransfer()
        defer { closeNightGate() }
        guard nightFetchAllowed(isVeritySense: isVeritySense) else {
            await collector.polarManager.stopDeviceRecordingIfNeeded(streamHoldsIt: false)
            return nil
        }
        collector.morningCoordination.morningStatus = .fetchingDevice(streamingBeats: streamingPoints.count)
        let recording = await downloadNight(since: baseSession.startDate, streamingCount: streamingPoints.count)
        guard collector.deviceFetchPolicy != .skipByUser else {
            debugLog("[RRCollector] Device fetch skipped by user during the download — using streaming data")
            await collector.polarManager.stopDeviceRecordingIfNeeded(streamHoldsIt: false)
            return nil
        }
        guard let recording else {
            reportDeviceFetchMiss(streamingPoints: streamingPoints)
            return nil
        }
        return recording.points(onClockOf: baseSession.startDate)
    }

    /// The night's Skip and its arming are read once, by the gate: both are
    /// reset when it finishes.
    private func closeNightGate() {
        collector.deviceFetchPolicy = .automatic
        collector.overnightDeviceBackupActive = false
    }

    /// The user's capture choice and the strap decide whether the night is
    /// downloaded at all.
    ///
    /// A night that never armed the strap holds no recording of its own
    /// there, so it is not downloaded, and the strap is not reconnected for
    /// it, unless the strap reports a recording running (the arming's answer
    /// was lost, but the strap did start). Downloading anyway would stop a
    /// recording that is not this night's and then report a strap copy of
    /// the night that does not exist. A recording the strap does hold stays
    /// on it, recoverable from the Record screen.
    private func nightFetchAllowed(isVeritySense: Bool) -> Bool {
        if collector.deviceFetchPolicy == .skipByUser {
            debugLog("[RRCollector] Device fetch skipped by user")
        } else if !collector.useDeviceBackupForOvernight {
            debugLog("[RRCollector] Skipping device fetch (capture mode: streaming only)")
        } else if isVeritySense {
            debugLog("[RRCollector] Skipping device fetch (Verity Sense uses streaming only)")
        } else if !collector.overnightDeviceBackupActive, !collector.polarManager.isRecordingOnDevice {
            debugLog("[RRCollector] Skipping device fetch (the strap was never armed for this night)", level: .warning)
        } else {
            return true
        }
        return false
    }

    /// Reconnect when the link dropped overnight (a radio reset or an
    /// out-of-range trip leaves the strap disconnected at wake), then
    /// download. The time it takes is logged against the morning's other
    /// steps.
    private func downloadNight(since start: Date, streamingCount: Int) async -> StrapRecording? {
        guard await collector.polarManager.reconnectForTransfer() else {
            debugLog("[RRCollector] Strap did not reconnect within \(Int(StrapRecordingPolicy.reconnectWindowSeconds))s — the strap's file is still on the H10")
            return nil
        }
        let started = Date()
        let recording = await collector.polarManager.fetchRecordingIfAvailable(recordedSince: start)
        debugLog("[MorningTiming] device fetch: \(Int(Date().timeIntervalSince(started) * 1000))ms (beats=\(recording?.points.count ?? -1), streamed=\(streamingCount))")
        return recording
    }

    /// The strap's copy exists precisely for the nights the live stream has a
    /// hole in it, so "we couldn't read it" must never be reported as "nothing
    /// was lost".
    ///
    /// The link can drop for hours while the H10 records the whole time; if the
    /// fetch then fails, a night scored and archived from the partial stream
    /// would never mention the strap's copy. A material gap is therefore surfaced to the user as an
    /// error telling them to recover the strap's copy before the next
    /// recording clears it; a covered session is only logged.
    ///
    /// The gap is measurable here rather than assumed: a session whose beats
    /// span materially less than its wall clock lost time, whatever the fetch
    /// said.
    private func reportDeviceFetchMiss(streamingPoints: [RRPoint]) {
        let gapMinutes = Self.streamGapMinutes(streamingPoints)
        guard gapMinutes >= Self.reportableGapMinutes else {
            debugLogExternal(
                "Couldn't read the strap's internal recording — scoring the live stream, which covers the session.",
                cause: .strap
            )
            return
        }
        debugLogExternal(
            "Couldn't read the strap's internal recording, and the live stream is missing about \(gapMinutes) minutes of this session. The H10 still holds its own copy — recover it from the Record screen before starting anything new, which clears it.",
            cause: .strap
        )
        collector.sessionState.lastError = RRCollector.CollectorError.strapStillHoldsNight(missingMinutes: gapMinutes)
    }

    /// Minutes of wall clock the streamed beats do not account for.
    ///
    /// `wallClockMs` exists on a streamed beat for exactly this ("for gap
    /// detection" — `RRPoint`): `t_ms` accumulates RR intervals, so it only
    /// advances while beats are arriving, while `wallClockMs` keeps running
    /// through a dropout. The difference between the two spans is the time the
    /// stream was not receiving. Zero for anything not streamed, which has no
    /// wall clock to compare against.
    static func streamGapMinutes(_ points: [RRPoint]) -> Int {
        guard let first = points.first, let last = points.last,
              let firstWall = first.wallClockMs, let lastWall = last.wallClockMs
        else { return 0 }
        let wallSpanMs = lastWall - firstWall
        let beatSpanMs = last.t_ms - first.t_ms
        return max(0, Int((wallSpanMs - beatSpanMs) / 60_000))
    }

    /// Below this a gap is ordinary settling at either end of the night, not a
    /// dropout worth telling the user about.
    private static let reportableGapMinutes = 10

    // MARK: - Stop Overnight Helpers

    /// Stops timers, background services, and streaming; returns base session data.
    ///
    /// Do NOT stop any keep-alive here. Morning
    /// processing (sleep poll, device fetch, window selection,
    /// analysis) must survive
    /// iOS's ~30s background-task budget; stopping a keep-alive here would
    /// let the 30s+ of processing that follows exhaust the budget and get the
    /// night SIGKILL'd.
    ///
    /// No location stop either; overnight never
    /// starts a location session (App Store 2.5.4, see
    /// `startOvernightStreaming`).
    ///
    /// `collector.streamingLifecycle.isStreamingMode` is cleared BEFORE stopping PolarManager streaming.
    /// `PolarManager.stopStreaming()` triggers Combine publishers that are
    /// delivered on the next main queue drain via `.receive(on: .main)`.
    /// If `collector.streamingLifecycle.isStreamingMode` is still true when that sink fires, it
    /// re-sets `isStreaming = true`, causing LiveDataPanel to flash on
    /// for one frame and permanently corrupt the parent ScrollView layout.
    /// The morning stop and the pause's gather both stop through here.
    func stopStreamingInfrastructure() async -> (HRVSession, [RRPoint], Int) {
        collector.stopStreamingTimer()
        AppDependencies.current.app.systemDiagnosticsManager.stopSamplingAfterRecording()
        collector.streamingLifecycle.isStreamingMode = false
        let baseSession = collector.sessionState.currentSession ?? HRVSession()
        let reconnectCount = collector.polarManager.streamingReconnectCount
        // Charge the strap's battery-usage counter with the recorded hours.
        // Captured BEFORE the publish helper zeroes the elapsed counter.
        let elapsedHoursForBattery = collector.streamingHoursForBattery
        let streamingPoints = collector.polarManager.stopStreaming()
        await collector.morning.publishGatherSavingState(streamingPoints: streamingPoints, elapsedHours: elapsedHoursForBattery)
        return (baseSession, streamingPoints, reconnectCount)
    }

    /// Backs up streaming data for crash safety. Runs off the main thread so
    /// the JSON encode + SHA256 + file write doesn't stall the UI for large
    /// sessions (overnight = ~1.5MB JSON).
    func backupStreamingData(_ points: [RRPoint], sessionId: UUID) async {
        guard !points.isEmpty else { return }
        let backup = collector.rawBackup
        let did = collector.polarManager.connectedDeviceId
        await Task.detached(priority: .utility) {
            do {
                try backup.backup(points: points, sessionId: sessionId, deviceId: did)
                debugLog("[RRCollector] Streaming data backed up (\(points.count) beats)")
            } catch {
                debugLog("[RRCollector] Failed to backup streaming data: \(error)", level: .error)
            }
        }.value
    }

    // There is deliberately no background device refinement after the morning
    // score: a beat-count skip plus a silent return-on-fetch-failure with NO
    // reconnect would score a "both" night streaming-only and discard the strap
    // file, which the H10 "both" redundancy forbids. The single finalize path
    // is the blocking morning in `stopOvernightStreaming` (a score that shifts
    // under a background refinement is worse than one accurate score).

    /// Merges, analyzes, and finalizes overnight session data.
    ///
    /// Overnight holds no audio session (App
    /// Store 2.5.4). Do not stop audio here to guard against a SIGKILL
    /// (budget reclaimed mid-morning-pipeline): that is handled by the
    /// background-task assertion in MorningProcessingService, and a
    /// kill past that budget recovers via SessionRecoveryService.
    /// Stopping audio here would also kill a concurrently
    /// recording workout's coach audio.
    private func analyzeAndFinalizeOvernight(
        finalPoints: [RRPoint], baseSession: HRVSession,
        streamingBeats: Int, deviceBeats: Int?,
        dataSource: String, reconnectCount: Int,
        prefetchedSleepData: SleepData? = nil
    ) async -> HRVSession {
        let merged = mergeParentSessionData(data: OvernightDataResult(
            points: finalPoints, baseSession: baseSession, streamingBeats: streamingBeats,
            deviceBeats: deviceBeats, dataSource: dataSource, reconnectCount: reconnectCount
        ))
        let totalBeats = merged.points.count
        await MainActor.run { collector.morningCoordination.morningStatus = .analyzing(beats: totalBeats, streamedBeats: streamingBeats, deviceBeats: deviceBeats, source: dataSource) }
        let finalSession = await collector.morning.processOvernightData(
            points: merged.points, baseSession: merged.baseSession,
            dataSource: dataSource, reconnectCount: reconnectCount,
            streamingBeats: streamingBeats, deviceBeats: deviceBeats,
            prefetchedSleepData: prefetchedSleepData
        )
        clearPersistedStateIfSaved(finalSession)
        releaseEndingOnceShown()
        await settleMorningStatus(
            complete: .complete(beats: totalBeats, streamedBeats: streamingBeats, deviceBeats: deviceBeats, source: dataSource),
            finalSession: finalSession
        )
        debugLog("[RRCollector] Final score shown (recovery: \(String(format: "%.1f", (finalSession.recoveryScore ?? 0) * 10)), source: \(dataSource))")
        return finalSession
    }

    /// The recording marker goes once the night is saved. A scored night
    /// whose pre-archive failed keeps it until Accept saves the night, so a
    /// crash on the review card still offers the night at launch.
    private func clearPersistedStateIfSaved(_ finalSession: HRVSession) {
        guard finalSession.state != .complete || collector.archive.store.exists(finalSession.id) else {
            debugLog("[RRCollector] Night \(finalSession.id.uuidString.prefix(8)) is not in the archive — keeping its recording marker until Accept", level: .warning)
            return
        }
        collector.clearPersistedRecordingState()
    }

    /// The stopped night is on the review card (or shown as failed): the
    /// stop's claim on the ending goes now rather than after the status hold
    /// and the baseline update, so a night started meanwhile can be stopped.
    /// Only the stop reaches here, and it still holds the claim, so the claim
    /// held is its own; its own release on return is then a no-op.
    private func releaseEndingOnceShown() {
        guard let claim = collector.streamingLifecycle.overnightEndingClaim else { return }
        collector.streamingLifecycle.releaseOvernightEnding(claim)
    }

    /// Show the finished status for a beat, clear it, and fold the night into
    /// the rolling baselines.
    private func settleMorningStatus(complete: RRCollector.MorningProcessingStatus, finalSession: HRVSession) async {
        await MainActor.run { collector.morningCoordination.morningStatus = complete }
        await Self.holdCompleteStatusBriefly()
        await MainActor.run { collector.morningCoordination.morningStatus = nil }
        collector.baselineTracker.update(with: finalSession, sleepSchedule: collector.settingsManager.settings.sleepSchedule)
    }

    /// Let the "complete" morning status sit on screen for a beat before it's
    /// cleared, so the user sees the finished state rather than a flash.
    private static func holdCompleteStatusBriefly() async {
        do {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        } catch {
            if !Task.isCancelled {
                debugLog("[RRCollector] Sleep interrupted before clearing morning status: \(error)")
            }
        }
    }

    /// Fallback when streaming data is insufficient: wait for device internal recording.
    /// Used only when streaming fails to capture enough beats.
    ///
    /// Goes through the same `fetchNightFromStrap` gate as the normal
    /// morning, so a strap the link dropped overnight is reconnected first,
    /// and the user's capture choice still holds: a streaming-only night, a
    /// Verity Sense or a tapped Skip fails on its stream rather than pulling
    /// a file the user did not ask for. A strap file that does exist stays on
    /// the strap, recoverable from the Record screen.
    ///
    /// A night that fails here has been shown as failed, so its recording
    /// marker goes, as it does for a night the analysis failed
    /// (`clearPersistedStateIfSaved`): the next launch must not offer it again
    /// as interrupted. Its streamed beats stay in their backup.
    private func fallbackToDeviceFetch(
        baseSession: HRVSession,
        streamingPoints: [RRPoint],
        reconnectCount: Int,
        isVeritySense: Bool
    ) async -> HRVSession? {
        debugLog("[RRCollector] Fallback: fetching device internal recording...")
        guard let devicePoints = await fetchNightFromStrap(
            baseSession: baseSession, streamingPoints: streamingPoints, isVeritySense: isVeritySense
        ), devicePoints.count >= Self.minimumUsableBeats else {
            debugLog("[RRCollector] Fallback: no usable device recording — recording failed")
            let failed = await failSession(from: baseSession)
            collector.clearPersistedRecordingState()
            return failed
        }
        // Device data is primary on this path (it holds a usable night); the
        // selector only decides whether streaming can fill gaps in it.
        let (points, source, _) = selectBestDataSource(
            streamingPoints: streamingPoints, devicePoints: devicePoints, baseSession: baseSession
        )
        return await finalizeFallbackSession(data: OvernightDataResult(
            points: points, baseSession: baseSession,
            streamingBeats: streamingPoints.count, deviceBeats: devicePoints.count,
            dataSource: source, reconnectCount: reconnectCount
        ), reconnectCount: reconnectCount)
    }

    /// Merge into the parent session (resumed nights), analyse, archive, and walk
    /// `collector.morningCoordination.morningStatus` through analyzing → complete → nil.
    private func finalizeFallbackSession(data: OvernightDataResult, reconnectCount: Int) async -> HRVSession? {
        let merged = mergeParentSessionData(data: data)
        let totalBeats = merged.points.count
        let dataSource = data.dataSource
        await MainActor.run {
            collector.morningCoordination.morningStatus = .analyzing(beats: totalBeats, streamedBeats: data.streamingBeats, deviceBeats: data.deviceBeats, source: dataSource)
        }
        let finalSession = await collector.morning.processOvernightData(
            points: merged.points, baseSession: merged.baseSession,
            dataSource: dataSource, reconnectCount: reconnectCount,
            streamingBeats: data.streamingBeats, deviceBeats: data.deviceBeats
        )
        clearPersistedStateIfSaved(finalSession)
        await MainActor.run { collector.sessionState.currentSession = finalSession }
        releaseEndingOnceShown()
        await settleMorningStatus(
            complete: .complete(beats: totalBeats, streamedBeats: data.streamingBeats, deviceBeats: data.deviceBeats, source: dataSource),
            finalSession: finalSession
        )
        return finalSession
    }
}

extension DeviceProvenance {
    /// Provenance for a session streamed live from the connected Polar strap —
    /// the overnight start and the pause/resume restart stamp the same thing.
    @MainActor
    static func streaming(from polarManager: PolarManager) -> DeviceProvenance {
        DeviceProvenance.current(
            deviceId: polarManager.connectedDeviceId ?? "unknown",
            deviceModel: polarManager.connectedDeviceType?.displayName ?? "Polar device",
            firmwareVersion: nil,
            recordingMode: .streaming
        )
    }
}

// MARK: - File-scope helpers
//
// Each names no member of `RRCollector` and calls nothing on it, so none needs
// to be inside the type.

@MainActor
/// Selects the best data source from streaming and device points. A device
/// recording below the selector's bar is not a source; one at or above it
/// always yields a selection.
private func selectBestDataSource(
    streamingPoints: [RRPoint],
    devicePoints: [RRPoint]?,
    baseSession: HRVSession
) -> ([RRPoint], String, Int?) {
    guard let dp = devicePoints, dp.count >= DataSourceSelector.minimumValidBeats,
          let selection = DataSourceSelector.selectBestSource(
              streamingPoints: streamingPoints,
              internalPoints: dp,
              sessionId: baseSession.id,
              sessionStart: baseSession.startDate
          ) else {
        return (streamingPoints, "streaming", nil)
    }
    debugLog("[RRCollector] Final data source: \(selection.normalizedSource), \(selection.points.count) beats (streaming: \(streamingPoints.count), device: \(dp.count))")
    return (selection.points, selection.normalizedSource, dp.count)
}
