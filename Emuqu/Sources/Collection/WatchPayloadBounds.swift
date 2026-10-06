import Foundation

/// Checks on the numbers the Watch sends the phone, applied where the
/// recorder first reads them. The Watch is a separately built app on another
/// device, so a value from it is not trusted to be finite or physiological:
/// `Int(...)` traps on a non-finite or huge `Double`, and an absurd heart
/// rate would reach the display, the peak and the saved samples.
enum WatchPayloadBounds {
    /// Beats the Watch relayed from its strap that are finite and inside the
    /// same band the phone keeps for Watch-routed beats
    /// (`HRVConstants.RRValidity`, 300–2500 ms exclusive). Anything else is
    /// dropped before it is converted or summed.
    static func plausibleRRMillis(_ values: [Double]) -> [Double] {
        let low = Double(HRVConstants.RRValidity.watchSynthesisMinExclusive)
        let high = Double(HRVConstants.RRValidity.watchSynthesisMaxExclusive)
        return values.filter {
            let millis = $0.rounded()
            return millis.isFinite && millis > low && millis < high
        }
    }

    /// Heart rates a person can have, in bpm. Wider than the 25–220 bpm the
    /// HRV pipeline keeps for resting beats, so a real maximal effort is
    /// never hidden from the live display.
    static let heartRateRange: ClosedRange<Int> = 25 ... 250

    /// `bpm` when it is inside `heartRateRange`, else nil.
    static func plausibleHeartRate(_ bpm: Int?) -> Int? {
        guard let bpm, heartRateRange.contains(bpm) else { return nil }
        return bpm
    }
}
