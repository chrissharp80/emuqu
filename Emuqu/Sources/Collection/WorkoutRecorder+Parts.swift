import Foundation

// The recorder's work, by job. Each is a value built on each access around
// this recorder; callers name the job they ask for.

extension WorkoutRecorder {
    /// The once-per-second loop over the live signals.
    var ticker: WorkoutTicker {
        WorkoutTicker(recorder: self)
    }

    /// Assembling the finished session and archiving it.
    var finalizer: WorkoutFinalizer {
        WorkoutFinalizer(recorder: self)
    }

    /// The live context the coach is given.
    var aiContext: WorkoutAIContextBuilder {
        WorkoutAIContextBuilder(recorder: self)
    }

    typealias HRArbitration = WorkoutTicker.HRArbitration

    static func sportFTP(for sport: Sport, settings: UserSettings) -> Int? {
        WorkoutAIContextBuilder.sportFTP(for: sport, settings: settings)
    }
}
