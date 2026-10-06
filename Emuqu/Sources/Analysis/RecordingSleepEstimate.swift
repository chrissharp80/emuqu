import Foundation

/// Time asleep estimated from the length of an overnight recording alone,
/// for a night Apple Health has no sleep for: 90 % of a recording past 3 h,
/// 85 % of a shorter one.
///
/// The Overnight screen and the Overnight PDF both read this one estimate,
/// so the two always print the same figure. It carries no deep sleep and no
/// awakenings: a recording length says nothing about sleep stages, so they
/// stay unknown rather than being invented as a fixed share.
struct RecordingSleepEstimate: Equatable {
    /// Recordings longer than this count as a full night.
    static let fullNightMinutes = 180
    static let fullNightAsleepShare = 0.90
    static let shortAsleepShare = 0.85

    let recordingMinutes: Int
    let asleepMinutes: Int

    init(recordingMinutes: Int) {
        let minutes = max(0, recordingMinutes)
        let share = minutes > Self.fullNightMinutes ? Self.fullNightAsleepShare : Self.shortAsleepShare
        self.recordingMinutes = minutes
        self.asleepMinutes = Int(Double(minutes) * share)
    }

    /// Asleep time as a percentage of the recording; 0 for an empty recording.
    var efficiencyPercent: Double {
        recordingMinutes > 0 ? Double(asleepMinutes) / Double(recordingMinutes) * 100 : 0
    }
}
