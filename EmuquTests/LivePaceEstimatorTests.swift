@testable import Emuqu
import XCTest

/// Live pace from distance that arrives in chunks.
///
/// `WorkoutLocationManager` credits a GPS step only once it clears 3.5 m and
/// 1.5 × the fix accuracy, so at 5 m accuracy a walker's distance lands in
/// 8.4 m chunks every 6 s. Pace used to be one tick's distance over one
/// second, which read an 11:54/km walker as 1:59/km on one tick in six and
/// "—" on the other five, and a 5:33/km runner as 1:51/km on a third of the
/// ticks. The harness below re-creates that credit rule, fix by fix.
final class LivePaceEstimatorTests: XCTestCase {
    private static let walkerPace = 1000 / 1.4
    private static let runnerPace = 1000 / 3.0

    func testAWalkerReadsElevenFiftyFourOnEveryTick() {
        let paces = PaceRun(speedMS: 1.4, fixEverySec: 1, accuracyM: 5).paces(ticks: 120)
        assertSteady(paces, from: 20, around: Self.walkerPace)
    }

    func testAWalkerWithSparseFixesReadsSteady() {
        for fixEvery in [2.0, 3.0, 5.0] {
            let paces = PaceRun(speedMS: 1.4, fixEverySec: fixEvery, accuracyM: 5).paces(ticks: 120)
            assertSteady(paces, from: 25, around: Self.walkerPace, "fix every \(fixEvery) s")
        }
    }

    func testARunnerReadsFiveThirtyThree() {
        for accuracy in [2.0, 5.0] {
            let paces = PaceRun(speedMS: 3.0, fixEverySec: 1, accuracyM: accuracy).paces(ticks: 120)
            assertSteady(paces, from: 20, around: Self.runnerPace, "accuracy \(accuracy) m")
        }
    }

    /// With GPS too coarse for small steps, the batched pedometer carries the
    /// pace, on its own: mixing it with the GPS staircase read as surges.
    func testThePedometerCarriesPaceWhenGPSIsPoor() {
        var run = PaceRun(speedMS: 1.4, fixEverySec: 1, accuracyM: 30)
        run.pedometerEverySec = 3
        var estimator = LivePaceEstimator()
        let paces = run.paces(ticks: 120, estimator: &estimator)
        assertSteady(paces, from: 20, around: Self.walkerPace)
        XCTAssertEqual(estimator.source, .pedometer)
    }

    /// An accurate Doppler speed is the pace from the first fix.
    func testAccurateDopplerSpeedIsUsed() {
        var run = PaceRun(speedMS: 3.0, fixEverySec: 1, accuracyM: 5)
        run.dopplerAccuracyMS = 0.3
        var estimator = LivePaceEstimator()
        let paces = run.paces(ticks: 60, estimator: &estimator)
        assertSteady(paces, from: 1, around: Self.runnerPace)
        XCTAssertEqual(estimator.source, .gpsDoppler)
    }

    func testImpreciseDopplerSpeedIsNotUsed() {
        var run = PaceRun(speedMS: 3.0, fixEverySec: 1, accuracyM: 5)
        run.dopplerAccuracyMS = 2
        var estimator = LivePaceEstimator()
        _ = run.paces(ticks: 60, estimator: &estimator)
        XCTAssertEqual(estimator.source, .gpsDistance)
    }

    /// Stopping clears the pace instead of holding it: within 20 s on
    /// distance alone, within 5 s with Doppler.
    func testStoppingClearsThePace() {
        var run = PaceRun(speedMS: 1.4, fixEverySec: 1, accuracyM: 5)
        run.stopAtSec = 60
        let paces = run.paces(ticks: 100)
        XCTAssertNil(paces[85], "20 s after stopping there is no pace")
        for tick in 60 ..< 100 {
            if let pace = paces[tick] { XCTAssertGreaterThanOrEqual(pace, Self.walkerPace * 0.98, "never faster after stopping") }
        }
        run.dopplerAccuracyMS = 0.3
        XCTAssertNil(run.paces(ticks: 100)[66])
    }

    func testFootPodSpeedWins() {
        var estimator = LivePaceEstimator()
        estimator.update(LivePaceEstimator.Reading(now: Date(), distanceMeters: 10, footPodSpeedMS: 2.5))
        XCTAssertEqual(estimator.paceSecPerKm ?? 0, 400, accuracy: 0.001)
        XCTAssertEqual(estimator.source, .footPod)
    }

    func testResetForgetsEverything() {
        var estimator = LivePaceEstimator()
        _ = PaceRun(speedMS: 3.0, fixEverySec: 1, accuracyM: 5).paces(ticks: 30, estimator: &estimator)
        XCTAssertNotNil(estimator.paceSecPerKm)
        estimator.reset()
        XCTAssertNil(estimator.paceSecPerKm)
        XCTAssertNil(estimator.speedMS)
    }

    /// METs (and from them Apple Health energy and training load) are read
    /// from the stored pace. The walker's are now a walking value on every
    /// tick, where the spikes gave the top walking band one tick in six and
    /// nothing on the rest.
    func testTheWalkersMETsAreSteady() {
        let paces = PaceRun(speedMS: 1.4, fixEverySec: 1, accuracyM: 5).paces(ticks: 120)
        let expected = WorkoutRecorder.estimateMETs(sport: .walk, paceSecPerKm: Self.walkerPace, heartRate: nil, userMaxHR: 190)
        XCTAssertNotNil(expected)
        for tick in 20 ..< 120 {
            let mets = WorkoutRecorder.estimateMETs(sport: .walk, paceSecPerKm: paces[tick], heartRate: nil, userMaxHR: 190)
            XCTAssertEqual(mets, expected, "tick \(tick)")
        }
    }

    // MARK: - Helpers

    private func assertSteady(
        _ paces: [Double?], from first: Int, around truth: Double, _ context: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for tick in first ..< paces.count {
            guard let pace = paces[tick] else {
                return XCTFail("no pace at tick \(tick) \(context)", file: file, line: line)
            }
            XCTAssertEqual(pace, truth, accuracy: truth * 0.03, "tick \(tick) \(context)", file: file, line: line)
        }
    }
}

/// Straight-line motion at `speedMS`, GPS fixes every `fixEverySec` credited
/// by `WorkoutLocationManager`'s rule, an optional batched pedometer, and a
/// 1 Hz ticker reading the estimator.
private struct PaceRun {
    let speedMS: Double
    let fixEverySec: Double
    let accuracyM: Double
    var pedometerEverySec: Double?
    /// Nil: the fix carries no valid Doppler speed accuracy.
    var dopplerAccuracyMS: Double?
    var stopAtSec: Double = .infinity

    private let start = Date(timeIntervalSince1970: 1_000_000)

    init(speedMS: Double, fixEverySec: Double, accuracyM: Double) {
        self.speedMS = speedMS
        self.fixEverySec = fixEverySec
        self.accuracyM = accuracyM
    }

    func paces(ticks: Int) -> [Double?] {
        var estimator = LivePaceEstimator()
        return paces(ticks: ticks, estimator: &estimator)
    }

    /// Index `t` holds the pace read on the tick at `t` seconds; index 0 is unused.
    func paces(ticks: Int, estimator: inout LivePaceEstimator) -> [Double?] {
        var gps = GPSCredit(run: self)
        var pedometer = 0.0
        var out: [Double?] = [nil]
        for tick in 1 ... ticks {
            let now = Double(tick)
            let fix = gps.advance(through: now)
            if let every = pedometerEverySec { pedometer = position(at: (now / every).rounded(.down) * every) }
            estimator.update(LivePaceEstimator.Reading(
                now: start.addingTimeInterval(now), distanceMeters: max(gps.creditedMeters, pedometer),
                gpsMeters: gps.creditedMeters, pedometerMeters: pedometerEverySec == nil ? nil : pedometer,
                gps: fix
            ))
            out.append(estimator.paceSecPerKm)
        }
        return out
    }

    func position(at seconds: Double) -> Double {
        min(seconds, stopAtSec) * speedMS
    }

    func fix(at seconds: Double) -> LivePaceEstimator.GPSSpeed {
        LivePaceEstimator.GPSSpeed(
            speedMS: seconds < stopAtSec ? speedMS : 0, speedAccuracyMS: dopplerAccuracyMS ?? -1,
            horizontalAccuracyM: accuracyM, timestamp: start.addingTimeInterval(seconds)
        )
    }
}

/// `WorkoutLocationManager.creditMovement`: a step from the last credited fix
/// counts once it is at least 3.5 m and at least 1.5 × the accuracy (capped
/// at 20 m).
private struct GPSCredit {
    let run: PaceRun
    var creditedMeters = 0.0
    var lastCreditedPosition = 0.0
    var nextFixAt = 0.5
    var latestFix: LivePaceEstimator.GPSSpeed?

    init(run: PaceRun) { self.run = run }

    mutating func advance(through tick: Double) -> LivePaceEstimator.GPSSpeed? {
        let floor = max(3.5, min(1.5 * run.accuracyM, 20))
        while nextFixAt <= tick {
            let position = run.position(at: nextFixAt)
            if position - lastCreditedPosition >= floor {
                creditedMeters += position - lastCreditedPosition
                lastCreditedPosition = position
            }
            latestFix = run.fix(at: nextFixAt)
            nextFixAt += run.fixEverySec
        }
        return latestFix
    }
}
