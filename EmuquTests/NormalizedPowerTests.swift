@testable import Emuqu
import XCTest

/// Tests for normalized power.
///
/// NP is the Coggan metric that says how hard a ride
/// actually was: a 30-second rolling mean, raised to the fourth power,
/// averaged, then fourth-rooted. The fourth power is the whole point — it
/// weights surges far above steady effort, so a ride with the same average
/// power scores higher when it was ragged. Getting it wrong misstates the
/// intensity of every ride and everything derived from it.
@MainActor
final class NormalizedPowerTests: XCTestCase {
    private func samples(_ watts: [Int]) -> [WorkoutSample] {
        watts.enumerated().map { i, w in
            WorkoutSample(offsetSec: i, powerWatts: w)
        }
    }

    // MARK: - The window requirement

    func testFewerThanThirtySamplesHasNoNormalizedPower() {
        // One full 30-second window is the minimum the definition allows.
        // Returning a number from 29 samples would be an invented figure.
        XCTAssertNil(WorkoutRecorder.computeNormalizedPower(samples: samples(Array(repeating: 200, count: 29))))
    }

    func testExactlyThirtySamplesProducesAValue() {
        let np = WorkoutRecorder.computeNormalizedPower(samples: samples(Array(repeating: 200, count: 30)))
        XCTAssertEqual(np ?? 0, 200, accuracy: 0.001)
    }

    func testNoSamplesAtAllIsNil() {
        XCTAssertNil(WorkoutRecorder.computeNormalizedPower(samples: []))
    }

    func testSamplesWithoutPowerAreExcluded() {
        // A ride with no power meter must not produce a power figure.
        let noPower = (0 ..< 60).map { WorkoutSample(offsetSec: $0) }
        XCTAssertNil(WorkoutRecorder.computeNormalizedPower(samples: noPower))
    }

    func testMixedSamplesUseOnlyThoseWithPower() {
        // 40 with power, 40 without. The 40 with power clear the 30 threshold.
        var mixed = samples(Array(repeating: 250, count: 40))
        mixed += (0 ..< 40).map { WorkoutSample(offsetSec: 100 + $0) }
        let np = WorkoutRecorder.computeNormalizedPower(samples: mixed)
        XCTAssertEqual(np ?? 0, 250, accuracy: 0.001, "gaps must not drag the figure down")
    }

    // MARK: - Steady effort

    func testConstantPowerEqualsThatPower() {
        let np = WorkoutRecorder.computeNormalizedPower(samples: samples(Array(repeating: 200, count: 60)))
        XCTAssertEqual(np ?? 0, 200, accuracy: 0.001)
    }

    // MARK: - The fourth power is what makes NP useful

    func testSurgesPushNormalizedPowerAboveTheAverage() {
        // 90s at 100 W then 30s at 500 W — average 200 W, but the ride was
        // nothing like a steady 200 W effort. NP must say so.
        let ragged = Array(repeating: 100, count: 90) + Array(repeating: 500, count: 30)
        let np = WorkoutRecorder.computeNormalizedPower(samples: samples(ragged)) ?? 0
        let average = Double(ragged.reduce(0, +)) / Double(ragged.count)
        XCTAssertEqual(average, 200, accuracy: 0.001, "fixture sanity: the average really is 200")
        XCTAssertEqual(np, 273.1329, accuracy: 0.01)
        XCTAssertGreaterThan(np, average, "a ragged ride must score above its own average")
    }

    /// Fast alternation is smoothed away by the 30-second window, which is why
    /// the window exists: NP measures sustained surges, not sample-to-sample
    /// noise. Same average, same NP.
    func testRapidAlternationIsSmoothedByTheWindow() {
        let alternating = (0 ..< 120).map { $0.isMultiple(of: 2) ? 300 : 100 }
        let np = WorkoutRecorder.computeNormalizedPower(samples: samples(alternating)) ?? 0
        XCTAssertEqual(np, 200, accuracy: 0.01, "30s smoothing removes alternation")
    }

    func testLongerSurgesScoreHigherThanShorterOnes() {
        let shortSurge = Array(repeating: 100, count: 110) + Array(repeating: 500, count: 10)
        let longSurge = Array(repeating: 100, count: 80) + Array(repeating: 500, count: 40)
        let shortNP = WorkoutRecorder.computeNormalizedPower(samples: samples(shortSurge)) ?? 0
        let longNP = WorkoutRecorder.computeNormalizedPower(samples: samples(longSurge)) ?? 0
        XCTAssertGreaterThan(longNP, shortNP, "a longer surge is a harder ride")
    }

    // MARK: - Degenerate power

    func testZeroPowerThroughoutIsZeroNotNil() {
        // Coasting is a real reading, distinct from "no power meter".
        let np = WorkoutRecorder.computeNormalizedPower(samples: samples(Array(repeating: 0, count: 60)))
        XCTAssertEqual(np ?? -1, 0, accuracy: 0.001)
    }

    // MARK: - FTP auto-estimate: best 20-minute mean power

    private func steady(_ watts: Int, seconds: Int, from start: Int = 0) -> [WorkoutSample] {
        (start ..< start + seconds).map { WorkoutSample(offsetSec: $0, powerWatts: watts) }
    }

    /// The estimate used whole-session NP, so a hard 20 minutes inside an
    /// easy hour read as the hour's average. It is the best 20-minute window.
    func testTheBestTwentyMinutesIsFoundInsideALongerSession() throws {
        let session = steady(150, seconds: 1_200) + steady(300, seconds: 1_200, from: 1_200) + steady(150, seconds: 1_200, from: 2_400)
        let best = try XCTUnwrap(FTPAutoEstimator.bestTwentyMinuteMeanPower(session))
        XCTAssertEqual(best, 300, accuracy: 1e-9)
    }

    func testUnderTwentyMinutesOfPowerHasNoEstimate() {
        XCTAssertNil(FTPAutoEstimator.bestTwentyMinuteMeanPower(steady(300, seconds: 1_199)))
    }

    /// A window with long gaps in the power stream isn't a 20-minute effort.
    func testAWindowWithTooFewPowerReadingsDoesNotCount() {
        let sparse = steady(300, seconds: 1_200).enumerated().map { i, sample in
            i.isMultiple(of: 5) ? WorkoutSample(offsetSec: sample.offsetSec, powerWatts: nil) : sample
        }
        XCTAssertNil(FTPAutoEstimator.bestTwentyMinuteMeanPower(sparse))
    }

    /// TrainingPeaks / Coggan: FTP is 95 % of the best 20-minute mean.
    func testFTPIsNinetyFivePercentOfTheBestTwentyMinutes() {
        XCTAssertEqual(FTPAutoEstimator.ftp(for: .init(meanPowerWatts: 300, sessionId: UUID())), 285)
    }

    func testTheStrongestWorkoutAnchorsTheEstimate() throws {
        func run(_ watts: Int) -> HRVSession {
            var meta = WorkoutMetadata(sport: .run)
            meta.samples = steady(watts, seconds: 1_500)
            var session = HRVSession(startDate: Date(), sessionType: .workout)
            session.workoutMetadata = meta
            return session
        }
        let strongest = run(280)
        let best = try XCTUnwrap(FTPAutoEstimator.bestEffort(in: [run(220), strongest, run(250)]))
        XCTAssertEqual(best.sessionId, strongest.id)
        XCTAssertEqual(best.meanPowerWatts, 280, accuracy: 1e-9)
    }

    func testNoQualifyingWorkoutGivesNoEffort() {
        XCTAssertNil(FTPAutoEstimator.bestEffort(in: []))
    }

    // MARK: - Concept2 PM5 stroke power (Additional Stroke Data 0x0036)

    private func strokePacket(power: UInt16, strokes: UInt16) -> Data {
        Data([0x10, 0x27, 0x00, UInt8(power & 0xFF), UInt8(power >> 8), 0x2C, 0x01,
              UInt8(strokes & 0xFF), UInt8(strokes >> 8), 0, 0, 0, 0, 0, 0])
    }

    /// Power was read from bytes 16–17 of 0x0032, which the PM5 sends as 17
    /// bytes, so a row never recorded power. It is bytes 3–4 of 0x0036.
    func testStrokePowerAndCountAreDecodedFromTheStrokePacket() throws {
        let stroke = try XCTUnwrap(Concept2Manager.strokeData(from: strokePacket(power: 245, strokes: 312)))
        XCTAssertEqual(stroke.powerWatts, 245)
        XCTAssertEqual(stroke.strokeCount, 312)
    }

    func testImplausibleStrokePowerIsDropped() throws {
        XCTAssertNil(try XCTUnwrap(Concept2Manager.strokeData(from: strokePacket(power: 0, strokes: 1))).powerWatts)
        XCTAssertNil(try XCTUnwrap(Concept2Manager.strokeData(from: strokePacket(power: 4_000, strokes: 1))).powerWatts)
    }

    func testAShortStrokePacketIsIgnored() {
        XCTAssertNil(Concept2Manager.strokeData(from: Data([0, 0, 0, 1, 0])))
    }
}
