import Foundation

/// Turning a finished workout into an archived session: running the analysis,
/// assembling the metadata, writing it, and everything that has to happen
/// exactly once at the end of a workout.
///
/// Works from `recording`, what the recorder held when the workout stopped,
/// and the services it names; it reads nothing else of the recorder.
@MainActor
struct WorkoutFinalizer {
    /// What the recorder held at Stop. The ticker and sensors have stopped
    /// by then, so none of it changes while the finalizer runs.
    struct Recording {
        let session: HRVSession?
        let startDate: Date?
        /// The per-second samples, before any Apple Watch HR backfill.
        let samples: [WorkoutSample]
        /// Sample offsets whose HR came from the Watch's wrist while the
        /// strap was silent.
        let wristHROffsets: [Int]
        /// The live coach snapshot taken at Stop, before the broker cleared.
        let liveSnapshot: AssistantContext.LiveWorkoutSnapshot?
        let pauseTimeline: PauseTimeline
        let pausedMotion: PausedMotionLedger
        let elapsedSeconds: Int
        let activeHRSource: WorkoutRecorder.HRSource
        /// The GPS and barometer, when this workout started them.
        let location: WorkoutLocationManager?
        let pedometerDistanceMeters: Double
        let footPodDistanceMeters: Double
        let motionDistanceMeters: Double
        let power: WorkoutPowerTally
        /// The saved route this workout followed, if any.
        let routeName: String?
    }

    let recording: Recording
    let settings: UserSettings
    let core: RecordingCore
    let services: WorkoutServices
    /// Archives the finished session and builds its stored coach context.
    let sessionLifecycle: WorkoutSessionLifecycle
}
