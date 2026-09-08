@testable import Emuqu
import XCTest

/// Tests for the `HKMetadataKeyExternalUUID` scheme that decides which of the
/// app's own samples a re-export deletes from the user's permanent Health
/// record.
///
/// A predicate that reaches one sample too far erases health data the user
/// cannot get back, so the safety argument — *"Exact match: `-hr` must NOT
/// swallow the `-hr-<n>` minute series"* — is asserted here rather than
/// left as a comment beside the delete call.
final class HealthExportIdentityTests: XCTestCase {
    private let session = UUID()
    private let otherSession = UUID()

    // MARK: - The comment that used to be the whole safeguard

    /// The summary sample's predicate is exact, so it cannot reach the minute
    /// series that shares its metric name.
    func testTheHeartRateSummaryPredicateDoesNotReachTheMinuteSeries() {
        for index in [0, 1, 42, 9_999] {
            let member = HealthExportIdentity.seriesMember(
                sessionId: session, metric: .heartRate, index: index
            )
            XCTAssertFalse(
                HealthExportIdentity.isSummary(member, sessionId: session, metric: .heartRate),
                "the summary delete must not swallow minute sample \(index)"
            )
        }
    }

    /// And the series' predicate is a prefix that stops short of the summary.
    func testTheMinuteSeriesPredicateDoesNotReachTheSummary() {
        let summary = HealthExportIdentity.summary(sessionId: session, metric: .heartRate)
        XCTAssertFalse(
            HealthExportIdentity.isSeriesMember(summary, sessionId: session, metric: .heartRate)
        )
    }

    /// Each predicate does reach what it is for.
    func testEachPredicateMatchesItsOwnSamples() {
        let summary = HealthExportIdentity.summary(sessionId: session, metric: .heartRate)
        XCTAssertTrue(HealthExportIdentity.isSummary(summary, sessionId: session, metric: .heartRate))
        for index in 0 ..< 5 {
            let member = HealthExportIdentity.seriesMember(
                sessionId: session, metric: .heartRate, index: index
            )
            XCTAssertTrue(
                HealthExportIdentity.isSeriesMember(member, sessionId: session, metric: .heartRate)
            )
        }
    }

    // MARK: - Cross-metric interference

    /// The property that has to hold for every pair, not just the pair someone
    /// happened to think about: no metric's delete may reach another metric's
    /// samples. Enumerating `Metric.allCases` means adding a metric to the app
    /// automatically extends this test to it.
    func testNoMetricsPredicatesReachAnotherMetricsSamples() {
        for owner in HealthExportIdentity.Metric.allCases {
            for other in HealthExportIdentity.Metric.allCases where other != owner {
                let otherSummary = HealthExportIdentity.summary(sessionId: session, metric: other)
                let otherMember = HealthExportIdentity.seriesMember(
                    sessionId: session, metric: other, index: 3
                )
                for sample in [otherSummary, otherMember] {
                    XCTAssertFalse(
                        HealthExportIdentity.belongsToSession(sample, sessionId: session, metric: owner),
                        "\(owner.rawValue)'s delete reaches \(other.rawValue)'s sample \(sample)"
                    )
                }
            }
        }
    }

    /// The specific collision the naming makes possible: `hr` is a prefix of
    /// nothing else today, but `rhr` ends in it and a future metric might
    /// start with it. Pinned so the names stay safe.
    func testHeartRateAndRestingHeartRateDoNotCollide() {
        let rhr = HealthExportIdentity.summary(sessionId: session, metric: .restingHeartRate)
        XCTAssertFalse(HealthExportIdentity.belongsToSession(rhr, sessionId: session, metric: .heartRate))
        let hr = HealthExportIdentity.summary(sessionId: session, metric: .heartRate)
        XCTAssertFalse(HealthExportIdentity.belongsToSession(hr, sessionId: session, metric: .restingHeartRate))
    }

    /// Sleep's delete is by prefix and its members carry a named suffix as
    /// well as numbered ones. A metric whose name merely starts with "sleep"
    /// must still not be caught by it.
    func testSleepsPrefixDeleteStopsAtTheSeparator() {
        let named = HealthExportIdentity.seriesMember(sessionId: session, metric: .sleep, suffix: "inbed")
        XCTAssertTrue(HealthExportIdentity.belongsToSession(named, sessionId: session, metric: .sleep))
        let hypotheticalOtherMetric = "\(session.uuidString)-sleepDebt-0"
        XCTAssertFalse(
            HealthExportIdentity.belongsToSession(hypotheticalOtherMetric, sessionId: session, metric: .sleep),
            "a prefix delete without a separator would erase another metric's samples"
        )
    }

    // MARK: - Session scoping

    /// Every predicate is scoped to one session. Re-exporting today's reading
    /// must not touch last week's.
    func testNoPredicateReachesAnotherSessionsSamples() {
        for metric in HealthExportIdentity.Metric.allCases {
            let theirSummary = HealthExportIdentity.summary(sessionId: otherSession, metric: metric)
            let theirMember = HealthExportIdentity.seriesMember(
                sessionId: otherSession, metric: metric, index: 1
            )
            for sample in [theirSummary, theirMember] {
                XCTAssertFalse(
                    HealthExportIdentity.belongsToSession(sample, sessionId: session, metric: metric),
                    "\(metric.rawValue) delete reached another session's sample"
                )
            }
        }
    }

    // MARK: - Shape

    /// The identities are stable strings: they are written into the user's
    /// Health record and read back on a later export, so the format cannot
    /// drift without orphaning everything already written.
    func testIdentityFormatIsStable() {
        XCTAssertEqual(
            HealthExportIdentity.summary(sessionId: session, metric: .heartRate),
            "\(session.uuidString)-hr"
        )
        XCTAssertEqual(
            HealthExportIdentity.seriesMember(sessionId: session, metric: .heartRate, index: 7),
            "\(session.uuidString)-hr-7"
        )
        XCTAssertEqual(
            HealthExportIdentity.summary(sessionId: session, metric: .restingHeartRate),
            "\(session.uuidString)-rhr"
        )
        XCTAssertEqual(
            HealthExportIdentity.seriesMember(sessionId: session, metric: .sdnn, index: 0),
            "\(session.uuidString)-sdnn-0"
        )
        XCTAssertEqual(
            HealthExportIdentity.seriesMember(sessionId: session, metric: .rmssd, index: 2),
            "\(session.uuidString)-rmssd-2"
        )
        XCTAssertEqual(
            HealthExportIdentity.seriesMember(sessionId: session, metric: .sleep, suffix: "inbed"),
            "\(session.uuidString)-sleep-inbed"
        )
    }

    /// An unrelated app's sample, or one of ours from before the scheme, is
    /// never matched.
    func testUnrelatedIdentifiersAreNeverMatched() {
        for junk in ["", "not-a-uuid", session.uuidString, "\(session.uuidString)", "hr", "-hr"] {
            for metric in HealthExportIdentity.Metric.allCases {
                XCTAssertFalse(
                    HealthExportIdentity.belongsToSession(junk, sessionId: session, metric: metric),
                    "matched \(junk.isEmpty ? "<empty>" : junk) for \(metric.rawValue)"
                )
            }
        }
    }
}
