import Foundation
#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

/// Taking a recording off the strap's own memory.
///
/// Every flow in the app that downloads a recording — the device-recording
/// Stop, Retry, Recover, the morning and a pause, a workout's end, crash
/// recovery, the strap merge on a past session, and the rescue before arming
/// — goes through `fetchRecording`. There is one stop, one reader, one
/// retry/reconnect loop and one date filter, so a fix to any of them reaches
/// every flow. Before this, four near-copies had drifted: only one refused a
/// recording from an earlier session, only one had a hard deadline, and the
/// Cancel button reached none of them.
extension StrapRecordingCoordinator {
    // MARK: - The one fetch

    /// Stops the strap's running recording, if any, and downloads the
    /// recording that belongs to `recordedSince`: the newest one that started
    /// at or after it, or simply the newest when it is nil. A strap holding
    /// only older recordings throws `noRecordingSinceSessionStart` rather
    /// than hand back an earlier night as this one.
    ///
    /// Each phase runs under `budget`'s hard deadline, and `cancelFetch()`
    /// ends it at once. Whatever happens, the app's recording state is left
    /// settled, never mid-`.stopping` or `.fetching`.
    func fetchRecording(recordedSince: Date?, budget: StrapRecordingPolicy.TransferBudget) async throws -> StrapRecording {
        try await fetchRecording(.newest(since: recordedSince), budget: budget)
    }

    /// One H10 exercise by the id it is stored under: the rescue of each
    /// recording the app does not hold before a start clears the strap.
    func fetchRecording(exerciseId: String, budget: StrapRecordingPolicy.TransferBudget) async throws -> StrapRecording {
        try await fetchRecording(.exercise(id: exerciseId), budget: budget)
    }

    private func fetchRecording(
        _ selection: StrapRecordingSelection, budget: StrapRecordingPolicy.TransferBudget
    ) async throws -> StrapRecording {
        guard let api = manager.strapAPI, let deviceId = manager.connectedDeviceId,
              manager.connectionState == .connected else { throw PolarManager.PolarError.notConnected }
        manager.transfersInFlight += 1
        defer { manager.transfersInFlight -= 1 }
        do {
            let stopped = try await runBounded(seconds: budget.stopSeconds, phase: "stop") {
                try await self.stopRunningRecording(api: api, deviceId: deviceId, showsProgress: budget.showsProgress)
            }
            let recording = try await runBounded(seconds: budget.downloadSeconds, phase: "download") {
                try await self.downloadWithRetries(
                    api: api, deviceId: deviceId, selection: selection,
                    showsProgress: budget.showsProgress, justStopped: stopped
                )
            }
            await noteDownloaded(recording, showsProgress: budget.showsProgress)
            return recording
        } catch {
            throw settleFailedTransfer(error)
        }
    }

    /// The unattended form: nil instead of an error, with the reason logged.
    /// A Verity Sense is only asked while its offline recording runs
    /// (`quickFetchDecision`); an H10 keeps its file either way and is always
    /// asked.
    func fetchRecordingIfAvailable(recordedSince: Date?) async -> StrapRecording? {
        let decision = StrapRecordingPolicy.quickFetchDecision(
            hasAPI: manager.strapAPI != nil, hasDeviceId: manager.connectedDeviceId != nil,
            isRecordingOnDevice: manager.isRecordingOnDevice, deviceType: manager.connectedDeviceType
        )
        guard decision == .fetchH10 || decision == .fetchVeritySense else {
            debugLog("[PolarManager] Strap download skipped: \(decision)")
            return nil
        }
        do {
            return try await fetchRecording(recordedSince: recordedSince, budget: .unattended)
        } catch {
            reportUnattendedFailure(error)
            return nil
        }
    }

    /// Say what actually failed, and never promise the night is safe: a
    /// fallback message must not make a claim the fallback cannot verify.
    private func reportUnattendedFailure(_ error: Error) {
        let stillOnStrap = manager.isRecordingOnDevice || manager.hasStoredExercise
        let tail = stillOnStrap
            ? "The strap still holds its own copy — recover it from the Record screen before starting anything new, which clears it."
            : "Scoring the live stream instead."
        debugLogExternal("Couldn't read the strap's internal recording — \(error). \(tail)", cause: .strap)
    }

    // MARK: - Starting, bounding and cancelling a transfer

    /// A flow that is about to take something off the strap starts here. The
    /// fetch itself never clears the flag: a Cancel or Skip tapped while the
    /// flow was still reconnecting must survive into the download.
    func beginTransfer() {
        manager.fetchCancelled = false
    }

    /// The user's Cancel: the flag stops the retry loop between attempts, and
    /// cancelling the running phase ends a call the strap never answers.
    func cancelActiveTransfer() {
        manager.fetchCancelled = true
        manager.activeTransfer?.cancel()
        debugLog("[PolarManager] Fetch cancellation requested")
    }

    /// One phase under its hard deadline, cancellable from `cancelFetch()`.
    func runBounded<T: Sendable>(
        seconds: UInt64, phase: String, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        if manager.fetchCancelled { throw CancellationError() }
        let timeout = PolarManager.PolarError.fetchFailed("strap \(phase) timed out after \(seconds)s (strap unresponsive)")
        let task = Task { try await StrapDeadline.race(seconds: seconds, timeout: timeout, operation: operation) }
        let handle = StrapTransferHandle(cancel: { task.cancel() })
        manager.activeTransfer = handle
        defer { if manager.activeTransfer?.id == handle.id { manager.activeTransfer = nil } }
        if manager.fetchCancelled { task.cancel() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Nothing is in flight any more, so the state machine is settled; the
    /// strap's own flag stays what the strap last said. A cancelled transfer
    /// reads as one.
    private func settleFailedTransfer(_ error: Error) -> Error {
        manager.fetchProgress = nil
        if manager.recordingState != .idle { manager.recordingState = .idle }
        guard error is CancellationError || manager.fetchCancelled else {
            debugLog("[PolarManager] Strap transfer failed: \(error)")
            return error
        }
        debugLog("[PolarManager] Strap transfer cancelled by user")
        return PolarManager.PolarError.fetchFailed("Cancelled by user")
    }

    /// The strap keeps its copy after a download, so it still holds one, and
    /// the download is on record so the copy is not offered again.
    private func noteDownloaded(_ recording: StrapRecording, showsProgress: Bool) async {
        manager.recordingState = .idle
        manager.hasStoredExercise = true
        if let start = recording.startedAt {
            manager.storedExerciseDate = start
            manager.downloadLedger.markDownloaded(recordingStartedAt: start)
        }
        debugLog("[PolarManager] Downloaded \(recording.points.count) beats, started \(recording.startedAt?.description ?? "unknown")")
        guard showsProgress else { return }
        await manager.updateProgress(.complete, progress: 1.0, message: "Downloaded \(recording.points.count) heartbeats!")
        await manager.sleepIgnoringCancellation(500_000_000, context: "strap download completion UI delay")
        manager.fetchProgress = nil
    }

    // MARK: - Reconnecting for a transfer

    /// Brings the strap back when the link has dropped, and reads what it is
    /// recording and holding before anything is decided from those flags.
    /// True when the strap is connected. Bounded by
    /// `StrapRecordingPolicy.reconnectWindowSeconds` and ended at once by
    /// Cancel or Skip.
    func reconnectForTransfer() async -> Bool {
        guard manager.connectionState != .connected else { return true }
        debugLog("[PolarManager] Strap not connected — reconnecting for the transfer…")
        manager.connectToLastDevice()
        let window = StrapRecordingPolicy.reconnectWindowSeconds
        manager.transfersInFlight += 1
        defer { manager.transfersInFlight -= 1 }
        do {
            return try await runBounded(seconds: UInt64(window) + 5, phase: "reconnect") {
                await self.awaitLinkAndRecordingState(until: Date().addingTimeInterval(window))
            }
        } catch {
            debugLog("[PolarManager] Strap did not come back for the transfer: \(error)")
            return false
        }
    }

    private func awaitLinkAndRecordingState(until deadline: Date) async -> Bool {
        guard await manager.link.awaitConnection(until: deadline) else { return false }
        await refreshRecordingState(until: deadline)
        return true
    }

    /// Reads whether the strap is recording and what it holds, once its
    /// recording feature is usable.
    func refreshRecordingState(until deadline: Date) async {
        let feature: StrapFeature = manager.connectedDeviceType == .veritySense ? .offlineRecording : .h10Recording
        do {
            _ = try await manager.link.whenFeatureUsable(feature, until: deadline) {
                try await checkRecordingStatus()
            }
            await checkForStoredExercises()
        } catch {
            debugLog("[PolarManager] Strap recording status unavailable: \(error)")
        }
    }

    // MARK: - The one stop

    /// Stop whatever the strap is recording, as its own status reports it.
    /// True when a recording was running and is now stopped.
    private func stopRunningRecording(api: any StrapRadio, deviceId: String, showsProgress: Bool) async throws -> Bool {
        if manager.connectedDeviceType == .veritySense {
            return try await stopVeritySenseIfRecording(api: api, deviceId: deviceId, showsProgress: showsProgress)
        }
        return try await stopH10Recording(
            api: api, deviceId: deviceId, awaitFinalize: true, showsProgress: showsProgress, cancellable: true,
            streamHoldsIt: false
        )
    }

    /// The one H10 stop. Asks the strap, stops it if it is recording, and
    /// returns the app's state to idle from the strap's own answer, so the
    /// next start is not refused for a recording that no longer runs. A stop
    /// that a download follows waits for the file to finalize. A recording
    /// whose beats the session saved from the stream (`streamHoldsIt`) goes on
    /// the download record.
    func stopH10Recording(
        api: any StrapRadio, deviceId: String, awaitFinalize: Bool, showsProgress: Bool, cancellable: Bool,
        streamHoldsIt: Bool
    ) async throws -> Bool {
        if showsProgress { await manager.updateProgress(.stopping, progress: 0.05, message: "Checking recording status...") }
        let status = try await manager.link.whenFeatureUsable(
            .h10Recording, until: Date().addingTimeInterval(StrapRecordingPolicy.featureReadyWindowSeconds),
            while: { !cancellable || !manager.fetchCancelled },
            perform: { try await h10RecordingStatus(api: api, deviceId: deviceId) }
        )
        guard status.ongoing else {
            applyStatus(ongoing: false)
            return false
        }
        manager.recordingState = .stopping
        if showsProgress { await manager.updateProgress(.stopping, progress: 0.1, message: "Stopping recording...") }
        try await api.stopRecording(deviceId)
        let startedAt = StrapExerciseDecoder.recordingStart(fromExerciseId: status.entryId)
        markRecordingStopped(startedAt: startedAt)
        if streamHoldsIt, let startedAt { manager.downloadLedger.markDownloaded(recordingStartedAt: startedAt) }
        if awaitFinalize { await awaitH10FileFinalize(api: api, deviceId: deviceId, showsProgress: showsProgress) }
        return true
    }

    /// The strap confirmed the stop: nothing records, and the strap now holds
    /// the finished file.
    private func markRecordingStopped(startedAt: Date?) {
        manager.recordingState = .idle
        manager.isRecordingOnDevice = false
        manager.hasStoredExercise = true
        if let startedAt { manager.storedExerciseDate = startedAt }
        debugLog("[PolarManager] Strap recording stopped (started \(startedAt?.description ?? "unknown"))")
    }

    /// A Verity Sense lists only completed recordings, so a running one is
    /// stopped first. A stop that fails is logged and the completed
    /// recordings are read anyway.
    private func stopVeritySenseIfRecording(api: any StrapRadio, deviceId: String, showsProgress: Bool) async throws -> Bool {
        let ongoing = try await manager.link.whenFeatureUsable(
            .offlineRecording, until: Date().addingTimeInterval(StrapRecordingPolicy.featureReadyWindowSeconds),
            while: { !manager.fetchCancelled },
            perform: { try await veritySenseRecordingStatus(api: api, deviceId: deviceId) }
        )
        guard ongoing else { return false }
        if showsProgress { await manager.updateProgress(.stopping, progress: 0.05, message: "Stopping recording...") }
        do {
            try await stopOfflinePpiRecording()
            await sleepQuietly(500_000_000, context: "Verity Sense stop before download")
            return true
        } catch {
            debugLog("[PolarManager] Could not stop the Verity Sense recording — reading completed ones: \(error)")
            return false
        }
    }

    /// Wait for the H10 to list the finished file before the download reads
    /// it. A full night is not written to flash in a fixed pause; a download
    /// fired too early hits a file that is not ready and spends the budget on
    /// retries. Polls the (fast) listing, bounded so a missing file falls
    /// through to the retry loop.
    private func awaitH10FileFinalize(api: any StrapRadio, deviceId: String, showsProgress: Bool) async {
        if showsProgress { await manager.updateProgress(.finalizing, progress: 0.2, message: "Strap is saving data...") }
        let started = Date()
        for poll in 1 ... 30 {
            if manager.fetchCancelled || Task.isCancelled { return }
            if await h10ListsAnyRecording(api: api, deviceId: deviceId) {
                debugLog("[MorningTiming] H10 finalize ready after \(Int(Date().timeIntervalSince(started) * 1000))ms (\(poll) polls)")
                return
            }
            await sleepQuietly(500_000_000, context: "awaitH10FileFinalize")
        }
        debugLog("[MorningTiming] H10 finalize: no listed entry after ~15s — proceeding to the retry loop")
    }

    private func h10ListsAnyRecording(api: any StrapRadio, deviceId: String) async -> Bool {
        do {
            return try await !listStoredExercises(api: api, deviceId: deviceId).isEmpty
        } catch {
            debugLog("[PolarManager] Listing during finalize failed: \(error)")
            return false
        }
    }

    /// The inline stop at a session's end when nothing will be downloaded
    /// (a workout whose stream covered it, a skipped morning download), so
    /// the strap cannot keep recording off-body and refuse the next session.
    /// Bounded, and not subject to Cancel: a stale Cancel must not leave the
    /// strap running. No-op for a Verity Sense and when nothing records.
    ///
    /// `streamHoldsIt` is true when the session already saved this
    /// recording's beats from the live stream. The stopped recording then goes
    /// on the download record, so the next start's rescue does not download
    /// it again; without it a walk's complete stream looked lost at bedtime.
    func stopDeviceRecordingIfNeeded(streamHoldsIt: Bool) async {
        guard StrapRecordingPolicy.shouldStopDeviceRecording(
            deviceType: manager.connectedDeviceType, hasAPI: manager.strapAPI != nil,
            hasDeviceId: manager.connectedDeviceId != nil, isRecordingOnDevice: manager.isRecordingOnDevice
        ), let api = manager.strapAPI, let deviceId = manager.connectedDeviceId else { return }
        let budget = StrapRecordingPolicy.TransferBudget.unattended
        do {
            _ = try await StrapDeadline.race(
                seconds: budget.stopSeconds,
                timeout: PolarManager.PolarError.fetchFailed("H10 stop timed out after \(budget.stopSeconds)s")
            ) {
                try await self.stopH10Recording(
                    api: api, deviceId: deviceId, awaitFinalize: false, showsProgress: false, cancellable: false,
                    streamHoldsIt: streamHoldsIt
                )
            }
        } catch {
            if manager.recordingState != .idle { manager.recordingState = .idle }
            debugLogExternal("H10 didn't confirm the recording stop — \(error). It is asked again before the next recording starts.", cause: .strap)
        }
    }

    // MARK: - The one download loop

    /// Quick retries while a just-stopped file finishes writing, then link
    /// resets for a transfer the SDK has wedged (`StrapRecordingPolicy.retryStep`).
    private func downloadWithRetries(
        api: any StrapRadio, deviceId: String, selection: StrapRecordingSelection, showsProgress: Bool, justStopped: Bool
    ) async throws -> StrapRecording {
        var attempt = 1
        while true {
            if manager.fetchCancelled || Task.isCancelled { throw CancellationError() }
            do {
                return try await readWhenUsable(
                    api: api, deviceId: deviceId, selection: selection, attempt: attempt, showsProgress: showsProgress
                )
            } catch {
                let failure = Self.classify(error)
                debugLog("[PolarManager] Strap download attempt \(attempt) failed (\(failure)): \(error)")
                try await prepareNextAttempt(
                    StrapRecordingPolicy.retryStep(after: failure, attempt: attempt, justStopped: justStopped),
                    after: error, attempt: attempt, showsProgress: showsProgress
                )
                attempt += 1
            }
        }
    }

    private func readWhenUsable(
        api: any StrapRadio, deviceId: String, selection: StrapRecordingSelection, attempt: Int, showsProgress: Bool
    ) async throws -> StrapRecording {
        try await manager.link.whenFeatureUsable(
            downloadFeature, until: Date().addingTimeInterval(StrapRecordingPolicy.featureReadyWindowSeconds),
            while: { !manager.fetchCancelled },
            perform: {
                try await readRecording(
                    api: api, deviceId: deviceId, selection: selection, attempt: attempt, showsProgress: showsProgress
                )
            }
        )
    }

    private var downloadFeature: StrapFeature {
        manager.connectedDeviceType == .veritySense ? .offlineRecording : .h10Recording
    }

    /// What a failed attempt means for the next one.
    static func classify(_ error: Error) -> StrapRecordingPolicy.DownloadFailure {
        switch error as? PolarManager.PolarError {
        case .noRecordingSinceSessionStart?, .pairingLost?: .deterministic
        case .noRecordingFound?: .nothingListed
        default: .transient
        }
    }

    private func prepareNextAttempt(
        _ step: StrapRecordingPolicy.RetryStep, after error: Error, attempt: Int, showsProgress: Bool
    ) async throws {
        switch step {
        case .giveUp:
            throw error
        case let .pause(milliseconds):
            try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        case .resetLink:
            if showsProgress {
                await manager.updateProgress(.reconnecting, progress: 0.35, attempt: attempt + 1, maxAttempts: StrapRecordingPolicy.maxDownloadAttempts, message: "Resetting connection...")
            }
            await resetLinkForRetry()
        }
    }

    /// Reset the link, then wait on its own events for the strap to come back
    /// and its recording feature to be usable again.
    private func resetLinkForRetry() async {
        debugLog("[PolarManager] Resetting the strap link before the next download attempt...")
        if manager.link.beginLinkReset() {
            _ = await manager.link.awaitDisconnection(until: Date().addingTimeInterval(StrapRecordingPolicy.linkDropWaitSeconds))
        }
        let outcome = await manager.link.awaitFeature(
            downloadFeature,
            until: Date().addingTimeInterval(StrapRecordingPolicy.featureReadyWindowSeconds),
            while: { !manager.fetchCancelled }
        )
        debugLog("[PolarManager] Link reset for retry — \(downloadFeature): \(outcome)")
    }

    // MARK: - The one reader

    private func readRecording(
        api: any StrapRadio, deviceId: String, selection: StrapRecordingSelection, attempt: Int, showsProgress: Bool
    ) async throws -> StrapRecording {
        manager.recordingState = .fetching
        if showsProgress {
            await manager.updateProgress(.fetchingData, progress: 0.5, attempt: attempt, maxAttempts: StrapRecordingPolicy.maxDownloadAttempts, message: "Downloading...")
        }
        let recording = try await readFromStrap(api: api, deviceId: deviceId, selection: selection)
        try Task.checkCancellation()
        return recording
    }

    private func readFromStrap(api: any StrapRadio, deviceId: String, selection: StrapRecordingSelection) async throws -> StrapRecording {
        if manager.connectedDeviceType == .veritySense {
            return try await readVeritySenseRecording(recordedSince: selection.since)
        }
        return try await readH10Recording(api: api, deviceId: deviceId, selection: selection)
    }

    private func readH10Recording(api: any StrapRadio, deviceId: String, selection: StrapRecordingSelection) async throws -> StrapRecording {
        let entry = try await selectedRecording(api: api, deviceId: deviceId, selection: selection)
        let exercise = try await api.fetchExercise(deviceId, entry: entry)
        return StrapRecording(
            points: manager.convertToRRPoints(exercise),
            startedAt: StrapExerciseDecoder.recordingStart(fromExerciseId: entry.entryId)
        )
    }

    private func selectedRecording(
        api: any StrapRadio, deviceId: String, selection: StrapRecordingSelection
    ) async throws -> PolarExerciseEntry {
        switch selection {
        case let .newest(since): return try await sessionRecording(api: api, deviceId: deviceId, recordedSince: since)
        case let .exercise(id): return try await storedExercise(id: id, api: api, deviceId: deviceId)
        }
    }

    private func storedExercise(id: String, api: any StrapRadio, deviceId: String) async throws -> PolarExerciseEntry {
        let entries = try await listStoredExercises(api: api, deviceId: deviceId)
        guard let entry = entries.first(where: { $0.entryId == id }) else { throw PolarManager.PolarError.noRecordingFound }
        return entry
    }

    /// The newest stored exercise that belongs to this session.
    private func sessionRecording(api: any StrapRadio, deviceId: String, recordedSince: Date?) async throws -> PolarExerciseEntry {
        let entries = try await listStoredExercises(api: api, deviceId: deviceId)
        if let entry = StrapExerciseDecoder.newestRecording(entries, exerciseId: \.entryId, notBefore: recordedSince) {
            return entry
        }
        if !entries.isEmpty, let recordedSince {
            debugLog("[PolarManager] \(entries.count) stored exercise(s) on the H10, none started since \(recordedSince) — not scoring an older recording as this session")
            throw PolarManager.PolarError.noRecordingSinceSessionStart
        }
        throw PolarManager.PolarError.noRecordingFound
    }

    /// The Verity Sense's completed offline recordings since `recordedSince`,
    /// joined into one series.
    private func readVeritySenseRecording(recordedSince: Date?) async throws -> StrapRecording {
        let recording = try await fetchOfflinePpiRecording(recordedSince: recordedSince)
        guard !recording.points.isEmpty else { throw PolarManager.PolarError.noRecordingFound }
        return recording
    }
}

/// The phase of a strap transfer that is running now, so Cancel can end it.
struct StrapTransferHandle: Sendable {
    let id = UUID()
    let cancel: @Sendable () -> Void
}

/// Which recording a transfer takes off the strap.
enum StrapRecordingSelection: Sendable {
    /// The newest one that started at or after `since`; the newest of all
    /// when nil.
    case newest(since: Date?)
    /// One H10 exercise, by the id it is stored under.
    case exercise(id: String)

    var since: Date? {
        if case let .newest(since) = self { return since }
        return nil
    }
}
