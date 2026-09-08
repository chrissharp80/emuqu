import Foundation

/// Which heart-rate source a workout will actually use, given what is really
/// attached at the moment Start is pressed.
///
/// ## Why this exists
///
/// The user picks a source on the ready screen. Between that tap and `start()`
/// running, the strap can drop out — BLE disconnect, the app backgrounded for a
/// moment, the strap knocked loose. Failing the start with "Not connected"
/// after they *just* saw "ready to start with strap connected" is the confusion
/// they reported, so the cascade downgrades instead.
///
/// Three outcomes matter, and each has a cost:
///
///  * **Refusing when the strap is mid-recording.** An overnight HRV recording
///    the user explicitly started must never be preempted by a workout — the
///    H10 keeps one file, so starting over it loses the night.
///  * **Downgrading too eagerly.** Reporting `.none` when a strap was reachable
///    throws away HRV-grade data (RMSSD, SDNN, DFA α1) that cannot be
///    reconstructed afterwards.
///  * **Not downgrading enough.** Recording `.strap` provenance for a workout
///    that captured no RR makes the analyzer expect data that was never there.
///
/// This lived inside `WorkoutRecorder+Start.swift`, 616 lines at **0% coverage**
/// — every branch reachable only with a physical strap in a
/// particular radio state.
enum WorkoutHRSourceResolver {
    /// What the caller should do. The resolver decides; the side effects —
    /// tearing down a stale stream, firing a reconnect, logging — stay with it.
    enum Resolution: Equatable {
        /// Use this source as-is.
        case use(WorkoutRecorder.HRSource)
        /// The strap is known but not currently connected: fire a reconnect and
        /// proceed as `.strap`, with streaming deferred until it lands.
        case reconnectThenUseStrap
        /// The strap is busy with its own recording. Refuse the start rather
        /// than preempt it.
        case strapBusy
    }

    /// The cascade, in the order the consequences demand.
    ///
    /// - Parameters:
    ///   - requested: what the user chose on the ready screen.
    ///   - strapIsRecordingOnDevice: the strap's own report, which can be true
    ///     after a crash or a session started on the device itself.
    ///   - strapIsConnected: whether the link is up right now.
    ///   - hasKnownDevices: whether a strap has ever been paired, so a
    ///     reconnect has something to aim at.
    ///   - isWatchPaired: whether an Apple Watch can stand in.
    static func resolve(
        requested: WorkoutRecorder.HRSource,
        strapIsRecordingOnDevice: Bool,
        strapIsConnected: Bool,
        hasKnownDevices: Bool,
        isWatchPaired: Bool
    ) -> Resolution {
        // Watch and none never consult the strap: those users are not blocked
        // on hardware they did not ask for.
        guard requested == .strap else { return .use(requested) }
        // Checked before connection state on purpose. A strap mid-recording is
        // busy whether or not we currently hold a link to it, and the cost of
        // getting this wrong is an entire night.
        guard !strapIsRecordingOnDevice else { return .strapBusy }
        guard !strapIsConnected else { return .use(.strap) }
        if hasKnownDevices { return .reconnectThenUseStrap }
        if isWatchPaired { return .use(.watch) }
        return .use(.none)
    }

    /// Why the workout is starting on the source it is. Lives here rather than
    /// on the recorder because it needs no recorder state — only the decision.
    static func log(_ resolution: Resolution) {
        switch resolution {
        case .strapBusy:
            debugLog("[WorkoutRecorder] strap is mid-recording — refusing to start over it", level: .warning)
        case .reconnectThenUseStrap:
            debugLog("[WorkoutRecorder] strap disconnected at start — firing reconnect, scheduling deferred startStreaming")
        case .use(.watch):
            debugLog("[WorkoutRecorder] no strap paired, falling back to Watch wrist HR (.watch)", level: .info)
        case .use(.none):
            debugLog("[WorkoutRecorder] strap source requested but no known devices and no paired Watch — downgrading to .none", level: .warning)
        case .use(.strap):
            break
        }
    }

    /// The source that will be recorded as provenance for a resolution, so
    /// downstream analysis knows which fields are trustworthy.
    static func provenanceSource(for resolution: Resolution) -> WorkoutRecorder.HRSource? {
        switch resolution {
        case let .use(source): return source
        case .reconnectThenUseStrap: return .strap
        case .strapBusy: return nil
        }
    }
}
