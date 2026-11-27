import Foundation

/// The energy a workout burned above rest, from its METs: the one rule every
/// calorie figure the app shows or stores uses, and the Active Energy it
/// writes to Apple Health, so one workout reads one kcal everywhere.
///
/// Active (net) energy is what Apple Fitness and Strava report for a workout:
/// gross Compendium METs less the 1 MET of resting metabolism, which Apple
/// Watch already writes as basal energy. kcal/min = METs x 3.5 x kg / 200
/// (ACSM; Ainsworth et al. 2011, Compendium of Physical Activities).
enum WorkoutEnergy {
    /// Oxygen uptake of one MET, ml/kg/min.
    static let mlOxygenPerKgPerMET = 3.5
    /// Oxygen per kcal, ml (5 kcal per litre).
    static let mlOxygenPerKcal = 200.0
    /// Resting metabolism, by the definition of the MET.
    static let restingMETs = 1.0

    /// The METs above rest: gross Compendium METs less the 1 MET of resting
    /// metabolism, never below zero.
    nonisolated static func netMETs(_ grossMETs: Double) -> Double {
        max(0, grossMETs - restingMETs)
    }

    /// Active kcal of `minutes` at `grossMETs` for a body of `bodyWeightKg`.
    nonisolated static func activeKilocalories(grossMETs: Double, minutes: Double, bodyWeightKg: Double) -> Double {
        netMETs(grossMETs) * mlOxygenPerKgPerMET * bodyWeightKg * minutes / mlOxygenPerKcal
    }

    /// Active kcal over `samples`: each tick's METs over the seconds since the
    /// tick before it in time order (the first since the start, at least one
    /// second), as `HealthKitWorkoutExport.activeEnergySamples` writes them.
    /// Nil when no sample carries METs.
    nonisolated static func activeKilocalories(samples: [WorkoutSample], bodyWeightKg: Double) -> Double? {
        var total: Double?
        var previous = 0
        for sample in samples.sorted(by: { $0.offsetSec < $1.offsetSec }) {
            defer { previous = sample.offsetSec }
            guard let mets = sample.mets, mets > 0, mets.isFinite else { continue }
            let minutes = Double(max(1, sample.offsetSec - previous)) / 60.0
            total = (total ?? 0) + activeKilocalories(grossMETs: mets, minutes: minutes, bodyWeightKg: bodyWeightKg)
        }
        return total
    }
}
