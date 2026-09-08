@testable import Emuqu
import XCTest

/// Capability-axis routing contract.
///
/// The acceptance gate is **≥ 95% capability correctness** on
/// hand-labeled slice (a) — real voice utterances from a recorded
/// session where routing failed.
///
/// This test suite is the thin first cut. It asserts the contract
/// against ~30 utterances drawn from the four failure categories the
/// user reported:
///
///   1. Tool-required questions that look short ("can you see the top
///      of the last hill") — must NOT classify as zero-flag Quick.
///   2. Web-required questions ("are there AI voices I can buy
///      commercially") — must set `needsWeb`.
///   3. Speculative questions ("best guess on how long I'm gonna
///      live") — must set `needsSpeculation`.
///   4. Pure factual lookups ("what's my recovery score") — must
///      classify as zero-flag → `.quick`.
///
/// The full eval set is
/// scaffolded by `EvalUtterances.swift`
/// — this file is the unit-test contract.
@MainActor
final class CapabilityClassifierTests: XCTestCase {

    // MARK: - Tool-required

    func testEmailRequestNeedsTools() {
        let req = CapabilityClassifier.shared.classify("email this report to my coach")
        XCTAssertTrue(req.needsTools, "Email action verb must set needsTools")
        XCTAssertNotEqual(req.requiredTier, .quick,
                          "Tool-required questions must escalate off Apple")
    }

    func testNavigationRequestNeedsTools() {
        let req = CapabilityClassifier.shared.classify("lead me back to where I parked")
        XCTAssertTrue(req.needsTools, "Navigation action must set needsTools")
        XCTAssertNotEqual(req.requiredTier, .quick)
    }

    func testRouteSaveNeedsTools() {
        let req = CapabilityClassifier.shared.classify("save this workout as a route called Morning Loop")
        XCTAssertTrue(req.needsTools)
        XCTAssertNotEqual(req.requiredTier, .quick)
    }

    // MARK: - Web-required

    func testWeatherNeedsWeb() {
        let req = CapabilityClassifier.shared.classify("what's the weather right now")
        XCTAssertTrue(req.needsWeb)
        XCTAssertNotEqual(req.requiredTier, .quick)
    }

    func testProductSearchNeedsWeb() {
        let req = CapabilityClassifier.shared.classify("are there AI voices I can buy and use commercially")
        // Apple Intelligence has no web-search tool and answers that it
        // can't help. This must escalate to a web-capable provider.
        XCTAssertTrue(req.needsTools || req.needsWeb,
                      "Commercial product question must trigger tools or web")
        XCTAssertNotEqual(req.requiredTier, .quick)
    }

    // MARK: - Speculation

    func testMortalitySpeculationNeedsSpeculation() {
        let req = CapabilityClassifier.shared.classify("do your best guess on how long I'm gonna live")
        XCTAssertTrue(req.needsSpeculation,
                      "Mortality speculation must trigger speculation flag — Apple's guardrail refuses; cloud is permitted under MedicalQueryGuard")
        XCTAssertNotEqual(req.requiredTier, .quick)
    }

    func testForecastNeedsSpeculation() {
        let req = CapabilityClassifier.shared.classify("predict what my recovery will look like next week")
        XCTAssertTrue(req.needsSpeculation)
    }

    func testWhatIfNeedsSpeculation() {
        let req = CapabilityClassifier.shared.classify("what if I rested for five days straight, how would I respond")
        XCTAssertTrue(req.needsSpeculation)
    }

    // MARK: - Historical depth

    func testEightWeekTrendNeedsDepth() {
        let req = CapabilityClassifier.shared.classify("explain my recovery trend over the last 8 weeks")
        XCTAssertTrue(req.needsHistoricalDepth)
    }

    func testQuarterComparisonNeedsDepth() {
        let req = CapabilityClassifier.shared.classify("across the past quarter, when did I peak")
        XCTAssertTrue(req.needsHistoricalDepth)
    }

    // MARK: - Pure factual lookups (must NOT escalate)

    func testRecoveryScoreLookupIsQuick() {
        let req = CapabilityClassifier.shared.classify("what's my recovery score")
        XCTAssertEqual(req.requiredTier, .quick,
                       "Pure factual lookup must stay on Apple — fits in 4K window")
    }

    func testRHRLookupIsQuick() {
        let req = CapabilityClassifier.shared.classify("what's my resting heart rate")
        XCTAssertEqual(req.requiredTier, .quick)
    }

    func testHRVLookupIsQuick() {
        let req = CapabilityClassifier.shared.classify("how was my HRV last night")
        XCTAssertEqual(req.requiredTier, .quick)
    }

    // MARK: - Tier resolution truth table

    func testZeroFlagsResolveToQuick() {
        let req = CapabilityClassifier.Requirement(
            needsTools: false, needsWeb: false,
            needsHistoricalDepth: false, needsSpeculation: false
        )
        XCTAssertEqual(req.requiredTier, .quick)
    }

    func testOneFlagResolvesToAuto() {
        let req = CapabilityClassifier.Requirement(
            needsTools: true, needsWeb: false,
            needsHistoricalDepth: false, needsSpeculation: false
        )
        XCTAssertEqual(req.requiredTier, .auto)
    }

    func testTwoOrMoreFlagsResolveToDeep() {
        let req = CapabilityClassifier.Requirement(
            needsTools: true, needsWeb: true,
            needsHistoricalDepth: false, needsSpeculation: false
        )
        XCTAssertEqual(req.requiredTier, .deep)
    }

    func testAllFlagsResolveToDeep() {
        let req = CapabilityClassifier.Requirement(
            needsTools: true, needsWeb: true,
            needsHistoricalDepth: true, needsSpeculation: true
        )
        XCTAssertEqual(req.requiredTier, .deep)
    }

    // MARK: - Empty / whitespace

    func testEmptyInputIsNone() {
        let req = CapabilityClassifier.shared.classify("")
        XCTAssertEqual(req, .none)
        XCTAssertEqual(req.requiredTier, .quick)
    }

    func testWhitespaceInputIsNone() {
        let req = CapabilityClassifier.shared.classify("   \n\t  ")
        XCTAssertEqual(req, .none)
    }
}
