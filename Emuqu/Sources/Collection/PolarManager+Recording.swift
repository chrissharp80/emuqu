import CoreBluetooth
import Foundation
import os

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

    /// Start a recording that holds only the session about to begin.
    ///
    /// A recording still running on the strap belongs to an earlier session
    /// that was never retrieved. It is stopped, and its beats go to the rescue
    /// backup (recoverable from Lost Sessions) rather than being dropped.
    ///
    /// The strap is asked whether it is recording rather than the app's own
    /// flag being trusted: after a relaunch, or a night the app never saw end,
    /// that flag is false while the strap is still writing. Starting on top of
    /// that is refused by the strap, so the night would be neither recorded nor
    /// rescued.
    func startFreshRecording() async throws {
        if await deviceIsRecording() {
            let stale = try await stopAndFetchRecording()
            if !stale.isEmpty { manager.onUnrecoveredDataRescued?(stale) }
        }
        try await startRecording()
    }

    /// What the strap says it is doing, falling back to what the app last knew
    /// when the strap cannot be asked.
    private func deviceIsRecording() async -> Bool {
        do {
            return try await checkRecordingStatus()
        } catch {
            debugLog("[PolarManager] Couldn't read the strap's recording status before arming: \(error)")
            return manager.isRecordingOnDevice
        }
    }

    #if canImport(PolarBleSdk)
        /// The order is `StrapStartSequence`'s, so "rescue before clear" is
        /// asserted by tests rather than held in place by this reading top to
        /// bottom.
        private func startVeritySenseRecording() async throws {
            try manager.link.requireUsable(.offlineRecording)
            await MainActor.run { manager.recordingState = .starting }
            var rescued = true
            for step in StrapStartSequence.steps(for: .veritySense) {
                switch step {
                case .rescueExisting: rescued = await rescueUnrecoveredOfflineRecordings()
                case .clearExisting where rescued: await clearExistingTolerantly(label: "recordings")
                // A night that did not download stays on the strap: deleting
                // it here lost it for good. The new recording starts beside it.
                case .clearExisting: break
                case .beginRecording: try await startOfflinePpiRecording()
                }
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
        /// True when the strap holds nothing that still needs downloading, so
        /// it is safe to clear.
        private func rescueUnrecoveredOfflineRecordings() async -> Bool {
            do {
                let existingPoints = try await fetchOfflinePpiRecording(requireEveryEntry: true)
                guard !existingPoints.isEmpty else { return true }
                debugLog("[PolarManager] ⚠️ Found \(existingPoints.count) unrecovered PPI points on \(deviceLabel) — rescuing before clear")
                manager.onUnrecoveredDataRescued?(existingPoints)
                return true
            } catch PolarManager.PolarError.noRecordingFound {
                // swallow-ok: "no existing data on the strap" is the ordinary case, not a
                // failure — there is nothing to rescue and nothing to report.
                return true
            } catch {
                debugLog("[PolarManager] Warning: Could not rescue existing recordings — leaving them on the strap: \(error)")
                return false
            }
        }

        /// No rescue step: see `StrapStartSequence` for why the H10 warns the
        /// user instead of downloading inline at workout start.
        private func startH10Recording() async throws {
            try manager.link.requireUsable(.h10Recording)
            await MainActor.run { manager.recordingState = .starting }
            for step in StrapStartSequence.steps(for: .h10) {
                try await runH10StartStep(step)
            }
        }

        private func runH10StartStep(_ step: StrapStartSequence.Step) async throws {
            switch step {
            // The H10 sequence has no rescue step, and the rescue reads the
            // Verity's offline PPI store, which an H10 does not have.
            case .rescueExisting: break
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
            try await api.startRecording(deviceId, exerciseId: exerciseId, interval: .interval_1s, sampleType: .rr)
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
                manager.lastError = PolarManager.PolarError.recordingFailed(PolarErrorMessages.humanizeStartFailure(error))
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
            guard manager.link.isUsable(.offlineRecording) else {
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
                try await api.removeExercise(deviceId, entry: entry)
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
        func listOfflinePpiRecordings(api: any StrapRadio, deviceId: String) async throws -> [PolarOfflineRecordingEntry] {
            try await Self.listPpiEntries(api: api, deviceId: deviceId)
        }

        /// Runs off the main actor so the SDK's entry values (not `Sendable`)
        /// stay in one region from listing to removal.
        nonisolated static func listPpiEntries(api: any StrapRadio, deviceId: String) async throws -> [PolarOfflineRecordingEntry] {
            var entries: [PolarOfflineRecordingEntry] = []
            for try await entry in api.listOfflineRecordings(deviceId) {
                entries.append(entry)
            }
            return StrapOfflineRecordingEntries.onePerRecording(entries.filter { $0.type == .ppi }, path: \.path)
        }

        /// Lists and removes every offline PPI recording; returns the count removed.
        nonisolated static func removeOfflinePpiRecordings(api: any StrapRadio, deviceId: String) async throws -> Int {
            let entries = try await listPpiEntries(api: api, deviceId: deviceId)
            for entry in entries {
                debugLog("[PolarManager] Removing offline PPI recording: \(entry.date)")
                try await api.removeOfflineRecord(deviceId, entry: entry)
            }
            return entries.count
        }

        /// Every exercise currently stored on an H10.
        func listStoredExercises(api: any StrapRadio, deviceId: String) async throws -> [PolarExerciseEntry] {
            var entries: [PolarExerciseEntry] = []
            for try await entry in api.listExercises(deviceId) {
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
        private func veritySenseRecordingStatus(api: any StrapRadio, deviceId: String) async throws -> Bool {
            try manager.link.requireUsable(.offlineRecording)
            // 8.2.0 returns the dictionary directly; the Rx `Single` and its
            // continuation wrapper are gone.
            let status: [PolarDeviceDataType: Bool] = try await api.getOfflineRecordingStatus(deviceId)
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
        private func checkStoredOfflineRecordings(api: any StrapRadio, deviceId: String) async {
            guard manager.link.isUsable(.offlineRecording) else {
                debugLog("[PolarManager] Offline recording feature not ready — cannot check for stored recordings")
                return
            }
            do {
                let ppiRecordings = try await listOfflinePpiRecordings(api: api, deviceId: deviceId)
                let recordingDate = ppiRecordings.map(\.date).min()
                debugLog("[PolarManager] Found \(ppiRecordings.count) offline PPI recording(s) on Verity Sense, date: \(recordingDate?.description ?? "none")")
                manager.hasStoredExercise = !ppiRecordings.isEmpty
                manager.storedExerciseDate = recordingDate
            } catch {
                debugLog("[PolarManager] Error checking Verity Sense offline recordings: \(error)")
                manager.hasStoredExercise = false
                manager.storedExerciseDate = nil
            }
        }

        private func checkStoredH10Exercises(api: any StrapRadio, deviceId: String) async {
            do {
                let entries = try await listStoredExercises(api: api, deviceId: deviceId)
                // The SDK dates an H10 entry when it is listed; the start time
                // lives in the id this app filed it under.
                let newest = StrapExerciseDecoder.newestRecording(entries, exerciseId: \.entryId, notBefore: nil)
                let exerciseDate = newest.flatMap { StrapExerciseDecoder.recordingStart(fromExerciseId: $0.entryId) }
                debugLog("[PolarManager] Found \(entries.count) stored exercise(s) on H10, started: \(exerciseDate?.description ?? "unknown")")
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

            // Verity Sense: stop the active recording if one is running, then
            // download its offline PPI files.
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
            try manager.link.requireUsable(.offlineRecording)
            debugLog("[PolarManager] Stopping active offline PPI recording on Verity Sense...")
            try await api.stopOfflineRecording(deviceId, feature: .ppi)
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
                feature: .offlineRecording,
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
    func stopAndFetchH10(api: any StrapRadio, deviceId: String, deviceName: String) async throws -> [RRPoint] {
        manager.fetchCancelled = false
        try await stopH10IfRecording(api: api, deviceId: deviceId, deviceName: deviceName)
        await MainActor.run { manager.recordingState = .fetching }
        return try await retryWithReconnect(
            deviceName: deviceName,
            progressBase: 0.35,
            feature: .h10Recording,
            operation: { [self] attempt, maxAttempts in
                try await downloadH10Exercise(
                    api: api, deviceId: deviceId, deviceName: deviceName,
                    attempt: attempt, maxAttempts: maxAttempts
                )
            }
        )
    }

    private func stopH10IfRecording(api: any StrapRadio, deviceId: String, deviceName: String) async throws {
        await manager.updateProgress(.stopping, progress: 0.05, message: "Checking recording status...")
        let status = try await manager.link.whenFeatureUsable(
            .h10Recording, until: Date().addingTimeInterval(StrapRecordingPolicy.featureReadyWindowSeconds)
        ) {
            try await h10RecordingStatus(api: api, deviceId: deviceId)
        }
        guard status.ongoing else {
            await manager.updateProgress(.listingExercises, progress: 0.35, message: "Recording already stopped")
            return
        }
        try await stopAndAwaitH10Finalize(api: api, deviceId: deviceId, deviceName: deviceName)
    }

    func h10RecordingStatus(api: any StrapRadio, deviceId: String) async throws -> PolarRecordingStatus {
        try await api.requestRecordingStatus(deviceId)
    }

    /// Stop the active recording and wait until the H10 lists the finalized
    /// file (`awaitH10FileFinalize`, as the quick path does) rather than for a
    /// fixed pause, which an 8-hour file outlasts.
    private func stopAndAwaitH10Finalize(api: any StrapRadio, deviceId: String, deviceName: String) async throws {
        await MainActor.run { manager.recordingState = .stopping }
        await manager.updateProgress(.stopping, progress: 0.1, message: "Stopping \(deviceName) recording...")
        try await api.stopRecording(deviceId)
        debugLog("[PolarManager] Recording stopped, waiting for \(deviceName) to finalize...")
        await manager.updateProgress(.finalizing, progress: 0.2, message: "\(deviceName) is saving data...")
        await awaitH10FileFinalize(api: api, deviceId: deviceId)
        await manager.updateProgress(.finalizing, progress: 0.35, message: "\(deviceName) is saving data...")
    }

    private func downloadH10Exercise(
        api: any StrapRadio,
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

    /// The morning download of the strap's own recording, bounded so a stale
    /// link cannot hang the morning. Returns nil on failure — the caller
    /// scores the live stream.
    ///
    /// An H10 is always asked when connected: `isRecordingOnDevice` is the
    /// app's memory of the strap, and the strap keeps its file whether or not
    /// the app remembers starting it. What keeps an old file from being scored
    /// as tonight's is `recordedSince`: only a recording that started at or
    /// after it is downloaded.
    func fetchExerciseDataQuick(recordedSince: Date?) async -> [RRPoint]? {
        #if canImport(PolarBleSdk)
            let decision = StrapRecordingPolicy.quickFetchDecision(
                hasAPI: manager.strapAPI != nil, hasDeviceId: manager.connectedDeviceId != nil,
                isRecordingOnDevice: manager.isRecordingOnDevice, deviceType: manager.connectedDeviceType
            )
            guard let api = manager.strapAPI, let deviceId = manager.connectedDeviceId, decision != .notConnected else {
                debugLog("[PolarManager] Quick fetch: not connected", level: .warning)
                return nil
            }
            manager.fetchCancelled = false
            switch decision {
            case .fetchVeritySense: return await fetchQuickVeritySense(recordedSince: recordedSince)
            case .skipVeritySenseNotRecording, .notConnected: return nil
            case .fetchH10: return await fetchQuickH10(api: api, deviceId: deviceId, recordedSince: recordedSince)
            }
        #else
            return nil
        #endif
    }

    #if canImport(PolarBleSdk)
        /// H10 quick fetch: stop + finalize, then download, each under its own
        /// hard timeout. The stop waits for the recording feature first: the
        /// morning fetch often runs moments after a reconnect, before the strap
        /// has set its file transfer up, and a stop sent then is refused.
        private func fetchQuickH10(api: any StrapRadio, deviceId: String, recordedSince: Date?) async -> [RRPoint]? {
            debugLog("[PolarManager] Quick fetch: H10 (stop → wait for finalize → download)...")
            do {
                try await manager.link.whenFeatureUsable(
                    .h10Recording,
                    until: Date().addingTimeInterval(StrapRecordingPolicy.featureReadyWindowSeconds),
                    while: { !manager.fetchCancelled },
                    perform: {
                        try await stopH10WithHardTimeout(api: api, deviceId: deviceId)
                    }
                )
                return try await downloadH10WithHardTimeout(api: api, deviceId: deviceId, recordedSince: recordedSince)
            } catch {
                reportQuickFetchFailure(error)
                await MainActor.run { manager.recordingState = .idle }
                return nil
            }
        }

        /// Say what actually failed, and never promise the night is safe: a
        /// fallback message must not make a claim the fallback cannot verify.
        private func reportQuickFetchFailure(_ error: Error) {
            let stillOnStrap = manager.isRecordingOnDevice || manager.hasStoredExercise
            let tail = stillOnStrap
                ? "The strap still holds its own copy — recover it from the Record screen before starting anything new, which clears it."
                : "Scoring the live stream instead."
            debugLogExternal(
                "Couldn't read the H10's internal recording — \(error). \(tail)",
                cause: .strap
            )
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
        /// `StrapDeadline` returns at the deadline even when the SDK call never
        /// answers (a task group would wait for it).
        private func stopH10WithHardTimeout(api: any StrapRadio, deviceId: String) async throws {
            let tStop = Date()
            try await StrapDeadline.race(
                seconds: 45,
                timeout: PolarManager.PolarError.fetchFailed("H10 stop/finalize timed out after 45s (strap unresponsive)")
            ) {
                try await self.stopH10RecordingQuick(api: api, deviceId: deviceId, waitForFinalize: true)
            }
            debugLog("[MorningTiming] H10 stop+finalize: \(Int(Date().timeIntervalSince(tStop) * 1000))ms")
        }

        /// The DOWNLOAD phase is capped generously so a genuine full-night
        /// transfer (1-2 min over BLE) isn't cut off.
        private func downloadH10WithHardTimeout(api: any StrapRadio, deviceId: String, recordedSince: Date?) async throws -> [RRPoint]? {
            let tDownload = Date()
            let pts: [RRPoint]? = try await StrapDeadline.race(
                seconds: 120,
                timeout: PolarManager.PolarError.fetchFailed("H10 download timed out after 120s")
            ) {
                await self.fetchH10WithRetries(api: api, deviceId: deviceId, recordedSince: recordedSince)
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

/// A hard wall clock for strap calls. `withThrowingTaskGroup` cannot provide
/// one: a group waits for every child, even after the timeout child throws
/// and `cancelAll()` runs, so an SDK call whose continuation never fires (a
/// stale BLE link) still hangs the caller. Here the call runs in its own
/// task and the caller resumes at whichever comes first, the result or the
/// deadline. At the deadline the call's task is cancelled, and its result,
/// if one still arrives, is ignored. Cancellation is cooperative: the call
/// stops at its next cancellation check (the quick-fetch retry loop checks
/// before every attempt and before writing any strap state).
enum StrapDeadline {
    static func race<T: Sendable>(
        seconds: UInt64,
        timeout: Error,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let work = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                let finish = ResumeOnce(continuation)
                keep(start(operation, seconds: seconds, timeout: timeout, finish: finish, work: work), in: work)
            }
        } onCancel: {
            work.withLock { $0?.cancel() }
        }
    }

    private static func keep(_ call: Task<Void, Never>, in work: OSAllocatedUnfairLock<Task<Void, Never>?>) {
        work.withLock { $0 = call }
    }

    /// Starts the clock and the call; returns the call so a cancelled caller
    /// can cancel it.
    private static func start<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T,
        seconds: UInt64,
        timeout: Error,
        finish: ResumeOnce<T>,
        work: OSAllocatedUnfairLock<Task<Void, Never>?>
    ) -> Task<Void, Never> {
        let clock = Task { await expire(after: seconds, finish: finish, with: timeout, work: work) }
        return Task { await run(operation, finish: finish, clock: clock) }
    }

    /// Fails the race at the deadline and cancels the call, unless the call
    /// already finished and cancelled the clock.
    private static func expire<T: Sendable>(
        after seconds: UInt64,
        finish: ResumeOnce<T>,
        with timeout: Error,
        work: OSAllocatedUnfairLock<Task<Void, Never>?>
    ) async {
        do {
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        } catch {
            return // swallow-ok: the call finished first and cancelled the clock
        }
        finish(.failure(timeout))
        work.withLock { $0?.cancel() }
    }

    private static func run<T: Sendable>(
        _ operation: @Sendable () async throws -> T,
        finish: ResumeOnce<T>,
        clock: Task<Void, Never>
    ) async {
        do {
            let value = try await operation()
            finish(.success(value))
        } catch {
            finish(.failure(error))
        }
        clock.cancel()
    }
}

/// Resumes a continuation with the first result it is given; later ones are
/// dropped.
private final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation: CheckedContinuation<T, Error>
    private let resumed = OSAllocatedUnfairLock(initialState: false)

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func callAsFunction(_ result: Result<T, Error>) {
        let first = resumed.withLock { (done: inout Bool) -> Bool in
            let wasFirst = !done
            done = true
            return wasFirst
        }
        if first { continuation.resume(with: result) }
    }
}
