@testable import Emuqu
import XCTest

/// Window classification: `ScoredRecoveryBlock.classification` and
/// `.isOrganizedRecovery`, the rules that decide which five minutes of the
/// night the recovery score is computed from.
///
/// These tests target `ScoredRecoveryBlock`, the type the selector actually
/// runs, on purpose: a second copy of the same three-tier α1 logic, the same
/// LF/HF-or-stable-HR rule and the same 60-beat floor on a type no production
/// path calls makes the logic look well covered while the live copy is free
/// to drift without a single test going red.
///
/// There is deliberately no case asserting the explanation string contains
/// "load-bearing" or "disorganized": that is an unsupported claim about the
/// reader's physiology, and a test that pins a claim in place is not coverage;
/// it is a lock on the claim.
final class RecoveryBlockClassificationTests: XCTestCase {
    /// A block with everything irrelevant to classification held constant, so
    /// each test varies exactly the field it is about.
    private func block(
        cleanBeatCount: Int = 400,
        dfaAlpha1: Double? = 0.85,
        lfHfRatio: Double? = 1.2,
        hrCV: Double = 0.05
    ) -> ScoredRecoveryBlock {
        ScoredRecoveryBlock(
            startIndex: 0,
            endIndex: max(0, cleanBeatCount - 1),
            startMs: 0,
            endMs: 300_000,
            artifactRate: 0.01,
            ectopicRate: 0.0,
            meanHR: 55,
            hrCV: hrCV,
            rmssd: 45,
            sdnn: 60,
            cleanBeatCount: cleanBeatCount,
            relativePosition: 0.5,
            cleanRRs: Array(repeating: 1_090, count: max(1, cleanBeatCount)),
            dfaAlpha1: dfaAlpha1,
            lfHfRatio: lfHfRatio
        )
    }

    /// Consolidation is not a property of the block — the selector composes it
    /// as "organized AND stable HR" at the call site. Reproduced here so the
    /// composition is pinned somewhere.
    private func isConsolidated(_ b: ScoredRecoveryBlock) -> Bool {
        b.isOrganizedRecovery && b.hrCV < WindowSelector.RecoveryWindow.unstableCVThreshold
    }

    // MARK: - Classification

    func testOptimalAlpha1ProducesOrganizedRecovery() {
        let b = block(dfaAlpha1: 0.85)
        XCTAssertEqual(b.classification, .organizedRecovery)
        XCTAssertTrue(b.isOrganizedRecovery)
    }

    func testFlexibleAlpha1ProducesFlexibleClassification() {
        let b = block(dfaAlpha1: 0.65) // Between 0.60 and 0.75
        XCTAssertEqual(b.classification, .flexibleUnconsolidated)
        XCTAssertFalse(b.isOrganizedRecovery)
    }

    func testHighAlpha1ProducesHighVariability() {
        let b = block(dfaAlpha1: 1.3) // Above the 1.0 upper bound
        XCTAssertEqual(b.classification, .highVariability)
        XCTAssertFalse(b.isOrganizedRecovery)
    }

    func testLowAlpha1ProducesHighVariability() {
        let b = block(dfaAlpha1: 0.4) // Below the 0.60 flexible floor
        XCTAssertEqual(b.classification, .highVariability)
        XCTAssertFalse(b.isOrganizedRecovery)
    }

    func testInsufficientBeatsProducesInsufficientClassification() {
        XCTAssertEqual(block(cleanBeatCount: 50).classification, .insufficient)
    }

    // MARK: - isOrganizedRecovery

    func testOrganizedRecoveryRequiresOptimalAlpha1() {
        XCTAssertTrue(block(dfaAlpha1: 0.85).isOrganizedRecovery)
        XCTAssertFalse(block(dfaAlpha1: 1.2).isOrganizedRecovery)
    }

    func testOrganizedRecoveryWithHighLfHfButStableHR() {
        // Above the 1.5 LF/HF bound, but HR is very stable — the tolerant rule
        // accepts either signal.
        XCTAssertTrue(block(lfHfRatio: 2.0, hrCV: 0.03).isOrganizedRecovery)
    }

    func testOrganizedRecoveryWithNilAlpha1UsesHRStability() {
        XCTAssertTrue(block(dfaAlpha1: nil, hrCV: 0.05).isOrganizedRecovery)
        XCTAssertFalse(block(dfaAlpha1: nil, hrCV: 0.12).isOrganizedRecovery)
    }

    // MARK: - Consolidation

    func testConsolidationRequiresOrganizedAndStableHR() {
        XCTAssertTrue(isConsolidated(block(hrCV: 0.05)))
        XCTAssertFalse(isConsolidated(block(hrCV: 0.12)))
    }

    // MARK: - Boundaries

    func testAlpha1AtExactOptimalBoundaries() {
        XCTAssertEqual(block(dfaAlpha1: 0.75).classification, .organizedRecovery)
        XCTAssertEqual(block(dfaAlpha1: 1.0).classification, .organizedRecovery)
    }

    func testCVAtExactThresholdIsNotConsolidated() {
        // The rule is `< 0.08`, so exactly 0.08 falls outside it.
        XCTAssertFalse(isConsolidated(block(hrCV: 0.08)))
    }

    func testBeatsAtMinimumThreshold() {
        XCTAssertNotEqual(block(cleanBeatCount: 60).classification, .insufficient)
        XCTAssertEqual(block(cleanBeatCount: 59).classification, .insufficient)
    }

    // MARK: - Edge cases

    func testNilLfHfRatioDoesNotBlockOrganizedRecovery() {
        XCTAssertEqual(block(lfHfRatio: nil, hrCV: 0.05).classification, .organizedRecovery)
    }

    func testNilLfHfStillRequiresStableHRForOrganizedRecovery() {
        XCTAssertFalse(
            block(lfHfRatio: nil, hrCV: 0.12).isOrganizedRecovery,
            "Without LF/HF, organized recovery should require stable HR"
        )
    }

    func testZeroBeatCountHandled() {
        XCTAssertEqual(block(cleanBeatCount: 0).classification, .insufficient)
    }

    // MARK: - The label that replaced the duplicate enum

    func testShortLabelCoversEveryClassification() {
        // `MorningResultsView` decodes a stored raw value through this enum and
        // falls back to the raw string when the label is missing, so every
        // case needs a label.
        let expected: [WindowSelector.RecoveryWindow.WindowClassification: String] = [
            .organizedRecovery: "Organized",
            .flexibleUnconsolidated: "Flexible",
            .highVariability: "Variable",
            .insufficient: "N/A"
        ]
        for (classification, label) in expected {
            XCTAssertEqual(classification.shortLabel, label)
            XCTAssertEqual(
                WindowSelector.RecoveryWindow.WindowClassification(rawValue: classification.rawValue),
                classification,
                "raw value must round-trip — the view decodes stored strings through it"
            )
        }
    }
}
