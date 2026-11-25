import Foundation
import HealthKit

/// The biometric profile Apple Health holds: body mass, date of birth and
/// biological sex, for the "Fill from Apple Health" button and the
/// assistant's facts.
///
/// A value over the part it uses: queries run through `access`.
@MainActor
struct ProfileHealthQueries {
    let access: HealthKitAccess

    func fetchBiometricProfile() async -> HealthKitManager.BiometricProfile {
        async let bodyWeightKg = fetchLatestBodyMassKg()
        let sex: HKBiologicalSex? = (try? access.store.biologicalSex().biologicalSex)
        // HealthKit's birth-date components are Gregorian; building them with
        // the user's calendar (Buddhist, Japanese) would give the wrong year.
        let dob: Date? = {
            guard let components = try? access.store.dateOfBirthComponents(),
                  let date = Calendar(identifier: .gregorian).date(from: components) else { return nil }
            return date
        }()
        return await HealthKitManager.BiometricProfile(
            bodyWeightKg: bodyWeightKg,
            biologicalSex: sex,
            dateOfBirth: dob
        )
    }

    /// Latest body-mass sample in kg, or nil if none / not authorized.
    func fetchLatestBodyMassKg() async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) else { return nil }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return await access.runBoundedQuery(timeout: HealthKitAccess.backgroundAggregateQueryTimeoutSec) { resolve in
            HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                resolve(Self.firstBodyMassKg(samples))
            }
        }
    }

    nonisolated private static func firstBodyMassKg(_ samples: [HKSample]?) -> Double? {
        guard let sample = samples?.first as? HKQuantitySample else { return nil }
        return sample.quantity.doubleValue(for: .gramUnit(with: .kilo))
    }
}
