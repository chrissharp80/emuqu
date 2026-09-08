@testable import Emuqu
import XCTest

@MainActor
final class ReanalysisServiceTests: XCTestCase {
    // MARK: - computeFrozenReadiness (static, pure function)

    func testComputeFrozenReadiness_withNilTrainingContext() {
        // When training context is nil, ATL and CTL default to 0
        let readiness = ReanalysisService.computeFrozenReadiness(
            compositeScore: 0.75,
            trainingContext: nil
        )
        // Should return a valid 0-10 scale score
        XCTAssertFalse(readiness.isNaN)
        XCTAssertFalse(readiness.isInfinite)
        XCTAssertGreaterThanOrEqual(readiness, 0)
        XCTAssertLessThanOrEqual(readiness, 10)
    }

    func testComputeFrozenReadiness_deterministic() {
        // Same inputs should always produce the same output
        let score1 = ReanalysisService.computeFrozenReadiness(
            compositeScore: 0.65,
            trainingContext: nil
        )
        let score2 = ReanalysisService.computeFrozenReadiness(
            compositeScore: 0.65,
            trainingContext: nil
        )
        XCTAssertEqual(score1, score2, accuracy: 0.0001)
    }

    func testComputeFrozenReadiness_higherCompositeScoreYieldsHigherReadiness() {
        let low = ReanalysisService.computeFrozenReadiness(
            compositeScore: 0.3,
            trainingContext: nil
        )
        let high = ReanalysisService.computeFrozenReadiness(
            compositeScore: 0.9,
            trainingContext: nil
        )
        XCTAssertGreaterThan(high, low)
    }

    func testComputeFrozenReadiness_zeroCompositeScore() {
        let readiness = ReanalysisService.computeFrozenReadiness(
            compositeScore: 0.0,
            trainingContext: nil
        )
        XCTAssertFalse(readiness.isNaN)
        XCTAssertGreaterThanOrEqual(readiness, 0)
    }

    func testComputeFrozenReadiness_oneCompositeScore() {
        let readiness = ReanalysisService.computeFrozenReadiness(
            compositeScore: 1.0,
            trainingContext: nil
        )
        XCTAssertFalse(readiness.isNaN)
        XCTAssertLessThanOrEqual(readiness, 10)
    }
}
