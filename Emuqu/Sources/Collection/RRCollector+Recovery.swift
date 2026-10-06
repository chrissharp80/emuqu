import Foundation

// MARK: - Data Recovery (Backup, Lost Sessions, Device Recovery)

extension SessionRecoveryCoordinator {
    // MARK: - Recovery Service

    /// Lazy-initialized recovery service with all dependencies injected from RRCollector.
    var recoveryService: SessionRecoveryService {
        if let existing = collector._recoveryService { return existing }
        let service = SessionRecoveryService(
            archive: collector.archive,
            rawBackup: collector.rawBackup,
            artifactDetector: collector.artifactDetector,
            windowSelector: collector.windowSelector,
            cloudSyncManager: collector.cloudSyncManager,
            baselineTracker: collector.baselineTracker
        )
        collector._recoveryService = service
        return service
    }

    // MARK: - Retry Fetch

    /// The Retry card after a failed download: the device-recording Stop
    /// again, so the session is resolved, date-checked, dated and assembled
    /// exactly as the first attempt was.
    func retryFetchRecording() async throws -> HRVSession? {
        try await collector.deviceRecording.stopSession()
    }

    // MARK: - Whose recording is on the strap

    /// A session of this app is recording right now, and the strap's
    /// recording is its own: an internal-mode or overnight night, or a
    /// workout's backup. Recovery flows leave that recording alone.
    var strapRecordingBelongsToLiveSession: Bool {
        if collector.isCollecting || collector.isOvernightStreaming { return true }
        guard let recorder = AppDependencies.current.app.recorderBox.recorder else { return false }
        return recorder.phase == .recording || recorder.phase == .finalizing
    }

    /// A recording still running on the strap that no session owns: none is
    /// live and none is on record to stop it (a crashed night or workout has
    /// its own recovery). Left by a crash, or started on the strap itself.
    var strapHoldsOrphanedRecording: Bool {
        collector.polarManager.isRecordingOnDevice
            && collector.getPersistedRecordingState() == nil
            && !strapRecordingBelongsToLiveSession
    }

    // MARK: - Recover from Device

    /// Take the strap's recording off it (stopping one still running) and
    /// present it for review. An earlier night the app never downloaded may
    /// legitimately be the one recovered; it is then dated by its own start
    /// and filed as that night, never as tonight.
    func recoverFromDevice() async throws -> HRVSession? {
        debugLog("[Recovery] ========== START recoverFromDevice ==========")
        try checkRecoverable()
        collector.polarManager.beginTransfer()
        let recording = try await downloadForRecovery()
        let placement = await recoveryPlacement(for: recording)
        let session = await collector.deviceRecording.assembleDownloadedSession(recording, placement: placement)
        debugLog("[Recovery] ========== END recoverFromDevice: \(session.id.uuidString.prefix(8)) \(session.state) ==========")
        guard session.state == .complete else {
            throw collector.lastError ?? RRCollector.CollectorError.insufficientData
        }
        return session
    }

    /// Recover needs the strap, must not stop a live session's recording, and
    /// does not offer a recording already downloaded and saved.
    private func checkRecoverable() throws {
        let manager = collector.polarManager
        guard manager.connectionState == .connected else { throw recoveryRefused(.notConnected) }
        guard !strapRecordingBelongsToLiveSession else { throw recoveryRefused(.alreadyRecording) }
        let alreadySaved = manager.hasStoredExercise && manager.storedExerciseDate != nil
            && !manager.isRecordingOnDevice && !collector.hasUnrecoveredData
        guard !alreadySaved else { throw recoveryRefused(.strapRecordingAlreadySaved) }
    }

    private func recoveryRefused(_ error: RRCollector.CollectorError) -> Error {
        debugLog("[Recovery] Not recovering: \(error)")
        collector.lastError = error
        return error
    }

    private func downloadForRecovery() async throws -> StrapRecording {
        do {
            let recording = try await collector.polarManager.fetchRecording(recordedSince: nil, budget: .attended)
            debugLog("[Recovery] Got \(recording.points.count) beats from strap, started \(recording.startedAt?.description ?? "unknown")")
            return recording
        } catch {
            debugLog("[Recovery] Strap download failed: \(error)")
            collector.lastError = error
            throw error
        }
    }

    /// Tonight's session only takes a recording that started during it. Any
    /// other recording is dated by its own start and merged into that
    /// night's archived session when there is one.
    private func recoveryPlacement(for recording: StrapRecording) async -> DeviceRecordingSession.DownloadPlacement {
        if let tonight = persistedSessionOwning(recording) { return tonight }
        let start = await collector.deviceRecording.recordingStart(recording)
        if let existing = archivedNightToMergeInto(recording, start: start) {
            // One clock from the earlier start. A start that was only
            // estimated can't place the beats, so they stay on the night's own.
            let clockStart = recording.startedAt == nil ? existing.startDate : min(existing.startDate, start)
            return DeviceRecordingSession.DownloadPlacement(
                sessionId: existing.id, sessionType: existing.sessionType, startDate: clockStart,
                deviceProvenance: existing.deviceProvenance, existing: existing
            )
        }
        return DeviceRecordingSession.DownloadPlacement(
            sessionId: UUID(), sessionType: .overnight, startDate: start,
            deviceProvenance: collector.deviceRecording.deviceRecordingProvenance(), existing: nil
        )
    }

    private func persistedSessionOwning(_ recording: StrapRecording) -> DeviceRecordingSession.DownloadPlacement? {
        guard let persisted = collector.getPersistedRecordingState(), let start = recording.startedAt,
              StrapRecordingPolicy.recording(startedAt: start, belongsToSessionStartedAt: persisted.startTime)
        else { return nil }
        debugLog("[Recovery] Recording started \(start), during the persisted session \(persisted.sessionId.uuidString.prefix(8))")
        let existing = collector.archive.exists(persisted.sessionId) ? collector.archive.retrieveOrLog(persisted.sessionId) : nil
        return DeviceRecordingSession.DownloadPlacement(
            sessionId: persisted.sessionId, sessionType: persisted.sessionType, startDate: persisted.startTime,
            deviceProvenance: existing?.deviceProvenance ?? collector.deviceRecording.deviceRecordingProvenance(),
            existing: existing
        )
    }

    /// The archived overnight a recovered recording merges into, by the same
    /// rule as every other merge (`SessionMerger.relation`): a copy of the
    /// same recording always, a segment of the same sleep within the merge
    /// gap when merging is on and the recording's start is known. Recordings
    /// further apart stay separate nights.
    private func archivedNightToMergeInto(_ recording: StrapRecording, start: Date) -> HRVSession? {
        let settings = collector.settingsManager.settings
        let end = start.addingTimeInterval(StrapExerciseDecoder.durationSeconds(of: recording.points))
        let span = SessionMerger.span(start: start, end: end)
        let allowsSameSleep = settings.sessionMergeMode != .off && recording.startedAt != nil
        for entry in collector.archive.entries where entry.sessionType == .overnight {
            let relation = SessionMerger.relation(
                of: span, to: SessionMerger.span(of: entry), mergeGap: settings.effectiveMergeGapSeconds
            )
            guard relation == .sameRecording || (relation == .sameSleep && allowsSameSleep) else { continue }
            guard let session = collector.archive.retrieveOrLog(entry.sessionId) else { continue }
            debugLog("[Recovery] Same-night session \(session.id.uuidString.prefix(8)) (\(session.rrSeries?.points.count ?? 0) beats, source \(session.dataSourceSummary?.selectedSource ?? "nil"))")
            return session
        }
        return nil
    }
}
