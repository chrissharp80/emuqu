import Foundation
#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

// Verity Sense offline-PPI recording and the reconnect-retry wrapper, split out
// of `PolarManager+Recording.swift`. The H10 and the Verity Sense
// have genuinely different offline models — the H10 records RR to internal
// memory while streaming, the Verity cannot do both — so the two paths share a
// file but no logic.

extension StrapRecordingCoordinator {
    // MARK: - Verity Sense Offline PPI Recording (Backup for overnight)

    /// Start offline PPI recording on Verity Sense device memory
    /// Analogous to H10's startRecording() - survives BLE disconnects
    func startOfflinePpiRecording() async throws {
        #if canImport(PolarBleSdk)
            guard let api = manager.strapAPI, let deviceId = manager.connectedDeviceId, manager.connectionState == .connected else {
                throw PolarManager.PolarError.notConnected
            }
            guard manager.isOfflineRecordingReady else {
                throw PolarManager.PolarError.recordingFailed("Offline recording feature not ready - wait a moment after connecting")
            }
            try await armOfflinePpiRecording(api: api, deviceId: deviceId)
        #else
            throw PolarManager.PolarError.sdkNotAvailable
        #endif
    }

    #if canImport(PolarBleSdk)
        private func armOfflinePpiRecording(api: StrapAPI, deviceId: String) async throws {
            await MainActor.run { manager.recordingState = .starting }
            do {
                try await api.sdk.startOfflineRecording(deviceId, feature: .ppi, settings: nil, secret: nil)
            } catch {
                await surfaceOfflineRecordingStartFailure(error)
                throw error
            }
            await MainActor.run {
                manager.recordingState = .recording
                manager.isRecordingOnDevice = true
            }
            debugLog("[PolarManager] Started Verity Sense offline PPI recording")
        }
    #endif

    #if canImport(PolarBleSdk)
        /// Humanise the Polar SDK error string so the `recordingFailed` alert
        /// reads naturally instead of leaking the SDK enum text. (Mirrors the
        /// same humanise pass on the H10 recording-start failure path in
        /// `PolarManager+Recording`.)
        private func surfaceOfflineRecordingStartFailure(_ error: Error) async {
            debugLog("[PolarManager] ERROR starting offline PPI recording: \(error)")
            await MainActor.run {
                manager.recordingState = .idle
                manager.lastError = PolarManager.PolarError.recordingFailed(PolarErrorMessages.humanize(error))
            }
        }
    #endif

    /// Fetch offline PPI data from Verity Sense without stopping the recording or
    /// deleting the data. The recording stays on the device until the user explicitly
    /// clears it (via discardPendingExercise or the next recording cycle).
    func fetchOfflinePpiRecording() async throws -> [RRPoint] {
        #if canImport(PolarBleSdk)
            guard let api = manager.strapAPI, let deviceId = manager.connectedDeviceId else { throw PolarManager.PolarError.notConnected }
            await MainActor.run { manager.recordingState = .fetching }
            let (found, allPoints) = try await Self.readAllOfflinePpi(api: api, deviceId: deviceId)
            debugLog("[PolarManager] Found \(found) PPI recordings on device")
            guard found > 0 else {
                await MainActor.run { manager.recordingState = .idle }
                throw PolarManager.PolarError.noRecordingFound
            }
            await MainActor.run { manager.recordingState = .idle }
            debugLog("[PolarManager] Total offline PPI points after quality filtering: \(allPoints.count)")
            return allPoints
        #else
            throw PolarManager.PolarError.sdkNotAvailable
        #endif
    }

    #if canImport(PolarBleSdk)
        /// Read one stored recording (read-only — no stop, no delete). A failure
        /// on a single entry is logged and skipped so one bad file can't lose the
        /// rest of the night.
        /// Lists every offline PPI recording and reads each one, all off the
        /// main actor so the SDK's entry values never cross isolation.
        nonisolated static func readAllOfflinePpi(api: StrapAPI, deviceId: String) async throws -> (count: Int, points: [RRPoint]) {
            let entries = try await listPpiEntries(api: api, deviceId: deviceId)
            var allPoints: [RRPoint] = []
            for entry in entries {
                allPoints.append(contentsOf: await readOfflinePpiEntry(api: api, deviceId: deviceId, entry: entry))
            }
            return (entries.count, allPoints)
        }

        nonisolated private static func readOfflinePpiEntry(
            api: StrapAPI,
            deviceId: String,
            entry: PolarOfflineRecordingEntry
        ) async -> [RRPoint] {
            do {
                let data = try await fetchOfflineRecord(api: api, deviceId: deviceId, entry: entry)
                let points = convertOfflinePpiToRRPoints(data)
                debugLog("[PolarManager] Fetched offline PPI recording: \(points.count) quality-filtered points")
                return points
            } catch {
                debugLog("[PolarManager] Error fetching offline recording: \(error)")
                return []
            }
        }

        nonisolated private static func fetchOfflineRecord(
            api: StrapAPI,
            deviceId: String,
            entry: PolarOfflineRecordingEntry
        ) async throws -> PolarOfflineRecordingData {
            try await api.sdk.getOfflineRecord(deviceId, entry: entry, secret: nil)
        }
    #endif

    #if canImport(PolarBleSdk)
        /// Convert offline PPI recording data to RRPoints with quality filtering.
        ///
        /// Same quality gates as streaming. RR-interval bounds come from
        /// `HRVThresholds` so this filter doesn't drift out of agreement with
        /// `Verification.checkOutOfBounds`.
        nonisolated static func convertOfflinePpiToRRPoints(_ data: PolarOfflineRecordingData) -> [RRPoint] {
            // PolarOfflineRecordingData is an enum — extract PPI data from the correct case
            guard case let .ppiOfflineRecordingData(ppiData, _) = data else {
                debugLog("[PolarManager] Offline recording data is not PPI type")
                return []
            }
            // Map the SDK's samples onto the app's own boundary type, then let
            // the shared filter decide, rather than restating the
            // three quality gates here with a range read from a different
            // constant than the live stream uses.
            return StrapPPIFilter.rrPoints(from: ppiData.samples.map {
                StrapPPISample(
                    ppInMs: Int($0.ppInMs),
                    ppErrorEstimate: Int($0.ppErrorEstimate),
                    blockerBit: $0.blockerBit
                )
            })
        }
    #endif

    // MARK: - Retry with Reconnect

    /// Shared retry/reconnect logic for all device fetch operations.
    /// The Polar SDK has a known issue with large downloads timing out (GitHub #181).
    /// Community workaround: disconnect/reconnect between retry attempts.
    ///
    /// - Parameters:
    ///   - maxAttempts: Maximum retry count (default 5)
    ///   - deviceName: Display name for progress messages
    ///   - progressBase: Starting progress value for reconnect phase (e.g. 0.35)
    ///   - readyCheck: Closure returning true when device is ready after reconnect
    ///   - operation: The actual fetch operation to retry. Receives (attempt, maxAttempts).
    func retryWithReconnect<T>(
        maxAttempts: Int = 5,
        deviceName: String,
        progressBase: Double = 0.35,
        readyCheck: @escaping () -> Bool,
        operation: (_ attempt: Int, _ maxAttempts: Int) async throws -> T
    ) async throws -> T {
        #if canImport(PolarBleSdk)
            guard let api = manager.strapAPI, let deviceId = manager.connectedDeviceId else { throw PolarManager.PolarError.notConnected }
            var lastError: Error?
            for attempt in 1 ... maxAttempts {
                if manager.fetchCancelled { throw await cancelledFetchError(context: nil) }
                do {
                    return try await operation(attempt, maxAttempts)
                } catch {
                    lastError = error
                    try await handleFetchAttemptFailure(
                        error, link: (api, deviceId), deviceName: deviceName,
                        attempt: attempt, maxAttempts: maxAttempts, progressBase: progressBase, readyCheck: readyCheck
                    )
                }
            }
            throw await exhaustedRetriesError(maxAttempts: maxAttempts, lastError: lastError)
        #else
            throw PolarManager.PolarError.sdkNotAvailable
        #endif
    }

    #if canImport(PolarBleSdk)
        /// Log the failure and, when attempts remain, run the disconnect/reconnect
        /// dance before the caller's loop tries again. Throws only when the fetch
        /// was cancelled mid-attempt.
        private func handleFetchAttemptFailure(
            _ error: Error,
            link: (api: StrapAPI, deviceId: String),
            deviceName: String,
            attempt: Int,
            maxAttempts: Int,
            progressBase: Double,
            readyCheck: @escaping () -> Bool
        ) async throws {
            if manager.fetchCancelled { throw await cancelledFetchError(context: "during attempt \(attempt)") }
            debugLog("[PolarManager] \(deviceName) fetch attempt \(attempt) failed: \(error)")
            guard attempt < maxAttempts else { return }
            try await reconnectBetweenAttempts(
                api: link.api, deviceId: link.deviceId, deviceName: deviceName, attempt: attempt,
                maxAttempts: maxAttempts, progressBase: progressBase, readyCheck: readyCheck
            )
        }
    #endif

    #if canImport(PolarBleSdk)
        private func exhaustedRetriesError(maxAttempts: Int, lastError: Error?) async -> Error {
            await manager.updateProgress(.failed, progress: 0, maxAttempts: maxAttempts, message: "Failed after \(maxAttempts) attempts")
            await clearFetchProgress()
            return lastError ?? PolarManager.PolarError.fetchFailed("Unknown error after retries")
        }
    #endif

    #if canImport(PolarBleSdk)
        private func cancelledFetchError(context: String?) async -> Error {
            debugLog("[PolarManager] Fetch cancelled\(context.map { " \($0)" } ?? "") by user")
            await clearFetchProgress()
            return PolarManager.PolarError.fetchFailed("Cancelled by user")
        }

        private func clearFetchProgress() async {
            await MainActor.run {
                self.manager.fetchProgress = nil
                manager.recordingState = .idle
            }
        }

        /// Disconnect/reconnect dance — proven workaround for the SDK timeout issue.
        /// The progress bar is stepped through the wait so it doesn't look frozen.
        private func reconnectBetweenAttempts(
            api: StrapAPI,
            deviceId: String,
            deviceName: String,
            attempt: Int,
            maxAttempts: Int,
            progressBase: Double,
            readyCheck: @escaping () -> Bool
        ) async throws {
            await manager.updateProgress(.reconnecting, progress: progressBase, attempt: attempt + 1, maxAttempts: maxAttempts, message: "Resetting connection...")
            debugLog("[PolarManager] Disconnecting and reconnecting for retry...")
            do {
                try api.sdk.disconnectFromDevice(deviceId)
            } catch {
                debugLog("[PolarManager] Disconnect error (continuing): \(error)")
            }
            try await awaitDisconnect(attempt: attempt, maxAttempts: maxAttempts, progressBase: progressBase)
            let reconnectProg = progressBase + 0.07
            await manager.updateProgress(.reconnecting, progress: reconnectProg, attempt: attempt + 1, maxAttempts: maxAttempts, message: "Reconnecting to \(deviceName)...")
            do {
                try api.sdk.connectToDevice(deviceId)
            } catch {
                debugLog("[PolarManager] Reconnect error: \(error)")
            }
            try await awaitReconnect(
                attempt: attempt, maxAttempts: maxAttempts, reconnectProg: reconnectProg, readyCheck: readyCheck
            )
            await manager.updateProgress(.retrying, progress: progressBase + 0.03, attempt: attempt + 1, maxAttempts: maxAttempts, message: "Retrying download...")
        }

        /// Wait for the disconnect to complete (~3 s).
        private func awaitDisconnect(attempt: Int, maxAttempts: Int, progressBase: Double) async throws {
            for i in 1 ... 30 {
                if manager.fetchCancelled { return }
                try await Task.sleep(nanoseconds: 100_000_000)
                let prog = progressBase + (Double(i) / 30.0) * 0.05
                await manager.updateProgress(.reconnecting, progress: prog, attempt: attempt + 1, maxAttempts: maxAttempts, message: "Disconnecting...")
            }
        }

        /// Wait for reconnection and feature readiness (~5 s). The first 2 s are
        /// skipped because the SDK briefly reports the stale link as still up.
        private func awaitReconnect(
            attempt: Int,
            maxAttempts: Int,
            reconnectProg: Double,
            readyCheck: @escaping () -> Bool
        ) async throws {
            for i in 1 ... 50 {
                if manager.fetchCancelled { return }
                try await Task.sleep(nanoseconds: 100_000_000)
                let prog = reconnectProg + (Double(i) / 50.0) * 0.08
                await manager.updateProgress(.reconnecting, progress: prog, attempt: attempt + 1, maxAttempts: maxAttempts, message: "Waiting for connection...")
                if i > 20, manager.connectionState == .connected, readyCheck() {
                    debugLog("[PolarManager] Reconnected and ready")
                    return
                }
            }
        }
    #endif
}
