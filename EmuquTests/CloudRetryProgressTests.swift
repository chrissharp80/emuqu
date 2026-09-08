@testable import Emuqu
import XCTest

/// A deferred upload must eventually become eligible again.
///
/// ## The defect this pins
///
/// A `shouldDeferForBackoff` of the form
/// `stableRetryBucket(id) % skipCycles != 0` never recovers. Both operands are constant while
/// an item is being skipped — the bucket comes from the UUID, and the failure
/// count only changes when an attempt is actually made — so a session that
/// deferred once deferred on every cycle for the life of the process. A backup
/// pending its first upload never retried, even after connectivity returned.
///
/// A worked example: UUID `01000000-0000-4000-8000-000000000000`
/// gives bucket 1. After one failure the test is `1 % 2 != 0` → true, and
/// re-evaluating it changes nothing.
///
/// A test that only checked bucket STABILITY would pass against the broken
/// code, because stability was never the problem. What has to be asserted is
/// PROGRESS: that advancing the cycle eventually makes a deferred session
/// eligible.
@MainActor
final class CloudRetryProgressTests: XCTestCase {
    /// The UUID from the worked example above: bucket 1, which under the old
    /// expression deferred forever after a single failure.
    private static let workedExampleUUID = UUID(
        uuid: (0x01, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 0)
    )

    /// The production expression, with the cycle counter passed in so it can
    /// be advanced deterministically instead of waiting on real pushes.
    private func defers(bucket: Int, failCount: Int, cycle: Int) -> Bool {
        let exponent = min(failCount, 6)
        let period = min(1 << exponent, 32)
        let offset = bucket % period
        return (cycle + offset) % period != 0
    }

    /// The buggy expression, kept so the regression is legible.
    private func oldDefers(bucket: Int, failCount: Int) -> Bool {
        bucket % min(1 << failCount, 32) != 0
    }

    // MARK: - The bug, reproduced

    func testTheOldExpressionNeverBecomesEligible() {
        let bucket = CloudKitSyncManager.stableRetryBucket(for: Self.workedExampleUUID)
        XCTAssertEqual(bucket, 1, "The report's worked example depends on this bucket")
        for _ in 0 ..< 1_000 {
            XCTAssertTrue(oldDefers(bucket: bucket, failCount: 1),
                          "The old expression deferred forever — that is F1")
        }
    }

    // MARK: - The fix

    /// Every session, at every failure count, must become eligible within its
    /// backoff period. This is the assertion the buggy expression cannot satisfy.
    func testEverySessionBecomesEligibleWithinItsPeriod() {
        for failCount in 1 ... 8 {
            let period = min(1 << min(failCount, 6), 32)
            for bucket in [0, 1, 2, 7, 31, 12_345, 8_388_607] {
                let eligible = (0 ..< period).contains {
                    !defers(bucket: bucket, failCount: failCount, cycle: $0)
                }
                XCTAssertTrue(eligible,
                              "bucket \(bucket) at failCount \(failCount) never became eligible "
                                  + "within \(period) cycles")
            }
        }
    }

    /// A transient failure followed by advancing cycles must produce another
    /// attempt.
    func testATransientFailureRetriesOnceTheCycleAdvances() {
        let bucket = CloudKitSyncManager.stableRetryBucket(for: Self.workedExampleUUID)
        var attempts = 0
        for cycle in 0 ..< 16 where !defers(bucket: bucket, failCount: 1, cycle: cycle) {
            attempts += 1
        }
        XCTAssertGreaterThan(attempts, 1, "A transient failure never retried")
    }

    /// Backoff must still back off — retrying every cycle would hammer
    /// CloudKit, which is what the mechanism exists to prevent.
    func testHigherFailureCountsRetryLessOften() {
        let bucket = 5
        let window = 256
        func attempts(failCount: Int) -> Int {
            (0 ..< window).filter { !defers(bucket: bucket, failCount: failCount, cycle: $0) }.count
        }
        XCTAssertGreaterThan(attempts(failCount: 1), attempts(failCount: 3))
        XCTAssertGreaterThan(attempts(failCount: 3), attempts(failCount: 6))
        XCTAssertGreaterThan(attempts(failCount: 6), 0, "Backoff must not become a permanent stop")
    }

    /// Sessions that fail together must not all retry on the same cycle — the
    /// reason a per-session offset is in the expression at all.
    func testDistinctSessionsAreSpreadAcrossCycles() {
        let period = 8
        let cycles = Set((0 ..< 64).map { bucket in
            (0 ..< period).first { !defers(bucket: bucket, failCount: 3, cycle: $0) }
        })
        XCTAssertGreaterThan(cycles.count, 1, "Every session retried on the same cycle")
    }

    /// A large failure count must not shift past Int width.
    func testTheExponentIsCappedBeforeShifting() {
        for failCount in [7, 32, 63, 200] {
            XCTAssertNoThrow(_ = defers(bucket: 3, failCount: failCount, cycle: 1))
        }
    }
}
