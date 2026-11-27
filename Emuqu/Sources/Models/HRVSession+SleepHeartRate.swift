import Foundation

// The one rule for which heart rate stands as a night's sleep HR: the score,
// its breakdown, the stored vitals snapshot and the detail screens read it.

extension HRVSession {
    /// The strap's analysis-window mean HR as this night's sleep HR.
    ///
    /// Nil when the recording is kept out of HRV aggregates (`.insufficient`,
    /// `.preSleep`): its heart rate was taken awake, or over too little of the
    /// night, so it is not a sleep or resting HR. Nil too when the analysis
    /// measured no heart rate (an estimate, or 0).
    var strapSleepHeartRate: Double? {
        analysisResult.flatMap(strapSleepHeartRate(in:))
    }

    /// `strapSleepHeartRate` read from `result` rather than the stored analysis.
    func strapSleepHeartRate(in result: HRVAnalysisResult) -> Double? {
        guard isReliableForHRVAggregates,
              let meanHR = result.measured(result.timeDomain.meanHR, as: .meanHR), meanHR > 0 else { return nil }
        return meanHR
    }

    /// `vitals` with this night's sleep HR in place: the strap's for a usable
    /// recording; otherwise the HealthKit resting HR `vitals` carries. An
    /// unusable recording's own mean HR, copied into the vitals by a pass
    /// that ran before the recording was classified, is dropped rather than
    /// read as a resting HR.
    func withSleepHeartRate(_ vitals: RecoveryVitals, from result: HRVAnalysisResult? = nil) -> RecoveryVitals {
        guard let result = result ?? analysisResult else { return vitals }
        if let strapHR = strapSleepHeartRate(in: result) { return vitals.withStrapNocturnalRHR(strapHR) }
        return vitals.droppingRestingHeartRate(copiedFrom: result.timeDomain.meanHR)
    }

    /// The stored vitals snapshot with this night's sleep HR in place.
    var vitalsWithSleepHeartRate: RecoveryVitals? {
        vitalsSnapshot.map { withSleepHeartRate($0) }
    }

    /// Puts this night's sleep HR into the stored vitals snapshot
    /// (`withSleepHeartRate`). Run once the recording's HRV quality is
    /// decided, since that decides whether the strap's heart rate counts.
    mutating func applySleepHeartRateToVitals() {
        guard let vitals = vitalsSnapshot else { return }
        vitalsSnapshot = withSleepHeartRate(vitals)
    }

    /// Puts this night's sleep HR into the stored vitals snapshot after its
    /// analysis or quality changed from `previous`'s. A resting HR equal to
    /// `previous`'s strap sleep HR is that analysis's swap, not a HealthKit
    /// reading, so it is dropped before this analysis's sleep HR goes in: a
    /// pass that moves the window, or marks the recording unusable, never
    /// keeps the old window's heart rate as the night's sleep HR. With the
    /// same analysis and quality it changes nothing.
    mutating func refreshSleepHeartRate(replacing previous: HRVSession) {
        guard let vitals = vitalsSnapshot else { return }
        let withoutPrevious = previous.strapSleepHeartRate.map { vitals.droppingRestingHeartRate(copiedFrom: $0) } ?? vitals
        vitalsSnapshot = withSleepHeartRate(withoutPrevious)
    }
}
