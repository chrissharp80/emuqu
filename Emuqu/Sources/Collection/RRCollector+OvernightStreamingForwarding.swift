import Foundation

// Overnight streaming lives in `OvernightStreamingCoordinator` —
// 846 lines out of what was still the largest type in the codebase.
//
// These forwarders exist so the call sites across the app and the test suite
// did not have to change in the same commit as the move. They are the
// collector's overnight-streaming API; the behaviour lives one reference away.

extension RRCollector {
    /// The overnight-streaming subsystem. Lazy: a daytime launch never touches
    /// it, and building it eagerly would put an object on the cold-start path
    /// for a case that only arises at night.
    var overnightStreaming: OvernightStreamingCoordinator {
        OvernightStreamingCoordinator(collector: self)
    }

    func isVeritySenseDevice(_ session: HRVSession) -> Bool {
        overnightStreaming.isVeritySenseDevice(session)
    }

    func failSession(from baseSession: HRVSession) async -> HRVSession {
        await overnightStreaming.failSession(from: baseSession)
    }

    func startOvernightStreaming(
        sessionType: SessionType = .overnight,
        useDeviceInternalBackup: Bool = true
    ) throws {
        try overnightStreaming.startOvernightStreaming(
            sessionType: sessionType, useDeviceInternalBackup: useDeviceInternalBackup
        )
    }

    func startOvernightStreamingTimer() {
        overnightStreaming.startOvernightStreamingTimer()
    }

    func mergeParentSessionData(
        data: OvernightStreamingCoordinator.OvernightDataResult
    ) -> (points: [RRPoint], baseSession: HRVSession) {
        overnightStreaming.mergeParentSessionData(data: data)
    }

    func stopOvernightStreaming() async -> HRVSession? {
        await overnightStreaming.stopOvernightStreaming()
    }

    func backupStreamingData(_ points: [RRPoint], sessionId: UUID) async {
        await overnightStreaming.backupStreamingData(points, sessionId: sessionId)
    }
}
