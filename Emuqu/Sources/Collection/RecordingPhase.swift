import Foundation

/// Explicit state machine for RRCollector recording lifecycle.
///
/// Transitions:
///   .idle → .streaming / .overnightStreaming / .deviceRecording
///   .streaming → .analyzing → .awaitingAcceptance → .idle
///   .overnightStreaming → .paused → .overnightStreaming (resume)
///   .overnightStreaming → .analyzing → .awaitingAcceptance → .idle
///   .paused → .analyzing → .awaitingAcceptance → .idle (finalize)
///   .deviceRecording → .analyzing → .awaitingAcceptance → .idle
///   Any → .idle (reset/reject)
enum RecordingPhase: Equatable, CustomStringConvertible {
    case idle
    case streaming(targetSeconds: Int)
    case overnightStreaming
    case deviceRecording
    case paused(sessionId: UUID)
    case analyzing
    case awaitingAcceptance

    var isRecording: Bool {
        switch self {
        case .streaming, .overnightStreaming, .deviceRecording:
            true
        default:
            false
        }
    }

    var isActive: Bool {
        self != .idle
    }

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
