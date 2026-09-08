import Foundation

/// How long the app keeps trying to get a dropped strap back, and how it spaces
/// the attempts.
///
/// It is the schedule that decides
/// whether a mid-night BLE dropout costs the user the night: the H10 keeps
/// recording to its own memory throughout, so as long as the phone gets back to
/// it before the user takes the strap off, nothing is lost. Shorten the window
/// and a five-minute radio outage ends the session.
///
/// The tiers are deliberately front-loaded — most dropouts recover in seconds,
/// so the first attempts are cheap and fast, and the long tail spaces out to
/// stop the radio burning battery for the rest of the night.
///
/// **The window is ~19.75 minutes, not ~45.** The schedule sums to
/// 5×2 + 10×5 + 15×15 + 30×30 = 1,185s. `totalWindowSeconds` is derived so
/// the figure cannot drift from the tiers the way a hand-written
/// "60 attempts ≈ 45 min of coverage" claim does.
enum PolarReconnectPolicy {
    /// Attempts before the app stops trying and marks the stream exhausted.
    static let maxAttempts = 60

    /// Graduated backoff: 2s → 5s → 15s → 30s.
    ///
    /// Takes the attempt number rather than reading manager state so the
    /// schedule can be stated, tested and reasoned about on its own.
    static func backoffSeconds(forAttempt attempt: Int) -> Double {
        if attempt <= 5 {
            2.0
        } else if attempt <= 15 {
            5.0
        } else if attempt <= 30 {
            15.0
        } else {
            30.0
        }
    }

    /// True once the app should stop retrying.
    static func shouldGiveUp(afterAttempt attempt: Int) -> Bool {
        attempt > maxAttempts
    }

    /// Total wall-clock the schedule spends before giving up.
    ///
    /// Derived rather than written down, so a change to any tier shows up as a
    /// change to the number that actually matters — how long a strap can be out
    /// of range and still be recovered.
    static var totalWindowSeconds: Double {
        (1 ... maxAttempts).reduce(0.0) { $0 + backoffSeconds(forAttempt: $1) }
    }
}
