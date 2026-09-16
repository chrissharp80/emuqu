@testable import Emuqu
import XCTest

/// Tests for what the app believes the current strap link can do.
///
/// Polar SDK 8.x reports readiness only inside a ten-second window after
/// service discovery. The app used to wait for those reports and never got
/// them on a slow link — the strap connected and no heart rate ever arrived.
/// These pin the rules that replaced that: a report is believed, a summary
/// that leaves a feature out lets the SDK's own per-call guard decide, and
/// nothing learned about one link survives into the next.
final class StrapReadinessTests: XCTestCase {
    private func linked() -> StrapReadiness {
        var readiness = StrapReadiness.initial
        readiness.linkEstablished()
        return readiness
    }

    // MARK: - Before and between links

    func testNothingIsKnownWithoutALink() {
        let readiness = StrapReadiness.initial

        XCTAssertFalse(readiness.isLinked)
        XCTAssertEqual(readiness.generation, 0)
        for feature in StrapFeature.allCases {
            XCTAssertEqual(readiness.state(of: feature), .pending)
            XCTAssertNil(readiness.waitOutcome(for: feature), "a waiter keeps waiting for a link")
        }
    }

    /// A report that arrives with no link is a stale callback, not knowledge.
    func testReportsWithoutALinkAreIgnored() {
        var readiness = StrapReadiness.initial
        readiness.markReady(.heartRate)
        readiness.confirm(.h10Recording)
        readiness.applySummary(ready: [.offlineRecording], unavailable: [])
        readiness.settleWithoutSummary()

        XCTAssertFalse(readiness.isSettled)
        for feature in StrapFeature.allCases {
            XCTAssertEqual(readiness.state(of: feature), .pending)
        }
    }

    func testEachLinkIsANewGeneration() {
        var readiness = linked()
        XCTAssertEqual(readiness.generation, 1)

        readiness.linkLost()
        XCTAssertEqual(readiness.generation, 1, "losing a link does not start a new one")
        readiness.linkEstablished()
        XCTAssertEqual(readiness.generation, 2)
    }

    /// A flag left over from the last link is a call believing it can record
    /// on a strap that has not set its services up again.
    func testNothingSurvivesALostLink() {
        var readiness = linked()
        readiness.markReady(.h10Recording)
        readiness.applySummary(ready: [.heartRate], unavailable: [.offlineRecording])

        readiness.linkLost()
        XCTAssertFalse(readiness.isLinked)
        XCTAssertFalse(readiness.isSettled)

        readiness.linkEstablished()
        for feature in StrapFeature.allCases {
            XCTAssertEqual(readiness.state(of: feature), .pending, "\(feature) carried over")
        }
        XCTAssertFalse(readiness.isSettled)
    }

    // MARK: - Waiting

    func testAFreshLinkKeepsWaitersWaiting() {
        let readiness = linked()
        for feature in StrapFeature.allCases {
            XCTAssertNil(readiness.waitOutcome(for: feature))
        }
    }

    func testAReportedFeatureIsReady() {
        var readiness = linked()
        readiness.markReady(.heartRate)

        XCTAssertTrue(readiness.isReady(.heartRate))
        XCTAssertEqual(readiness.waitOutcome(for: .heartRate), .ready)
        XCTAssertNil(readiness.waitOutcome(for: .h10Recording))
    }

    /// The summary means the SDK stopped checking, not that the features it
    /// left out are absent.
    func testASummaryLeavesUnreportedFeaturesUnconfirmedNotUnavailable() {
        var readiness = linked()
        readiness.applySummary(ready: [.heartRate], unavailable: [.offlineRecording])

        XCTAssertTrue(readiness.isSettled)
        XCTAssertEqual(readiness.waitOutcome(for: .heartRate), .ready)
        XCTAssertEqual(readiness.waitOutcome(for: .offlineRecording), .unavailable)
        XCTAssertEqual(readiness.state(of: .h10Recording), .pending)
        XCTAssertEqual(readiness.waitOutcome(for: .h10Recording), .unconfirmed)
    }

    /// An earlier per-feature report outranks a summary that lists the same
    /// feature as unavailable — the report is the more specific evidence.
    func testASummaryDoesNotDowngradeAFeatureAlreadyReady() {
        var readiness = linked()
        readiness.markReady(.onlineStreaming)
        readiness.applySummary(ready: [], unavailable: [.onlineStreaming])

        XCTAssertEqual(readiness.waitOutcome(for: .onlineStreaming), .ready)
    }

    /// With no summary at all, the link settles on the app's own timer and
    /// every unreported feature becomes worth trying.
    func testSettlingWithoutASummaryMakesPendingFeaturesUnconfirmed() {
        var readiness = linked()
        readiness.markReady(.heartRate)
        readiness.settleWithoutSummary()

        XCTAssertEqual(readiness.waitOutcome(for: .heartRate), .ready)
        XCTAssertEqual(readiness.waitOutcome(for: .h10Recording), .unconfirmed)
    }

    /// A call that needed the feature and succeeded is proof it is usable.
    func testASuccessfulOperationConfirmsItsFeature() {
        var readiness = linked()
        readiness.applySummary(ready: [], unavailable: [.h10Recording])
        readiness.confirm(.h10Recording)

        XCTAssertEqual(readiness.waitOutcome(for: .h10Recording), .ready)
    }
}
