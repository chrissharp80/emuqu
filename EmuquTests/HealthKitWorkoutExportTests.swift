@testable import Emuqu
import HealthKit
import XCTest

/// Tests for the samples written into Apple Health after a workout.
///
/// This is the code that puts your workout
/// into the Health app: heart rate, distance, and active energy. Wrong values
/// here do not just render badly — they are written into the user's permanent
/// Health record and contribute to their activity rings.
@MainActor
final class HealthKitWorkoutExportTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_622_534_400)

    private func sample(
        _ offsetSec: Int, hr: Int? = nil, distance: Double? = nil, mets: Double? = nil
    ) -> WorkoutSample {
        WorkoutSample(offsetSec: offsetSec, heartRate: hr, distanceMeters: distance, mets: mets)
    }

    // MARK: - Heart rate

    func testHeartRateSamplesAreEmittedPerReading() {
        let samples = [sample(0, hr: 120), sample(10, hr: 130), sample(20, hr: 140)]
        XCTAssertEqual(HealthKitWorkoutExport.heartRateSamples(from: samples, startDate: start).count, 3)
    }

    func testTicksWithoutAHeartRateAreSkipped() {
        // The strap drops out mid-workout; those ticks must not become samples.
        let samples = [sample(0, hr: 120), sample(10), sample(20, hr: 140)]
        XCTAssertEqual(HealthKitWorkoutExport.heartRateSamples(from: samples, startDate: start).count, 2)
    }

    func testHeartRateSampleCarriesTheRightValueAndTime() {
        let out = HealthKitWorkoutExport.heartRateSamples(from: [sample(60, hr: 152)], startDate: start)
        let s = try? XCTUnwrap(out.first)
        XCTAssertEqual(s?.quantity.doubleValue(for: HKUnit(from: "count/min")), 152)
        XCTAssertEqual(s?.startDate, start.addingTimeInterval(60))
    }

    func testNoSamplesProducesNothing() {
        XCTAssertTrue(HealthKitWorkoutExport.heartRateSamples(from: [], startDate: start).isEmpty)
    }

    // MARK: - Distance

    func testDistanceIsWrittenAsPerTickDeltas() {
        // Cumulative 0, 100, 250 -> deltas 100 and 150. Writing cumulative
        // values instead would triple-count the distance in Health.
        let samples = [sample(0, distance: 0), sample(10, distance: 100), sample(20, distance: 250)]
        let out = HealthKitWorkoutExport.distanceSamples(from: samples, sport: .run, startDate: start)
        let metres = out.map { $0.quantity.doubleValue(for: .meter()) }
        XCTAssertEqual(metres, [100, 150])
    }

    func testNonAdvancingDistanceIsSkipped() {
        // GPS jitter reports the same or a lower cumulative distance. Those
        // ticks must not emit — a negative delta would subtract from the
        // user's Health total. The first reading is real travel and does.
        let samples = [sample(0, distance: 100), sample(10, distance: 100), sample(20, distance: 90)]
        let out = HealthKitWorkoutExport.distanceSamples(from: samples, sport: .run, startDate: start)
        XCTAssertEqual(out.count, 1, "only the advancing reading emits")
        XCTAssertEqual(out.first?.quantity.doubleValue(for: .meter()), 100)
    }

    func testTotalDistanceMatchesTheFinalCumulativeReading() {
        let samples = (0 ..< 20).map { sample($0 * 10, distance: Double($0) * 45) }
        let out = HealthKitWorkoutExport.distanceSamples(from: samples, sport: .run, startDate: start)
        let total = out.reduce(0.0) { $0 + $1.quantity.doubleValue(for: .meter()) }
        XCTAssertEqual(total, 19 * 45, accuracy: 0.001, "deltas must sum to the distance actually travelled")
    }

    func testCyclingUsesTheCyclingDistanceType() {
        // Filing a ride under walking/running distance corrupts both metrics.
        let samples = [sample(0, distance: 0), sample(10, distance: 100)]
        let ride = HealthKitWorkoutExport.distanceSamples(from: samples, sport: .bike, startDate: start)
        let run = HealthKitWorkoutExport.distanceSamples(from: samples, sport: .run, startDate: start)
        XCTAssertEqual(ride.first?.quantityType, HKQuantityType.quantityType(forIdentifier: .distanceCycling))
        XCTAssertEqual(run.first?.quantityType, HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning))
    }

    func testNonFiniteDistanceIsRejected() {
        let samples = [sample(0, distance: 0), sample(10, distance: .infinity)]
        XCTAssertTrue(HealthKitWorkoutExport.distanceSamples(from: samples, sport: .run, startDate: start).isEmpty)
    }

    // MARK: - Active energy

    func testEnergyIsEmittedForTicksWithMETs() {
        let samples = [sample(0, mets: 8), sample(60, mets: 8), sample(120, mets: 8)]
        let out = HealthKitWorkoutExport.activeEnergySamples(
            from: samples, startDate: start, bodyWeightKg: 75
        )
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.allSatisfy { $0.quantity.doubleValue(for: .kilocalorie()) > 0 })
    }

    func testTicksWithoutMETsAreSkipped() {
        let out = HealthKitWorkoutExport.activeEnergySamples(
            from: [sample(0), sample(60)], startDate: start, bodyWeightKg: 75
        )
        XCTAssertTrue(out.isEmpty)
    }

    func testHeavierAthleteBurnsMoreForTheSameEffort() {
        // kcal scales with body mass; if it did not, the formula is wrong.
        let samples = [sample(0, mets: 8), sample(60, mets: 8)]
        let light = HealthKitWorkoutExport.activeEnergySamples(from: samples, startDate: start, bodyWeightKg: 60)
        let heavy = HealthKitWorkoutExport.activeEnergySamples(from: samples, startDate: start, bodyWeightKg: 100)
        let lightKcal = light.reduce(0.0) { $0 + $1.quantity.doubleValue(for: .kilocalorie()) }
        let heavyKcal = heavy.reduce(0.0) { $0 + $1.quantity.doubleValue(for: .kilocalorie()) }
        XCTAssertGreaterThan(heavyKcal, lightKcal)
    }

    func testHarderEffortBurnsMore() {
        let easy = [sample(0, mets: 4), sample(60, mets: 4)]
        let hard = [sample(0, mets: 12), sample(60, mets: 12)]
        let easyKcal = HealthKitWorkoutExport.activeEnergySamples(from: easy, startDate: start, bodyWeightKg: 75)
            .reduce(0.0) { $0 + $1.quantity.doubleValue(for: .kilocalorie()) }
        let hardKcal = HealthKitWorkoutExport.activeEnergySamples(from: hard, startDate: start, bodyWeightKg: 75)
            .reduce(0.0) { $0 + $1.quantity.doubleValue(for: .kilocalorie()) }
        XCTAssertGreaterThan(hardKcal, easyKcal)
    }

    func testNonFiniteMETsAreRejected() {
        // HKQuantity raises an NSException on NaN or infinity — an uncatchable
        // crash while writing to Health.
        let samples = [sample(0, mets: .nan), sample(60, mets: .infinity)]
        XCTAssertTrue(
            HealthKitWorkoutExport.activeEnergySamples(from: samples, startDate: start, bodyWeightKg: 75).isEmpty
        )
    }

    func testNegativeMETsAreRejected() {
        let samples = [sample(0, mets: -5), sample(60, mets: -5)]
        XCTAssertTrue(
            HealthKitWorkoutExport.activeEnergySamples(from: samples, startDate: start, bodyWeightKg: 75).isEmpty
        )
    }
}
