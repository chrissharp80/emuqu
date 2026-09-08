import Foundation

// MARK: - Workout-start latency tracker
//
// Stamps the four points in the start chain that matter so a
// hang can be localised to a specific span without guessing:
//
//   tap              — user pressed Start in WorkoutPreflightView
//   start.entry      — WorkoutRecorder.start() body began
//   start.phaseFlip  — lifecycle.phase = .recording
//   announce.fire    — announceStart() actually ran on the main actor
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

    func recordStartEntry() {
        guard let tapAt else { return }
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
        self.tapAt = nil
        self.startEntryAt = nil
        self.phaseFlipAt = nil
    }
}
