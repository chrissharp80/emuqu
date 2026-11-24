import Foundation

/// Progress of a device-memory fetch, as the record screen shows it.
///
/// `PolarManager.FetchProgress` is a typealias for it.
///
/// The stage raw values and `statusMessage` are English log text; the record
/// screen shows its own localized wording per stage
/// (`FetchProgressCard.stageText`).
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
}
