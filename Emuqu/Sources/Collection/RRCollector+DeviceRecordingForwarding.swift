import Foundation

// Device-internal recording lives in `DeviceRecordingSession` —
// 451 lines off `RRCollector`.
//
// These forwarders keep every existing call site working.

extension RRCollector {
    /// The device-internal capture subsystem. Lazy — a streaming night never
    /// builds it.
    var deviceRecording: DeviceRecordingSession {
        DeviceRecordingSession(collector: self)
    }

    func startSession(sessionType: SessionType = .overnight) async throws {
        try await deviceRecording.startSession(sessionType: sessionType)
    }

    func stopSession() async throws -> HRVSession? {
        try await deviceRecording.stopSession()
    }

    func backupRawData(_ points: [RRPoint], sessionId: UUID) {
        deviceRecording.backupRawData(points, sessionId: sessionId)
    }

    func fetchTrainingLoadIfEnabled() async {
        await deviceRecording.fetchTrainingLoadIfEnabled()
    }

    func runAnalysis(
        session: HRVSession,
        windowResult: WindowSelector.WindowSelectionResult?,
        flags: [ArtifactFlags]
    ) async -> HRVAnalysisResult? {
        await deviceRecording.runAnalysis(
            session: session, windowResult: windowResult, flags: flags
        )
    }
}
