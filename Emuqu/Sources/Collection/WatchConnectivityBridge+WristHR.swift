import Foundation

extension WatchConnectivityBridge {
    /// The Watch's wrist HR while it is still arriving, else nil. A reading
    /// the Watch sent more than `wristHRMaxAgeSec` ago is what a Watch that
    /// stopped sending leaves behind; recording it every second would write a
    /// flat, false heart rate into the samples. A steady heart rate the Watch
    /// keeps sending stays fresh.
    func freshWristHR(now: Date) -> Int? {
        guard let wrist = WatchPayloadBounds.plausibleHeartRate(latestWatchHR),
              let receivedAt = latestWatchHRAt else { return nil }
        return now.timeIntervalSince(receivedAt) <= WorkoutTicker.HRArbitration.wristHRMaxAgeSec ? wrist : nil
    }
}
