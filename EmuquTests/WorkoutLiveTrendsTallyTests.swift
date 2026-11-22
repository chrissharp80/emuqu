@testable import Emuqu
import Foundation
import XCTest

/// The live trend tally (`WorkoutLiveTrends.Tally`) answers what the
/// stateless functions answer on the same buffer, while it is kept as the
/// buffer grows, starts over, or holds offsets out of order.
final class WorkoutLiveTrendsTallyTests: XCTestCase {
    /// A 25-minute run: heart rate rising, pace easing, cadence falling,
    /// a climb, and gaps in each series so every window skips some rows.
    private func run(seconds: Int, from start: Int = 0) -> [WorkoutSample] {
        (start ..< start + seconds).map { t in
            WorkoutSample(
                offsetSec: t,
                heartRate: t % 7 == 0 ? nil : 130 + t / 40,
                distanceMeters: t % 11 == 0 ? nil : Double(t) * 3.1,
                paceSecPerKm: t % 5 == 0 ? nil : 300 + Double(t % 90) / 3,
                cadenceStepsPerMin: t % 9 == 0 ? nil : 172 - Double(t) / 120,
                altitudeMeters: t % 13 == 0 ? nil : 40 + Double(t) / 20
            )
        }
    }

    private func assertMatchesStateless(_ tally: inout WorkoutLiveTrends.Tally, _ samples: [WorkoutSample], line: UInt = #line) {
        func near(_ a: Double?, _ b: Double?, _ name: String) {
            switch (a, b) {
            case (nil, nil): break
            case let (a?, b?): XCTAssertEqual(a, b, accuracy: 1e-9, name, line: line)
            default: XCTFail("\(name): \(String(describing: a)) vs \(String(describing: b))", line: line)
            }
        }
        near(tally.reverseSplitDeltaSecPerKm, WorkoutLiveTrends.reverseSplitDeltaSecPerKm(samples: samples), "reverse split")
        near(tally.hrDriftPercent, WorkoutLiveTrends.hrDriftPercent(samples: samples), "HR drift")
        near(tally.cadenceDriftSpm, WorkoutLiveTrends.cadenceDriftSpm(samples: samples), "cadence drift")
        near(tally.aerobicDecouplingPercent, WorkoutLiveTrends.aerobicDecouplingPercent(samples: samples), "decoupling")
        near(tally.recentHRSlopeBpm, WorkoutLiveTrends.recentHRSlopeBpm(samples: samples), "HR slope")
        let drift = WorkoutLiveTrends.hrDriftPercent(samples: samples)
        near(tally.projectedMinutesUntilFade, WorkoutLiveTrends.projectedMinutesUntilFade(samples: samples, currentDriftPercent: drift), "fade")
        let hrs = samples.compactMap(\.heartRate)
        near(tally.sessionAverageHR, hrs.isEmpty ? nil : Double(hrs.reduce(0, +)) / Double(hrs.count), "average HR")
        XCTAssertEqual(tally.recentSplitGradeAdjustedPaces, WorkoutLiveTrends.recentSplitGradeAdjustedPaces(samples: samples), line: line)
        XCTAssertEqual(tally.kilometreChunks.map(\.tEnd), WorkoutGeometry.kilometreChunks(samples).map(\.tEnd), line: line)
        for maxHR in [185, 160] {
            XCTAssertEqual(
                tally.zoneBreakdown(of: samples, userMaxHR: maxHR),
                WorkoutZoneBreakdown.compute(samples: samples, userMaxHR: maxHR), line: line
            )
        }
    }

    /// Grown a second at a time, past every metric's minimum, the tally
    /// gives the stateless answers at each step it is read.
    func testAGrowingBufferMatchesTheStatelessTrends() {
        let samples = run(seconds: 1_500)
        var tally = WorkoutLiveTrends.Tally()
        for end in stride(from: 0, through: samples.count, by: 61) {
            let buffer = Array(samples[..<end])
            tally.catchUp(to: buffer)
            XCTAssertEqual(tally.count, end)
            assertMatchesStateless(&tally, buffer)
        }
        XCTAssertNotNil(tally.hrDriftPercent, "the run is long enough for every trend")
        XCTAssertNotNil(tally.aerobicDecouplingPercent)
    }

    /// A buffer that is not the held one grown (a new workout, or the head
    /// dropped at the memory cap) starts the tally over.
    func testAnotherBufferStartsOver() {
        var tally = WorkoutLiveTrends.Tally()
        tally.catchUp(to: run(seconds: 900))
        let trimmed = Array(run(seconds: 1_000).dropFirst(200))
        tally.catchUp(to: trimmed)
        XCTAssertEqual(tally.count, trimmed.count)
        assertMatchesStateless(&tally, trimmed)
        let next = run(seconds: 700)
        tally.catchUp(to: next)
        assertMatchesStateless(&tally, next)
        tally.catchUp(to: [])
        XCTAssertEqual(tally.count, 0)
        assertMatchesStateless(&tally, [])
    }

    /// Offsets that go back (a merged buffer) are answered from the buffer
    /// itself.
    func testOffsetsOutOfOrderAreAnsweredFromTheBuffer() {
        let samples = run(seconds: 600, from: 700) + run(seconds: 700)
        var tally = WorkoutLiveTrends.Tally()
        tally.catchUp(to: Array(samples[..<650]))
        tally.catchUp(to: samples)
        assertMatchesStateless(&tally, samples)
    }
}
