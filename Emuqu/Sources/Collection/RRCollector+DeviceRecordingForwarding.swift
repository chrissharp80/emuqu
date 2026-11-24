import Foundation

// Device-internal recording lives in `DeviceRecordingSession`; these
// forwarders give `RRCollector` callers the same entry points.

extension RRCollector {
    /// The device-internal capture subsystem: a small value built on each
    /// access around the collector, holding no state of its own.
    var deviceRecording: DeviceRecordingSession {
        DeviceRecordingSession(collector: self)
    }

    func startSession(sessionType: SessionType = .overnight) async throws {
        try await deviceRecording.startSession(sessionType: sessionType)
    }

    func stopSession() async throws -> HRVSession? {
        try await deviceRecording.stopSession()
    }

    func fetchTrainingLoadIfEnabled() async {
        await deviceRecording.fetchTrainingLoadIfEnabled()
    }
}
