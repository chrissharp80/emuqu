import CoreLocation
@testable import Emuqu
import XCTest

/// Characterization tests for `WorkoutRecorder`'s sub-observables
/// (`WorkoutMotion`, `WorkoutHR`).
///
/// Pins down the default state + reset behavior so future internal
/// refactors of `WorkoutRecorder.incrementalBackupTick` / `resetMetrics`
/// don't silently change semantics.
@MainActor
final class WorkoutSubObservablesTests: XCTestCase {

    // MARK: - WorkoutMotion

    func testWorkoutMotionDefaults() {
        let motion = WorkoutMotion()
        XCTAssertEqual(motion.distanceMeters, 0)
        XCTAssertEqual(motion.elevationGainMeters, 0)
        XCTAssertTrue(motion.liveTrack.isEmpty)
        XCTAssertEqual(motion.stepCount, 0)
        XCTAssertNil(motion.cadenceStepsPerMin)
        XCTAssertNil(motion.powerWatts)
        XCTAssertFalse(motion.footPodActive)
    }

    func testWorkoutMotionResetRestoresDefaults() {
        let motion = WorkoutMotion()
        motion.distanceMeters = 5_000
        motion.elevationGainMeters = 120
        motion.liveTrack = [CLLocation(latitude: 1, longitude: 2)]
        motion.stepCount = 8_000
        motion.cadenceStepsPerMin = 170
        motion.powerWatts = 250
        motion.footPodActive = true

        motion.reset()

        XCTAssertEqual(motion.distanceMeters, 0)
        XCTAssertEqual(motion.elevationGainMeters, 0)
        XCTAssertTrue(motion.liveTrack.isEmpty)
        XCTAssertEqual(motion.stepCount, 0)
        XCTAssertNil(motion.cadenceStepsPerMin)
        XCTAssertNil(motion.powerWatts)
        XCTAssertFalse(motion.footPodActive)
    }

    // MARK: - WorkoutHR

    func testWorkoutHRDefaults() {
        let hr = WorkoutHR()
        XCTAssertNil(hr.currentHR)
        XCTAssertEqual(hr.peakHR, 0)
        XCTAssertEqual(hr.beatCount, 0)
    }

    func testWorkoutHRResetRestoresDefaults() {
        let hr = WorkoutHR()
        hr.currentHR = 145
        hr.peakHR = 180
        hr.beatCount = 5_000

        hr.reset()

        XCTAssertNil(hr.currentHR)
        XCTAssertEqual(hr.peakHR, 0)
        XCTAssertEqual(hr.beatCount, 0)
    }
}
