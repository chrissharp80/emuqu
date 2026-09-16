import CoreBluetooth
import Foundation

#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

// The quick-fetch helpers: the retry and reconnect path used when a workout
// stop needs the device's internal recording in a hurry.

extension StrapRecordingCoordinator {
    // MARK: - fetchExerciseDataQuick Helpers

    /// Verity Sense quick fetch: single attempt with safety timeout
    func fetchQuickVeritySense() async -> [RRPoint]? {
        let timeoutSeconds: UInt64 = 90
        debugLog("[PolarManager] Quick fetch: Verity Sense, timeout \(timeoutSeconds)s")
        do {
            let points = try await fetchOfflinePpiRecording(timeoutSeconds: timeoutSeconds)
            debugLog("[PolarManager] Quick fetch (Verity) succeeded: \(points.count) points")
            return points
        } catch {
            debugLog("[PolarManager] Quick fetch (Verity) failed: \(error)")
            await MainActor.run { manager.recordingState = .idle }
            return nil
        }
    }

    /// The offline-PPI download raced against a hard wall clock, so a stale BLE
    /// link can't hang the morning.
    private func fetchOfflinePpiRecording(timeoutSeconds: UInt64) async throws -> [RRPoint] {
        try await withThrowingTaskGroup(of: [RRPoint].self) { group in
            group.addTask { try await self.fetchOfflinePpiRecording() }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw PolarManager.PolarError.fetchFailed("Timeout after \(timeoutSeconds) seconds")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw PolarManager.PolarError.fetchFailed("task group produced no result")
            }
            return result
        }
    }

    /// H10 Phase 1: check recording status and stop if ongoing.
    /// - Parameter waitForFinalize: when true, after sending the stop this polls
    ///   the device until the finalized file is listed (needed ONLY before a
    ///   download, so the fetch reads a ready file). When false, it returns as
    ///   soon as the stop is sent — the inline "just stop the strap" case, which
    ///   has no download to serve. Passing true unnecessarily is the
    ///   "workout took ~2 minutes to save" bug: a 100%-streaming-density workout
    ///   never fetches the file, yet the inline stop blocks ~61s waiting for an
    ///   overnight-sized file to finalize that nothing will ever read.
    func stopH10RecordingQuick(api: any StrapRadio, deviceId: String, waitForFinalize: Bool) async throws {
        let status = try await h10RecordingStatus(api: api, deviceId: deviceId)
        guard status.ongoing else { return }
        try await api.stopRecording(deviceId)
        // Only wait for the file to finalize when a download will follow. The
        // inline "stop the strap so it can't keep recording" caller has nothing
        // to read, so it returns immediately here (see `waitForFinalize` doc).
        guard waitForFinalize else { return }
        debugLog("[PolarManager] Quick fetch: H10 recording stopped — waiting for finalize")
        await awaitH10FileFinalize(api: api, deviceId: deviceId)
    }

    /// Wait for the H10 to actually FINALIZE the file before
    /// returning (so the download that follows reads a ready file).
    ///
    /// A 300ms blind pause is the morning's "3-4 minutes" bug. An
    /// 8-hour file isn't written to flash in 300ms; firing `fetchExercise`
    /// that early hits a not-ready file, the SDK call hangs to its internal
    /// timeout (~20-30s) before erroring, and `fetchH10WithRetries` then
    /// burns 6 quick attempts + 2 disconnect/reconnect cycles — minutes.
    /// A manual "recover" of the SAME full night is <10s precisely because
    /// the file is already finalized: the very first read succeeds.
    ///
    /// Polls the stored-exercise list (a fast BLE op) until the finalized
    /// entry appears, then returns. Bounded so a genuinely-missing file still
    /// falls through to the retry path rather than hanging forever.
    private func awaitH10FileFinalize(api: any StrapRadio, deviceId: String) async {
        let tFinalize = Date()
        for poll in 1 ... 30 { // up to ~15s (plenty for a full night to finalize)
            if manager.fetchCancelled { return }
            let entries = (try? await listStoredExercises(api: api, deviceId: deviceId)) ?? []
            if !entries.isEmpty {
                debugLog("[MorningTiming] H10 finalize ready after \(Int(Date().timeIntervalSince(tFinalize) * 1000))ms (\(poll) polls)")
                return
            }
            await sleepQuietly(500_000_000, context: "awaitH10FileFinalize")
        }
        debugLog("[MorningTiming] H10 finalize: no listed entry after ~15s — proceeding to retry path")
    }

    /// H10 Phase 2: aggressive quick retries, then disconnect/reconnect fallback.
    ///
    /// On-demand downloads complete in seconds because the file is already
    /// finalized. After stopping a recording, the device may need a moment —
    /// quick retries catch the file as soon as it's ready without wasting time
    /// on BLE cycling.
    func fetchH10WithRetries(api: any StrapRadio, deviceId: String, recordedSince: Date?) async -> [RRPoint]? {
        let quickRetries = 6
        let totalAttempts = quickRetries + 2 // + reconnect retries
        var lastError: Error?
        for attempt in 1 ... totalAttempts {
            if manager.fetchCancelled { return await cancelQuickFetch() }
            let outcome = await attemptQuickFetch(
                api: api, deviceId: deviceId, recordedSince: recordedSince, attempt: attempt,
                quickRetries: quickRetries, totalAttempts: totalAttempts
            )
            switch outcome {
            case .points(let points): return points
            case .retry(let error): lastError = error
            case .giveUp(let error): lastError = error
            }
            if case .giveUp = outcome { break }
        }
        return await failQuickFetch(totalAttempts: totalAttempts, lastError: lastError)
    }

    private enum QuickFetchOutcome {
        case points([RRPoint])
        case retry(Error)
        case giveUp(Error)
    }

    /// One download attempt plus its back-off. `.giveUp` when the fetch was
    /// cancelled or the reconnect dance itself failed.
    private func attemptQuickFetch(
        api: any StrapRadio,
        deviceId: String,
        recordedSince: Date?,
        attempt: Int,
        quickRetries: Int,
        totalAttempts: Int
    ) async -> QuickFetchOutcome {
        do {
            return .points(try await completeQuickFetchAttempt(
                api: api, deviceId: deviceId, recordedSince: recordedSince, attempt: attempt, totalAttempts: totalAttempts
            ))
        } catch {
            debugLog("[PolarManager] Quick fetch attempt \(attempt)/\(totalAttempts) failed: \(error)")
            guard !manager.fetchCancelled, await backOffBeforeNextQuickFetch(
                api: api, deviceId: deviceId, attempt: attempt,
                quickRetries: quickRetries, totalAttempts: totalAttempts
            ) else { return .giveUp(error) }
            return .retry(error)
        }
    }

    private func failQuickFetch(totalAttempts: Int, lastError: Error?) async -> [RRPoint]? {
        debugLog("[PolarManager] Quick fetch failed after \(totalAttempts) attempts: \(lastError?.localizedDescription ?? "unknown")")
        await MainActor.run { manager.recordingState = .idle }
        return nil
    }

    private func cancelQuickFetch() async -> [RRPoint]? {
        debugLog("[PolarManager] Quick fetch: cancelled by user")
        await markDeviceRecordingFinished()
        return nil
    }

    private func completeQuickFetchAttempt(
        api: any StrapRadio,
        deviceId: String,
        recordedSince: Date?,
        attempt: Int,
        totalAttempts: Int
    ) async throws -> [RRPoint] {
        let points = try await fetchExerciseDataWithProgress(
            api: api, deviceId: deviceId, attempt: attempt, maxAttempts: totalAttempts,
            silent: true, recordedSince: recordedSince
        )
        await markDeviceRecordingFinished()
        debugLog("[PolarManager] Quick fetch succeeded on attempt \(attempt): \(points.count) points")
        return points
    }

    /// False when the retry delay itself failed (cancelled / reconnect threw),
    /// which ends the attempt loop.
    private func backOffBeforeNextQuickFetch(
        api: any StrapRadio,
        deviceId: String,
        attempt: Int,
        quickRetries: Int,
        totalAttempts: Int
    ) async -> Bool {
        do {
            try await handleQuickFetchRetryDelay(
                api: api, deviceId: deviceId,
                attempt: attempt, quickRetries: quickRetries, totalAttempts: totalAttempts
            )
            return true
        } catch {
            return false
        }
    }

    private func markDeviceRecordingFinished() async {
        await MainActor.run {
            manager.recordingState = .idle
            manager.isRecordingOnDevice = false
        }
    }

    /// Determine retry strategy: quick backoff for early attempts, disconnect/reconnect for later ones
    func handleQuickFetchRetryDelay(
        api: any StrapRadio, deviceId: String,
        attempt: Int, quickRetries: Int, totalAttempts: Int
    ) async throws {
        if attempt <= quickRetries {
            // Quick retry: just wait briefly and try again.
            // The device may still be finalizing the file.
            let delayMs: UInt64 = attempt <= 3 ? 500 : 1000
            debugLog("[PolarManager] Quick retry in \(delayMs)ms...")
            try await Task.sleep(nanoseconds: delayMs * 1_000_000)
        } else if attempt < totalAttempts {
            try await disconnectAndReconnectForRetry(api: api, deviceId: deviceId)
        }
    }

    /// Disconnect and reconnect BLE to recover a transfer the SDK has wedged.
    /// Each wait is on the link's own events rather than a fixed sleep.
    func disconnectAndReconnectForRetry(api _: any StrapRadio, deviceId _: String) async throws {
        debugLog("[PolarManager] Resetting the strap link for retry...")
        if manager.link.beginLinkReset() {
            _ = await manager.link.awaitDisconnection(until: Date().addingTimeInterval(StrapRecordingPolicy.linkDropWaitSeconds))
        }
        let outcome = await manager.link.awaitFeature(
            .h10Recording,
            until: Date().addingTimeInterval(StrapRecordingPolicy.featureReadyWindowSeconds),
            while: { !manager.fetchCancelled }
        )
        debugLog("[PolarManager] Link reset for retry — recording feature: \(outcome)")
    }

    /// Internal helper to fetch exercise data from H10 (no progress updates)
    func fetchExerciseData(api: any StrapRadio, deviceId: String) async throws -> [RRPoint] {
        try await fetchExerciseDataWithProgress(api: api, deviceId: deviceId, attempt: 1, maxAttempts: 5)
    }

    /// Internal helper to fetch exercise data from H10 with progress updates.
    /// Pass `silent: true` to skip manager.fetchProgress UI updates (used by background refinement).
    func fetchExerciseDataWithProgress(
        api: any StrapRadio, deviceId: String, attempt: Int, maxAttempts: Int,
        silent: Bool = false, recordedSince: Date? = nil
    ) async throws -> [RRPoint] {
        let entry = try await sessionRecording(api: api, deviceId: deviceId, recordedSince: recordedSince)
        if !silent {
            await manager.updateProgress(.fetchingData, progress: 0.5, attempt: attempt, maxAttempts: maxAttempts, message: "Found recording, downloading...")
        }
        let exercise = try await fetchExercise(api: api, deviceId: deviceId, entry: entry)
        if !silent {
            await manager.updateProgress(.fetchingData, progress: 0.8, attempt: attempt, maxAttempts: maxAttempts, message: "Processing data...")
        }
        let rrPoints = manager.convertToRRPoints(exercise)
        if !silent {
            await manager.updateProgress(.fetchingData, progress: 0.9, attempt: attempt, maxAttempts: maxAttempts, message: "Got \(rrPoints.count) heartbeats")
        }
        // Store entry for deferred clearing - user must accept report first
        await MainActor.run {
            manager.pendingExerciseEntry = entry
            manager.hasPendingExercise = true
        }
        return rrPoints
    }

    /// The newest stored exercise that belongs to this session.
    private func sessionRecording(api: any StrapRadio, deviceId: String, recordedSince: Date?) async throws -> PolarExerciseEntry {
        let entries = try await listStoredExercises(api: api, deviceId: deviceId)
        if let entry = StrapExerciseDecoder.newestRecording(entries, exerciseId: \.entryId, notBefore: recordedSince) {
            return entry
        }
        if !entries.isEmpty, let recordedSince {
            debugLog("[PolarManager] \(entries.count) stored exercise(s) on the H10, none started since \(recordedSince) — not scoring an older recording as this session")
        }
        throw PolarManager.PolarError.noRecordingFound
    }

    /// Recovered exercise data with recording timestamp
    struct RecoveredExercise {
        let rrPoints: [RRPoint]
        let recordingDate: Date // When the recording ENDED on H10 (from PolarExerciseEntry.date)
    }

    /// Recover exercise data from H10 with progress tracking and retry logic
    /// Use this to fetch stored RR data for recovery purposes
    /// Does NOT mark for clearing - data stays on H10 until explicitly cleared
    /// Verity Sense fetches its offline PPI recordings directly instead.
    func recoverExerciseData() async throws -> RecoveredExercise {
        #if canImport(PolarBleSdk)
            guard let api = manager.strapAPI, let deviceId = manager.connectedDeviceId, manager.connectionState == .connected else {
                throw PolarManager.PolarError.notConnected
            }
            if manager.connectedDeviceType == .veritySense { return try await recoverVeritySenseData() }
            let entry = try await locateWhenReady(api: api, deviceId: deviceId)
            return try await retryWithReconnect(
                deviceName: "H10", progressBase: 0.2,
                feature: .h10Recording,
                operation: { [self] attempt, maxAttempts in
                    try await downloadRecoveredExercise(
                        api: api, deviceId: deviceId, entry: entry, attempt: attempt, maxAttempts: maxAttempts
                    )
                }
            )
        #else
            throw PolarManager.PolarError.sdkNotAvailable
        #endif
    }

    #if canImport(PolarBleSdk)
        /// The recording to recover, once the strap's recording feature is usable.
        private func locateWhenReady(api: any StrapRadio, deviceId: String) async throws -> PolarExerciseEntry {
            try await manager.link.whenFeatureUsable(
                .h10Recording, until: Date().addingTimeInterval(StrapRecordingPolicy.featureReadyWindowSeconds)
            ) {
                try await locateStoredExerciseForRecovery(api: api, deviceId: deviceId)
            }
        }

        /// Get the exercise entry to recover (quick, no retry needed).
        private func locateStoredExerciseForRecovery(api: any StrapRadio, deviceId: String) async throws -> PolarExerciseEntry {
            manager.fetchCancelled = false
            debugLog("[PolarManager] Recovering exercise data from H10...")
            await manager.updateProgress(.listingExercises, progress: 0.1, message: "Finding stored data...")
            let entries = try await listStoredExercises(api: api, deviceId: deviceId)
            guard let entry = StrapExerciseDecoder.newestRecording(entries, exerciseId: \.entryId, notBefore: nil) else {
                await MainActor.run { self.manager.fetchProgress = nil }
                throw PolarManager.PolarError.noRecordingFound
            }
            debugLog("[PolarManager] Found exercise: \(entry.path) (\(entries.count) stored), fetching data...")
            return entry
        }
    #endif

    #if canImport(PolarBleSdk)
        private func downloadRecoveredExercise(
            api: any StrapRadio,
            deviceId: String,
            entry: PolarExerciseEntry,
            attempt: Int,
            maxAttempts: Int
        ) async throws -> RecoveredExercise {
            await manager.updateProgress(.fetchingData, progress: 0.3, attempt: attempt, maxAttempts: maxAttempts, message: "Downloading from H10...")
            let exercise = try await fetchExercise(api: api, deviceId: deviceId, entry: entry)
            await manager.updateProgress(.fetchingData, progress: 0.8, attempt: attempt, maxAttempts: maxAttempts, message: "Processing data...")
            let rrPoints = manager.convertToRRPoints(exercise)
            await manager.updateProgress(.complete, progress: 1.0, attempt: attempt, maxAttempts: maxAttempts, message: "Recovered \(rrPoints.count) heartbeats!")
            await manager.sleepIgnoringCancellation(500_000_000, context: "H10 recovery completion UI delay")
            await MainActor.run { self.manager.fetchProgress = nil }
            let recordingEnd = Self.recordingEnd(of: entry, points: rrPoints)
            debugLog("[PolarManager] Recovered \(rrPoints.count) RR points from H10 (NOT cleared), ended \(recordingEnd)")
            return RecoveredExercise(rrPoints: rrPoints, recordingDate: recordingEnd)
        }

        /// When the recording ended: its start (from the id) plus the beats'
        /// own duration. The SDK's entry date is only when the list was read,
        /// which is the fallback for a recording this app did not file.
        nonisolated static func recordingEnd(of entry: PolarExerciseEntry, points: [RRPoint]) -> Date {
            guard let start = StrapExerciseDecoder.recordingStart(fromExerciseId: entry.entryId) else { return entry.date }
            return start.addingTimeInterval(StrapExerciseDecoder.durationSeconds(of: points))
        }

        /// The SDK returns this directly as of 8.2.0; the Rx bridge is gone.
        func fetchExercise(api: any StrapRadio, deviceId: String, entry: PolarExerciseEntry) async throws -> PolarExerciseData {
            try await api.fetchExercise(deviceId, entry: entry)
        }
    #endif

    /// Recover offline PPI data from Verity Sense internal memory
    func recoverVeritySenseData() async throws -> RecoveredExercise {
        manager.fetchCancelled = false
        let deviceName = manager.connectedDeviceType?.displayName ?? "Verity Sense"
        debugLog("[PolarManager] Recovering offline PPI data from \(deviceName)...")
        return try await retryWithReconnect(
            deviceName: deviceName,
            progressBase: 0.35,
            feature: .offlineRecording,
            operation: { [self] attempt, maxAttempts in
                try await downloadRecoveredPpi(deviceName: deviceName, attempt: attempt, maxAttempts: maxAttempts)
            }
        )
    }

    private func downloadRecoveredPpi(deviceName: String, attempt: Int, maxAttempts: Int) async throws -> RecoveredExercise {
        await manager.updateProgress(.listingExercises, progress: 0.1, attempt: attempt, maxAttempts: maxAttempts, message: "Finding stored data on \(deviceName)...")
        let points = try await fetchOfflinePpiRecording()
        guard !points.isEmpty else {
            await MainActor.run { self.manager.fetchProgress = nil }
            throw PolarManager.PolarError.noRecordingFound
        }
        // `storedExerciseDate` is when the Verity's recording started;
        // recovery wants when it ended.
        let recordingDate = manager.storedExerciseDate.map {
            $0.addingTimeInterval(StrapExerciseDecoder.durationSeconds(of: points))
        } ?? Date()
        await manager.updateProgress(.complete, progress: 1.0, attempt: attempt, maxAttempts: maxAttempts, message: "Recovered \(points.count) heartbeats!")
        await manager.sleepIgnoringCancellation(500_000_000, context: "Verity Sense recovery completion UI delay")
        await MainActor.run {
            self.manager.fetchProgress = nil
            self.manager.hasStoredExercise = false
            self.manager.storedExerciseDate = nil
        }
        debugLog("[PolarManager] Recovered \(points.count) PPI points from \(deviceName), date: \(recordingDate)")
        return RecoveredExercise(rrPoints: points, recordingDate: recordingDate)
    }

    /// Clear the pending exercise entry from H10 memory (H10-specific).
    /// For Verity Sense, use discardStoredExercises() instead.
    /// Call this ONLY after user has accepted the report.
    func clearPendingExercise() async throws {
        #if canImport(PolarBleSdk)
            guard let api = manager.strapAPI, let deviceId = manager.connectedDeviceId else {
                throw PolarManager.PolarError.notConnected
            }
            guard let entry = manager.pendingExerciseEntry else {
                debugLog("[PolarManager] No pending exercise to clear")
                return
            }
            debugLog("[PolarManager] Clearing exercise from H10 memory...")
            try await api.removeExercise(deviceId, entry: entry)
            await MainActor.run {
                manager.pendingExerciseEntry = nil
                manager.hasPendingExercise = false
            }
            debugLog("[PolarManager] Exercise cleared from H10")
        #else
            throw PolarManager.PolarError.sdkNotAvailable
        #endif
    }

    /// Discard pending exercise without clearing from device
    /// Use if user rejects the session
    func discardPendingExercise() {
        #if canImport(PolarBleSdk)
            manager.pendingExerciseEntry = nil
        #endif
        manager.hasPendingExercise = false
    }

    /// Explicitly discard any stored exercise/recording data on the connected device
    /// H10: removes stored exercises. Verity Sense: removes offline PPI recordings.
    /// Use when user chooses to start fresh and lose unrecovered data.
    func discardStoredExercises() async throws {
        #if canImport(PolarBleSdk)
            guard manager.strapAPI != nil, manager.connectedDeviceId != nil else {
                throw PolarManager.PolarError.notConnected
            }

            let deviceName = manager.connectedDeviceType?.displayName ?? "device"
            debugLog("[PolarManager] User requested discard of stored data on \(deviceName)...")
            try await clearAnyExistingExercises()

            await MainActor.run {
                manager.hasStoredExercise = false
                manager.storedExerciseDate = nil
            }
        #else
            throw PolarManager.PolarError.sdkNotAvailable
        #endif
    }
}
