@testable import Emuqu
import XCTest

/// Tests for `HRRCaptureService.enforceMonotonicDrop` — the
/// post-capture filter that drops contaminated samples violating
/// monotonic recovery from peak. The async multi-tier capture itself
/// requires a live Polar/HealthKit stack and is exercised by
/// integration tests; this file pins the pure logic.
final class HRRCaptureServiceTests: XCTestCase {

    private func sample(offset: Int, drop: Int, provenance: HRRSample.Provenance = .strap, peak: Int = 175) -> HRRSample {
        HRRSample(
            offsetSec: offset,
            hr: peak - drop,
            drop: drop,
            peakHR: peak,
            provenance: provenance
        )
    }

    // MARK: - Monotonic happy path

    func testKeepsBothWhenDropIncreasesOverTime() {
        let input = [sample(offset: 60, drop: 40), sample(offset: 120, drop: 55)]
        let kept = HRRCaptureService.enforceMonotonicDrop(input)
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(kept.map(\.offsetSec), [60, 120])
    }

    func testKeepsBothWhenDropEqualOverTime() {
        // Plateau is rare but legal; treat as monotonic non-decreasing.
        let input = [sample(offset: 60, drop: 40), sample(offset: 120, drop: 40)]
        let kept = HRRCaptureService.enforceMonotonicDrop(input)
        XCTAssertEqual(kept.count, 2)
    }

    // MARK: - The reported user bug

    func testDropsTwoMinuteWhenLessThanOneMinute() {
        // Real user report: 1-min drop 45, 2-min drop 24 → drop the 2-min.
        let input = [
            sample(offset: 60, drop: 45, provenance: .strap),
            sample(offset: 120, drop: 24, provenance: .watchSamples)
        ]
        let kept = HRRCaptureService.enforceMonotonicDrop(input)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.offsetSec, 60)
        XCTAssertEqual(kept.first?.drop, 45)
    }

    func testKeepsLeadingValidSampleEvenIfLaterContaminated() {
        // Three samples, only the middle is contaminated. Contamination per
        // the documented contract means MORE than the 10 bpm
        // `regressionTolerance` below the running max — smaller dips are
        // micro-movement noise and are deliberately kept (see the companion
        // boundary test below). The original fixture used drop=10 against
        // max=20 — exactly AT tolerance, which the service correctly keeps —
        // so the test contradicted the production contract, not the reverse.
        let input = [
            sample(offset: 30, drop: 20),
            sample(offset: 60, drop: 5), // contamination: 15 bpm below max 20, past tolerance
            sample(offset: 120, drop: 35) // chain recovers: exceeds the running max
        ]
        let kept = HRRCaptureService.enforceMonotonicDrop(input)
        // First (20) kept. Middle (5) dropped — >10 bpm below the running
        // max. Third (35) kept — the leading valid sample stays AND the
        // chain stays usable after the contaminated reading is excised.
        XCTAssertEqual(kept.map(\.drop), [20, 35])
    }

    func testDipWithinRegressionToleranceIsKept() {
        // Pins the tolerance contract: regressions of ≤10 bpm
        // below the running max are sensor / micro-movement noise (a yawn,
        // a stretch), NOT contamination — the user still wants the reading.
        let input = [
            sample(offset: 30, drop: 20),
            sample(offset: 60, drop: 10), // exactly 10 below the max — within tolerance
            sample(offset: 120, drop: 35)
        ]
        let kept = HRRCaptureService.enforceMonotonicDrop(input)
        XCTAssertEqual(kept.map(\.drop), [20, 10, 35])
    }

    // MARK: - Edge cases

    func testEmptyInput() {
        XCTAssertTrue(HRRCaptureService.enforceMonotonicDrop([]).isEmpty)
    }

    func testSingleSamplePassesThrough() {
        let input = [sample(offset: 60, drop: 30)]
        XCTAssertEqual(HRRCaptureService.enforceMonotonicDrop(input).count, 1)
    }

    func testNegativeDropTreatedAsValidStartingPoint() {
        // Edge: HR briefly went UP just after stop (not unheard-of for a
        // sprint finish). Then a real recovery follows. Both should be
        // kept — the negative isn't contamination, just the actual signal.
        let input = [
            sample(offset: 60, drop: -3),
            sample(offset: 120, drop: 25)
        ]
        let kept = HRRCaptureService.enforceMonotonicDrop(input)
        XCTAssertEqual(kept.count, 2)
    }
}
