@testable import Emuqu
import XCTest

/// Tests for the route-history TRIMP estimator.
///
/// This decides the training load a user is
/// credited with when their strap dropped mid-workout — the case the feature
/// exists for. That number feeds CTL and ATL, which feed every recommendation
/// afterwards, so an over-estimate here tells someone to rest when they are
/// fine, and an under-estimate tells them to train when they are cooked.
@MainActor
final class RouteTRIMPEstimatorTests: XCTestCase {
    // MARK: - TRIMP per metre

    func testRatioIsLoadOverDistance() {
        XCTAssertEqual(
            RouteTRIMPEstimator.trimpPerMetre(trimp: 100, distance: 10_000) ?? 0,
            0.01, accuracy: 1e-9
        )
    }

    func testZeroDistanceProducesNoRatio() {
        // Guards a division by zero that would otherwise be infinity and then
        // scale to an absurd estimate.
        XCTAssertNil(RouteTRIMPEstimator.trimpPerMetre(trimp: 100, distance: 0))
    }

    func testZeroTRIMPProducesNoRatio() {
        // TRIMP 0 is the strap-dropped signature, not a real easy run. Using
        // it as an anchor would propagate the very bug this estimator fixes.
        XCTAssertNil(RouteTRIMPEstimator.trimpPerMetre(trimp: 0, distance: 10_000))
    }

    func testMissingInputsProduceNoRatio() {
        XCTAssertNil(RouteTRIMPEstimator.trimpPerMetre(trimp: nil, distance: 10_000))
        XCTAssertNil(RouteTRIMPEstimator.trimpPerMetre(trimp: 100, distance: nil))
    }

    // MARK: - Target distance

    func testFullLoopUsesTheSavedDistance() {
        // Within 10% of the saved route: treat it as the whole loop.
        XCTAssertEqual(
            RouteTRIMPEstimator.targetDistance(recordedDistance: 9_500, savedDistance: 10_000),
            10_000
        )
    }

    func testStrapDroppedEarlyStillScalesToTheWholeRoute() {
        // Recorded far short of the route — the strap died, the user did not
        // stop. The estimate must cover the route they actually ran.
        XCTAssertEqual(
            RouteTRIMPEstimator.targetDistance(recordedDistance: 4_000, savedDistance: 10_000),
            10_000
        )
    }

    /// The "whole loop" test was a floor (`>= 0.9 x saved`)
    /// with no upper bound, so this returned 10,000 — the `max` below it was
    /// unreachable and the documented user-extended case had never worked.
    func testUserRanFurtherThanTheSavedRoute() {
        XCTAssertEqual(
            RouteTRIMPEstimator.targetDistance(recordedDistance: 14_000, savedDistance: 10_000),
            14_000,
            "running past the saved route must credit the distance actually run"
        )
    }

    func testSlightlyLongerStillCountsAsTheWholeLoop() {
        // Within 10% either way is the same loop, not an extension.
        XCTAssertEqual(
            RouteTRIMPEstimator.targetDistance(recordedDistance: 10_500, savedDistance: 10_000),
            10_000
        )
    }

    func testMuchLongerRunIsNotClampedToTheRoute() {
        // Four laps of a 10 km loop is 40 km of load, not 10.
        XCTAssertEqual(
            RouteTRIMPEstimator.targetDistance(recordedDistance: 40_000, savedDistance: 10_000),
            40_000
        )
    }

    func testNoRecordedDistanceFallsBackToTheRoute() {
        XCTAssertEqual(
            RouteTRIMPEstimator.targetDistance(recordedDistance: nil, savedDistance: 10_000),
            10_000
        )
    }

    // MARK: - The three estimation cases

    func testFullDropoutUsesPriorRunsDirectly() {
        // Case 3a — the complaint this feature was built for: HR missing
        // entirely, but the user has run this route before.
        let e = RouteTRIMPEstimator.scaledEstimate(
            priorAvgRatio: 0.01, recordedRatio: nil, priorCount: 3, targetDistance: 10_000
        )
        XCTAssertEqual(e?.trimp ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(e?.priorDominant, true, "with no recorded data the prior must dominate")
    }

    func testPartialDataBlendsBiasedTowardPriors() {
        // Case 2 — 60/40 toward the prior, because today's number is the
        // suspicious one.
        let e = RouteTRIMPEstimator.scaledEstimate(
            priorAvgRatio: 0.01, recordedRatio: 0.005, priorCount: 3, targetDistance: 10_000
        )
        XCTAssertEqual(e?.trimp ?? 0, (0.01 * 0.6 + 0.005 * 0.4) * 10_000, accuracy: 1e-9)
        XCTAssertEqual(e?.priorDominant, false)
    }

    func testNoPriorsScalesTodayAtLowConfidence() {
        // Case 3b — never run this route, so the estimate is weak and must say so.
        let e = RouteTRIMPEstimator.scaledEstimate(
            priorAvgRatio: nil, recordedRatio: 0.008, priorCount: 0, targetDistance: 10_000
        )
        XCTAssertEqual(e?.trimp ?? 0, 80, accuracy: 1e-9)
        XCTAssertEqual(e?.confidence ?? 0, 0.4, accuracy: 1e-9)
    }

    func testNoBasisProducesNoEstimate() {
        // Inventing a number here would be worse than showing none.
        XCTAssertNil(
            RouteTRIMPEstimator.scaledEstimate(
                priorAvgRatio: nil, recordedRatio: nil, priorCount: 0, targetDistance: 10_000
            )
        )
    }

    // MARK: - Confidence

    func testConfidenceRisesWithPriorRunsButIsCapped() {
        let one = RouteTRIMPEstimator.scaledEstimate(
            priorAvgRatio: 0.01, recordedRatio: nil, priorCount: 1, targetDistance: 1_000
        )
        let many = RouteTRIMPEstimator.scaledEstimate(
            priorAvgRatio: 0.01, recordedRatio: nil, priorCount: 20, targetDistance: 1_000
        )
        XCTAssertLessThan(one?.confidence ?? 0, many?.confidence ?? 0)
        XCTAssertLessThanOrEqual(
            many?.confidence ?? 1, 0.85,
            "an estimate must never present itself as near-certain"
        )
    }

    // MARK: - Which prior runs count

    /// An unnoticed strap dropout (TRIMP ≈ 2) among the priors dragged the
    /// average toward the very dropout this estimator corrects.
    func testADropoutPriorIsDroppedAsAnOutlier() {
        XCTAssertEqual(RouteTRIMPEstimator.withoutOutliers([0.010, 0.011, 0.0002]), [0.010, 0.011])
    }

    func testSimilarPriorsAreAllKept() {
        XCTAssertEqual(RouteTRIMPEstimator.withoutOutliers([0.009, 0.010, 0.012]), [0.009, 0.010, 0.012])
        XCTAssertEqual(RouteTRIMPEstimator.withoutOutliers([0.01]), [0.01])
    }

    private let workoutStart = Date(timeIntervalSince1970: 1_700_000_000)

    private func prior(
        endingAt end: Date, sport: Sport = .run, luciaTRIMP: Double = 60, partial: Bool = false
    ) -> HRVSession {
        var meta = WorkoutMetadata(sport: sport)
        meta.luciaTRIMP = luciaTRIMP
        meta.partialDataReason = partial ? .appCrashed : nil
        var session = HRVSession(
            id: UUID(), startDate: end.addingTimeInterval(-3_600), endDate: end, state: .complete,
            sessionType: .workout, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        session.workoutMetadata = meta
        return session
    }

    func testAnEarlierCleanRunOfTheSameSportIsAPrior() {
        XCTAssertTrue(RouteTRIMPEstimator.isCleanPrior(
            prior(endingAt: workoutStart.addingTimeInterval(-86_400)), sport: .run, before: workoutStart
        ))
    }

    /// The backfill estimated an archived session whose own low ratio sat in
    /// its priors. A prior must have ended before the workout began.
    func testTheWorkoutBeingEstimatedIsNotItsOwnPrior() {
        let itself = prior(endingAt: workoutStart.addingTimeInterval(3_600))
        XCTAssertFalse(RouteTRIMPEstimator.isCleanPrior(itself, sport: .run, before: workoutStart))
    }

    func testAnotherSportIsNotAPrior() {
        let ride = prior(endingAt: workoutStart.addingTimeInterval(-86_400), sport: .bike)
        XCTAssertFalse(RouteTRIMPEstimator.isCleanPrior(ride, sport: .run, before: workoutStart))
    }

    func testARecoveredPartialIsNotAPrior() {
        let partial = prior(endingAt: workoutStart.addingTimeInterval(-86_400), partial: true)
        XCTAssertFalse(RouteTRIMPEstimator.isCleanPrior(partial, sport: .run, before: workoutStart))
    }

    /// A run whose own load was replaced by a route estimate was a dropout;
    /// its recorded TRIMP is not the route's intensity.
    func testADropoutWhoseLoadWasReplacedIsNotAPrior() {
        var dropout = prior(endingAt: workoutStart.addingTimeInterval(-86_400), luciaTRIMP: 2)
        dropout.workoutMetadata?.extrapolatedTRIMP = 80
        dropout.workoutMetadata?.extrapolationConfidence = 0.7
        XCTAssertFalse(RouteTRIMPEstimator.isCleanPrior(dropout, sport: .run, before: workoutStart))
    }
}
