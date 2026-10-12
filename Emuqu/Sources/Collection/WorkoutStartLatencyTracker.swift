import Foundation

// MARK: - Workout-start latency tracker
//
// Stamps the four points in the start chain that matter so a
// hang can be localised to a specific span without guessing:
//
//   tap              — user pressed Start in WorkoutPreflightView
//   start.entry      — WorkoutRecorder.start() body began
//   start.phaseFlip  — lifecycle.phase = .recording
//   announce.fire    — the announce Task was queued: stamped synchronously
//                      in start() right after the phase flip, so it stays
//                      comparable to older logs; how long that Task then
//                      waited for the main actor is logged separately by
//                      `queueStartAnnouncement`
//
// A tap belongs to the next start only: a start that throws clears it
// (`recordStartAbandoned`), and a tap older than `tapMatchWindowSeconds`
// when a start begins (a preflight that never reached start, then a Watch
// start much later) is dropped rather than measured against.
//
// A clean run logs three sub-100 ms gaps. A bad run shows one of the gaps
// in seconds, and the next investigation can target that span.
//
// Its own file rather than inline in WorkoutRecorder.swift, which sits
// against SwiftLint's `file_length` ERROR threshold of 2000 — that fails the
// `swiftlint lint` CI step, not just the warning budget. The type is fully
// self-contained (no reference to WorkoutRecorder in either direction);
// `scripts/add_swift_file.py` handles the pbxproj membership.
@MainActor
final class WorkoutStartLatencyTracker {
    static let shared = WorkoutStartLatencyTracker()
    private var tapAt: Date?
    private var startEntryAt: Date?
    private var phaseFlipAt: Date?
    private init() {}

    func recordTap() {
        tapAt = Date()
        startEntryAt = nil
        phaseFlipAt = nil
        debugLog("[StartLatency] tap")
    }

    /// Longest tap → start gap still taken as one start.
    private static let tapMatchWindowSeconds: TimeInterval = 60

    func recordStartEntry() {
        guard let tapAt else { return }
        guard Date().timeIntervalSince(tapAt) <= Self.tapMatchWindowSeconds else {
            debugLog("[StartLatency] tap is older than \(Int(Self.tapMatchWindowSeconds)) s — not this start's, not measured")
            clear()
            return
        }
        startEntryAt = Date()
        let ms = Int(Date().timeIntervalSince(tapAt) * 1000)
        let level: DebugLogger.LogLevel = ms > 500 ? .warning : .info
        debugLog("[StartLatency] tap → start.entry: \(ms) ms", level: level)
    }

    func recordPhaseFlip() {
        guard let startEntryAt else { return }
        phaseFlipAt = Date()
        let entryMs = Int(Date().timeIntervalSince(startEntryAt) * 1000)
        let totalMs = tapAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        let level: DebugLogger.LogLevel = entryMs > 500 ? .warning : .info
        debugLog("[StartLatency] entry → phase.recording: \(entryMs) ms (tap → phase: \(totalMs) ms)", level: level)
    }

    func recordAnnounceFire() {
        guard let phaseFlipAt = self.phaseFlipAt else { return }
        let phaseMs = Int(Date().timeIntervalSince(phaseFlipAt) * 1000)
        let totalMs = self.tapAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        let level: DebugLogger.LogLevel = phaseMs > 500 ? .warning : .info
        debugLog("[StartLatency] phase.recording → announce.fire: \(phaseMs) ms (tap → voice: \(totalMs) ms)", level: level)
    }

    /// Stamps when `start()` finishes its synchronous body. Instrumentation
    /// that stops at `announce.fire` leaves gaps like the
    /// 14.6 s + 9.5 s in `hrv_debug_log_1778675167.txt` to be inferred
    /// from per-step log spacing. This gives a single explicit number for
    /// "tap → start() returned" — anything over a few hundred ms is a
    /// regression and the per-step logs after this line tell us where it lives.
    func recordStartReturned() {
        guard let tapAt else { return }
        let totalMs = Int(Date().timeIntervalSince(tapAt) * 1000)
        let level: DebugLogger.LogLevel = totalMs > 500 ? .warning : .info
        debugLog("[StartLatency] tap → start() returned: \(totalMs) ms", level: level)
        clear()
    }

    /// `start()` threw: the tap and stamps are this failed start's, so a
    /// later start (a Watch start records no tap) is not measured from them.
    func recordStartAbandoned() {
        clear()
    }

    private func clear() {
        tapAt = nil
        startEntryAt = nil
        phaseFlipAt = nil
    }
}
