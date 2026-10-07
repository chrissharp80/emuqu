import CoreBluetooth
import Foundation

#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

extension StrapRecordingCoordinator {
    // MARK: - Recording Control (H10 Internal Memory)

    /// Start internal recording on the connected device.
    /// H10: exercise recording. Verity Sense: offline PPI recording.
    /// Both survive BLE disconnect and app backgrounding. `stillWanted` is
    /// asked again before each destructive step, so a session that ended
    /// meanwhile never has the strap cleared or started under it.
    func startRecording(while stillWanted: () -> Bool = { true }) async throws {
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
            case .startVeritySense: try await startVeritySenseRecording(while: stillWanted)
            case .startH10: try await startH10Recording(while: stillWanted)
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
    ///
    /// Arming never runs while the session that wants it is ending or while
    /// another transfer is using the strap (`requireArmingAllowed`): in a
    /// field log the morning stop woke the arming loop, which cleared and
    /// started the strap during the morning download.
    func startFreshRecording(while stillWanted: () -> Bool = { true }) async throws {
        try requireArmingAllowed(stillWanted)
        if await deviceIsRecording() {
            beginTransfer()
            let stale = try await fetchRecording(recordedSince: nil, budget: .attended)
            if !stale.points.isEmpty { manager.onUnrecoveredDataRescued?(stale) }
        }
        try await startRecording(while: stillWanted)
    }

    /// Throws `CancellationError` when the session no longer wants the strap
    /// armed, the task was cancelled, or a transfer is using the strap.
    func requireArmingAllowed(_ stillWanted: () -> Bool) throws {
        guard stillWanted(), !Task.isCancelled, manager.transfersInFlight == 0 else {
            debugLog("[PolarManager] Arming withdrawn: the session is ending or a transfer is using the strap")
            throw CancellationError()
        }
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
        private func startVeritySenseRecording(while stillWanted: () -> Bool) async throws {
            try manager.link.requireUsable(.offlineRecording)
            manager.recordingState = .starting
            var rescued = true
            for step in StrapStartSequence.steps(for: .veritySense) {
                try requireArmingAllowed(stillWanted)
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
                let existing = try await fetchOfflinePpiRecording(requireEveryEntry: true)
                guard !existing.points.isEmpty else { return true }
                debugLog("[PolarManager] Found \(existing.points.count) unrecovered PPI points on \(deviceLabel) — rescuing before clear")
                manager.onUnrecoveredDataRescued?(existing)
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

        /// Rescue, clear, begin (`StrapStartSequence`). The clear deletes
        /// every stored exercise, so each one the app does not already hold is
        /// downloaded to the rescue backup first; one that cannot be stops
        /// the start rather than be deleted.
        private func startH10Recording(while stillWanted: () -> Bool) async throws {
            try manager.link.requireUsable(.h10Recording)
            for step in StrapStartSequence.steps(for: .h10) {
                try requireArmingAllowed(stillWanted)
                try await runH10StartStep(step)
            }
        }

        private func runH10StartStep(_ step: StrapStartSequence.Step) async throws {
            switch step {
            case .rescueExisting: try await rescueUndownloadedH10Recordings()
            case .clearExisting:
                manager.recordingState = .starting
                await clearExistingTolerantly(label: "exercises")
            case .beginRecording: try await beginH10RecordingSurfacingFailure()
            }
        }

        /// Downloads every stored exercise the app does not hold, each to the
        /// rescue backup. Throws `strapHoldsUndownloadedRecording` when one
        /// cannot be downloaded.
        private func rescueUndownloadedH10Recordings() async throws {
            guard let api = manager.strapAPI, let deviceId = manager.connectedDeviceId else { throw PolarManager.PolarError.notConnected }
            for entryId in try await unsavedExerciseIds(api: api, deviceId: deviceId) {
                debugLog("[PolarManager] Stored exercise \(entryId) was never downloaded — rescuing it before the clear")
                beginTransfer()
                do {
                    let rescued = try await fetchRecording(exerciseId: entryId, budget: .attended)
                    manager.onUnrecoveredDataRescued?(rescued)
                } catch {
                    debugLogExternal("Couldn't download a recording the strap holds — \(error). Its own recording was not started, which would have deleted it.", cause: .strap)
                    throw PolarManager.PolarError.strapHoldsUndownloadedRecording
                }
            }
        }

        /// Stored exercises the app does not hold. One this app did not file
        /// cannot be dated or looked up, so it counts as not held.
        private func unsavedExerciseIds(api: any StrapRadio, deviceId: String) async throws -> [String] {
            try await listStoredExercises(api: api, deviceId: deviceId).compactMap { entry in
                let start = StrapExerciseDecoder.recordingStart(fromExerciseId: entry.entryId)
                return start.map { manager.isRecordingSaved(startedAt: $0) } == true ? nil : entry.entryId
            }
        }

        private func beginH10RecordingSurfacingFailure() async throws {
            do {
                try await beginH10ExerciseRecording()
            } catch {
                throw await surfaceH10StartFailure(error)
            }
        }

        private func beginH10ExerciseRecording() async throws {
            guard let api = manager.strapAPI, let deviceId = manager.connectedDeviceId else { throw PolarManager.PolarError.notConnected }
            let exerciseId = StrapExerciseDecoder.exerciseId()
            debugLog("[PolarManager] Starting \(deviceLabel) internal recording with exerciseId: \(exerciseId)")
            try await api.startRecording(deviceId, exerciseId: exerciseId, interval: .interval_1s, sampleType: .rr)
            manager.recordingState = .recording
            manager.isRecordingOnDevice = true
            debugLog("[PolarManager] Started \(deviceLabel) internal RR recording successfully")
        }

        /// Humanise raw Polar SDK errors before they surface to the user via
        /// `manager.lastError`. Without this the alert showed e.g. "Recording failed:
        /// PolarBleSdk.PolarErrors error 3." (real tester report). A refusal for
        /// a low battery becomes `strapBatteryTooLow`, which callers act on.
        private func surfaceH10StartFailure(_ error: Error) async -> Error {
            debugLog("[PolarManager] ERROR starting recording: \(error)")
            manager.recordingState = .idle
            guard Self.isBatteryTooLow(error) else {
                manager.lastError = PolarManager.PolarError.recordingFailed(PolarErrorMessages.humanizeStartFailure(error))
                return error
            }
            let refusal = PolarManager.PolarError.strapBatteryTooLow(percent: manager.batteryLevel)
            manager.lastError = refusal
            return refusal
        }

        /// Polar PFTP `BATTERY_TOO_LOW` (209 in the SDK's `pftp_error.proto`):
        /// the strap will not record to its own memory on this battery.
        nonisolated static func isBatteryTooLow(_ error: Error) -> Bool {
            guard case let BlePsFtpException.responseError(errorCode: code) = error else { return false }
            return Protocol_PbPFtpError(rawValue: code) == .batteryTooLow
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
            applyStatus(ongoing: status.ongoing)
            debugLog("[PolarManager] H10 recording status: ongoing=\(status.ongoing)")
            return status.ongoing
        #else
            throw PolarManager.PolarError.sdkNotAvailable
        #endif
    }

    #if canImport(PolarBleSdk)
        func veritySenseRecordingStatus(api: any StrapRadio, deviceId: String) async throws -> Bool {
            try manager.link.requireUsable(.offlineRecording)
            // 8.2.0 returns the dictionary directly; the Rx `Single` and its
            // continuation wrapper are gone.
            let status: [PolarDeviceDataType: Bool] = try await api.getOfflineRecordingStatus(deviceId)
            let ppiRecording = status[.ppi] ?? false
            applyStatus(ongoing: ppiRecording)
            debugLog("[PolarManager] Verity Sense offline recording status: PPI=\(ppiRecording)")
            return ppiRecording
        }
    #endif

    /// What the strap said about its own recording, applied to the app's
    /// state through `StrapRecordingPolicy.statusOutcome`.
    func applyStatus(ongoing: Bool) {
        let outcome = StrapRecordingPolicy.statusOutcome(ongoing: ongoing, current: manager.recordingState)
        manager.isRecordingOnDevice = outcome.isRecordingOnDevice
        if let state = outcome.recordingState { manager.recordingState = state }
    }

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
            manager.isRecordingOnDevice = false
            manager.recordingState = .idle
            debugLog("[PolarManager] Stopped offline PPI recording")
        #else
            throw PolarManager.PolarError.sdkNotAvailable
        #endif
    }

    func h10RecordingStatus(api: any StrapRadio, deviceId: String) async throws -> PolarRecordingStatus {
        try await api.requestRecordingStatus(deviceId)
    }

    /// Explicitly discard what the strap holds: a recording still running is
    /// stopped (nothing downloads it), then every stored one is removed.
    /// H10: stored exercises. Verity Sense: offline PPI recordings. The
    /// Record screen's "Discard & Start Fresh".
    func discardStoredExercises() async throws {
        #if canImport(PolarBleSdk)
            guard let api = manager.strapAPI, let deviceId = manager.connectedDeviceId else {
                throw PolarManager.PolarError.notConnected
            }
            let deviceName = manager.connectedDeviceType?.displayName ?? "device"
            debugLog("[PolarManager] User requested discard of stored data on \(deviceName)...")
            try await stopBeforeDiscarding(api: api, deviceId: deviceId)
            try await clearAnyExistingExercises()
            manager.hasStoredExercise = false
            manager.storedExerciseDate = nil
        #else
            throw PolarManager.PolarError.sdkNotAvailable
        #endif
    }

    /// Bounded like every other stop, so a stale link cannot hang Discard.
    private func stopBeforeDiscarding(api: any StrapRadio, deviceId: String) async throws {
        guard manager.isRecordingOnDevice else { return }
        let seconds = StrapRecordingPolicy.TransferBudget.attended.stopSeconds
        try await StrapDeadline.race(
            seconds: seconds, timeout: PolarManager.PolarError.fetchFailed("strap stop timed out after \(seconds)s")
        ) {
            try await self.stopForDiscard(api: api, deviceId: deviceId)
        }
    }

    private func stopForDiscard(api: any StrapRadio, deviceId: String) async throws {
        if manager.connectedDeviceType == .veritySense {
            try await stopOfflinePpiRecording()
        } else {
            _ = try await stopH10Recording(
                api: api, deviceId: deviceId, awaitFinalize: true, showsProgress: false, cancellable: false,
                streamHoldsIt: false
            )
        }
    }
}
