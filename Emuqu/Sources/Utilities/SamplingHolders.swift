import Foundation

/// Which kind of recording asked the diagnostics sampler to run.
enum SamplingHolder: Hashable, Sendable {
    /// A workout, from its start to its stop.
    case workout
    /// A Record screen recording: a night or a resumed segment.
    case recordScreen
}

/// The recordings the diagnostics sampler is running for. The sampler is
/// shared: a Watch workout's stop must not end a night's memory trace.
struct SamplingHolders: Equatable, Sendable {
    private var holders: Set<SamplingHolder> = []

    /// `holder` started a recording.
    mutating func add(_ holder: SamplingHolder) {
        holders.insert(holder)
    }

    /// Removes `holder`; true when no recording is left, so the sampler stops.
    mutating func remove(_ holder: SamplingHolder) -> Bool {
        holders.remove(holder)
        return holders.isEmpty
    }
}
