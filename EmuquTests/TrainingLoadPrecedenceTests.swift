@testable import Emuqu
import XCTest

/// Tests for the training-load precedence a historical workout is scored by.
///
/// `TrainingLoadPrecedence.stored` picks one number out of up to five, and that number
/// becomes the workout's contribution to CTL, ATL and TSB — so every
/// recommendation the app makes rests on the order below. The order is the
/// entire content of the function, and losing a tier is silent: treadmill
/// walks under-count until TSB sits at ~−2 instead of ~−13.
final class TrainingLoadPrecedenceTests: XCTestCase {
    /// `computedMETLoad` is derived, not stored, so the METs tier is supplied
    /// as a sample stream carrying a METs column — the same shape a real
    /// treadmill walk produces.
    private func metadata(
        powerTSS: Double? = nil,
        hrTSS: Double? = nil,
        mets: Double? = nil,
        luciaTRIMP: Double? = nil,
        extrapolatedTRIMP: Double? = nil
    ) -> WorkoutMetadata {
        var meta = WorkoutMetadata(sport: .run)
        meta.powerTSS = powerTSS
        meta.hrTSS = hrTSS
        meta.luciaTRIMP = luciaTRIMP
        meta.extrapolatedTRIMP = extrapolatedTRIMP
        if let mets {
            meta.samples = (0 ..< 60).map {
                WorkoutSample(offsetSec: $0 * 30, heartRate: nil, mets: mets)
            }
        }
        return meta
    }

    /// Guard for the fixture itself: the METs tier is only exercised if the
    /// sample stream actually produces a load. A silently-nil fixture would
    /// make every "METs wins" assertion below vacuous.
    func testTheMETsFixtureProducesALoad() throws {
        let load = try XCTUnwrap(metadata(mets: 6).computedMETLoad)
        XCTAssertGreaterThan(load, 0)
    }

    private func picked(_ meta: WorkoutMetadata) -> (value: Double, source: WorkoutMetadata.TrainingLoadSource)? {
        TrainingLoadPrecedence.stored(meta)
    }

    // MARK: - The order

    /// Power is the best available signal and is HR-independent, so it wins
    /// over everything even when the others are present and larger.
    func testPowerWinsOverEveryOtherSource() throws {
        let result = try XCTUnwrap(picked(metadata(
            powerTSS: 50, hrTSS: 900, mets: 9,
            luciaTRIMP: 900, extrapolatedTRIMP: 900
        )))
        XCTAssertEqual(result.source, .power)
        XCTAssertEqual(result.value, 50)
    }

    func testHeartRateWinsWhenThereIsNoPower() throws {
        let result = try XCTUnwrap(picked(metadata(
            hrTSS: 60, mets: 9, luciaTRIMP: 900, extrapolatedTRIMP: 900
        )))
        XCTAssertEqual(result.source, .hr)
    }

    /// A treadmill walk has no power and often no stored hrTSS; without this
    /// tier it falls through to the HR-Banister fallback, which reads low for
    /// easy-HR walking, and the walk never reaches ATL.
    func testMETLoadWinsWhenThereIsNeitherPowerNorHeartRateTSS() throws {
        let result = try XCTUnwrap(picked(metadata(
            mets: 6, luciaTRIMP: 900, extrapolatedTRIMP: 900
        )))
        XCTAssertEqual(result.source, .mets)
    }

    func testBanisterWinsOverRouteHistory() throws {
        let result = try XCTUnwrap(picked(metadata(luciaTRIMP: 30, extrapolatedTRIMP: 900)))
        XCTAssertEqual(result.source, .banister)
    }

    /// Route history is the last resort: it is an estimate from prior runs of
    /// the same route, used when the strap dropped entirely.
    func testRouteHistoryIsTheLastResort() throws {
        let result = try XCTUnwrap(picked(metadata(extrapolatedTRIMP: 25)))
        XCTAssertEqual(result.source, .routeHistory)
        XCTAssertEqual(result.value, 25)
    }

    /// Stated as one property rather than five pairs, so the order cannot be
    /// permuted without a failure naming the pair that moved.
    func testTheFullOrderHoldsForEveryPair() throws {
        let tiers: [(WorkoutMetadata.TrainingLoadSource, (Double) -> WorkoutMetadata)] = [
            (.power, { self.metadata(powerTSS: $0) }),
            (.hr, { self.metadata(hrTSS: $0) }),
            (.mets, { _ in self.metadata(mets: 6) }),
            (.banister, { self.metadata(luciaTRIMP: $0) }),
            (.routeHistory, { self.metadata(extrapolatedTRIMP: $0) })
        ]
        for (betterIndex, better) in tiers.enumerated() {
            for worse in tiers[(betterIndex + 1)...] {
                var meta = better.1(10)
                let worseMeta = worse.1(900)
                meta.powerTSS = meta.powerTSS ?? worseMeta.powerTSS
                meta.hrTSS = meta.hrTSS ?? worseMeta.hrTSS
                meta.samples = meta.samples ?? worseMeta.samples
                meta.luciaTRIMP = meta.luciaTRIMP ?? worseMeta.luciaTRIMP
                meta.extrapolatedTRIMP = meta.extrapolatedTRIMP ?? worseMeta.extrapolatedTRIMP
                let result = try XCTUnwrap(picked(meta))
                XCTAssertEqual(
                    result.source, better.0,
                    "\(better.0.rawValue) must outrank \(worse.0.rawValue)"
                )
            }
        }
    }

    // MARK: - A strap dropout on a known route

    private func dropout(luciaTRIMP: Double, hrTSS: Double?, confidence: Double) -> WorkoutMetadata {
        var meta = metadata(hrTSS: hrTSS, luciaTRIMP: luciaTRIMP, extrapolatedTRIMP: 80)
        meta.extrapolationConfidence = confidence
        return meta
    }

    /// The case the route estimate was built for: recorded TRIMP 2, estimate
    /// 80 from prior runs. CTL/ATL used the 2 because every HR-derived tier
    /// outranked the estimate.
    func testARouteEstimateReplacesAStrapDropoutsHeartRateLoad() throws {
        let result = try XCTUnwrap(picked(dropout(luciaTRIMP: 2, hrTSS: 3, confidence: 0.7)))
        XCTAssertEqual(result.source, .routeHistory)
        XCTAssertEqual(result.value, 80)
    }

    /// An easy day on a familiar route is not a dropout: a recorded load at
    /// over half the estimate keeps its own value.
    func testAnEasyDayKeepsItsRecordedLoad() throws {
        let result = try XCTUnwrap(picked(dropout(luciaTRIMP: 50, hrTSS: 45, confidence: 0.7)))
        XCTAssertEqual(result.source, .hr)
    }

    /// With no prior run of the route the estimate is today's own ratio
    /// scaled up — no evidence of a dropout, so it never replaces HR.
    func testAnEstimateWithoutPriorRunsNeverReplacesHeartRate() throws {
        let result = try XCTUnwrap(picked(dropout(luciaTRIMP: 2, hrTSS: 3, confidence: 0.4)))
        XCTAssertEqual(result.source, .hr)
    }

    func testPowerStillOutranksARouteEstimate() throws {
        var meta = dropout(luciaTRIMP: 2, hrTSS: 3, confidence: 0.7)
        meta.powerTSS = 70
        XCTAssertEqual(try XCTUnwrap(picked(meta)).source, .power)
    }

    // MARK: - Power TSS over moving time

    /// A 60-minute ride with a 30-minute café stop at IF 0.8 was stored as
    /// 96 TSS (90 wall-clock minutes); TSS counts the 60 moving minutes: 64.
    func testPowerTSSCountsMovingTimeNotPausedTime() throws {
        var meta = metadata(powerTSS: 96)
        meta.intensityFactor = 0.8
        meta.samples = (0 ... 3_600).map { WorkoutSample(offsetSec: $0, powerWatts: 200) }
        let result = try XCTUnwrap(picked(meta))
        XCTAssertEqual(result.source, .power)
        XCTAssertEqual(result.value, 64, accuracy: 1e-9)
    }

    /// Without the per-second samples there is no moving time to re-derive
    /// from, so the stored figure stands.
    func testStoredPowerTSSStandsWithoutSamples() throws {
        var meta = metadata(powerTSS: 96)
        meta.intensityFactor = 0.8
        XCTAssertEqual(try XCTUnwrap(picked(meta)).value, 96)
    }

    // MARK: - What does not count as a load

    /// Zero is not a load, it is an absent one. Treating it as present would
    /// stop a real lower-tier value being used and credit the workout nothing.
    func testAZeroValueFallsThroughToTheNextTier() throws {
        let result = try XCTUnwrap(picked(metadata(powerTSS: 0, hrTSS: 70)))
        XCTAssertEqual(result.source, .hr)
    }

    /// Same for a negative, which can only be corrupt data.
    func testANegativeValueFallsThroughToTheNextTier() throws {
        let result = try XCTUnwrap(picked(metadata(powerTSS: -5, hrTSS: 70)))
        XCTAssertEqual(result.source, .hr)
    }

    /// A workout with nothing to go on contributes no load, rather than a
    /// fabricated zero that would look like a real easy session.
    func testAWorkoutWithNoLoadAtAllYieldsNothing() {
        XCTAssertNil(picked(metadata()))
        XCTAssertNil(picked(metadata(powerTSS: 0, hrTSS: 0, luciaTRIMP: 0, extrapolatedTRIMP: 0)))
    }
}
