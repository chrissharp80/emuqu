@testable import Emuqu
import XCTest

/// Tests for heart-rate-recovery contamination filtering.
///
/// HRR — how far
/// your heart rate falls in the minute after stopping — is a recognised
/// cardiovascular marker, and this filter decides which captured samples the
/// user is shown.
///
/// It is a two-sided problem, which is why both directions are pinned below.
/// Too strict and a real 2-minute recovery is suppressed and the user sees
/// nothing. Too loose and a yawn or a sensor inversion is presented as
/// physiology. The committed tolerance is 10 bpm below the running maximum.
final class HRRMonotonicDropTests: XCTestCase {
    private func sample(offsetSec: Int, drop: Int, peakHR: Int = 170) -> HRRSample {
        HRRSample(
            offsetSec: offsetSec,
            hr: peakHR - drop,
            drop: drop,
            peakHR: peakHR,
            provenance: .strap
        )
    }

    // MARK: - Normal recovery

    func testImprovingRecoveryIsKeptWhole() {
        // Recovery deepens over time: 30 bpm at 1 min, 45 at 2 min.
        let samples = [sample(offsetSec: 60, drop: 30), sample(offsetSec: 120, drop: 45)]
        XCTAssertEqual(HRRCaptureService.enforceMonotonicDrop(samples).count, 2)
    }

    func testFirstSampleIsAlwaysKept() {
        let samples = [sample(offsetSec: 60, drop: 12)]
        XCTAssertEqual(HRRCaptureService.enforceMonotonicDrop(samples).count, 1)
    }

    func testEmptyInputIsSafe() {
        XCTAssertTrue(HRRCaptureService.enforceMonotonicDrop([]).isEmpty)
    }

    // MARK: - Contamination is rejected

    func testLargeInversionIsSuppressed() {
        // The case this filter was written for: 45 bpm at 1 min then 24 at
        // 2 min. A 21-bpm reversal is not physiology — the strap moved or the
        // user yawned.
        let samples = [sample(offsetSec: 60, drop: 45), sample(offsetSec: 120, drop: 24)]
        let kept = HRRCaptureService.enforceMonotonicDrop(samples)
        XCTAssertEqual(kept.count, 1, "a 21-bpm reversal is contamination")
        XCTAssertEqual(kept.first?.drop, 45)
    }

    // MARK: - Noise is tolerated

    func testSmallDipSurvives() {
        // A 6-bpm regression is sensor and micro-movement noise. Suppressing
        // it hid the user's real 2-minute recovery, which is why the tolerance
        // exists at all.
        let samples = [sample(offsetSec: 60, drop: 45), sample(offsetSec: 120, drop: 39)]
        XCTAssertEqual(
            HRRCaptureService.enforceMonotonicDrop(samples).count, 2,
            "a 6-bpm dip is noise, not contamination — the user must still see it"
        )
    }

    /// Boundary: the rule is "MORE than 10 bpm below the running max is
    /// suppressed", so exactly 10 below is kept.
    func testDipExactlyAtToleranceIsKept() {
        let samples = [sample(offsetSec: 60, drop: 45), sample(offsetSec: 120, drop: 35)]
        XCTAssertEqual(
            HRRCaptureService.enforceMonotonicDrop(samples).count, 2,
            "exactly at the tolerance is within it"
        )
    }

    func testDipJustBeyondToleranceIsSuppressed() {
        let samples = [sample(offsetSec: 60, drop: 45), sample(offsetSec: 120, drop: 34)]
        XCTAssertEqual(HRRCaptureService.enforceMonotonicDrop(samples).count, 1)
    }

    // MARK: - The running maximum

    func testToleranceIsMeasuredAgainstTheRunningMaxNotThePrevious() {
        // 45, then 40 (kept — within tolerance), then 34. If the comparison
        // used the PREVIOUS sample (40) rather than the running max (45), 34
        // would be within tolerance and wrongly kept.
        let samples = [
            sample(offsetSec: 60, drop: 45),
            sample(offsetSec: 90, drop: 40),
            sample(offsetSec: 120, drop: 33)
        ]
        let kept = HRRCaptureService.enforceMonotonicDrop(samples)
        XCTAssertEqual(kept.count, 2, "the running max anchors the comparison, not the last sample")
        XCTAssertEqual(kept.map(\.drop), [45, 40])
    }

    func testRunningMaxAdvancesWithDeeperRecovery() {
        let samples = [
            sample(offsetSec: 60, drop: 30),
            sample(offsetSec: 120, drop: 50),
            sample(offsetSec: 180, drop: 38)
        ]
        let kept = HRRCaptureService.enforceMonotonicDrop(samples)
        XCTAssertEqual(
            kept.map(\.drop), [30, 50],
            "38 is 12 below the new max of 50, so it is suppressed"
        )
    }
}
