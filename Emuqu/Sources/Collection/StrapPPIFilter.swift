import Foundation

/// One optical (PPG) inter-pulse interval, in the app's own terms rather than
/// the Polar SDK's.
///
/// The boundary type for the anti-corruption layer: the SDK's sample types are
/// only ever consumed, never constructed, so nothing downstream — and no test —
/// could reach this logic while it spoke in SDK types.
struct StrapPPISample: Equatable {
    /// The measured inter-pulse interval in milliseconds.
    let ppInMs: Int
    /// The sensor's own estimate of the error on that interval, in ms.
    let ppErrorEstimate: Int
    /// Non-zero when the sensor flags the interval as unreliable (motion,
    /// poor contact).
    let blockerBit: Int
}

/// The quality gate an optical interval must pass before it is trusted as a
/// heartbeat.
///
/// ## Why this exists
///
/// The live PPI stream (`PolarManager+Streaming.acceptedPpiInterval`) and a
/// recording pulled off the Verity Sense's own memory
/// (`PolarManager+VeritySense.convertOfflinePpiToRRPoints`) must apply the
/// same three gates from the same constants. Two hand-written copies reading
/// their physiological range from **different constants**
/// (`HRVConstants.RRValidity.polarStreamRange` vs
/// `HRVThresholds.minimumRRIntervalMs...maximumRRIntervalMs`) agree only by
/// accident: if either moves, the same sensor's data is filtered differently
/// depending on whether it arrived live or was downloaded afterwards — the
/// live night and the recovered night disagreeing, with no symptom the user
/// could see.
///
/// One gate, one source of truth, used by both paths.
enum StrapPPIFilter {
    /// Intervals whose error estimate exceeds this are discarded. Optical
    /// sensing degrades with motion and contact; above this the interval is
    /// noise dressed as a beat.
    static let maxErrorEstimateMs = 20

    /// The physiological range, 300–2000 ms (200–30 bpm). Deliberately read
    /// from the shared constant rather than restated, so this cannot drift from
    /// the rest of the app's idea of a plausible beat.
    static var acceptedRange: ClosedRange<Int> { HRVConstants.RRValidity.polarStreamRange }

    /// The interval if it passes all three gates, or nil.
    ///
    ///   1. blocker bit set → the sensor says the measurement is unreliable
    ///   2. error estimate above the cap
    ///   3. outside the physiological range
    static func acceptedInterval(_ sample: StrapPPISample) -> Int? {
        guard sample.blockerBit == 0, sample.ppErrorEstimate <= maxErrorEstimateMs else { return nil }
        guard acceptedRange.contains(sample.ppInMs) else { return nil }
        return sample.ppInMs
    }

    /// A recording's accepted intervals as a beat series.
    ///
    /// The timeline advances **only across accepted beats**: a rejected
    /// interval contributes no elapsed time, so `t_ms` measures accumulated
    /// good beats rather than wall clock. That is the behaviour the offline
    /// path has always had and it is preserved here deliberately — it is also
    /// why the window selector translates through `wallClockMs` rather than
    /// trusting `t_ms` across gaps.
    static func rrPoints(from samples: [StrapPPISample]) -> [RRPoint] {
        var points: [RRPoint] = []
        var cumulativeMs: Int64 = 0
        for sample in samples {
            guard let interval = acceptedInterval(sample) else { continue }
            points.append(RRPoint(t_ms: cumulativeMs, rr_ms: interval))
            cumulativeMs += Int64(interval)
        }
        return points
    }
}
