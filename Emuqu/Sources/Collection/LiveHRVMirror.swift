import Foundation
import os

/// The live HRV recording's state, mirrored for the assistant's broker
/// (`LiveHRVBroker`), whose provider closure reads it from any thread without
/// crossing actors.
@MainActor
final class LiveHRVMirror {
    /// Thread-safe mirror of the live HRV snapshot. Written
    /// only from MainActor (via `refresh(from:)` on every
    /// sessionState change). Read from any thread by the
    /// `LiveHRVBroker` provider closure WITHOUT crossing actors. The
    /// `OSAllocatedUnfairLock` holds the value, so every read and write
    /// goes through `withLock` and the compiler checks the Sendable fields.
    nonisolated let snapshot = OSAllocatedUnfairLock<Snapshot?>(initialState: nil)

    /// Sendable inputs captured on MainActor; the broker provider
    /// recomputes `elapsedSeconds` / `snapshotAt` at read time (those
    /// are clock-derived and would go stale otherwise).
    struct Snapshot: Sendable {
        let phaseLabel: String
        let phaseDescription: String
        let isCollecting: Bool
        let beatCount: Int
        let sessionStartAt: Date?
        let lastErrorDescription: String?
    }

    /// Write the snapshot mirror so the off-main provider
    /// closure can read it without crossing actors. Called from
    /// `CollectorSessionControl.onSessionStateChanged`, which the
    /// self-re-arming observation of `sessionState` schedules on the main
    /// actor after every mutation. Cheap: pure value reads + one
    /// lock-protected pointer write.
    func refresh(from sessionState: SessionState) {
        let phase = sessionState.recordingPhase
        guard phase != .idle else {
            snapshot.withLock { $0 = nil }
            return
        }
        let mirror = Snapshot(
            phaseLabel: phaseMachineLabel(phase),
            phaseDescription: phaseHumanLabel(phase),
            isCollecting: sessionState.isCollecting,
            beatCount: sessionState.collectedPoints.count,
            sessionStartAt: sessionState.currentSession?.startDate,
            lastErrorDescription: sessionState.lastError.map { ($0 as NSError).localizedDescription }
        )
        snapshot.withLock { $0 = mirror }
    }
}

@MainActor
private func phaseMachineLabel(_ phase: RecordingPhase) -> String {
    switch phase {
    case .idle: "idle"
    case .streaming: "streaming"
    case .overnightStreaming: "overnight"
    case .deviceRecording: "deviceRecording"
    case .paused: "paused"
    case .analyzing: "analyzing"
    case .awaitingAcceptance: "awaitingAcceptance"
    }
}

/// In the app language: the assistant is told to quote it to the user.
@MainActor
private func phaseHumanLabel(_ phase: RecordingPhase) -> String {
    let bundle = LanguageManager.appBundle
    switch phase {
    case .idle: return String(localized: "Idle", bundle: bundle)
    case let .streaming(target):
        return String(localized: "Quick streaming (target \(LocalizedDuration.minutes(target / 60)))", bundle: bundle)
    case .overnightStreaming: return String(localized: "Overnight recording", bundle: bundle)
    case .deviceRecording: return String(localized: "Device-internal recording", bundle: bundle)
    case .paused: return String(localized: "Paused", bundle: bundle)
    case .analyzing: return String(localized: "Analyzing", bundle: bundle)
    case .awaitingAcceptance: return String(localized: "Awaiting session review", bundle: bundle)
    }
}
