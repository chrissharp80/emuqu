import Foundation

extension WorkoutMetadata {
    /// The HRR readings re-measured from the workout's peak heart rate (the
    /// highest per-second sample), or nil when they already are.
    ///
    /// Builds that measured the drops from the heart rate at Stop stored that
    /// rate as each reading's `peakHR`, below the session's real peak. This
    /// restores the peak as the reference: a measured reading keeps its heart
    /// rate and gets a new drop; Apple's computed reading keeps its drop and
    /// gets the heart rate that drop implies, as `HRRCaptureService` builds it.
    func hrrRemeasuredFromPeak() -> [HRRSample]? {
        guard let readings = hrrSamples, !readings.isEmpty,
              let peak = samples?.compactMap(\.heartRate).max(), peak > 0,
              readings.contains(where: { $0.peakHR < peak }) else { return nil }
        return readings.map { Self.remeasured($0, peak: peak) }
    }

    private static func remeasured(_ reading: HRRSample, peak: Int) -> HRRSample {
        guard reading.peakHR < peak else { return reading }
        if reading.provenance == .healthKitComputed {
            return HRRSample(
                offsetSec: reading.offsetSec, hr: max(0, peak - reading.drop),
                drop: reading.drop, peakHR: peak, provenance: reading.provenance
            )
        }
        return HRRSample(
            offsetSec: reading.offsetSec, hr: reading.hr,
            drop: peak - reading.hr, peakHR: peak, provenance: reading.provenance
        )
    }
}
