import Foundation
#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

// Verity Sense offline-PPI recording, split out of
// `PolarManager+Recording.swift`. The H10 and the Verity Sense
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

    /// Read the Verity Sense's completed offline PPI recordings without
    /// stopping or deleting anything; the sensor keeps them until the next
    /// recording clears them. `requireEveryEntry` throws when any recording
    /// failed to download, instead of returning the ones that did: the start
    /// sequence deletes everything on the sensor after the rescue, so a
    /// partial rescue must not count as one. `recordedSince` limits the read
    /// to recordings that started at or after it; nil reads them all.
    func fetchOfflinePpiRecording(requireEveryEntry: Bool = false, recordedSince: Date? = nil) async throws -> StrapRecording {
        #if canImport(PolarBleSdk)
            guard let api = manager.strapAPI, let deviceId = manager.connectedDeviceId else { throw PolarManager.PolarError.notConnected }
            let read = try await Self.readAllOfflinePpi(api: api, deviceId: deviceId, since: recordedSince)
            debugLog("[PolarManager] Found \(read.count) PPI recordings on device (\(read.failed) failed to download)")
            guard read.count > 0 else { throw PolarManager.PolarError.noRecordingFound }
            if read.failed > 0, requireEveryEntry || read.points.isEmpty {
                throw PolarManager.PolarError.fetchFailed("\(read.failed) of \(read.count) recordings did not download")
            }
            debugLog("[PolarManager] Total offline PPI points after quality filtering: \(read.points.count)")
            return StrapRecording(points: read.points, startedAt: read.start)
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
        /// `start` is when the earliest of them began.
        nonisolated static func readAllOfflinePpi(
            api: any StrapRadio, deviceId: String, since: Date? = nil
        ) async throws -> OfflinePpiRead {
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
            return OfflinePpiRead(count: entries.count, points: allPoints, failed: failed, start: entries.first?.date)
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
}

/// The Verity Sense's offline recordings as read: how many were listed, the
/// beats of those that downloaded, how many failed, and when the earliest
/// began.
struct OfflinePpiRead: Sendable {
    let count: Int
    let points: [RRPoint]
    let failed: Int
    let start: Date?
}
