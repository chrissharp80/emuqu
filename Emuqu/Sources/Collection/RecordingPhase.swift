import Foundation

/// Explicit state machine for RRCollector recording lifecycle.
///
/// Transitions:
///   .idle → .streaming / .overnightStreaming / .deviceRecording
///   .streaming → .analyzing → .idle (a quick reading is saved at stop, not reviewed)
///   .overnightStreaming → .analyzing → .awaitingAcceptance → .idle
///   .overnightStreaming → .analyzing → .paused → .overnightStreaming (pause, resume)
///   .paused → .awaitingAcceptance (Done on an analysed night) or .idle (Done on a short one)
///   .deviceRecording → .idle (the strap stops for the download) → .awaitingAcceptance → .idle
///   .analyzing → .idle (a night that failed)
///   Any → .idle (reset/reject)
enum RecordingPhase: Equatable, CustomStringConvertible {
    case idle
    case streaming(targetSeconds: Int)
    case overnightStreaming
    case deviceRecording
    case paused(sessionId: UUID)
    case analyzing
    case awaitingAcceptance

    var description: String {
        switch self {
        case .idle: "idle"
        case let .streaming(target): "streaming(\(target)s)"
        case .overnightStreaming: "overnightStreaming"
        case .deviceRecording: "deviceRecording"
        case let .paused(id): "paused(\(id.uuidString.prefix(8)))"
        case .analyzing: "analyzing"
        case .awaitingAcceptance: "awaitingAcceptance"
        }
    }
}
