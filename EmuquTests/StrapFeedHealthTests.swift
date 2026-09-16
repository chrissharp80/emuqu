@testable import Emuqu
import XCTest

/// Tests for when a silent strap feed is acted on, and how hard.
///
/// Every reconnect makes an H10 enumerate its services again, which on a
/// loaded phone has taken tens of seconds — so a policy that resets the link
/// too eagerly keeps the strap permanently setting up and never delivering.
/// These pin the escalation: describe, re-subscribe over the same link, and
/// only for a recording session, only after that has had its chance, and
/// never twice in quick succession, reset the link.
final class StrapFeedHealthTests: XCTestCase {
    private typealias Health = StrapFeedHealth

    private let linkedAt = Date(timeIntervalSince1970: 1_788_000_000)

    private func at(_ seconds: TimeInterval) -> Date { linkedAt.addingTimeInterval(seconds) }

    private func inputs(
        now: TimeInterval,
        isLinked: Bool = true,
        settledAt: TimeInterval? = nil,
        lastSampleAt: TimeInterval? = nil,
        lastResubscribeAt: TimeInterval? = nil,
        lastLinkResetAt: TimeInterval? = nil,
        sessionActive: Bool = true
    ) -> Health.Inputs {
        Health.Inputs(
            now: at(now),
            isLinked: isLinked,
            linkedAt: isLinked ? linkedAt : nil,
            settledAt: settledAt.map(at),
            lastSampleAt: lastSampleAt.map(at),
            lastResubscribeAt: lastResubscribeAt.map(at),
            lastLinkResetAt: lastLinkResetAt.map(at),
            sessionActive: sessionActive
        )
    }

    private func decide(_ inputs: Health.Inputs) -> Health.Decision { Health.decide(inputs) }

    // MARK: - Contract

    func testThresholdsMatchTheFieldEvidence() {
        XCTAssertEqual(Health.liveSilenceSec, 15)
        XCTAssertEqual(Health.setupGraceAfterSettleSec, 45)
        XCTAssertEqual(Health.setupGraceUnsettledSec, 90)
        XCTAssertEqual(Health.resubscribeGraceSec, 30)
        XCTAssertEqual(Health.linkResetCooldownSec, 180)
    }

    // MARK: - Status

    func testNoLinkIsWaitingAndDoesNothing() {
        XCTAssertEqual(
            decide(inputs(now: 500, isLinked: false, lastSampleAt: 0)),
            Health.Decision(status: .waitingForStrap, action: .none)
        )
    }

    func testRecentBeatsAreLive() {
        XCTAssertEqual(decide(inputs(now: 100, lastSampleAt: 90)), Health.Decision(status: .live, action: .none))
        XCTAssertEqual(decide(inputs(now: 115, lastSampleAt: 100)), Health.Decision(status: .live, action: .none))
    }

    /// Discovery has been observed at 43 s on a loaded phone: no summary yet
    /// means the strap is still setting up, not stalled.
    func testANewLinkWithoutASummaryIsSettingUpForTheFullAllowance() {
        XCTAssertEqual(decide(inputs(now: 60)), Health.Decision(status: .settingUp, action: .none))
        XCTAssertEqual(decide(inputs(now: 89)), Health.Decision(status: .settingUp, action: .none))
        XCTAssertEqual(decide(inputs(now: 90)).status, .stalled)
    }

    /// After the summary, HR notifications have been seen 17 s later.
    func testAfterTheSummaryTheAllowanceRunsFromTheSummary() {
        XCTAssertEqual(decide(inputs(now: 50, settledAt: 20)).status, .settingUp)
        XCTAssertEqual(decide(inputs(now: 65, settledAt: 20)).status, .stalled)
    }

    func testAFeedThatWentQuietIsStalledAfterTheSilenceAllowance() {
        XCTAssertEqual(decide(inputs(now: 116, lastSampleAt: 100)).status, .stalled)
    }

    // MARK: - Escalation

    /// Re-subscribing costs nothing: the SDK checks locally before the radio.
    func testTheFirstResponseToAStallIsAResubscribe() {
        XCTAssertEqual(decide(inputs(now: 120, lastSampleAt: 100)).action, .resubscribe)
    }

    /// One re-subscribe per stall episode — not one every health check.
    func testTheResubscribeIsNotRepeatedWithinTheSameStall() {
        XCTAssertEqual(
            decide(inputs(now: 125, lastSampleAt: 100, lastResubscribeAt: 120, sessionActive: false)),
            Health.Decision(status: .stalled, action: .none)
        )
    }

    /// A re-subscribe from an earlier episode does not count for this one.
    func testAResubscribeFromAnEarlierStallDoesNotCount() {
        XCTAssertEqual(decide(inputs(now: 320, lastSampleAt: 300, lastResubscribeAt: 120)).action, .resubscribe)
    }

    func testASessionResetsTheLinkOnlyAfterTheResubscribeHadItsChance() {
        XCTAssertEqual(decide(inputs(now: 149, lastSampleAt: 100, lastResubscribeAt: 120)).action, .none)
        XCTAssertEqual(decide(inputs(now: 150, lastSampleAt: 100, lastResubscribeAt: 120)).action, .resetLink)
    }

    /// Outside a session nothing is being lost, so the link is left alone.
    func testWithoutASessionTheLinkIsNeverReset() {
        XCTAssertEqual(
            decide(inputs(now: 1_000, lastSampleAt: 100, lastResubscribeAt: 120, sessionActive: false)).action,
            .none
        )
    }

    /// Resets in quick succession keep the strap permanently enumerating.
    func testLinkResetsRespectTheCooldown() {
        XCTAssertEqual(
            decide(inputs(now: 150, lastSampleAt: 100, lastResubscribeAt: 120, lastLinkResetAt: -29)).action,
            .none
        )
        XCTAssertEqual(
            decide(inputs(now: 150, lastSampleAt: 100, lastResubscribeAt: 120, lastLinkResetAt: -30)).action,
            .resetLink
        )
    }

    // MARK: - Re-subscribe cadence

    func testTheResubscribeCadenceIsShortAndBounded() {
        XCTAssertEqual(Health.resubscribeDelay(afterFailures: -1), 1)
        XCTAssertEqual(Health.resubscribeDelay(afterFailures: 0), 1)
        XCTAssertEqual(Health.resubscribeDelay(afterFailures: 1), 2)
        XCTAssertEqual(Health.resubscribeDelay(afterFailures: 2), 3)
        XCTAssertEqual(Health.resubscribeDelay(afterFailures: 3), 5)
        XCTAssertEqual(Health.resubscribeDelay(afterFailures: 1_000), 5)
    }
}
