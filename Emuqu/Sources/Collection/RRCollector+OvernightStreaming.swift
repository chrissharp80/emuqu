import Foundation
import HealthKit
import UIKit

// MARK: - Overnight Streaming Mode (bluetooth-central driven)
//
// Lives off `RRCollector` for the same reason as the
// `SessionRecoveryCoordinator` split: ~850 lines reading 39 collector members.
// The coupling is real — this IS the recording pipeline at night — but those
// reads are now `collector.` and countable, instead of looking like the
// type's own state.

extension OvernightStreamingCoordinator {
    /// Result of gathering overnight data — the chosen RR points and metadata
    struct OvernightDataResult {
        let points: [RRPoint]
        let baseSession: HRVSession
        let streamingBeats: Int
        let deviceBeats: Int?
        let dataSource: String
        let reconnectCount: Int
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
    /// Extracted to eliminate 4 copies of the same 10-line block.
    func failSession(from baseSession: HRVSession) async -> HRVSession {
        let failed = HRVSession(
            id: baseSession.id, startDate: baseSession.startDate, endDate: Date(),
            state: .failed, sessionType: baseSession.sessionType,
            rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        await MainActor.run {
            collector.currentSession = failed
            collector.lastError = RRCollector.CollectorError.insufficientData
            collector.morningStatus = nil
        }
        // Overnight holds no audio session (App Store 2.5.4); nothing to
        // release on the failure path.
        return failed
    }

    /// Start overnight streaming. Background execution rides on the
    /// `bluetooth-central` mode (incoming Polar packets wake the app) —
    /// see the note below; no keep-alive sessions are held.
    ///
    /// Neither overnight keep-alive is used (App Store 2.5.4, the
    /// prior-rejection area). Background location was a
    /// pure keep-alive with no location feature; silent background
    /// audio all night is the textbook 2.5.4 abuse pattern reviewers
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
    /// Workout audio remains, gated on audible coach content — see
    /// WorkoutRecorder.deferKeepAliveStart.
    ///
    /// The diagnostics sampler is armed here. If iOS kills the
    /// app during overnight streaming we need the memory/thermal trace to
    /// diagnose why. See SystemDiagnosticsManager doc.
    ///
    /// `useDeviceInternalBackup` configures whether overnight streaming
    /// includes device-internal backup. Verity Sense can't record internally
    /// while streaming, so it always streams only.
    ///
    /// - Parameter sessionType: .overnight or .nap
    @MainActor
    func startOvernightStreaming(sessionType: SessionType = .overnight, useDeviceInternalBackup: Bool = true) throws {
        guard collector.polarManager.connectionState == .connected else { throw RRCollector.CollectorError.notConnected }
        guard !collector.polarManager.isStreaming else { throw RRCollector.CollectorError.alreadyRecording }
        AppDependencies.current.app.systemDiagnosticsManager.startSamplingDuringRecording()
        let session = HRVSession(sessionType: sessionType, deviceProvenance: .streaming(from: collector.polarManager))
        collector.useDeviceBackupForOvernight = useDeviceInternalBackup
        try collector.polarManager.startStreaming()  // primary data source
        if useDeviceInternalBackup, collector.polarManager.connectedDeviceType != .veritySense {
            launchDeviceRecordingLoop()  // H10-only internal-recording backup
        }
        resetOvernightStreamingState(session: session)
        startOvernightHealthKitObservers()
        collector.persistRecordingState(sessionId: session.id, startTime: Date(), sessionType: sessionType)
        logOvernightStreamingStart(session: session, sessionType: sessionType)
        startOvernightStreamingTimer()
    }

    /// Arm the H10's internal recording for the night.
    ///
    /// The H10 enumerates its recording feature lazily and unpredictably — a
    /// minute after connecting in one field log, nearly four in another — and
    /// every fixed ceiling tried has turned out too short. So there is no
    /// ceiling: the arming waits on the strap's readiness for as long as the
    /// night lasts, across drops and reconnects, and arms the moment the SDK
    /// accepts the start. Starting a few minutes late costs nothing; streaming
    /// covers the opening minutes and the file still protects the rest of the
    /// night. It is off the critical path and ends the instant the night does.
    func launchDeviceRecordingLoop() {
        Task { [weak collector] in
            guard let collector else { return }
            let started = await collector.overnightStreaming.awaitDeviceRecordingStart()
            if !started {
                // PRIMARY, not backup: `docs/ARCHITECTURE.md` puts H10 internal
                // recording first ("more stable, survives disconnects") and BLE
                // streaming second. A night that ran streaming-only ran on the
                // fallback, with no protection against a disconnect.
                debugLog("[RRCollector] ❌ H10 internal recording — the PRIMARY source — never armed before the night ended. This night ran on BLE streaming alone, with no protection against a disconnect.", level: .error)
            }
        }
    }

    /// Waits for the recording feature on each link and arms once. A start the
    /// strap rejects for a reason other than "not ready yet" waits for the
    /// next change in the strap's state — a reconnect, a readiness report —
    /// before trying again, rather than retrying into the same refusal.
    private func awaitDeviceRecordingStart() async -> Bool {
        while collector.isOvernightStreaming {
            do {
                try await armWhenStrapIsReady()
                return true
            } catch {
                await waitAfterArmingFailed(error)
            }
        }
        return false
    }

    /// Wait for the next change on the strap link before trying again — unless
    /// the session has already ended.
    private func waitAfterArmingFailed(_ error: Error) async {
        guard collector.isOvernightStreaming else { return }
        debugLog("[RRCollector] H10 internal recording not armed yet: \(error) — waiting for the strap")
        _ = await collector.polarManager.linkRuntime.signal.wait(timeout: nil)
    }

    private func armWhenStrapIsReady() async throws {
        try await collector.polarManager.link.whenFeatureUsable(
            .h10Recording, until: nil, while: { [collector] in collector.isOvernightStreaming },
            perform: attemptDeviceRecordingStart
        )
    }

    /// One attempt at arming the H10's internal recording. Any stale recording is
    /// stopped first so the fresh one holds THIS night only (else `startRecording`
    /// throws `alreadyRecording`), and rescued rather than dropped.
    private func attemptDeviceRecordingStart() async throws {
        try await collector.polarManager.recording.startFreshRecording()
        let deviceName = collector.polarManager.connectedDeviceType?.displayName ?? "device"
        debugLog("[RRCollector] ✅ \(deviceName) internal recording started")
        // The strap is now capturing the full night to its own
        // flash memory — mark it so a mid-night BLE loss can't
        // trigger the destructive pause-and-fetch (see
        // RRCollector+Bindings reconnectExhausted handler).
        collector.overnightDeviceBackupActive = true
    }

    /// `collector.overnightDeviceBackupActive` is cleared here; the async backup-start Task
    /// flips it true once the H10's internal recording actually begins. This runs
    /// synchronously before that Task's `startRecording` completes, so it can't
    /// clobber it.
    @MainActor
    private func resetOvernightStreamingState(session: HRVSession) {
        collector.currentSession = session
        collector.collectedPoints = []
        collector.sessionStartTime = Date()
        collector.isStreamingMode = true
        collector.isOvernightStreaming = true
        collector.recordingPhase = .overnightStreaming
        collector.streamingTargetSeconds = Int.max
        collector.streamingElapsedSeconds = 0
        collector.isCollecting = true
        collector.pausedBeatCount = 0
        collector.lastSeenReconnectCount = 0
        collector.isDeviceFetchInProgress = false
        collector.overnightDeviceBackupActive = false
    }

    /// Start observing HealthKit for sleep data so we catch Apple Watch sync.
    /// Same for vitals — the Watch syncs respiratory rate, SpO2, wrist temp,
    /// and resting HR well after sleep ends. Without this observer the
    /// SleepDetail card stays empty for "most nights" until the next
    /// launch happens to coincide with the Watch having synced.
    private func startOvernightHealthKitObservers() {
        collector.healthKit.startObservingSleepData()
        collector.healthKit.startObservingVitalsData()
    }

    private func logOvernightStreamingStart(session: HRVSession, sessionType: SessionType) {
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
    @MainActor
    private func overnightStreamingTick() {
        guard collector.isOvernightStreaming, collector.streamingTimer != nil else { return }
        collector.streamingElapsedSeconds += 1
        if collector.streamingElapsedSeconds % 30 == 0 {
            collector.polarManager.checkBatteryStaleness()
        }
        let currentReconnectCount = collector.polarManager.streamingReconnectCount
        let reconnectionOccurred = currentReconnectCount > collector.lastSeenReconnectCount
        if reconnectionOccurred {
            debugLog("[RRCollector] Streaming reconnection detected (\(collector.lastSeenReconnectCount) → \(currentReconnectCount)) - forcing backup")
            collector.lastSeenReconnectCount = currentReconnectCount
        }
        guard let session = collector.currentSession else { return }
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

    /// Minimum beats for one source to stand on its own as a usable night.
    private static let minimumUsableBeats = 120

    /// Whether the night has enough data to finalize.
    ///
    /// A resumed CHILD session is held to a lower bar deliberately: its beats
    /// are merged into the parent night rather than standing alone, so "some
    /// data" is enough. A standalone night needs a real sample from at least
    /// one source.
    ///
    /// Kept out of `gatherOvernightData` for its body-length budget; this is
    /// the only self-contained decision in it.
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
    /// This is the blocking morning, per Chris. A
    /// "streaming-first / instant score + background refinement" design was
    /// rejected (the quick streaming score then shifting under a background
    /// refinement was worse than one accurate score).
    ///
    /// It blocks on the strap download for one accurate score and polls
    /// HealthKit sleep IN PARALLEL so the 1-2 min download time isn't wasted.
    /// An H10 the link dropped overnight is reconnected first, within a
    /// bounded window and not at all when it is still connected (see
    /// `fetchDeviceAndSleepConcurrently`). Insufficient-streaming nights take
    /// the blocking `fallbackToDeviceFetch`.
    func stopOvernightStreaming() async -> HRVSession? {
        guard collector.isOvernightStreaming else { return nil }
        let (baseSession, streamingPoints, reconnectCount) = await stopStreamingInfrastructure()
        await backupStreamingData(streamingPoints, sessionId: baseSession.id)
        let isVeritySense = isVeritySenseDevice(baseSession)
        let policyAllowsFetch = resolveDeviceFetchPolicy(isVeritySense: isVeritySense)
        // If streaming data is insufficient, fall back to device-only path
        guard Self.hasValidStreaming(streamingPoints, baseSession: baseSession) else {
            debugLog("[RRCollector] Insufficient streaming data (\(streamingPoints.count) beats) — attempting device fetch")
            return await fallbackToDeviceFetch(
                baseSession: baseSession, streamingPoints: streamingPoints,
                reconnectCount: reconnectCount, fetchBarred: isVeritySense || !policyAllowsFetch
            )
        }
        let finalSession = await downloadMergeAndScoreNight(
            baseSession: baseSession, streamingPoints: streamingPoints,
            reconnectCount: reconnectCount, isVeritySense: isVeritySense,
            shouldFetchDevice: policyAllowsFetch
        )
        disconnectVeritySenseAfterNight(isVeritySense: isVeritySense)
        return finalSession
    }

    /// A resumed child only needs *some* new beats — its parent already holds the
    /// bulk of the night. A fresh night needs enough to analyse on its own.
    private static func hasValidStreaming(_ streamingPoints: [RRPoint], baseSession: HRVSession) -> Bool {
        let isResumedChild = baseSession.linkedSessionIds?.isEmpty == false
        return streamingPoints.count >= minimumUsableBeats || (isResumedChild && !streamingPoints.isEmpty)
    }

    /// A Verity Sense night is scored from the stream alone (the morning never
    /// downloads from it), so nothing is left to pull and the sensor is
    /// released once the night is scored.
    private func disconnectVeritySenseAfterNight(isVeritySense: Bool) {
        guard isVeritySense else { return }
        debugLog("[RRCollector] Auto-disconnecting Verity Sense after overnight session")
        collector.polarManager.disconnect()
    }

    /// The good-streaming morning: pull the strap file (and sleep) concurrently,
    /// pick the winning source, then analyse and archive the night.
    private func downloadMergeAndScoreNight(
        baseSession: HRVSession,
        streamingPoints: [RRPoint],
        reconnectCount: Int,
        isVeritySense: Bool,
        shouldFetchDevice: Bool
    ) async -> HRVSession {
        let fetched = await fetchDeviceAndSleepConcurrently(
            baseSession: baseSession, streamingPoints: streamingPoints,
            isVeritySense: isVeritySense, shouldFetchDevice: shouldFetchDevice
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
    /// night — no density-based skip. This is Chris's core design: the strap
    /// file is REDUNDANCY and the source of truth, so a dropped connection can
    /// never lose a night. (A "skip the download when streaming
    /// looked ≥95% complete" optimization traded that guarantee for a faster
    /// morning; rejected per Chris — never weaken the redundancy.)
    /// `shouldFetchDevice` is already false for Verity Sense / backup-disabled,
    /// so this only ever fetches on a real H10 backup night. The fetch is
    /// hard-timeout-guarded (45s stop + 120s download), so a genuinely
    /// unresponsive strap still falls back to the streamed night in seconds.
    ///
    /// The sleep poll is a quick fast-path for sleep that ALREADY synced by wake
    /// (short now — the HKObserverQuery auto-rescores when Apple Watch sleep
    /// lands later), and runs concurrently with the download.
    ///
    /// If BLE dropped overnight (transient radio reset / out-of-range trip),
    /// the strap is disconnected by wake and `fetchExerciseDataQuick` would
    /// bail at its connected/recording guards — losing the full-night file the
    /// H10 still holds (a whole-night loss in the field). Reconnect first (bounded,
    /// H10 only, no-op when already connected+recording so normal mornings add
    /// no latency).
    private func fetchDeviceAndSleepConcurrently(
        baseSession: HRVSession,
        streamingPoints: [RRPoint],
        isVeritySense: Bool,
        shouldFetchDevice: Bool
    ) async -> (devicePoints: [RRPoint]?, sleep: SleepData?) {
        async let earlySleepData = pollSleepDuringDeviceFetch(sessionStart: baseSession.startDate)
        if shouldFetchDevice {
            // Show the strap step while reconnecting, not "Securing data".
            await MainActor.run { collector.morningStatus = .fetchingDevice(streamingBeats: streamingPoints.count) }
            await reconnectStrapForFetchIfNeeded(isVeritySense: isVeritySense)
        }
        let devicePoints = await fetchDeviceDataIfNeeded(
            shouldFetch: shouldFetchDevice,
            streamingCount: streamingPoints.count,
            sessionStart: baseSession.startDate
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

    /// Reconnect to the strap before the morning fetch IF the BLE link dropped
    /// overnight. When a transient BLE power-off (iOS radio reset) or an
    /// out-of-range trip exhausts reconnection mid-night, the connection is gone
    /// and `isRecordingOnDevice` is stale-false by wake — so
    /// `fetchExerciseDataQuick` bails at its first two guards and the night would
    /// score streaming-only, discarding the full-night file the H10 kept in flash.
    /// Bounded to `StrapRecordingPolicy.morningReconnectWindowSeconds` (a
    /// minute) and H10-only; a no-op when the strap is already
    /// connected+recording (the normal morning), so it adds zero latency there.
    /// The fetch itself is hard-timeout-guarded, so a genuinely dead/stale strap
    /// still falls back to the streamed night in seconds. Mirrors the reconnect
    /// step in `gatherOvernightData` (the pause path).
    func reconnectStrapForFetchIfNeeded(isVeritySense: Bool) async {
        guard !isVeritySense else { return }
        guard !(collector.polarManager.connectionState == .connected && collector.polarManager.isRecordingOnDevice) else { return }
        if collector.polarManager.connectionState != .connected {
            debugLog("[RRCollector] Strap not connected at wake — reconnecting before device fetch…")
            collector.polarManager.connectToLastDevice()
        }
        // Up to a minute: at wake the phone has usually been locked all night
        // and the strap has to be found again.
        let connected = await collector.polarManager.link.awaitConnection(
            until: Date().addingTimeInterval(StrapRecordingPolicy.morningReconnectWindowSeconds)
        )
        debugLog("[RRCollector] Reconnect before fetch: connected=\(connected) recordingOnDevice=\(collector.polarManager.isRecordingOnDevice)")
        guard !connected else { return }
        debugLogExternal("Strap did not reconnect within \(Int(StrapRecordingPolicy.morningReconnectWindowSeconds))s of wake — scoring from the live stream; the strap's file is still on the H10.", cause: .strap)
    }

    /// Fetch the H10 internal recording over the EXISTING connection (no forced
    /// reconnect). Part of the blocking morning.
    private func fetchDeviceDataIfNeeded(shouldFetch: Bool, streamingCount: Int, sessionStart: Date) async -> [RRPoint]? {
        guard shouldFetch else { return nil }

        await MainActor.run {
            collector.morningStatus = .fetchingDevice(streamingBeats: streamingCount)
        }
        debugLog("[RRCollector] Fetching device internal recording inline...")
        let devicePoints = await collector.polarManager.fetchExerciseDataQuick(recordedSince: sessionStart)

        if let pts = devicePoints {
            debugLog("[RRCollector] Device internal recording fetched: \(pts.count) beats")
        } else {
            reportDeviceFetchMiss()
        }

        return devicePoints
    }

    /// The strap's copy exists precisely for the nights the live stream has a
    /// hole in it, so "we couldn't read it" must never be reported as "nothing
    /// was lost".
    ///
    /// In a field log the link dropped at 00:56 and did not come back until
    /// 04:16; the live stream held 2 h 46 m of about six hours, the H10 had
    /// been recording the whole time, the fetch failed, and the night was
    /// scored and archived from the partial stream with the strap's copy never
    /// mentioned. A material gap is therefore surfaced to the user as an
    /// error telling them to recover the strap's copy before the next
    /// recording clears it; a covered session is only logged.
    ///
    /// The gap is measurable here rather than assumed: a session whose beats
    /// span materially less than its wall clock lost time, whatever the fetch
    /// said.
    private func reportDeviceFetchMiss() {
        let gapMinutes = streamGapMinutes()
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
        collector.lastError = RRCollector.CollectorError.strapStillHoldsNight(missingMinutes: gapMinutes)
    }

    /// Minutes of wall clock the streamed beats do not account for.
    ///
    /// `wallClockMs` exists on a streamed beat for exactly this ("for gap
    /// detection" — `RRPoint`): `t_ms` accumulates RR intervals, so it only
    /// advances while beats are arriving, while `wallClockMs` keeps running
    /// through a dropout. The difference between the two spans is the time the
    /// stream was not receiving. Zero for anything not streamed, which has no
    /// wall clock to compare against.
    private func streamGapMinutes() -> Int {
        let points = collector.polarManager._streamedRRPoints
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
    /// iOS's ~30s background-task budget; overnights
    /// were getting SIGKILL'd when a keep-alive stopped at this point
    /// and the subsequent 30s+ of processing exhausted the budget.
    ///
    /// No location stop either; overnight never
    /// starts a location session (App Store 2.5.4, see
    /// `startOvernightStreaming`).
    ///
    /// `collector.isStreamingMode` is cleared BEFORE stopping PolarManager streaming.
    /// `PolarManager.stopStreaming()` triggers Combine publishers that are
    /// delivered on the next main queue drain via `.receive(on: .main)`.
    /// If `collector.isStreamingMode` is still true when that sink fires, it
    /// re-sets `isStreaming = true`, causing LiveDataPanel to flash on
    /// for one frame and permanently corrupt the parent ScrollView layout.
    private func stopStreamingInfrastructure() async -> (HRVSession, [RRPoint], Int) {
        await MainActor.run {
            collector.isDeviceFetchInProgress = false
        }
        collector.stopStreamingTimer()
        AppDependencies.current.app.systemDiagnosticsManager.stopSamplingAfterRecording()
        collector.isStreamingMode = false
        let baseSession = collector.currentSession ?? HRVSession()
        let reconnectCount = collector.polarManager.streamingReconnectCount
        // Charge the strap's battery-usage counter with the recorded hours.
        // Captured BEFORE the publish helper zeroes the elapsed counter.
        let elapsedHoursForBattery = Double(collector.streamingElapsedSeconds) / 3600.0
        let streamingPoints = collector.polarManager.stopStreaming()
        await collector.publishGatherSavingState(streamingPoints: streamingPoints, elapsedHours: elapsedHoursForBattery)
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

    /// Determines whether device fetch should happen and resets the policy.
    private func resolveDeviceFetchPolicy(isVeritySense: Bool) -> Bool {
        let skipByUser = collector.deviceFetchPolicy == .skipByUser
        let backupEnabled = collector.useDeviceBackupForOvernight
        let shouldFetch = backupEnabled && !isVeritySense && !skipByUser
        collector.deviceFetchPolicy = .automatic
        return shouldFetch
    }

    // There is deliberately no `scheduleBackgroundDeviceRefinement`. It
    // embodied the exact
    // pattern the H10 "both" redundancy forbids: a beat-count skip
    // (`guard mergedPoints.count > streamingPoints.count`) plus a silent
    // return-on-fetch-failure with NO reconnect, which would score a "both"
    // night streaming-only and discard the strap file. The single finalize
    // path is the blocking morning in `stopOvernightStreaming`
    // (streaming-first + background refinement was tried and
    // rejected by Chris — a shifting score was worse than one accurate score).
    // Do not revive.

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
        await MainActor.run { collector.morningStatus = .analyzing(beats: totalBeats, streamedBeats: streamingBeats, deviceBeats: deviceBeats, source: dataSource) }
        let finalSession = await collector.processOvernightData(
            points: merged.points, baseSession: merged.baseSession,
            dataSource: dataSource, reconnectCount: reconnectCount,
            streamingBeats: streamingBeats, deviceBeats: deviceBeats,
            prefetchedSleepData: prefetchedSleepData
        )
        collector.clearPersistedRecordingState()
        await settleMorningStatus(
            complete: .complete(beats: totalBeats, streamedBeats: streamingBeats, deviceBeats: deviceBeats, source: dataSource),
            finalSession: finalSession
        )
        debugLog("[RRCollector] Final score shown (recovery: \(String(format: "%.1f", (finalSession.recoveryScore ?? 0) * 10)), source: \(dataSource))")
        return finalSession
    }

    /// Show the finished status for a beat, clear it, and fold the night into
    /// the rolling baselines.
    private func settleMorningStatus(complete: RRCollector.MorningProcessingStatus, finalSession: HRVSession) async {
        await MainActor.run { collector.morningStatus = complete }
        await Self.holdCompleteStatusBriefly()
        await MainActor.run { collector.morningStatus = nil }
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
    /// RECONNECT BEFORE FETCH. When a
    /// BLE drop both shortened streaming (which routes the night here) AND
    /// left the strap disconnected by wake, `fetchExerciseDataQuick` bailed at
    /// its connected/recording guards → failSession → the full-night file the
    /// H10 still held in flash was LOST. The normal-wake and pause paths
    /// already reconnect via this exact helper; this sibling must too.
    /// Guaranteeing the reconnect here is
    /// required by the H10 "both" redundancy: the strap file is the source of
    /// truth and a dropped BLE link must never lose a night. Bounded + H10
    /// only; the fetch itself is hard-timeout-guarded, so a genuinely
    /// dead/stale strap still falls through to `failSession` in seconds.
    ///
    /// The user's capture choice still holds here: streaming-only capture
    /// (no strap file was armed) or a tapped "skip" passes `fetchBarred`, and
    /// the night fails on its stream rather than reconnecting and pulling a
    /// file the user did not ask for. A strap file that does exist stays on
    /// the strap, recoverable from the Record screen.
    private func fallbackToDeviceFetch(
        baseSession: HRVSession,
        streamingPoints: [RRPoint],
        reconnectCount: Int,
        fetchBarred: Bool
    ) async -> HRVSession? {
        guard !fetchBarred else {
            debugLog("[RRCollector] Insufficient streaming and no device fetch (Verity Sense, streaming-only capture or skipped by the user) — recording failed")
            return await failSession(from: baseSession)
        }
        await MainActor.run { collector.morningStatus = .fetchingDevice(streamingBeats: streamingPoints.count) }
        debugLog("[RRCollector] Fallback: fetching device internal recording...")
        await reconnectStrapForFetchIfNeeded(isVeritySense: false)
        let internalPoints = await fetchDeviceDataIfNeeded(shouldFetch: true, streamingCount: streamingPoints.count, sessionStart: baseSession.startDate)
        guard let devicePoints = internalPoints, devicePoints.count >= 120 else {
            debugLog("[RRCollector] Fallback: device fetch also insufficient — recording failed")
            return await failSession(from: baseSession)
        }
        let chosen = Self.deviceFirstSelection(
            streamingPoints: streamingPoints, devicePoints: devicePoints, baseSession: baseSession
        )
        return await finalizeFallbackSession(data: OvernightDataResult(
            points: chosen.points, baseSession: baseSession,
            streamingBeats: streamingPoints.count, deviceBeats: devicePoints.count,
            dataSource: chosen.source, reconnectCount: reconnectCount
        ), reconnectCount: reconnectCount)
    }

    /// Device data is primary on this path; the selector only decides whether
    /// streaming can fill gaps in it.
    private static func deviceFirstSelection(
        streamingPoints: [RRPoint],
        devicePoints: [RRPoint],
        baseSession: HRVSession
    ) -> (points: [RRPoint], source: String) {
        guard let selection = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: devicePoints,
            sessionId: baseSession.id,
            sessionStart: baseSession.startDate
        ) else {
            return (devicePoints, "internal")
        }
        return (selection.points, selection.normalizedSource)
    }

    /// Merge into the parent session (resumed nights), analyse, archive, and walk
    /// `collector.morningStatus` through analyzing → complete → nil.
    private func finalizeFallbackSession(data: OvernightDataResult, reconnectCount: Int) async -> HRVSession? {
        let merged = mergeParentSessionData(data: data)
        let totalBeats = merged.points.count
        let dataSource = data.dataSource
        await MainActor.run {
            collector.morningStatus = .analyzing(beats: totalBeats, streamedBeats: data.streamingBeats, deviceBeats: data.deviceBeats, source: dataSource)
        }
        let finalSession = await collector.processOvernightData(
            points: merged.points, baseSession: merged.baseSession,
            dataSource: dataSource, reconnectCount: reconnectCount,
            streamingBeats: data.streamingBeats, deviceBeats: data.deviceBeats
        )
        collector.clearPersistedRecordingState()
        await MainActor.run { collector.currentSession = finalSession }
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
// Kept out of RRCollector. Each names no member of the
// type and calls nothing that stayed behind, so none needed to be inside
// it. `private` at file scope is fileprivate, so every call site in this
// file resolves exactly as before.

@MainActor
/// Selects the best data source from streaming and device points.
private func selectBestDataSource(
    streamingPoints: [RRPoint],
    devicePoints: [RRPoint]?,
    baseSession: HRVSession
) -> ([RRPoint], String, Int?) {
    let hasValidDevice = devicePoints?.count ?? 0 >= 120
    guard hasValidDevice, let dp = devicePoints else {
        return (streamingPoints, "streaming", nil)
    }

    if let selection = DataSourceSelector.selectBestSource(
        streamingPoints: streamingPoints,
        internalPoints: dp,
        sessionId: baseSession.id,
        sessionStart: baseSession.startDate
    ) {
        debugLog("[RRCollector] Final data source: \(selection.normalizedSource), \(selection.points.count) beats (streaming: \(streamingPoints.count), device: \(dp.count))")
        return (selection.points, selection.normalizedSource, dp.count)
    }

    debugLog("[RRCollector] Final data source: streaming, \(streamingPoints.count) beats (streaming: \(streamingPoints.count), device: \(dp.count))")
    return (streamingPoints, "streaming", dp.count)
}
