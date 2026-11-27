import Foundation

// The targets a heart-rate-recovery reading is captured at and read back by.

extension HRRSample {
    /// The offsets after Stop the capture aims for: one and two minutes.
    static let targetOffsetsSec = [60, 120]

    /// How far a reading may lie from its target and still stand as that
    /// target's reading. The one tolerance the capture accepts a late or
    /// sparse reading by and the summary reads it back with
    /// (`bestAtOneMinute`, `bestAtTwoMinutes`), so no reading the capture
    /// stores is then ignored.
    static let targetToleranceSec = 15

    /// Whether a reading taken `offsetSec` after Stop stands for `target`.
    static func isReading(atOffset offsetSec: Int, for target: Int) -> Bool {
        abs(offsetSec - target) <= targetToleranceSec
    }

    /// The target this reading stands for, if any.
    var target: Int? {
        Self.targetOffsetsSec.first { Self.isReading(atOffset: offsetSec, for: $0) }
    }
}
