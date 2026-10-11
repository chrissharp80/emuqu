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
            manager.recordingState = .starting
            do {
                try await api.startOfflineRecording(deviceId, feature: .ppi, settings: nil, secret: nil)
            } catch {
                // The same humanising and low-battery mapping as the H10 start.
                throw surfaceStartFailure(error)
            }
            manager.recordingState = .recording
            manager.isRecordingOnDevice = true
            debugLog("[PolarManager] Started Verity Sense offline PPI recording")
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
            return try Self.offlinePpiRecording(from: read, requireEveryEntry: requireEveryEntry)
        #else
            throw PolarManager.PolarError.sdkNotAvailable
        #endif
    }

    /// The rescue's read before a start clears the sensor: every stored
    /// recording the app does not already hold (`isRecordingSaved`), each of
    /// which must download. The sensor keeps a recording after its download,
    /// so reading them all re-filed an already-saved night on every arming.
    /// Throws `noRecordingFound` when there is nothing unsaved.
    func fetchUnsavedOfflinePpiRecordings() async throws -> StrapRecording {
        #if canImport(PolarBleSdk)
            guard let api = manager.strapAPI, let deviceId = manager.connectedDeviceId else { throw PolarManager.PolarError.notConnected }
            let starts = try await Self.listPpiEntries(api: api, deviceId: deviceId).map(\.date)
            let saved = Set(starts.filter { manager.isRecordingSaved(startedAt: $0) })
            let read = try await Self.readAllOfflinePpi(api: api, deviceId: deviceId, excluding: saved)
            return try Self.offlinePpiRecording(from: read, requireEveryEntry: true)
        #else
            throw PolarManager.PolarError.sdkNotAvailable
        #endif
    }

    /// What a read hands back. None listed throws `noRecordingFound`; a read
    /// with failures throws when every recording was required or none
    /// downloaded, and otherwise returns the ones that did with the shortfall
    /// logged as a warning, so it reaches Recent Problems rather than only
    /// the debug log.
    private static func offlinePpiRecording(from read: OfflinePpiRead, requireEveryEntry: Bool) throws -> StrapRecording {
        debugLog("[PolarManager] Found \(read.count) PPI recordings on device (\(read.failed) failed to download)")
        guard read.count > 0 else { throw PolarManager.PolarError.noRecordingFound }
        if read.failed > 0, requireEveryEntry || read.points.isEmpty {
            throw PolarManager.PolarError.fetchFailed("\(read.failed) of \(read.count) recordings did not download")
        }
        if read.failed > 0 {
            debugLog("[PolarManager] Verity Sense download is incomplete: \(read.failed) of \(read.count) recordings did not download", level: .warning)
        }
        debugLog("[PolarManager] Total offline PPI points after quality filtering: \(read.points.count)")
        return StrapRecording(points: read.points, startedAt: read.start)
    }

    #if canImport(PolarBleSdk)
        /// Lists the offline PPI recordings (those started at or after `since`
        /// when given, and not started at a time in `excluding`) and reads each
        /// one (read-only — no stop, no delete), oldest first, all off the main
        /// actor so the SDK's entry values never cross isolation. A failure on
        /// a single entry is counted in `failed` and skipped, so one bad file
        /// can't lose the rest of the night. `start` is when the earliest
        /// recording that downloaded began, so it never predates the first beat.
        nonisolated static func readAllOfflinePpi(
            api: any StrapRadio, deviceId: String, since: Date? = nil, excluding: Set<Date> = []
        ) async throws -> OfflinePpiRead {
            let entries = try await listPpiEntries(api: api, deviceId: deviceId)
                .filter { entry in since.map { entry.date >= $0 } ?? true }
                .filter { !excluding.contains($0.date) }
                .sorted { $0.date < $1.date }
            var allPoints: [RRPoint] = []
            var failed = 0
            var start: Date?
            for entry in entries {
                guard let points = await readOfflinePpiEntry(api: api, deviceId: deviceId, entry: entry) else {
                    failed += 1
                    continue
                }
                start = start ?? entry.date
                allPoints.append(contentsOf: continuing(points, after: allPoints))
            }
            return OfflinePpiRead(count: entries.count, points: allPoints, failed: failed, start: start)
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
/// one that downloaded began.
struct OfflinePpiRead: Sendable {
    let count: Int
    let points: [RRPoint]
    let failed: Int
    let start: Date?
}
