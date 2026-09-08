@testable import Emuqu
import HealthKit
import XCTest

final class WorkoutDeduplicationTests: XCTestCase {
    // MARK: - Helpers

    private func makeWorkout(
        minutesFromEpoch: Double,
        type: HKWorkoutActivityType = .running,
        duration: Double = 30,
        calories: Double? = 200,
        avgHR: Double? = nil,
        maxHR: Double? = nil
    ) -> HealthKitManager.WorkoutSummary {
        let date = Date(timeIntervalSince1970: minutesFromEpoch * 60)
        return HealthKitManager.WorkoutSummary(
            date: date,
            type: type,
            durationMinutes: duration,
            caloriesBurned: calories,
            averageHR: avgHR,
            maxHR: maxHR
        )
    }

    // MARK: - Tests

    func testEmptyArrayReturnsEmpty() {
        let result = HealthKitManager.deduplicateWorkouts([])
        XCTAssertEqual(result.count, 0)
    }

    func testSingleWorkoutReturnsSame() {
        let w = makeWorkout(minutesFromEpoch: 100)
        let result = HealthKitManager.deduplicateWorkouts([w])
        XCTAssertEqual(result.count, 1)
    }

    func testNoDuplicatesPreservesAll() {
        let workouts = [
            makeWorkout(minutesFromEpoch: 100, type: .running),
            makeWorkout(minutesFromEpoch: 200, type: .cycling),
            makeWorkout(minutesFromEpoch: 300, type: .swimming)
        ]
        let result = HealthKitManager.deduplicateWorkouts(workouts)
        XCTAssertEqual(result.count, 3)
    }

    func testDuplicatesSameTypeWithin5MinDeduped() {
        let workouts = [
            makeWorkout(minutesFromEpoch: 100, type: .running, calories: 200),
            makeWorkout(minutesFromEpoch: 102, type: .running, calories: 210)
        ]
        let result = HealthKitManager.deduplicateWorkouts(workouts)
        XCTAssertEqual(result.count, 1)
    }

    func testKeepsWorkoutWithHRData() {
        let noHR = makeWorkout(minutesFromEpoch: 100, type: .running, calories: 200, avgHR: nil, maxHR: nil)
        let withHR = makeWorkout(minutesFromEpoch: 102, type: .running, calories: 180, avgHR: 145, maxHR: 172)
        let result = HealthKitManager.deduplicateWorkouts([noHR, withHR])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].averageHR, 145)
    }

    /// Different-type but time-overlapping workouts collapse: Emuqu
    /// exports a session as Walk, the Watch's auto-detection writes a parallel
    /// Run HKWorkout covering the same wall clock. Physically one activity.
    func testOverlappingDifferentTypesCollapse() {
        let walk = makeWorkout(minutesFromEpoch: 100, type: .walking, duration: 35, avgHR: 115, maxHR: 140)
        let run = makeWorkout(minutesFromEpoch: 100, type: .running, duration: 35, avgHR: nil, maxHR: nil)
        let result = HealthKitManager.deduplicateWorkouts([walk, run])
        XCTAssertEqual(result.count, 1)
        // The richer entry survives.
        XCTAssertEqual(result[0].averageHR, 115)
    }

    /// Different types that do NOT overlap in time stay separate (e.g., a brick:
    /// 30-minute ride followed by a run that starts after the ride ends).
    func testDifferentTypesNoOverlapStaySeparate() {
        let ride = makeWorkout(minutesFromEpoch: 100, type: .cycling, duration: 30)
        let run = makeWorkout(minutesFromEpoch: 135, type: .running, duration: 30) // 5 min gap after ride end
        let result = HealthKitManager.deduplicateWorkouts([ride, run])
        XCTAssertEqual(result.count, 2)
    }

    func testDistinctNonOverlappingWorkoutsNotDeduped() {
        // Dedup now merges same-type starts within 5 min OR any pair whose spans
        // overlap ≥ 60% of the shorter (a session + its drifted HealthKit
        // back-fill). Two 30-min runs 20 min apart clear both rules — starts are
        // 20 min > 5 min apart and the spans overlap only ~33% — so they are
        // genuinely distinct back-to-back sessions and must both survive.
        let first = makeWorkout(minutesFromEpoch: 100, type: .running)
        let second = makeWorkout(minutesFromEpoch: 120, type: .running)
        let result = HealthKitManager.deduplicateWorkouts([first, second])
        XCTAssertEqual(result.count, 2)
    }

    func testExactly5MinBoundaryDeduped() {
        let first = makeWorkout(minutesFromEpoch: 100, type: .running, calories: 200)
        let second = makeWorkout(minutesFromEpoch: 105, type: .running, calories: 210) // exactly 5 min = 300s
        let result = HealthKitManager.deduplicateWorkouts([first, second])
        XCTAssertEqual(result.count, 1)
    }

    func testTripleDuplicateReducesToOne() {
        let workouts = [
            makeWorkout(minutesFromEpoch: 100, type: .running, calories: 200, avgHR: nil, maxHR: nil),
            makeWorkout(minutesFromEpoch: 101, type: .running, calories: 190, avgHR: 140, maxHR: nil),
            makeWorkout(minutesFromEpoch: 103, type: .running, calories: 210, avgHR: 142, maxHR: 175)
        ]
        let result = HealthKitManager.deduplicateWorkouts(workouts)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].maxHR, 175) // richest data wins
    }

    func testMixedDuplicatesAndUniques() {
        let workouts = [
            makeWorkout(minutesFromEpoch: 100, type: .running, calories: 200),
            makeWorkout(minutesFromEpoch: 102, type: .running, calories: 210),
            makeWorkout(minutesFromEpoch: 300, type: .cycling, calories: 400),
            makeWorkout(minutesFromEpoch: 500, type: .swimming, calories: 150),
            makeWorkout(minutesFromEpoch: 501, type: .swimming, calories: 160)
        ]
        let result = HealthKitManager.deduplicateWorkouts(workouts)
        XCTAssertEqual(result.count, 3)
    }

    func testUnsortedInputStillDedupes() {
        let workouts = [
            makeWorkout(minutesFromEpoch: 102, type: .running, calories: 210, avgHR: 140, maxHR: 170),
            makeWorkout(minutesFromEpoch: 100, type: .running, calories: 200, avgHR: nil, maxHR: nil)
        ]
        let result = HealthKitManager.deduplicateWorkouts(workouts)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].averageHR, 140) // richer one kept
    }
}
