import Foundation

/// Progress of a device-memory fetch, as the record screen shows it.
///
/// A top-level type, not a nested one: the aggregate type-size gate counts a
/// nested type against its parent no matter which file it sits in, and
/// `PolarManager` is over the threshold. `PolarManager.FetchProgress` remains
/// as a typealias so no call site changes.
///
/// The stage strings are the user-facing text, which is why they are the raw
/// values rather than a separate mapping.
struct StrapFetchProgress: Equatable {
    enum Stage: String {
        case stopping = "Stopping recording..."
        case finalizing = "Waiting for device to finalize..."
        case listingExercises = "Finding recorded data..."
        case fetchingData = "Downloading from device..."
        case reconnecting = "Reconnecting to device..."
        case retrying = "Retrying..."
        case complete = "Complete"
        case failed = "Failed"
    }

    var stage: Stage
    var progress: Double // 0.0 to 1.0
    var attempt: Int
    var maxAttempts: Int
    var statusMessage: String

    static let idle = StrapFetchProgress(stage: .stopping, progress: 0, attempt: 0, maxAttempts: 3, statusMessage: "")

}
