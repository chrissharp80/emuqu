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
            try manager.link.requireUsable(.offlineRecording)
            try await armOfflinePpiRecording(api: api, deviceId: deviceId)
        #else
            throw PolarManager.PolarError.sdkNotAvailable
        #endif
    }

    #if canImport(PolarBleSdk)
        private func armOfflinePpiRecording(api: any StrapRadio, deviceId: String) async throws {
            await MainActor.run { manager.recordingState = .starting }
            do {
                try await api.startOfflineRecording(deviceId, feature: .ppi, settings: nil, secret: nil)
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
                manager.lastError = PolarManager.PolarError.recordingFailed(PolarErrorMessages.humanizeStartFailure(error))
            }
        }
    #endif

    /// Fetch offline PPI data from Verity Sense without stopping the recording or
    /// deleting the data. The recording stays on the device until the user explicitly
    /// clears it (via discardPendingExercise or the next recording cycle).
    /// `requireEveryEntry` throws when any recording on the strap failed to
    /// download, instead of returning the ones that did: the start sequence
    /// deletes everything on the strap after the rescue, so a partial rescue
    /// must not count as one. `recordedSince` limits the read to recordings
    /// that started at or after it; nil reads them all.
    func fetchOfflinePpiRecording(requireEveryEntry: Bool = false, recordedSince: Date? = nil) async throws -> [RRPoint] {
        #if canImport(PolarBleSdk)
            guard let api = manager.strapAPI, let deviceId = manager.connectedDeviceId else { throw PolarManager.PolarError.notConnected }
            await MainActor.run { manager.recordingState = .fetching }
            let read = try await Self.readAllOfflinePpi(api: api, deviceId: deviceId, since: recordedSince)
            let (found, allPoints) = (read.count, read.points)
            debugLog("[PolarManager] Found \(found) PPI recordings on device (\(read.failed) failed to download)")
            await MainActor.run { manager.recordingState = .idle }
            guard found > 0 else { throw PolarManager.PolarError.noRecordingFound }
            if read.failed > 0, requireEveryEntry || allPoints.isEmpty {
                throw PolarManager.PolarError.fetchFailed("\(read.failed) of \(found) recordings did not download")
            }
            debugLog("[PolarManager] Total offline PPI points after quality filtering: \(allPoints.count)")
            return allPoints
        #else
            throw PolarManager.PolarError.sdkNotAvailable
        #endif
    }

    #if canImport(PolarBleSdk)
        /// Lists the offline PPI recordings (those started at or after `since`
        /// when given) and reads each one (read-only — no stop, no delete),
        /// oldest first, all off the main actor so the SDK's entry values never
        /// cross isolation. A failure on a single entry is counted in `failed`
        /// and skipped, so one bad file can't lose the rest of the night.
        nonisolated static func readAllOfflinePpi(
            api: any StrapRadio, deviceId: String, since: Date? = nil
        ) async throws -> (count: Int, points: [RRPoint], failed: Int) {
            let entries = try await listPpiEntries(api: api, deviceId: deviceId)
                .filter { entry in since.map { entry.date >= $0 } ?? true }
                .sorted { $0.date < $1.date }
            var allPoints: [RRPoint] = []
            var failed = 0
            for entry in entries {
                guard let points = await readOfflinePpiEntry(api: api, deviceId: deviceId, entry: entry) else {
                    failed += 1
                    continue
                }
                allPoints.append(contentsOf: continuing(points, after: allPoints))
            }
            return (entries.count, allPoints, failed)
        }

        /// Each recording's beats start at `t_ms` 0. Joined as they come, a
        /// second recording would send the timeline back to 0 mid-series and
        /// windowed analysis would read overlapping windows; instead each one
        /// is placed after the previous one ends (the gap between recordings
        /// is not known, so none is inserted).
        nonisolated private static func continuing(_ points: [RRPoint], after earlier: [RRPoint]) -> [RRPoint] {
            guard let end = earlier.last?.endMs, let first = points.first else { return points }
            let offset = end - first.t_ms
            return offset == 0 ? points : points.map { $0.shifted(by: offset) }
        }

        nonisolated private static func readOfflinePpiEntry(
            api: any StrapRadio,
            deviceId: String,
            entry: PolarOfflineRecordingEntry
        ) async -> [RRPoint]? {
            do {
                let data = try await fetchOfflineRecord(api: api, deviceId: deviceId, entry: entry)
                let points = convertOfflinePpiToRRPoints(data)
                debugLog("[PolarManager] Fetched offline PPI recording: \(points.count) quality-filtered points")
                return points
            } catch {
                debugLog("[PolarManager] Error fetching offline recording: \(error)")
                return nil
            }
        }

        nonisolated private static func fetchOfflineRecord(
            api: any StrapRadio,
            deviceId: String,
            entry: PolarOfflineRecordingEntry
        ) async throws -> PolarOfflineRecordingData {
            try await api.getOfflineRecord(deviceId, entry: entry, secret: nil)
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
    /// Community workaround: reset the link between retry attempts.
    ///
    /// - Parameters:
    ///   - maxAttempts: Maximum retry count (default 5)
    ///   - deviceName: Display name for progress messages
    ///   - progressBase: Starting progress value for reconnect phase (e.g. 0.35)
    ///   - feature: The strap feature the operation needs; each attempt waits for it
    ///   - operation: The actual fetch operation to retry. Receives (attempt, maxAttempts).
    func retryWithReconnect<T>(
        maxAttempts: Int = 5,
        deviceName: String,
        progressBase: Double = 0.35,
        feature: StrapFeature,
        operation: (_ attempt: Int, _ maxAttempts: Int) async throws -> T
    ) async throws -> T {
        #if canImport(PolarBleSdk)
            guard manager.strapAPI != nil, manager.connectedDeviceId != nil else { throw PolarManager.PolarError.notConnected }
            var lastError: Error?
            for attempt in 1 ... maxAttempts {
                if manager.fetchCancelled { throw await cancelledFetchError(context: nil) }
                do {
                    return try await whenUsable(feature, attempt: attempt, maxAttempts: maxAttempts, operation: operation)
                } catch {
                    lastError = error
                    try await handleFetchAttemptFailure(
                        error, deviceName: deviceName, attempt: attempt, maxAttempts: maxAttempts,
                        progressBase: progressBase, feature: feature
                    )
                }
            }
            throw await exhaustedRetriesError(maxAttempts: maxAttempts, lastError: lastError)
        #else
            throw PolarManager.PolarError.sdkNotAvailable
        #endif
    }

    #if canImport(PolarBleSdk)
        /// Run one attempt once the strap can serve `feature`, for as long as
        /// the fetch is not cancelled.
        private func whenUsable<T>(
            _ feature: StrapFeature, attempt: Int, maxAttempts: Int,
            operation: (_ attempt: Int, _ maxAttempts: Int) async throws -> T
        ) async throws -> T {
            try await manager.link.whenFeatureUsable(
                feature,
                until: Date().addingTimeInterval(StrapRecordingPolicy.featureReadyWindowSeconds),
                while: { !manager.fetchCancelled },
                perform: { try await operation(attempt, maxAttempts) }
            )
        }

        /// Log the failure and, when attempts remain, reset the link before the
        /// caller's loop tries again. Throws only when the fetch was cancelled.
        private func handleFetchAttemptFailure(
            _ error: Error,
            deviceName: String,
            attempt: Int,
            maxAttempts: Int,
            progressBase: Double,
            feature: StrapFeature
        ) async throws {
            if manager.fetchCancelled { throw await cancelledFetchError(context: "during attempt \(attempt)") }
            debugLog("[PolarManager] \(deviceName) fetch attempt \(attempt) failed: \(error)")
            guard attempt < maxAttempts else { return }
            await reconnectBetweenAttempts(
                deviceName: deviceName, attempt: attempt,
                maxAttempts: maxAttempts, progressBase: progressBase, feature: feature
            )
        }

        private func exhaustedRetriesError(maxAttempts: Int, lastError: Error?) async -> Error {
            await manager.updateProgress(.failed, progress: 0, maxAttempts: maxAttempts, message: "Failed after \(maxAttempts) attempts")
            await clearFetchProgress()
            return lastError ?? PolarManager.PolarError.fetchFailed("Unknown error after retries")
        }

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

        /// Reset the link, then wait — on the link's events — for the strap to
        /// come back and its feature to be usable again.
        private func reconnectBetweenAttempts(
            deviceName: String,
            attempt: Int,
            maxAttempts: Int,
            progressBase: Double,
            feature: StrapFeature
        ) async {
            await manager.updateProgress(.reconnecting, progress: progressBase, attempt: attempt + 1, maxAttempts: maxAttempts, message: "Resetting connection...")
            debugLog("[PolarManager] Resetting the strap link before retry...")
            if manager.link.beginLinkReset() {
                _ = await manager.link.awaitDisconnection(until: Date().addingTimeInterval(StrapRecordingPolicy.linkDropWaitSeconds))
            }
            await manager.updateProgress(.reconnecting, progress: progressBase + 0.07, attempt: attempt + 1, maxAttempts: maxAttempts, message: "Reconnecting to \(deviceName)...")
            let outcome = await manager.link.awaitFeature(
                feature,
                until: Date().addingTimeInterval(StrapRecordingPolicy.featureReadyWindowSeconds),
                while: { !manager.fetchCancelled }
            )
            debugLog("[PolarManager] Reconnected for retry — \(feature): \(outcome)")
            await manager.updateProgress(.retrying, progress: progressBase + 0.07, attempt: attempt + 1, maxAttempts: maxAttempts, message: "Retrying download...")
        }
    #endif
}
