@testable import Emuqu
import XCTest

/// Tests for the sport-specific FTP lookup the recorder uses to anchor power
/// thresholds.
///
/// Settings arrive as a parameter rather than being read from
/// `SettingsManager.shared.settings`, so exercising the lookup does not mean
/// mutating global state. There is exactly one copy: `private` is file-scoped
/// in a Swift extension, so byte-identical `private static` copies in two
/// files compile happily and either can be edited without the other.
@MainActor
final class WorkoutRecorderSettingsTests: XCTestCase {
    private func settings(running: Int? = nil, cycling: Int? = nil) -> UserSettings {
        var s = UserSettings()
        s.runningFTPWatts = running
        s.cyclingFTPWatts = cycling
        return s
    }

    // MARK: - The split that motivated the code

    func testCyclingSportsReadCyclingFTP() {
        let s = settings(running: 300, cycling: 240)
        XCTAssertEqual(WorkoutRecorder.sportFTP(for: .bike, settings: s), 240)
        XCTAssertEqual(WorkoutRecorder.sportFTP(for: .indoorBike, settings: s), 240)
    }

    func testRunningSportsDoNotReadCyclingFTP() {
        // Running and cycling FTP are physiologically distinct — a runner's
        // threshold is typically 5-15% above their cycling one. Crossing the
        // wires would mis-anchor every power threshold in the session.
        let s = settings(running: 300, cycling: 240)
        XCTAssertNotEqual(
            WorkoutRecorder.sportFTP(for: .run, settings: s), 240,
            "a run must not be anchored to the cycling FTP"
        )
    }

    func testSportsWithoutAPowerModelHaveNoFTP() {
        let s = settings(running: 300, cycling: 240)
        XCTAssertNil(WorkoutRecorder.sportFTP(for: .row, settings: s))
    }

    // MARK: - Zero and nil are the same thing here

    func testZeroCyclingFTPIsTreatedAsUnset() {
        // A user who typed 0 must not get a zero denominator downstream.
        let s = settings(cycling: 0)
        XCTAssertNil(WorkoutRecorder.sportFTP(for: .bike, settings: s))
    }

    func testUnsetCyclingFTPIsNil() {
        XCTAssertNil(WorkoutRecorder.sportFTP(for: .bike, settings: settings()))
    }

    func testNegativeCyclingFTPIsRejected() {
        XCTAssertNil(WorkoutRecorder.sportFTP(for: .bike, settings: settings(cycling: -50)))
    }
}
