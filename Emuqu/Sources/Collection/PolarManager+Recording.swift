import CoreBluetooth
import Foundation

#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

extension StrapRecordingCoordinator {
    // MARK: - Recording Control (H10 Internal Memory)

    /// Start internal recording on the connected device.
    /// H10: exercise recording. Verity Sense: offline PPI recording.
    /// Both survive BLE disconnect and app backgrounding.
    func startRecording() async throws {
        #if canImport(PolarBleSdk)
            switch StrapRecordingPolicy.startDecision(
                hasAPI: manager.strapAPI != nil,
                hasDeviceId: manager.connectedDeviceId != nil,
                connectionState: manager.connectionState,
                recordingState: manager.recordingState,
                isRecordingOnDevice: manager.isRecordingOnDevice,
                deviceType: manager.connectedDeviceType
            ) {
            case .notConnected: throw PolarManager.PolarError.notConnected
            case .alreadyRecording: throw PolarManager.PolarError.alreadyRecording
            case .startVeritySense: try await startVeritySenseRecording()
            case .startH10: try await startH10Recording()
            }
        #else
            throw PolarManager.PolarError.sdkNotAvailable
        #endif
    }

    #if canImport(PolarBleSdk)
        /// The order is `StrapStartSequence`'s, so "rescue before clear" is
        /// asserted by tests rather than held in place by this reading top to
        /// bottom.
        private func startVeritySenseRecording() async throws {
            guard manager.isOfflineRecordingReady else {
                throw PolarManager.PolarError.recordingFailed("Offline recording feature not ready - wait a moment after connecting")
            }
            await MainActor.run { manager.recordingState = .starting }
            for step in StrapStartSequence.steps(for: .veritySense) {
                try await runVeritySenseStartStep(step)
            }
        }

        private func runVeritySenseStartStep(_ step: StrapStartSequence.Step) async throws {
            switch step {
            case .rescueExisting: await rescueUnrecoveredOfflineRecordings()
            case .clearExisting: await clearExistingTolerantly(label: "recordings")
            case .beginRecording: try await startOfflinePpiRecording()
            }
        }

        /// A clear that fails is logged and stepped over: the start may still
        /// succeed, and refusing to record because a stale file could not be
        /// deleted is worse than trying.
        private func clearExistingTolerantly(label: String) async {
            debugLog("[PolarManager] Clearing any existing \(label) on \(deviceLabel) before start...")
            do {
                try await clearAnyExistingExercises()
            } catch {
                debugLog("[PolarManager] Warning: Could not clear existing \(label): \(error)")
            }
        }

        /// Rescue any existing offline recordings BEFORE clearing.
        /// Previous data may not have been downloaded yet (e.g. app crashed, user
        /// kicked off a standalone session on the device). Download → backup → clear.
        private func rescueUnrecoveredOfflineRecordings() async {
            do {
                let existingPoints = try await fetchOfflinePpiRecording()
                guard !existingPoints.isEmpty else { return }
                debugLog("[PolarManager] ⚠️ Found \(existingPoints.count) unrecovered PPI points on \(deviceLabel) — rescuing before clear")
                manager.onUnrecoveredDataRescued?(existingPoints)
            } catch PolarManager.PolarError.noRecordingFound {
                // swallow-ok: "no existing data on the strap" is the ordinary case, not a
            // failure — there is nothing to rescue and nothing to report.
            } catch {
                debugLog("[PolarManager] Warning: Could not rescue existing recordings: \(error)")
                // Continue anyway — better to start a new recording than fail entirely
            }
        }

        /// No rescue step: see `StrapStartSequence` for why the H10 warns the
        /// user instead of downloading inline at workout start.
        private func startH10Recording() async throws {
            guard manager.isH10RecordingFeatureReady else {
                throw PolarManager.PolarError.recordingFailed("H10 recording feature not ready - wait a moment after connecting")
            }
            await MainActor.run { manager.recordingState = .starting }
            for step in StrapStartSequence.steps(for: .h10) {
                try await runH10StartStep(step)
            }
        }

        private func runH10StartStep(_ step: StrapStartSequence.Step) async throws {
            switch step {
            case .rescueExisting: await rescueUnrecoveredOfflineRecordings()
            case .clearExisting: await clearExistingTolerantly(label: "exercises")
            case .beginRecording: try await beginH10RecordingSurfacingFailure()
            }
        }

        private func beginH10RecordingSurfacingFailure() async throws {
            do {
                try await beginH10ExerciseRecording()
            } catch {
                await surfaceH10StartFailure(error)
                throw error
            }
        }

        private func beginH10ExerciseRecording() async throws {
            guard let api = manager.strapAPI, let deviceId = manager.connectedDeviceId else { throw PolarManager.PolarError.notConnected }
            let exerciseId = StrapExerciseDecoder.exerciseId()
            debugLog("[PolarManager] Starting \(deviceLabel) internal recording with exerciseId: \(exerciseId)")
            try await api.sdk.startRecording(deviceId, exerciseId: exerciseId, interval: .interval_1s, sampleType: .rr)
            await MainActor.run {
                manager.recordingState = .recording
                manager.isRecordingOnDevice = true
            }
            debugLog("[PolarManager] Started \(deviceLabel) internal RR recording successfully")
        }

        /// Humanise raw Polar SDK errors before they surface to the user via
        /// `manager.lastError`. Without this the alert showed e.g. "Recording failed:
        /// PolarBleSdk.PolarErrors error 3." (real tester report).
        private func surfaceH10StartFailure(_ error: Error) async {
            debugLog("[PolarManager] ERROR starting recording: \(error)")
            await MainActor.run {
                manager.recordingState = .idle
                manager.lastError = PolarManager.PolarError.recordingFailed(PolarErrorMessages.humanize(error))
            }
        }

        private var deviceLabel: String {
            manager.connectedDeviceType?.displayName ?? "device"
        }
    #endif

    /// Clear any existing exercises/recordings from the connected device before starting
    /// a new recording. H10: removes stored exercises (prevents error 106). Verity Sense:
    /// removes offline PPI recordings. This is also the user-initiated "discard" path.
    func clearAnyExistingExercises() async throws {
        #if canImport(PolarBleSdk)
            guard manager.connectedDeviceId != nil else { return }
            if manager.connectedDeviceType == .veritySense {
                try await clearOfflinePpiRecordings()
            } else {
                try await clearStoredExercises()
            }
        #endif
    }

    #if canImport(PolarBleSdk)
        /// Verity Sense: clear offline PPI recordings.
        private func clearOfflinePpiRecordings() async throws {
            guard let api = manager.strapAPI, let deviceId = manager.connectedDeviceId else { return }
            guard manager.isOfflineRecordingReady else {
                debugLog("[PolarManager] Offline recording feature not ready — cannot clear recordings")
                return
            }
            let removed = try await Self.removeOfflinePpiRecordings(api: api, deviceId: deviceId)
            guard removed > 0 else {
                debugLog("[PolarManager] No offline PPI recordings to clear on Verity Sense")
                return
            }
            debugLog("[PolarManager] Cleared \(removed) offline PPI recording(s) from Verity Sense")
        }

        /// H10: clear stored exercises (prevents error 106 operationNotPermitted).
        private func clearStoredExercises() async throws {
            guard let api = manager.strapAPI, let deviceId = manager.connectedDeviceId else { return }
            let entries = try await listStoredExercises(api: api, deviceId: deviceId)
            guard !entries.isEmpty else {
                debugLog("[PolarManager] No existing exercises to clear on H10")
                return
            }
            debugLog("[PolarManager] Found \(entries.count) existing exercise(s), removing...")
            for entry in entries {
                debugLog("[PolarManager] Removing exercise: \(entry.path)")
                try await api.sdk.removeExercise(deviceId, entry: entry)
            }
            await MainActor.run {
                manager.pendingExerciseEntry = nil
                manager.hasPendingExercise = false
            }
            debugLog("[PolarManager] Cleared \(entries.count) exercise(s) from H10")
        }

        /// Every offline PPI recording currently stored on a Verity Sense.
        ///
        /// Polar 8.2.0 returns an `AsyncThrowingStream`, so this collects the
        /// sequence directly. Not an Rx subscription wrapped in a
        /// `CheckedContinuation`: that shape has a failure mode this one cannot
        /// have — a stream that neither completes nor errors leaks the
        /// continuation and hangs the caller forever.
        func listOfflinePpiRecordings(api: StrapAPI, deviceId: String) async throws -> [PolarOfflineRecordingEntry] {
            try await Self.listPpiEntries(api: api, deviceId: deviceId)
        }

        /// Runs off the main actor so the SDK's entry values (not `Sendable`)
        /// stay in one region from listing to removal.
        nonisolated static func listPpiEntries(api: StrapAPI, deviceId: String) async throws -> [PolarOfflineRecordingEntry] {
            var entries: [PolarOfflineRecordingEntry] = []
            for try await entry in api.sdk.listOfflineRecordings(deviceId) {
                entries.append(entry)
            }
            return entries.filter { $0.type == .ppi }
        }

        /// Lists and removes every offline PPI recording; returns the count removed.
        nonisolated static func removeOfflinePpiRecordings(api: StrapAPI, deviceId: String) async throws -> Int {
            let entries = try await listPpiEntries(api: api, deviceId: deviceId)
            for entry in entries {
                debugLog("[PolarManager] Removing offline PPI recording: \(entry.date)")
                try await api.sdk.removeOfflineRecord(deviceId, entry: entry)
            }
            return entries.count
        }

        /// Every exercise currently stored on an H10.
        func listStoredExercises(api: StrapAPI, deviceId: String) async throws -> [PolarExerciseEntry] {
            var entries: [PolarExerciseEntry] = []
            for try await entry in api.sdk.listExercises(deviceId) {
                entries.append(entry)
            }
            return entries
        }
    #endif

    /// Check if the connected device has an active recording.
    /// H10: uses requestRecordingStatus. Verity Sense: uses getOfflineRecordingStatus.
    /// Called only after the relevant BLE feature is ready (no polling needed).
    /// - Parameter deviceId: Optional device ID to use. If nil, uses manager.connectedDeviceId.
    func checkRecordingStatus(deviceId: String? = nil) async throws -> Bool {
        #if canImport(PolarBleSdk)
            guard let api = manager.strapAPI, let deviceId = deviceId ?? manager.connectedDeviceId else {
                throw PolarManager.PolarError.notConnected
            }
            if manager.connectedDeviceType == .veritySense {
                return try await veritySenseRecordingStatus(api: api, deviceId: deviceId)
            }
            let status = try await h10RecordingStatus(api: api, deviceId: deviceId)
            let outcome = StrapRecordingPolicy.statusOutcome(ongoing: status.ongoing)
            manager.isRecordingOnDevice = outcome.isRecordingOnDevice
            if let state = outcome.recordingState { manager.recordingState = state }
            debugLog("[PolarManager] H10 recording status: ongoing=\(status.ongoing)")
            return status.ongoing
        #else
            throw PolarManager.PolarError.sdkNotAvailable
        #endif
    }

    #if canImport(PolarBleSdk)
        private func veritySenseRecordingStatus(api: StrapAPI, deviceId: String) async throws -> Bool {
            guard manager.isOfflineRecordingReady else {
                debugLog("[PolarManager] Offline recording feature not ready — cannot check recording status")
                return false
            }
            // 8.2.0 returns the dictionary directly; the Rx `Single` and its
            // continuation wrapper are gone.
            let status: [PolarDeviceDataType: Bool] = try await api.sdk.getOfflineRecordingStatus(deviceId)
            let ppiRecording = status[.ppi] ?? false
            let outcome = StrapRecordingPolicy.statusOutcome(ongoing: ppiRecording)
            manager.isRecordingOnDevice = outcome.isRecordingOnDevice
            if let state = outcome.recordingState { manager.recordingState = state }
            debugLog("[PolarManager] Verity Sense offline recording status: PPI=\(ppiRecording)")
            return ppiRecording
        }
    #endif

    /// Check if H10 has stored exercise data that can be recovered.
    /// Called only after the relevant BLE feature is ready (no polling needed).
    /// - Parameter deviceId: Optional device ID to use. If nil, uses manager.connectedDeviceId.
    func checkForStoredExercises(deviceId: String? = nil) async {
        #if canImport(PolarBleSdk)
            guard let api = manager.strapAPI, let deviceId = deviceId ?? manager.connectedDeviceId else {
                debugLog("[PolarManager] checkForStoredExercises: No device ID available")
                return
            }
            if manager.connectedDeviceType == .veritySense {
                await checkStoredOfflineRecordings(api: api, deviceId: deviceId)
            } else {
                await checkStoredH10Exercises(api: api, deviceId: deviceId)
            }
        #endif
    }

    #if canImport(PolarBleSdk)
        private func checkStoredOfflineRecordings(api: StrapAPI, deviceId: String) async {
            guard manager.isOfflineRecordingReady else {
                debugLog("[PolarManager] Offline recording feature not ready — cannot check for stored recordings")
                return
            }
            do {
                let ppiRecordings = try await listOfflinePpiRecordings(api: api, deviceId: deviceId)
                let recordingDate = ppiRecordings.first?.date
                debugLog("[PolarManager] Found \(ppiRecordings.count) offline PPI recording(s) on Verity Sense, date: \(recordingDate?.description ?? "none")")
                manager.hasStoredExercise = !ppiRecordings.isEmpty
                manager.storedExerciseDate = recordingDate
            } catch {
                debugLog("[PolarManager] Error checking Verity Sense offline recordings: \(error)")
                manager.hasStoredExercise = false
                manager.storedExerciseDate = nil
            }
        }

        private func checkStoredH10Exercises(api: StrapAPI, deviceId: String) async {
            do {
                let entries = try await listStoredExercises(api: api, deviceId: deviceId)
                let exerciseDate = entries.first?.date
                debugLog("[PolarManager] Found \(entries.count) stored exercise(s) on H10, date: \(exerciseDate?.description ?? "none")")
                manager.hasStoredExercise = !entries.isEmpty
                manager.storedExerciseDate = exerciseDate
            } catch {
                debugLog("[PolarManager] Error checking for stored exercises: \(error)")
                manager.hasStoredExercise = false
                manager.storedExerciseDate = nil
            }
        }
    #endif

    /// Stop recording and fetch RR data from H10 internal memory
    func stopAndFetchRecording() async throws -> [RRPoint] {
        #if canImport(PolarBleSdk)
            guard let api = manager.strapAPI, let deviceId = manager.connectedDeviceId else {
                throw PolarManager.PolarError.notConnected
            }

            let deviceName = manager.connectedDeviceType?.displayName ?? "device"

            // Verity Sense: read-only fetch (no stop — recording stays on device)
            if manager.connectedDeviceType == .veritySense {
                return try await stopAndFetchVeritySense(deviceName: deviceName)
            }

            // H10 path below
            return try await stopAndFetchH10(api: api, deviceId: deviceId, deviceName: deviceName)
        #else
            throw PolarManager.PolarError.sdkNotAvailable
        #endif
    }

    /// Stop an active offline PPI recording on the Verity Sense.
    /// Must be called before fetching data from an active recording —
    /// `listOfflineRecordings` only returns completed recordings.
    func stopOfflinePpiRecording() async throws {
        #if canImport(PolarBleSdk)
            guard let api = manager.strapAPI, let deviceId = manager.connectedDeviceId else {
                throw PolarManager.PolarError.notConnected
            }
            guard manager.isOfflineRecordingReady else {
                throw PolarManager.PolarError.recordingFailed("Offline recording feature not ready")
            }
            debugLog("[PolarManager] Stopping active offline PPI recording on Verity Sense...")
            try await api.sdk.stopOfflineRecording(deviceId, feature: .ppi)
            await MainActor.run {
                manager.isRecordingOnDevice = false
                manager.recordingState = .idle
            }
            debugLog("[PolarManager] ✅ Stopped offline PPI recording")
        #else
            throw PolarManager.PolarError.sdkNotAvailable
        #endif
    }

    /// Verity Sense stop-and-fetch: stop active recording if needed, download, retry/reconnect
    func stopAndFetchVeritySense(deviceName: String) async throws -> [RRPoint] {
        #if canImport(PolarBleSdk)
            manager.fetchCancelled = false
            await stopActiveVeritySenseRecordingIfNeeded(deviceName: deviceName)
            return try await retryWithReconnect(
                deviceName: deviceName,
                progressBase: 0.35,
                readyCheck: { [weak manager] in manager?.isOfflineRecordingReady ?? false },
                operation: { [self] attempt, maxAttempts in
                    try await downloadOfflinePpi(deviceName: deviceName, attempt: attempt, maxAttempts: maxAttempts)
                }
            )
        #else
            throw PolarManager.PolarError.sdkNotAvailable
        #endif
    }

    #if canImport(PolarBleSdk)
        /// If the Verity Sense has an active recording, stop it so it becomes
        /// a completed recording that `listOfflineRecordings` can find.
        private func stopActiveVeritySenseRecordingIfNeeded(deviceName: String) async {
            guard manager.isRecordingOnDevice else { return }
            await manager.updateProgress(.stopping, progress: 0.05, message: "Stopping recording on \(deviceName)...")
            do {
                try await stopOfflinePpiRecording()
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                debugLog("[PolarManager] ⚠️ Could not stop active recording: \(error) — attempting fetch anyway")
            }
        }
    #endif

    #if canImport(PolarBleSdk)
        private func downloadOfflinePpi(deviceName: String, attempt: Int, maxAttempts: Int) async throws -> [RRPoint] {
            await manager.updateProgress(.fetchingData, progress: 0.2, attempt: attempt, maxAttempts: maxAttempts, message: "Downloading from \(deviceName)...")
            let rrPoints = try await fetchOfflinePpiRecording()
            await manager.updateProgress(.complete, progress: 1.0, attempt: attempt, maxAttempts: maxAttempts, message: "Downloaded \(rrPoints.count) heartbeats!")
            await MainActor.run { manager.recordingState = .idle }
            await manager.sleepIgnoringCancellation(500_000_000, context: "Verity Sense fetch completion UI delay")
            await MainActor.run { self.manager.fetchProgress = nil }
            debugLog("[PolarManager] Fetched \(rrPoints.count) RR points from \(deviceName)")
            return rrPoints
        }
    #endif

    /// H10 stop-and-fetch: stop recording, then download with retry/reconnect
    func stopAndFetchH10(api: StrapAPI, deviceId: String, deviceName: String) async throws -> [RRPoint] {
        manager.fetchCancelled = false
        await manager.updateProgress(.stopping, progress: 0.05, message: "Checking recording status...")
        let status = try await h10RecordingStatus(api: api, deviceId: deviceId)
        if status.ongoing {
            try await stopAndAwaitH10Finalize(api: api, deviceId: deviceId, deviceName: deviceName)
        } else {
            await manager.updateProgress(.listingExercises, progress: 0.35, message: "Recording already stopped")
        }
        await MainActor.run { manager.recordingState = .fetching }
        return try await retryWithReconnect(
            deviceName: deviceName,
            progressBase: 0.35,
            readyCheck: { [weak manager] in manager?.isH10RecordingFeatureReady ?? false },
            operation: { [self] attempt, maxAttempts in
                try await downloadH10Exercise(
                    api: api, deviceId: deviceId, deviceName: deviceName,
                    attempt: attempt, maxAttempts: maxAttempts
                )
            }
        )
    }

    func h10RecordingStatus(api: StrapAPI, deviceId: String) async throws -> PolarRecordingStatus {
        try await api.sdk.requestRecordingStatus(deviceId)
    }

    /// Stop the active recording and give the H10 ~1.5 s to flush its file,
    /// stepping the progress bar so the wait reads as work rather than a stall.
    private func stopAndAwaitH10Finalize(api: StrapAPI, deviceId: String, deviceName: String) async throws {
        await MainActor.run { manager.recordingState = .stopping }
        await manager.updateProgress(.stopping, progress: 0.1, message: "Stopping \(deviceName) recording...")
        try await api.sdk.stopRecording(deviceId)
        debugLog("[PolarManager] Recording stopped, waiting for \(deviceName) to finalize...")
        await manager.updateProgress(.finalizing, progress: 0.2, message: "\(deviceName) is saving data...")
        for i in 1 ... 15 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let prog = 0.2 + (Double(i) / 15.0) * 0.15
            await manager.updateProgress(.finalizing, progress: prog, message: "\(deviceName) is saving data...")
        }
    }

    private func downloadH10Exercise(
        api: StrapAPI,
        deviceId: String,
        deviceName: String,
        attempt: Int,
        maxAttempts: Int
    ) async throws -> [RRPoint] {
        await manager.updateProgress(.listingExercises, progress: 0.4, attempt: attempt, maxAttempts: maxAttempts, message: "Searching for data on \(deviceName)...")
        let rrPoints = try await fetchExerciseDataWithProgress(api: api, deviceId: deviceId, attempt: attempt, maxAttempts: maxAttempts)
        await manager.updateProgress(.complete, progress: 1.0, attempt: attempt, maxAttempts: maxAttempts, message: "Downloaded \(rrPoints.count) heartbeats!")
        await MainActor.run {
            manager.recordingState = .idle
            manager.isRecordingOnDevice = false
        }
        await manager.sleepIgnoringCancellation(500_000_000, context: "H10 fetch completion UI delay")
        await MainActor.run { self.manager.fetchProgress = nil }
        debugLog("[PolarManager] Fetched \(rrPoints.count) RR points from \(deviceName) (pending clear)")
        return rrPoints
    }

    /// Quick single-attempt device fetch with timeout — used by morning processing flow.
    /// Returns points on success, nil on failure. No retries, no reconnect dance.
    /// `stopAndFetchRecording()` with its 5-retry logic handles manual recovery.
    /// For H10: stops recording, then retries the download with BLE reconnect on failure.
    /// For Verity Sense: single attempt with safety timeout.
    /// Returns nil on failure — caller falls back to streaming data.
    /// `isRecordingOnDevice` is the app's memory of the strap, not the strap:
    /// a Bluetooth power-off clears it and nothing restores it when the link
    /// comes back. The H10 keeps its exercise file either way, so a connected
    /// strap is always worth asking; the stop step is a no-op when nothing is
    /// ongoing.
    private func noteQuickFetchRecordingFlag() {
        guard !manager.isRecordingOnDevice else { return }
        debugLog("[PolarManager] Quick fetch: recording flag is off — asking the strap for a stored exercise anyway", level: .warning)
    }

    func fetchExerciseDataQuick() async -> [RRPoint]? {
        #if canImport(PolarBleSdk)
            let decision = StrapRecordingPolicy.quickFetchDecision(
                hasAPI: manager.strapAPI != nil, hasDeviceId: manager.connectedDeviceId != nil,
                isRecordingOnDevice: manager.isRecordingOnDevice, deviceType: manager.connectedDeviceType
            )
            guard let api = manager.strapAPI, let deviceId = manager.connectedDeviceId, decision != .notConnected else {
                debugLog("[PolarManager] Quick fetch: not connected", level: .warning)
                return nil
            }
            noteQuickFetchRecordingFlag()
            manager.fetchCancelled = false
            switch decision {
            case .fetchVeritySense: return await fetchQuickVeritySense()
            case .skipVeritySenseNotRecording, .notConnected: return nil
            case .fetchH10: return await fetchQuickH10(api: api, deviceId: deviceId)
            }
        #else
            return nil
        #endif
    }

    #if canImport(PolarBleSdk)
        /// H10 quick fetch: stop + finalize, then download, each under its own
        /// hard timeout. A timeout returns nil so the caller scores the streamed
        /// night instead of hanging.
        private func fetchQuickH10(api: StrapAPI, deviceId: String) async -> [RRPoint]? {
            debugLog("[PolarManager] Quick fetch: H10 (stop → wait for finalize → download)...")
            do {
                try await stopH10WithHardTimeout(api: api, deviceId: deviceId)
                return try await downloadH10WithHardTimeout(api: api, deviceId: deviceId)
            } catch {
                debugLogExternal("H10 didn't finalize its internal recording in time — \(error). Using the live stream instead (no data lost).", cause: .strap)
                await MainActor.run { manager.recordingState = .idle }
                return nil
            }
        }
    #endif

    #if canImport(PolarBleSdk)
        /// Split the timing so a real morning log proves where the wait
        /// goes: stopping+finalizing the active recording vs the actual
        /// download. (Manual "recover" of the SAME full night is <10s
        /// because it reads an ALREADY-finalized file and never stops.)
        ///
        /// HARD timeouts on the BLE phases. When the strap
        /// connection goes stale (iOS still reports it "connected" but the
        /// H10 has stopped answering), the SDK's Rx continuations for
        /// `requestRecordingStatus`/`stopRecording`/`fetchExercise` never
        /// fire; without a bound the ENTIRE morning hangs and the user
        /// force-quits — a field log showed "Quick fetch: H10…"
        /// then dead silence until a relaunch five minutes later. The Verity path
        /// (fetchQuickVeritySense) has the same cap.
        /// The STOP phase is capped short so a dead connection falls back
        /// to the streamed night in seconds; 45s covers a legit slow
        /// `stopRecording` (H10 flushing an 8h file to flash) plus the ~15s
        /// finalize poll. A thrown timeout drops to the caller's `catch` →
        /// returns nil → the caller scores the streamed night instead of hanging.
        private func stopH10WithHardTimeout(api: StrapAPI, deviceId: String) async throws {
            let tStop = Date()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.stopH10RecordingQuick(api: api, deviceId: deviceId, waitForFinalize: true) }
                group.addTask {
                    try await Task.sleep(nanoseconds: 45_000_000_000) // 45s
                    throw PolarManager.PolarError.fetchFailed("H10 stop/finalize timed out after 45s (strap unresponsive)")
                }
                _ = try await group.next()
                group.cancelAll()
            }
            debugLog("[MorningTiming] H10 stop+finalize: \(Int(Date().timeIntervalSince(tStop) * 1000))ms")
        }

        /// The DOWNLOAD phase is capped generously so a genuine full-night
        /// transfer (1-2 min over BLE) isn't cut off.
        private func downloadH10WithHardTimeout(api: StrapAPI, deviceId: String) async throws -> [RRPoint]? {
            let tDownload = Date()
            let pts: [RRPoint]? = try await withThrowingTaskGroup(of: [RRPoint]?.self) { group in
                group.addTask { await self.fetchH10WithRetries(api: api, deviceId: deviceId) }
                group.addTask {
                    try await Task.sleep(nanoseconds: 120_000_000_000) // 120s
                    throw PolarManager.PolarError.fetchFailed("H10 download timed out after 120s")
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
            debugLog("[MorningTiming] H10 download: \(Int(Date().timeIntervalSince(tDownload) * 1000))ms (beats=\(pts?.count ?? -1))")
            return pts
        }
    #endif

    /// Stop the H10's in-progress internal recording RIGHT NOW, without
    /// downloading. Fast (a BLE stop + ~0.3s finalize). Call this inline the
    /// moment a session (workout OR overnight) ends so the strap can't keep
    /// recording off-body afterward — otherwise the recording runs for hours,
    /// produces garbage, and a later `checkRecordingStatus` reads
    /// `status.ongoing == true`, blocking the next session ("strap used by
    /// another session"). Field logs 2026-06/07 showed EVERY high-streaming-
    /// density workout leaving the H10 recording because the workout finalize
    /// skipped the fetch (which was the only thing that stopped it).
    ///
    /// Deliberately does NOT clear `manager.isRecordingOnDevice`: a caller that still
    /// wants the finalized file can `fetchExerciseDataQuick` after (it guards
    /// on that flag). The flag is corrected from the device on the next status
    /// check. No-op for Verity (can't record while streaming) and when nothing
    /// is recording.
    func stopDeviceRecordingIfNeeded() async {
        #if canImport(PolarBleSdk)
            guard StrapRecordingPolicy.shouldStopDeviceRecording(
                deviceType: manager.connectedDeviceType,
                hasAPI: manager.strapAPI != nil,
                hasDeviceId: manager.connectedDeviceId != nil,
                isRecordingOnDevice: manager.isRecordingOnDevice
            ) else { return }
            guard let api = manager.strapAPI, let deviceId = manager.connectedDeviceId else { return }
            do {
                // Inline stop only — no download follows, so don't block on the
                // file finalizing (that ~61s wait was the "workout takes 2 min to
                // save" bug on high-streaming-density sessions).
                try await stopH10RecordingQuick(api: api, deviceId: deviceId, waitForFinalize: false)
                debugLog("[PolarManager] H10 internal recording stopped inline at session end")
            } catch {
                debugLogExternal("H10 didn't confirm the inline recording stop — \(error). The strap stops on its own; no data affected.", cause: .strap)
            }
        #endif
    }
}
