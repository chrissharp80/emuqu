import Foundation

/// The power readings a workout counted while it was running: their sum and
/// count for the average, and the highest single reading. Readings taken
/// while paused are not counted.
struct WorkoutPowerTally: Equatable {
    private(set) var sum = 0
    private(set) var count = 0
    private(set) var peak = 0

    mutating func add(_ watts: Int) {
        sum += watts
        count += 1
        peak = max(peak, watts)
    }

    /// The mean of the counted readings; nil before any.
    var average: Double? {
        count > 0 ? Double(sum) / Double(count) : nil
    }
}
