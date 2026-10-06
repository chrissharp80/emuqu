@testable import Emuqu
import XCTest

/// Load & Trajectory raised the monotony warning when weekly load passed 200;
/// the Training Load screen when strain (weekly load × monotony) passed 200.
/// The same week could warn on one screen and not the other. Both now ask
/// `FosterMonotonyWarning`: monotony above 2.0 and strain above Foster's
/// moderate band.
final class FosterMonotonyWarningTests: XCTestCase {
    private let reference = Date(timeIntervalSince1970: 1_790_000_000)

    private func week(_ loads: [Double]) -> [Date: Double] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: reference)
        return Dictionary(uniqueKeysWithValues: loads.enumerated().compactMap { offset, load in
            calendar.date(byAdding: .day, value: -offset, to: today).map { ($0, load) }
        })
    }

    /// Seven near-identical light sessions: monotony is high, but 140 a week
    /// is not the heavy, unvaried week Foster describes. The Training Load
    /// screen warned here (strain 1400 > 200); Load & Trajectory did not.
    func testALightUnvariedWeekDoesNotWarn() throws {
        let loads = [20, 21, 19, 20, 21, 19, 20.0]
        let foster = try XCTUnwrap(RecoveryScoreCalculator.fosterMonotonyStrain(dailyTrimp: week(loads), referenceDate: reference))
        XCTAssertGreaterThan(foster.monotony, RecoveryScoreConstants.Training.monotonyThreshold)
        XCTAssertGreaterThan(foster.strain, 200)
        XCTAssertFalse(FosterMonotonyWarning.isRaised(dailyLoad: week(loads), referenceDate: reference))
    }

    func testAHeavyUnvariedWeekWarns() {
        let loads = [70, 72, 68, 70, 71, 69, 70.0]
        XCTAssertTrue(FosterMonotonyWarning.isRaised(dailyLoad: week(loads), referenceDate: reference))
    }

    /// Hard, easy and rest days: heavy, but varied, so no warning.
    func testAHeavyVariedWeekDoesNotWarn() {
        let loads = [150, 0, 60, 140, 0, 50, 130.0]
        XCTAssertFalse(FosterMonotonyWarning.isRaised(dailyLoad: week(loads), referenceDate: reference))
    }

    func testAnEmptyWeekDoesNotWarn() {
        XCTAssertFalse(FosterMonotonyWarning.isRaised(dailyLoad: [:], referenceDate: reference))
    }

    func testTheGateIsMonotonyAndStrainBothOverTheirThresholds() {
        let strain = RecoveryScoreConstants.Training.strainThreshold
        let monotony = RecoveryScoreConstants.Training.monotonyThreshold
        XCTAssertTrue(FosterMonotonyWarning.isRaised((monotony: monotony + 0.1, strain: strain + 1)))
        XCTAssertFalse(FosterMonotonyWarning.isRaised((monotony: monotony + 0.1, strain: strain - 1)))
        XCTAssertFalse(FosterMonotonyWarning.isRaised((monotony: monotony - 0.1, strain: strain * 3)))
    }
}
