import Foundation

/// Recovery vitals from overnight/sleep period
struct RecoveryVitals: Codable, Sendable, Equatable {
    let respiratoryRate: Double? // breaths per minute
    let respiratoryRateBaseline: Double? // 7-day average
    let oxygenSaturation: Double? // percentage (0-100)
    let oxygenSaturationMin: Double? // lowest during sleep
    /// Tonight's wrist temperature on a common scale (°C offset from a fixed
    /// 36.5 °C), NOT a personal deviation. See `wristTemperatureDeviation`.
    let wristTemperature: Double?
    /// Mean of the 7 nights before, on the same scale as `wristTemperature`.
    let wristTemperatureBaseline: Double?
    /// Sleep-period heart rate.
    ///
    /// When the user has a strap recording for the night, this should be
    /// populated from the analysis-window mean HR (`session.analysisResult
    /// .timeDomain.meanHR`) — the same nocturnal-strap signal that
    /// `BaselineTracker.meanHRBaseline` is built from. Apples-to-apples
    /// against the baseline.
    ///
    /// Falls back to HealthKit's `.restingHeartRate` sample when no strap
    /// recording exists. **That fallback is daytime-rest physiology** (Apple
    /// computes it from quiet daytime windows), not nocturnal — so the
    /// score will read systematically higher when the fallback fires.
    /// The score-breakdown copy distinguishes the two so the user knows
    /// what they're looking at.
    ///
    /// References for choosing nocturnal sleep HR over Apple's daytime
    /// RHR: Halson 2014 (Sports Medicine); Plews & Buchheit 2014 (Frontiers
    /// in Physiology); Altini & Plews 2021 (Sensors).
    let restingHeartRate: Double?

    /// True when every substantive vitals field is nil. Used by the dashboard
    /// to decide whether to re-fetch from HealthKit: the Watch writes overnight
    /// vitals (resp rate, SpO2, wrist temp) some minutes AFTER sleep ends, so
    /// the snapshot captured at session acceptance can be entirely empty even
    /// though the Watch has the data and will sync it shortly after. Treating
    /// empty snapshots as "no data yet" triggers a live fetch on dashboard open.
    var isEmpty: Bool {
        respiratoryRate == nil
            && respiratoryRateBaseline == nil
            && oxygenSaturation == nil
            && oxygenSaturationMin == nil
            && wristTemperature == nil
            && wristTemperatureBaseline == nil
            && restingHeartRate == nil
    }

    /// Respiratory rate deviation from baseline (positive = elevated)
    var respiratoryDeviation: Double? {
        guard let rate = respiratoryRate, let baseline = respiratoryRateBaseline else { return nil }
        return rate - baseline
    }

    /// Is respiratory rate elevated? (>2 breaths/min above baseline suggests illness/stress)
    var isRespiratoryElevated: Bool {
        guard let deviation = respiratoryDeviation else { return false }
        return deviation > 2.0
    }

    /// Nightly SpO2 (%) below which the recovery score's SpO2 penalty applies;
    /// every screen and report that flags low SpO2 reads this.
    static let concerningSpO2Below: Double = 95.0

    /// Is SpO2 concerning? (below `concerningSpO2Below`)
    var isSpO2Concerning: Bool {
        guard let spo2 = oxygenSaturation else { return false }
        return spo2 < Self.concerningSpO2Below
    }

    /// Tonight's wrist temperature against the user's own baseline, in °C
    /// (positive = warmer). Nil without a baseline: the raw reading is offset
    /// from a population constant, not from the user, so it is no deviation.
    var wristTemperatureDeviation: Double? {
        guard let temp = wristTemperature, let baseline = wristTemperatureBaseline else { return nil }
        return temp - baseline
    }

    /// Is temperature elevated? (>0.5°C above the personal baseline)
    var isTemperatureElevated: Bool {
        guard let deviation = wristTemperatureDeviation else { return false }
        return deviation > 0.5
    }

    /// Overall vitals status
    var status: VitalsStatus {
        if isRespiratoryElevated && isTemperatureElevated {
            return .warning // Two overnight signals up together
        } else if isRespiratoryElevated || isTemperatureElevated || isSpO2Concerning {
            return .elevated
        }
        return .normal
    }

    enum VitalsStatus {
        case normal, elevated, warning
    }

    /// Returns a copy with `restingHeartRate` replaced by the supplied
    /// strap-derived nocturnal HR when non-nil. Used by the session-
    /// acceptance / morning-processing pipelines to swap Apple's
    /// daytime-rest RHR sample for the strap's nocturnal analysis-window
    /// mean HR — making the comparison against `meanHRBaseline`
    /// physiologically self-consistent (both sides nocturnal-strap-
    /// derived). When `strapHR` is nil, the receiver is returned
    /// unchanged so the HealthKit fallback survives.
    func withStrapNocturnalRHR(_ strapHR: Double?) -> RecoveryVitals {
        guard let strapHR else { return self }
        return RecoveryVitals(
            respiratoryRate: respiratoryRate,
            respiratoryRateBaseline: respiratoryRateBaseline,
            oxygenSaturation: oxygenSaturation,
            oxygenSaturationMin: oxygenSaturationMin,
            wristTemperature: wristTemperature,
            wristTemperatureBaseline: wristTemperatureBaseline,
            restingHeartRate: strapHR
        )
    }
}
