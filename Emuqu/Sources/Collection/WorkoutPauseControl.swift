import Foundation

/// Pausing and resuming a workout, by hand or automatically.
///
/// The recorder stays in `.recording` while paused — pause is a soft gate
/// inside the ticker, not a separate phase. This keeps every other
/// subsystem (strap, GPS, broker, Watch bridge) running so samples are ready
/// to flow the instant we resume; a hard phase transition would force those
/// to tear down + re-init each time, which would lose the first few seconds
/// of the resumed segment.
@Observable
@MainActor
final class WorkoutPauseControl {
    // MARK: Auto-pause / auto-resume counters
    //
    // Auto-pause fires after a rolling window of "no movement" ticks and
    // auto-resume fires after a shorter window of "moving again" ticks.
    // Separate counters rather than one signed integer because the
    // thresholds are different and conflating the two made the transition
    // feel draggy — resume felt sluggish because the decrement from "−15
    // stationary" to zero took its own 15 ticks.
    /// Counters and thresholds both live in `AutoPauseDetector`; the ticker
    /// accrues them each second.
    var autoPause = AutoPauseDetector()

    private let lifecycle: WorkoutLifecycle
    private let sensors: WorkoutSensors

    init(lifecycle: WorkoutLifecycle, sensors: WorkoutSensors) {
        self.lifecycle = lifecycle
        self.sensors = sensors
    }

    /// Pause the active workout. No-op if not currently recording, or
    /// already paused. `isAuto = true` flags this pause as system-
    /// initiated so the auto-resume path knows it may re-enable the
    /// clock; user-initiated pauses can only be resumed by the user.
    func pause(isAuto: Bool = false) {
        guard case .recording = lifecycle.phase, !lifecycle.isPaused else { return }
        lifecycle.isPaused = true
        lifecycle.autoPaused = isAuto
        lifecycle.pausedMotion.pause(pedometer: sensors.pedometer.distanceMeters, footPod: sensors.footPodDistanceMeters())
        lifecycle.pauseTimeline.pause(atElapsed: lifecycle.elapsedSeconds, now: Date())
        sensors.startedLocation?.isPaused = true
        autoPause.reset()
        debugLog("[WorkoutRecorder] paused (auto=\(isAuto))")
    }

    /// Resume the active workout, now or, for a resume asked for earlier than
    /// it arrived (a Watch Resume), at `resumedAt`
    /// (`WorkoutRecorder.resumeFromWatch`). No-op if not paused.
    func resume(at resumedAt: Date? = nil) {
        guard case .recording = lifecycle.phase, lifecycle.isPaused else { return }
        lifecycle.isPaused = false
        lifecycle.autoPaused = false
        lifecycle.pausedMotion.resume(
            pedometer: sensors.pedometer.distanceMeters, footPod: sensors.footPodDistanceMeters(), resumedAt: resumedAt
        )
        lifecycle.pauseTimeline.resume(now: resumedAt ?? Date())
        sensors.startedLocation?.isPaused = false
        autoPause.reset()
        debugLog("[WorkoutRecorder] resumed")
    }

    /// Records the motion counters while paused, once a tick, so a resume
    /// dated earlier can end the paused stretch where it was asked for.
    func notePausedMotion(at date: Date) {
        guard lifecycle.isPaused else { return }
        lifecycle.pausedMotion.note(pedometer: sensors.pedometer.distanceMeters, footPod: sensors.footPodDistanceMeters(), at: date)
    }
}
