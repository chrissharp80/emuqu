@testable import Emuqu
import XCTest

/// A deferred upload must eventually become eligible again.
///
/// Every assertion runs against `CloudKitSyncManager.defersForBackoff`, the
/// decision `pendingPushBatch` uses, with the cycle passed in so it can be
/// advanced deterministically instead of waiting on real pushes.
///
/// What has to be asserted is PROGRESS, not bucket stability. A decision built
/// only from the session's bucket and failure count (`bucket % period != 0`)
/// has a stable bucket and still never recovers: both operands stay constant
/// while a session is skipped, so it defers on every cycle. UUID
/// `01000000-0000-4000-8000-000000000000` gives bucket 1, which under that form
/// defers forever after a single failure.
final class CloudRetryProgressTests: XCTestCase {
    private static let bucketOneUUID = UUID(
        uuid: (0x01, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 0)
    )

    private func defers(bucket: Int, failCount: Int, cycle: Int) -> Bool {
        CloudKitSyncManager.defersForBackoff(failCount: failCount, bucket: bucket, cycle: cycle)
    }

    func testTheBucketIsDerivedFromTheUUIDBytes() {
        XCTAssertEqual(CloudKitSyncManager.stableRetryBucket(for: Self.bucketOneUUID), 1)
        XCTAssertEqual(
            CloudKitSyncManager.stableRetryBucket(for: Self.bucketOneUUID),
            CloudKitSyncManager.stableRetryBucket(for: Self.bucketOneUUID),
            "The bucket must not change between calls (hashValue would)"
        )
    }

    func testASessionWithNoFailuresNeverDefers() {
        for cycle in 0 ..< 64 {
            XCTAssertFalse(defers(bucket: 1, failCount: 0, cycle: cycle))
        }
    }

    /// The bucket-1 session after one failure is the case a cycle-free
    /// decision defers forever.
    func testTheBucketOneSessionRetriesOnceTheCycleAdvances() {
        let bucket = CloudKitSyncManager.stableRetryBucket(for: Self.bucketOneUUID)
        let attempts = (0 ..< 16).filter { !defers(bucket: bucket, failCount: 1, cycle: $0) }.count
        XCTAssertGreaterThan(attempts, 1, "A session that failed once never retried")
    }

    /// Every session, at every failure count, becomes eligible within the
    /// backoff ceiling.
    func testEverySessionBecomesEligibleWithinTheCeiling() {
        let ceiling = CloudKitSyncManager.maxBackoffCycles
        for failCount in 1 ... 8 {
            for bucket in [0, 1, 2, 7, 31, 12_345, 8_388_607] {
                for start in [0, 5, 1_000] {
                    let eligible = (start ..< start + ceiling).contains {
                        !defers(bucket: bucket, failCount: failCount, cycle: $0)
                    }
                    XCTAssertTrue(eligible, "bucket \(bucket) at failCount \(failCount) from cycle \(start) "
                        + "never became eligible within \(ceiling) cycles")
                }
            }
        }
    }

    /// The period doubles with each failure and stops at the ceiling.
    func testThePeriodDoublesThenStopsAtTheCeiling() {
        XCTAssertEqual(CloudKitSyncManager.backoffPeriod(failCount: 1), 2)
        XCTAssertEqual(CloudKitSyncManager.backoffPeriod(failCount: 2), 4)
        XCTAssertEqual(CloudKitSyncManager.backoffPeriod(failCount: 3), 8)
        XCTAssertEqual(CloudKitSyncManager.backoffPeriod(failCount: 5), 32)
        for failCount in [6, 7, 63, 64, 200, Int.max] {
            XCTAssertEqual(CloudKitSyncManager.backoffPeriod(failCount: failCount),
                           CloudKitSyncManager.maxBackoffCycles,
                           "failCount \(failCount) must stop at the ceiling without overflowing")
        }
    }

    /// Backoff still backs off: retrying every cycle would hammer CloudKit.
    func testHigherFailureCountsRetryLessOften() {
        func attempts(failCount: Int) -> Int {
            (0 ..< 256).filter { !defers(bucket: 5, failCount: failCount, cycle: $0) }.count
        }
        XCTAssertEqual(attempts(failCount: 1), 128)
        XCTAssertEqual(attempts(failCount: 3), 32)
        XCTAssertEqual(attempts(failCount: 6), 8)
    }

    /// Sessions that fail together do not all retry on the same cycle.
    func testDistinctSessionsAreSpreadAcrossCycles() {
        let firstRetry = Set((0 ..< 64).map { bucket in
            (0 ..< 8).first { !defers(bucket: bucket, failCount: 3, cycle: $0) }
        })
        XCTAssertEqual(firstRetry.count, 8, "Sessions failing together must spread over the whole period")
    }
}
