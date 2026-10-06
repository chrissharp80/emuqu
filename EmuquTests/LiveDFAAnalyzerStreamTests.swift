@testable import Emuqu
import XCTest

/// Live α1 fed the way a workout feeds it: beats from 1 Hz strap
/// notifications, each stamped with the interval-sum clock (`t_ms`) and its
/// arrival time (`wallClockMs`), ingested by the 1 Hz ticker.
///
/// The window used to be trimmed on the wall clock but measured on the
/// interval-sum clock, so every beat lost to a dropout left it permanently
/// short of the two-minute gate: α1 froze at its last value with the status
/// "warming up 98 %", and a strap that then died never cleared it. These
/// tests stream beats over time, which the single-batch tests in
/// `LiveDFAAnalyzerTests` never did.
@MainActor
final class LiveDFAAnalyzerStreamTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// A 2.5 s Bluetooth dropout at 300 s, then the athlete works harder from
    /// 330 s. α1 must keep recomputing after the gap and follow the effort
    /// down, not stay frozen at the pre-gap value.
    func testAlpha1KeepsUpdatingAfterAShortDropout() {
        let analyzer = stream(StrapScenario(hrEasy: 140, hrHard: 165, dropAt: 300, dropSec: 2.5), until: 500)
        XCTAssertEqual(analyzer.status, .ok)
        XCTAssertGreaterThanOrEqual(
            analyzer.lastComputeAt?.timeIntervalSince(start) ?? 0, 480, "recompute must keep its 20 s cadence after the gap"
        )
        let alpha1 = analyzer.currentAlpha1 ?? .nan
        XCTAssertLessThan(alpha1, 0.9, "α1 must fall with the harder effort that started after the gap")
    }

    /// The freeze, then the strap dies: α1 must clear once it has been silent
    /// for 40 s, whatever state the window was in.
    func testAlpha1ClearsWhenTheStrapDiesAfterADropout() {
        let scenario = StrapScenario(hrEasy: 140, hrHard: 165, dropAt: 200, dropSec: 2.5, dieAt: 300)
        let analyzer = stream(scenario, until: 400)
        XCTAssertNil(analyzer.currentAlpha1, "a strap silent for 100 s has no current α1")
        XCTAssertEqual(analyzer.currentBand, .unknown)
        guard case .stalled = analyzer.status else {
            return XCTFail("status should say the strap is silent, not \(analyzer.status.label)")
        }
    }

    /// At 60 bpm, notification batching alone used more than the 2 s slack,
    /// and α1 never appeared even with no dropout.
    func testAlpha1IsProducedAtSlowHeartRates() {
        let analyzer = stream(StrapScenario(hrEasy: 60, hrHard: 75, dropAt: 300, dropSec: 0), until: 600)
        XCTAssertEqual(analyzer.status, .ok)
        XCTAssertNotNil(analyzer.currentAlpha1)
        XCTAssertGreaterThanOrEqual(analyzer.lastComputeAt?.timeIntervalSince(start) ?? 0, 580)
    }

    /// A published α1 always comes with `.ok`, on every tick of a session
    /// with a dropout, a strap death and a silent stretch.
    func testAPublishedAlpha1AlwaysHasAnOKStatus() {
        let scenario = StrapScenario(hrEasy: 140, hrHard: 165, dropAt: 200, dropSec: 2.5, dieAt: 300)
        _ = stream(scenario, until: 400) { analyzer in
            if analyzer.currentAlpha1 != nil { XCTAssertEqual(analyzer.status, .ok) }
        }
    }

    /// The live clock is the offline re-analyzer's gap-corrected timeline,
    /// computed one beat at a time, so live and offline windows agree.
    func testTheBeatClockMatchesTheOfflineGapCorrection() {
        let points = StrapScenario(hrEasy: 140, hrHard: 165, dropAt: 100, dropSec: 3).deliveredBeats(until: 200)
        var clock = LiveDFAAnalyzer.BeatClock()
        let live = points.map { clock.stamp($0).t_ms }
        XCTAssertEqual(live, WorkoutAnalyzer.gapCorrectedOffsetsMs(points))
    }

    // MARK: - Harness

    /// Runs the 1 Hz ticker over `scenario` and returns the analyzer.
    private func stream(
        _ scenario: StrapScenario, until seconds: Int, eachTick: (LiveDFAAnalyzer) -> Void = { _ in }
    ) -> LiveDFAAnalyzer {
        let analyzer = LiveDFAAnalyzer()
        analyzer.reset(sessionStart: start)
        var feed = scenario.feed()
        for tick in 1 ... seconds {
            let batch = feed.deliver(through: Double(tick))
            let now = start.addingTimeInterval(Double(tick))
            if batch.isEmpty { analyzer.tick(now: now) } else { analyzer.ingest(points: batch, now: now) }
            eachTick(analyzer)
        }
        return analyzer
    }
}

/// A heart beating from before the workout: correlated variation at
/// `hrEasy` until 30 s after the dropout, then uncorrelated at `hrHard`.
/// Notifications arrive every second, 0.3 s after the tick, carrying the beats
/// that ended since the previous one; those inside the dropout, or after
/// `dieAt`, are lost.
private struct StrapScenario {
    let hrEasy: Double
    let hrHard: Double
    let dropAt: Double
    let dropSec: Double
    var dieAt: Double = .infinity

    struct Feed {
        let scenario: StrapScenario
        let beats: [(end: Double, rrMs: Int)]
        var nextBeat = 0
        var nextNotification = 0.32
        var cumulativeMs: Int64 = 0

        mutating func deliver(through tick: Double) -> [RRPoint] {
            var out: [RRPoint] = []
            while nextNotification <= tick {
                let at = nextNotification
                let lost = (at >= scenario.dropAt && at < scenario.dropAt + scenario.dropSec) || at >= scenario.dieAt
                while nextBeat < beats.count, beats[nextBeat].end <= at {
                    let rr = beats[nextBeat].rrMs
                    nextBeat += 1
                    guard !lost else { continue }
                    out.append(RRPoint(t_ms: cumulativeMs, rr_ms: rr, wallClockMs: Int64((at * 1000).rounded()), hr: nil))
                    cumulativeMs += Int64(rr)
                }
                nextNotification += 1
            }
            return out
        }
    }

    func feed() -> Feed {
        var random = SeededNormal(seed: 3)
        var beats: [(end: Double, rrMs: Int)] = []
        var t = -3.0
        var drift = 0.0
        while t < 1_000 {
            let rr: Double
            if t < dropAt + 30 {
                drift = 0.95 * drift + random.next() * 0.01 * 60_000 / hrEasy
                rr = 60_000 / hrEasy + drift
            } else {
                rr = 60_000 / hrHard + random.next() * 0.015 * 60_000 / hrHard
            }
            let rrMs = Int(rr.rounded())
            t += Double(rrMs) / 1000
            if t > 0 { beats.append((t, rrMs)) }
        }
        return Feed(scenario: self, beats: beats)
    }

    func deliveredBeats(until seconds: Int) -> [RRPoint] {
        var feed = feed()
        return (1 ... seconds).flatMap { feed.deliver(through: Double($0)) }
    }
}

/// Deterministic standard-normal draws (Box–Muller over a 64-bit LCG).
private struct SeededNormal {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> Double {
        let u = max(uniform(), 1e-12)
        let v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }

    private mutating func uniform() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }
}
