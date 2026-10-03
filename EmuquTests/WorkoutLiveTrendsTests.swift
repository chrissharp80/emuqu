@testable import Emuqu
import Foundation
import XCTest

/// Tests for the mid-workout trend helpers in `WorkoutLiveTrends.swift` —
/// reverse split, HR drift, aerobic decoupling, cadence drift, grade-adjusted
/// pace, zone breakdown, Riegel race prediction, Daniels pace zones, and the
/// Banister load projection.
///
/// The house rule this file exists to protect: **every one of these returns
/// nil rather than a confident wrong number when the buffer is too small.**
/// The voice coach reads these out loud mid-run, so a metric computed from
/// four samples is worse than silence. Each function's minimum-data guard
/// therefore gets its own test alongside the happy path.
/// Shared workout fixtures. At file scope so the suites below can share
/// them while each type body stays under SwiftLint's 500-line limit.
private enum WorkoutFixture {
    /// One sample per second, offsets `0 ..< count`. Each field is supplied
    /// by a closure over the offset so a test can express "first quartile
    /// 140 bpm, last quartile 154 bpm" directly.
    static func samples(
        count: Int,
        hr: ((Int) -> Int?)? = nil,
        pace: ((Int) -> Double?)? = nil,
        cadence: ((Int) -> Double?)? = nil,
        distance: ((Int) -> Double?)? = nil,
        altitude: ((Int) -> Double?)? = nil
    ) -> [WorkoutSample] {
        (0 ..< count).map { offset in
            WorkoutSample(
                offsetSec: offset,
                heartRate: hr?(offset),
                distanceMeters: distance?(offset),
                paceSecPerKm: pace?(offset),
                cadenceStepsPerMin: cadence?(offset),
                altitudeMeters: altitude?(offset)
            )
        }
    }

    /// Distance curve from a list of `(seconds, metersPerSecond)` legs.
    static func distanceCurve(_ legs: [(sec: Int, mps: Double)]) -> (count: Int, fn: (Int) -> Double?) {
        var cumulative: [Double] = []
        var total: Double = 0
        for leg in legs {
            for _ in 0 ..< leg.sec {
                cumulative.append(total)
                total += leg.mps
            }
        }
        cumulative.append(total)
        return (cumulative.count, { offset in
            offset < cumulative.count ? cumulative[offset] : nil
        })
    }

    static func runSession(
        distanceMeters: Double,
        durationSec: TimeInterval,
        sport: Sport = .run,
        samples: [WorkoutSample] = [],
        startedDaysIn: Int = 0
    ) -> HRVSession {
        let start = Double(startedDaysIn) * 86_400
        var session = HRVSession(
            id: UUID(),
            startDate: Date(timeIntervalSince1970: start),
            endDate: Date(timeIntervalSince1970: start + durationSec),
            state: .complete,
            sessionType: .workout,
            rrSeries: nil,
            analysisResult: nil,
            artifactFlags: nil
        )
        session.workoutMetadata = WorkoutMetadata(
            sport: sport,
            distanceMeters: distanceMeters,
            samples: samples.isEmpty ? nil : samples
        )
        return session
    }
}

/// Half-vs-half and quartile-vs-quartile metrics read off the live sample
/// buffer: reverse split, HR drift, aerobic decoupling, recent HR slope,
/// cadence drift.
final class WorkoutLiveTrendsSampleMetricsTests: XCTestCase {
    // MARK: - reverseSplitDeltaSecPerKm

    func testReverseSplitIsPositiveWhenSlowingDown() {
        // 1201 samples → last offset 1200, midpoint 600.
        let result = WorkoutLiveTrends.reverseSplitDeltaSecPerKm(
            samples: WorkoutFixture.samples(count: 1201, pace: { $0 < 600 ? 300 : 320 })
        )
        XCTAssertEqual(result ?? 0, 20, accuracy: 0.001)
    }

    func testReverseSplitIsNegativeForATrueNegativeSplit() {
        let result = WorkoutLiveTrends.reverseSplitDeltaSecPerKm(
            samples: WorkoutFixture.samples(count: 1201, pace: { $0 < 600 ? 320 : 300 })
        )
        XCTAssertEqual(result ?? 0, -20, accuracy: 0.001)
    }

    func testReverseSplitIsSilentBeforeTenMinutes() {
        // Last offset 599 — one second short of the 600 s floor.
        XCTAssertNil(WorkoutLiveTrends.reverseSplitDeltaSecPerKm(
            samples: WorkoutFixture.samples(count: 600, pace: { _ in 300 })
        ))
    }

    func testReverseSplitIsSilentWithoutThirtyPacesPerHalf() {
        // Long enough in time, but the watch only reported pace 20 times.
        XCTAssertNil(WorkoutLiveTrends.reverseSplitDeltaSecPerKm(
            samples: WorkoutFixture.samples(count: 1201, pace: { $0.isMultiple(of: 60) ? 300 : nil })
        ))
    }

    func testReverseSplitIsSilentOnAnEmptyBuffer() {
        XCTAssertNil(WorkoutLiveTrends.reverseSplitDeltaSecPerKm(samples: []))
    }

    // MARK: - hrDriftPercent

    func testHRDriftIsPositiveWhenHeartRateClimbs() {
        // 1201 samples → last offset 1200, quartile 300.
        let result = WorkoutLiveTrends.hrDriftPercent(samples: WorkoutFixture.samples(count: 1201, hr: {
            if $0 < 300 { return 140 }
            if $0 >= 900 { return 154 }
            return 147
        }))
        XCTAssertEqual(result ?? 0, 10, accuracy: 0.001)
    }

    func testHRDriftIsNegativeWhenHeartRateRecovers() {
        let result = WorkoutLiveTrends.hrDriftPercent(samples: WorkoutFixture.samples(count: 1201, hr: {
            if $0 < 300 { return 150 }
            if $0 >= 900 { return 135 }
            return 142
        }))
        XCTAssertEqual(result ?? 0, -10, accuracy: 0.001)
    }

    func testHRDriftIsSilentBeforeSevenMinutes() {
        XCTAssertNil(WorkoutLiveTrends.hrDriftPercent(
            samples: WorkoutFixture.samples(count: 420, hr: { _ in 140 })
        ))
    }

    func testHRDriftIsSilentWhenTheStrapWasMostlyQuiet() {
        XCTAssertNil(WorkoutLiveTrends.hrDriftPercent(
            samples: WorkoutFixture.samples(count: 1201, hr: { $0.isMultiple(of: 60) ? 140 : nil })
        ))
    }

    // MARK: - aerobicDecouplingPercent

    func testDecouplingIsPositiveWhenEfficiencyDrops() {
        // Same pace, higher second-half HR → efficiency falls by 1 - 140/154.
        let result = WorkoutLiveTrends.aerobicDecouplingPercent(
            samples: WorkoutFixture.samples(
                count: 1201,
                hr: { $0 < 600 ? 140 : 154 },
                pace: { _ in 300 }
            )
        )
        XCTAssertEqual(result ?? 0, (1 - 140.0 / 154.0) * 100, accuracy: 0.001)
    }

    func testDecouplingIsNegativeWhenEfficiencyImproves() {
        let result = WorkoutLiveTrends.aerobicDecouplingPercent(
            samples: WorkoutFixture.samples(
                count: 1201,
                hr: { $0 < 600 ? 140 : 130 },
                pace: { _ in 300 }
            )
        )
        XCTAssertEqual(result ?? 0, (1 - 140.0 / 130.0) * 100, accuracy: 0.001)
    }

    func testDecouplingIsZeroWhenNothingChanges() {
        let result = WorkoutLiveTrends.aerobicDecouplingPercent(
            samples: WorkoutFixture.samples(count: 1201, hr: { _ in 145 }, pace: { _ in 300 })
        )
        XCTAssertEqual(result ?? 99, 0, accuracy: 0.001)
    }

    func testDecouplingIsSilentWithoutBothPaceAndHeartRate() {
        // Pace but no HR — the ratio is undefined, so say nothing.
        XCTAssertNil(WorkoutLiveTrends.aerobicDecouplingPercent(
            samples: WorkoutFixture.samples(count: 1201, pace: { _ in 300 })
        ))
        XCTAssertNil(WorkoutLiveTrends.aerobicDecouplingPercent(
            samples: WorkoutFixture.samples(count: 1201, hr: { _ in 145 })
        ))
    }

    func testDecouplingIsSilentBeforeTenMinutes() {
        XCTAssertNil(WorkoutLiveTrends.aerobicDecouplingPercent(
            samples: WorkoutFixture.samples(count: 600, hr: { _ in 145 }, pace: { _ in 300 })
        ))
    }

    // MARK: - recentHRSlopeBpm

    func testRecentSlopeIsPositiveWhileHeartRateRises() {
        // Last offset 120: "recent" is 91–120, "prior" is 31–60.
        let result = WorkoutLiveTrends.recentHRSlopeBpm(
            samples: WorkoutFixture.samples(count: 121, hr: { $0 > 90 ? 150 : 140 })
        )
        XCTAssertEqual(result ?? 0, 10, accuracy: 0.001)
    }

    func testRecentSlopeIsNegativeWhileHeartRateFalls() {
        let result = WorkoutLiveTrends.recentHRSlopeBpm(
            samples: WorkoutFixture.samples(count: 121, hr: { $0 > 90 ? 130 : 140 })
        )
        XCTAssertEqual(result ?? 0, -10, accuracy: 0.001)
    }

    func testRecentSlopeIsSilentBeforeNinetySeconds() {
        XCTAssertNil(WorkoutLiveTrends.recentHRSlopeBpm(
            samples: WorkoutFixture.samples(count: 90, hr: { _ in 140 })
        ))
    }

    func testRecentSlopeIsSilentWithoutTenReadingsInEachWindow() {
        XCTAssertNil(WorkoutLiveTrends.recentHRSlopeBpm(
            samples: WorkoutFixture.samples(count: 121, hr: { $0.isMultiple(of: 20) ? 140 : nil })
        ))
    }

    // MARK: - cadenceDriftSpm

    func testCadenceDriftIsNegativeWhenStrideBreaksDown() {
        let result = WorkoutLiveTrends.cadenceDriftSpm(samples: WorkoutFixture.samples(count: 1201, cadence: {
            if $0 < 300 { return 180 }
            if $0 >= 900 { return 172 }
            return 176
        }))
        XCTAssertEqual(result ?? 0, -8, accuracy: 0.001)
    }

    func testCadenceDriftIsSilentBeforeSevenMinutes() {
        XCTAssertNil(WorkoutLiveTrends.cadenceDriftSpm(
            samples: WorkoutFixture.samples(count: 420, cadence: { _ in 180 })
        ))
    }

    func testCadenceDriftIsSilentForABikeWithNoCadencePod() {
        XCTAssertNil(WorkoutLiveTrends.cadenceDriftSpm(samples: WorkoutFixture.samples(count: 1201)))
    }
}

/// Grade-adjusted pace, the per-split flat-equivalent companion, and the
/// time-to-fade projection.
final class WorkoutGradeAdjustedPaceTests: XCTestCase {
    // MARK: - gradeAdjustedPaceSecPerKm

    func testGradeAdjustedPaceNeedsARealPace() {
        XCTAssertNil(WorkoutLiveTrends.gradeAdjustedPaceSecPerKm(pace: nil, gradePercent: 5))
        XCTAssertNil(WorkoutLiveTrends.gradeAdjustedPaceSecPerKm(pace: 0, gradePercent: 5))
        XCTAssertNil(WorkoutLiveTrends.gradeAdjustedPaceSecPerKm(pace: -10, gradePercent: 5))
    }

    func testGradeAdjustedPaceIsAPassThroughWithoutAGrade() {
        XCTAssertEqual(
            WorkoutLiveTrends.gradeAdjustedPaceSecPerKm(pace: 300, gradePercent: nil),
            300
        )
    }

    func testFlatGroundLeavesThePaceAlone() {
        XCTAssertEqual(
            WorkoutLiveTrends.gradeAdjustedPaceSecPerKm(pace: 300, gradePercent: 0) ?? 0,
            300,
            accuracy: 0.001
        )
    }

    func testUphillPaceIsWorthAFasterFlatEquivalent() {
        // Minetti: a 5 % climb costs ~1.30× the flat, so 300 s/km up it is
        // the same effort as ~231 s/km on the flat.
        let gap = WorkoutLiveTrends.gradeAdjustedPaceSecPerKm(pace: 300, gradePercent: 5) ?? 0
        XCTAssertLessThan(gap, 300)
        XCTAssertEqual(gap, 230.5, accuracy: 1.0)
    }

    func testDownhillPaceIsWorthASlowerFlatEquivalent() {
        // The free speed of a descent is discounted, not credited.
        let gap = WorkoutLiveTrends.gradeAdjustedPaceSecPerKm(pace: 300, gradePercent: -5) ?? 0
        XCTAssertGreaterThan(gap, 300)
        XCTAssertEqual(gap, 393.3, accuracy: 1.0)
    }

    func testDescentsToThirtyFivePercentCountAsEasierThanTheFlat() {
        // Minetti's saving peaks near −20 % (about half the flat cost) and
        // shrinks on steeper descents; it stays a saving down to −35 %.
        for grade in stride(from: -35.0, through: -1.0, by: 1.0) {
            let gap = WorkoutLiveTrends.gradeAdjustedPaceSecPerKm(pace: 900, gradePercent: grade) ?? 0
            XCTAssertGreaterThan(gap, 900, "grade \(grade)")
        }
        let twenty = WorkoutLiveTrends.gradeAdjustedPaceSecPerKm(pace: 300, gradePercent: -20) ?? 0
        XCTAssertEqual(twenty, 600, accuracy: 1.0)
    }

    func testGradeIsClampedAtFortyFivePercent() {
        // Minetti fitted the polynomial on −45 % to +45 %, so the input is
        // clipped there rather than extrapolated.
        XCTAssertEqual(
            WorkoutLiveTrends.gradeAdjustedPaceSecPerKm(pace: 300, gradePercent: 80) ?? 0,
            WorkoutLiveTrends.gradeAdjustedPaceSecPerKm(pace: 300, gradePercent: 45) ?? -1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            WorkoutLiveTrends.gradeAdjustedPaceSecPerKm(pace: 300, gradePercent: -80) ?? 0,
            WorkoutLiveTrends.gradeAdjustedPaceSecPerKm(pace: 300, gradePercent: -45) ?? -1,
            accuracy: 0.0001
        )
    }

    func testDescentsSteeperThanFortyPercentCostMoreThanTheFlat() {
        // Minetti: at −45 % braking makes the descent ~12 % costlier than the
        // flat, so the flat-equivalent pace is faster than the actual pace.
        let gap = WorkoutLiveTrends.gradeAdjustedPaceSecPerKm(pace: 300, gradePercent: -45) ?? 0
        XCTAssertEqual(gap, 268.0, accuracy: 1.0)
    }

    func testSteeperUphillsAdjustMore() {
        let two = WorkoutLiveTrends.gradeAdjustedPaceSecPerKm(pace: 300, gradePercent: 2) ?? 0
        let five = WorkoutLiveTrends.gradeAdjustedPaceSecPerKm(pace: 300, gradePercent: 5) ?? 0
        let ten = WorkoutLiveTrends.gradeAdjustedPaceSecPerKm(pace: 300, gradePercent: 10) ?? 0
        XCTAssertGreaterThan(two, five)
        XCTAssertGreaterThan(five, ten)
    }

    // MARK: - recentSplitGradeAdjustedPaces

    func testNoSplitsBeforeTheFirstKilometre() {
        let curve = WorkoutFixture.distanceCurve([(sec: 100, mps: 4)]) // 400 m
        XCTAssertTrue(WorkoutLiveTrends.recentSplitGradeAdjustedPaces(
            samples: WorkoutFixture.samples(count: curve.count, distance: curve.fn)
        ).isEmpty)
    }

    func testNoSplitsFromAnEmptyBuffer() {
        XCTAssertTrue(WorkoutLiveTrends.recentSplitGradeAdjustedPaces(samples: []).isEmpty)
    }

    func testNoSplitsWithoutDistanceReadings() {
        XCTAssertTrue(
            WorkoutLiveTrends.recentSplitGradeAdjustedPaces(samples: WorkoutFixture.samples(count: 2000)).isEmpty
        )
    }

    func testSplitsComeBackMostRecentFirst() {
        // 5 m/s, then 4 m/s, then 2.5 m/s → 200, 250 and 400 sec/km.
        let curve = WorkoutFixture.distanceCurve([
            (sec: 200, mps: 5),
            (sec: 250, mps: 4),
            (sec: 400, mps: 2.5)
        ])
        let paces = WorkoutLiveTrends.recentSplitGradeAdjustedPaces(
            samples: WorkoutFixture.samples(count: curve.count, distance: curve.fn)
        )
        XCTAssertEqual(paces.count, 3)
        XCTAssertEqual(paces[0], 400, accuracy: 2)
        XCTAssertEqual(paces[1], 250, accuracy: 2)
        XCTAssertEqual(paces[2], 200, accuracy: 2)
    }

    func testOnlyTheLastThreeSplitsAreReturned() {
        let curve = WorkoutFixture.distanceCurve([(sec: 1000, mps: 5)]) // 5 km at 200 sec/km
        let paces = WorkoutLiveTrends.recentSplitGradeAdjustedPaces(
            samples: WorkoutFixture.samples(count: curve.count, distance: curve.fn)
        )
        XCTAssertEqual(paces.count, 3)
    }

    func testAClimbingSplitReportsAFasterFlatEquivalent() {
        // 1 km at 4 m/s (250 sec/km) with 50 m of climb → a 5 % grade.
        let curve = WorkoutFixture.distanceCurve([(sec: 260, mps: 4)])
        let climbed = WorkoutLiveTrends.recentSplitGradeAdjustedPaces(
            samples: WorkoutFixture.samples(
                count: curve.count,
                distance: curve.fn,
                altitude: { Double($0) * 50.0 / 250.0 }
            )
        )
        let flat = WorkoutLiveTrends.recentSplitGradeAdjustedPaces(
            samples: WorkoutFixture.samples(count: curve.count, distance: curve.fn, altitude: { _ in 0 })
        )
        XCTAssertEqual(flat.first ?? 0, 250, accuracy: 2)
        XCTAssertLessThan(climbed.first ?? .infinity, flat.first ?? 0)
    }

    func testAMissingAltitudeAtTheSplitEndCarriesTheLastKnownAltitude() {
        // Starting at 300 m with the barometer dropping out mid-split must not
        // read as a 30 % descent: the last known altitude stands in.
        let curve = WorkoutFixture.distanceCurve([(sec: 260, mps: 4)])
        let paces = WorkoutLiveTrends.recentSplitGradeAdjustedPaces(
            samples: WorkoutFixture.samples(
                count: curve.count,
                distance: curve.fn,
                altitude: { $0 < 100 ? 300 : nil }
            )
        )
        XCTAssertEqual(paces.first ?? 0, 250, accuracy: 2)
    }

    func testASplitWithNoAltitudeAtAllKeepsItsRawPace() {
        let curve = WorkoutFixture.distanceCurve([(sec: 260, mps: 4)])
        let paces = WorkoutLiveTrends.recentSplitGradeAdjustedPaces(
            samples: WorkoutFixture.samples(count: curve.count, distance: curve.fn)
        )
        XCTAssertEqual(paces.first ?? 0, 250, accuracy: 2)
    }

    // MARK: - projectedMinutesUntilFade

    func testNoFadeProjectionWithoutMeaningfulDrift() {
        let buffer = WorkoutFixture.samples(count: 1201)
        XCTAssertNil(WorkoutLiveTrends.projectedMinutesUntilFade(
            samples: buffer, currentDriftPercent: nil
        ))
        XCTAssertNil(WorkoutLiveTrends.projectedMinutesUntilFade(
            samples: buffer, currentDriftPercent: 0
        ))
        XCTAssertNil(WorkoutLiveTrends.projectedMinutesUntilFade(
            samples: buffer, currentDriftPercent: -3
        ))
        XCTAssertNil(
            WorkoutLiveTrends.projectedMinutesUntilFade(samples: buffer, currentDriftPercent: 1.0),
            "exactly 1 % is not yet a trend"
        )
    }

    func testNoFadeProjectionBeforeFourteenMinutes() {
        XCTAssertNil(WorkoutLiveTrends.projectedMinutesUntilFade(
            samples: WorkoutFixture.samples(count: 840), currentDriftPercent: 5
        ))
    }

    func testFadeProjectionExtrapolatesTheDriftRate() {
        // 20 min elapsed → drift accumulated over 15 min. 5 % in 15 min is
        // 0.333 %/min, so the remaining 5 % to the 10 % threshold is 15 min.
        let result = WorkoutLiveTrends.projectedMinutesUntilFade(
            samples: WorkoutFixture.samples(count: 1201), currentDriftPercent: 5
        )
        XCTAssertEqual(result ?? 0, 15, accuracy: 0.01)
    }

    func testFadeProjectionIsZeroOnceDriftPassesTenPercent() {
        XCTAssertEqual(
            WorkoutLiveTrends.projectedMinutesUntilFade(
                samples: WorkoutFixture.samples(count: 1201), currentDriftPercent: 12
            ),
            0
        )
    }

    func testNoFadeProjectionWhenTheDriftRateIsBelowTheNoiseFloor() {
        // 60 min elapsed, only 2 % of drift → 0.044 %/min, under the 0.05
        // floor. That's flat within measurement noise, not a trend.
        XCTAssertNil(WorkoutLiveTrends.projectedMinutesUntilFade(
            samples: WorkoutFixture.samples(count: 3601), currentDriftPercent: 2
        ))
    }

    func testFadeProjectionNeverReportsLessThanAMinute() {
        // 14 min elapsed with 9.5 % drift extrapolates to ~33 s; reporting
        // "fading in 0 minutes" while the user is still running is useless.
        XCTAssertEqual(
            WorkoutLiveTrends.projectedMinutesUntilFade(
                samples: WorkoutFixture.samples(count: 841), currentDriftPercent: 9.5
            ),
            1
        )
    }
}

/// Live percent-of-max-HR time-in-zone binning.
final class WorkoutZoneBreakdownTests: XCTestCase {
    // MARK: - WorkoutZoneBreakdown

    func testZoneBreakdownIsEmptyWithoutSamples() {
        XCTAssertEqual(WorkoutZoneBreakdown.compute(samples: [], userMaxHR: 190), .empty)
    }

    func testZoneBreakdownIsEmptyWithoutAMaxHeartRate() {
        let buffer = WorkoutFixture.samples(count: 100, hr: { _ in 140 })
        XCTAssertEqual(WorkoutZoneBreakdown.compute(samples: buffer, userMaxHR: 0), .empty)
    }

    func testEachZoneCatchesItsOwnHeartRate() {
        // Max 200 → breakpoints at 100 / 120 / 140 / 160 / 180 bpm.
        let cases: [(Int, Int)] = [(110, 1), (130, 2), (150, 3), (170, 4), (190, 5)]
        for (hr, expectedZone) in cases {
            let breakdown = WorkoutZoneBreakdown.compute(
                samples: WorkoutFixture.samples(count: 101, hr: { _ in hr }),
                userMaxHR: 200
            )
            XCTAssertEqual(breakdown.dominantZone, expectedZone, "hr \(hr)")
            XCTAssertEqual(breakdown.totalSec, 100, "hr \(hr)")
        }
    }

    func testLiveZonesMatchTheSummaryBands() {
        // Max 190, HR 165 is 87 % of max: zone 4, as the post-workout summary
        // and the assistant's reference say — not zone 5.
        let breakdown = WorkoutZoneBreakdown.compute(
            samples: WorkoutFixture.samples(count: 101, hr: { _ in 165 }),
            userMaxHR: 190
        )
        XCTAssertEqual(breakdown.dominantZone, 4)
    }

    func testTheZoneBoundaryBelongsToTheHigherZone() {
        // 120 bpm is exactly 60 % of max — zone 2, not zone 1.
        let breakdown = WorkoutZoneBreakdown.compute(
            samples: WorkoutFixture.samples(count: 101, hr: { _ in 120 }),
            userMaxHR: 200
        )
        XCTAssertEqual(breakdown.dominantZone, 2)
        XCTAssertEqual(breakdown.z1Sec, 0)
    }

    func testZoneSecondsSplitAcrossZonesAndSumToTheTotal() {
        let breakdown = WorkoutZoneBreakdown.compute(
            samples: WorkoutFixture.samples(count: 201, hr: { $0 <= 100 ? 110 : 170 }),
            userMaxHR: 200
        )
        XCTAssertEqual(breakdown.z1Sec, 100)
        XCTAssertEqual(breakdown.z4Sec, 100)
        XCTAssertEqual(breakdown.totalSec, 200)
        XCTAssertEqual(
            breakdown.z1Sec + breakdown.z2Sec + breakdown.z3Sec
                + breakdown.z4Sec + breakdown.z5Sec,
            breakdown.totalSec
        )
    }

    func testTimeBelowHalfOfMaxIsNotBinned() {
        // Standing still at the trailhead shouldn't count as zone 1.
        let breakdown = WorkoutZoneBreakdown.compute(
            samples: WorkoutFixture.samples(count: 101, hr: { _ in 90 }),
            userMaxHR: 200
        )
        XCTAssertEqual(breakdown.totalSec, 0)
        XCTAssertNil(breakdown.dominantZone)
    }

    func testGapsInHeartRateAreNotBinned() {
        let breakdown = WorkoutZoneBreakdown.compute(
            samples: WorkoutFixture.samples(count: 101, hr: { _ in nil }),
            userMaxHR: 200
        )
        XCTAssertEqual(breakdown.totalSec, 0)
        XCTAssertNil(breakdown.dominantZone)
    }
}

/// Daniels-style pace zones and the Banister EWMA load projection that
/// answers "when am I fresh again?".
final class TrainingLoadProjectionTests: XCTestCase {
    // MARK: - TrainingPaceZones

    func testPaceZonesNeedAPositiveBasis() {
        XCTAssertNil(TrainingPaceZones.from5KPace(secPerKm: 0))
        XCTAssertNil(TrainingPaceZones.from5KPace(secPerKm: -10))
    }

    func testPaceZonesScaleFromTheFiveKBasis() {
        guard let zones = TrainingPaceZones.from5KPace(secPerKm: 240) else {
            return XCTFail("expected zones")
        }
        XCTAssertEqual(zones.easySecPerKm, 312, accuracy: 0.001)
        XCTAssertEqual(zones.marathonSecPerKm, 276, accuracy: 0.001)
        XCTAssertEqual(zones.thresholdSecPerKm, 264, accuracy: 0.001)
        XCTAssertEqual(zones.intervalSecPerKm, 240, accuracy: 0.001)
        XCTAssertEqual(zones.repetitionSecPerKm, 223.2, accuracy: 0.001)
    }

    func testPaceZonesAreOrderedEasiestToHardest() {
        guard let zones = TrainingPaceZones.from5KPace(secPerKm: 240) else {
            return XCTFail("expected zones")
        }
        XCTAssertGreaterThan(zones.easySecPerKm, zones.marathonSecPerKm)
        XCTAssertGreaterThan(zones.marathonSecPerKm, zones.thresholdSecPerKm)
        XCTAssertGreaterThan(zones.thresholdSecPerKm, zones.intervalSecPerKm)
        XCTAssertGreaterThan(zones.intervalSecPerKm, zones.repetitionSecPerKm)
    }

    func testPaceZonesFromRacePredictionsUseTheFiveKEntry() {
        // A 20-minute 5K → 240 sec/km.
        let zones = TrainingPaceZones.from(racePredictions: [5_000: 1_200, 10_000: 2_500])
        XCTAssertEqual(zones, TrainingPaceZones.from5KPace(secPerKm: 240))
    }

    func testPaceZonesAreNilWithoutAFiveKPrediction() {
        XCTAssertNil(TrainingPaceZones.from(racePredictions: [10_000: 2_500]))
        XCTAssertNil(TrainingPaceZones.from(racePredictions: [:]))
    }

    // MARK: - TrainingLoadProjection

    func testProjectionReturnsOneEntryPerHorizonDay() {
        let days = TrainingLoadProjection.project(
            startingATL: 50, startingCTL: 50, dailyTrimp: 50, horizonDays: 7
        )
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.map(\.daysFromNow), Array(1 ... 7))
    }

    func testProjectionAlwaysReturnsAtLeastOneDay() {
        XCTAssertEqual(
            TrainingLoadProjection.project(
                startingATL: 50, startingCTL: 50, dailyTrimp: 0, horizonDays: 0
            ).count,
            1
        )
    }

    func testRestingDecaysBothLoadsTowardZero() {
        let days = TrainingLoadProjection.project(
            startingATL: 80, startingCTL: 60, dailyTrimp: 0, horizonDays: 7
        )
        // Exact EWMA step, not a linear approximation: τ=7 for ATL,
        // τ=42 for CTL, so ATL sheds ~13 %/day and CTL only ~2.4 %.
        XCTAssertEqual(days[0].atl, 80 * exp(-1.0 / 7.0), accuracy: 0.0001)
        XCTAssertEqual(days[0].ctl, 60 * exp(-1.0 / 42.0), accuracy: 0.0001)
        XCTAssertLessThan(days[6].atl, days[0].atl)
        XCTAssertLessThan(days[6].ctl, days[0].ctl)
    }

    func testAcuteLoadShedsFasterThanChronicLoad() {
        // The whole reason TSB recovers during a rest week.
        let days = TrainingLoadProjection.project(
            startingATL: 80, startingCTL: 80, dailyTrimp: 0, horizonDays: 7
        )
        for day in days {
            XCTAssertLessThan(day.atl, day.ctl, "day \(day.daysFromNow)")
            XCTAssertGreaterThan(day.tsb, 0, "day \(day.daysFromNow)")
        }
    }

    func testTsbIsChronicMinusAcute() {
        let day = TrainingLoadProjection.project(
            startingATL: 90, startingCTL: 60, dailyTrimp: 0, horizonDays: 1
        )[0]
        XCTAssertEqual(day.tsb, day.ctl - day.atl, accuracy: 1e-12)
    }

    func testASteadyDailyLoadConvergesOnThatLoad() {
        let days = TrainingLoadProjection.project(
            startingATL: 10, startingCTL: 10, dailyTrimp: 60, horizonDays: 365
        )
        guard let last = days.last else { return XCTFail("expected a projection") }
        XCTAssertEqual(last.atl, 60, accuracy: 0.5)
        XCTAssertEqual(last.ctl, 60, accuracy: 1.0)
    }

    // MARK: - daysUntilFresh

    func testAlreadyFreshIsZeroDays() {
        XCTAssertEqual(TrainingLoadProjection.daysUntilFresh(currentATL: 50, currentCTL: 60), 0)
        XCTAssertEqual(TrainingLoadProjection.daysUntilFresh(currentATL: 60, currentCTL: 60), 0)
    }

    func testDaysUntilFreshCountsForwardToTheTsbCrossing() {
        let days = TrainingLoadProjection.daysUntilFresh(currentATL: 80, currentCTL: 60)
        XCTAssertEqual(days, 3)
    }

    func testDeeperFatigueTakesLonger() {
        let shallow = TrainingLoadProjection.daysUntilFresh(currentATL: 70, currentCTL: 60) ?? 0
        let deep = TrainingLoadProjection.daysUntilFresh(currentATL: 110, currentCTL: 60) ?? 0
        XCTAssertGreaterThan(deep, shallow)
    }

    func testDaysUntilFreshGivesUpPastAMonth() {
        // Not "take 40 days off" — nil is the signal to say "take a real
        // off-week and re-check", which is the only honest answer here.
        XCTAssertNil(TrainingLoadProjection.daysUntilFresh(currentATL: 400, currentCTL: 10))
    }

    // MARK: - daysUntilATLConverges

    func testAlreadyInsideTheGapIsZeroDays() {
        XCTAssertEqual(
            TrainingLoadProjection.daysUntilATLConverges(
                currentATL: 61, currentCTL: 60, dailyTrimp: 60, gapTrimp: 2
            ),
            0
        )
    }

    func testConvergenceIsFoundForASustainableLoad() {
        // ATL climbs to the 50-unit daily load in a week or so; CTL drifts
        // down to meet it on the 42-day constant, which is what sets the
        // timescale. Inside 5 units of each other by day 31.
        let days = TrainingLoadProjection.daysUntilATLConverges(
            currentATL: 40, currentCTL: 60, dailyTrimp: 50, gapTrimp: 5
        )
        XCTAssertEqual(days, 31)
    }

    func testConvergenceIsNilWhenTheHorizonIsTooShort() {
        XCTAssertNil(TrainingLoadProjection.daysUntilATLConverges(
            currentATL: 10, currentCTL: 90, dailyTrimp: 200, gapTrimp: 1, horizonDays: 5
        ))
    }

    func testAWiderGapConvergesSooner() {
        let tight = TrainingLoadProjection.daysUntilATLConverges(
            currentATL: 40, currentCTL: 60, dailyTrimp: 50, gapTrimp: 3
        )
        let loose = TrainingLoadProjection.daysUntilATLConverges(
            currentATL: 40, currentCTL: 60, dailyTrimp: 50, gapTrimp: 10
        )
        XCTAssertEqual(tight, 51)
        XCTAssertEqual(loose, 11)
    }

    func testConvergenceIsNilWhenTheGapIsTighterThanTheHorizonAllows() {
        // 2 units apart is never reached inside 60 days at this load — CTL
        // is still ~2.4 above ATL on day 60. nil, not a wrong number.
        XCTAssertNil(TrainingLoadProjection.daysUntilATLConverges(
            currentATL: 40, currentCTL: 60, dailyTrimp: 50, gapTrimp: 2
        ))
    }

    // MARK: - RecoveryTimeEstimate

    func testNoRecoveryHoursWhenAlreadyFresh() {
        XCTAssertNil(RecoveryTimeEstimate.hoursFromTrainingLoad(atl: 50, ctl: 60))
        XCTAssertNil(RecoveryTimeEstimate.hoursFromTrainingLoad(atl: 60, ctl: 60))
    }

    func testNoRecoveryHoursWithoutBothInputs() {
        XCTAssertNil(RecoveryTimeEstimate.hoursFromTrainingLoad(atl: nil, ctl: 60))
        XCTAssertNil(RecoveryTimeEstimate.hoursFromTrainingLoad(atl: 80, ctl: nil))
        XCTAssertNil(RecoveryTimeEstimate.hoursFromTrainingLoad(atl: nil, ctl: nil))
    }

    func testRecoveryHoursAreDaysUntilFreshInHours() {
        XCTAssertEqual(RecoveryTimeEstimate.hoursFromTrainingLoad(atl: 80, ctl: 60), 72)
    }

    func testNoRecoveryHoursWhenFreshnessIsMoreThanAMonthAway() {
        XCTAssertNil(RecoveryTimeEstimate.hoursFromTrainingLoad(atl: 400, ctl: 10))
    }
}

/// Riegel race-time prediction and the cross-workout history baselines.
final class RaceAndHistoryBaselineTests: XCTestCase {
    // MARK: - RaceTimePrediction

    func testRacePredictionIsEmptyWithoutAnyComparableEffort() {
        XCTAssertTrue(RaceTimePrediction.predict(from: [], sport: .run).isEmpty)
        XCTAssertTrue(RaceTimePrediction.predict(
            from: [WorkoutFixture.runSession(distanceMeters: 5_000, durationSec: 1_200, sport: .bike)],
            sport: .run
        ).isEmpty)
    }

    func testRacePredictionIgnoresEffortsUnderThreeKilometres() {
        XCTAssertTrue(RaceTimePrediction.predict(
            from: [WorkoutFixture.runSession(distanceMeters: 1_200, durationSec: 264)],
            sport: .run
        ).isEmpty)
    }

    func testRacePredictionPrefersAnEffortNearTheTargetDistance() {
        // A fast 3 km would extrapolate to a quicker marathon than the
        // athlete's real 21 km run supports; the half uses the 21 km run.
        let predictions = RaceTimePrediction.predictWithBasis(
            from: [
                WorkoutFixture.runSession(distanceMeters: 3_000, durationSec: 660),    // 3:40/km
                WorkoutFixture.runSession(distanceMeters: 21_000, durationSec: 7_560)  // 6:00/km
            ],
            sport: .run
        )
        XCTAssertEqual(predictions[21_097.5]?.basis.distanceMeters, 21_000)
        XCTAssertEqual(predictions[5_000]?.basis.distanceMeters, 3_000)
    }

    func testRacePredictionPrefersRecentEfforts() {
        let now = Date(timeIntervalSince1970: 200 * 86_400)
        let predictions = RaceTimePrediction.predictWithBasis(
            from: [
                WorkoutFixture.runSession(distanceMeters: 5_000, durationSec: 1_100, startedDaysIn: 10),
                WorkoutFixture.runSession(distanceMeters: 5_000, durationSec: 1_500, startedDaysIn: 190)
            ],
            sport: .run,
            now: now
        )
        XCTAssertEqual(predictions[5_000]?.totalSec ?? 0, 1_500, accuracy: 0.001)
    }

    func testRacePredictionCoversEveryStandardDistance() {
        let predictions = RaceTimePrediction.predict(
            from: [WorkoutFixture.runSession(distanceMeters: 5_000, durationSec: 1_200)],
            sport: .run
        )
        XCTAssertEqual(
            Set(predictions.keys),
            Set(RaceTimePrediction.standardDistancesMeters)
        )
    }

    func testRacePredictionReproducesTheBasisAtItsOwnDistance() {
        let predictions = RaceTimePrediction.predict(
            from: [WorkoutFixture.runSession(distanceMeters: 5_000, durationSec: 1_200)],
            sport: .run
        )
        XCTAssertEqual(predictions[5_000] ?? 0, 1_200, accuracy: 0.001)
    }

    func testRiegelPenalisesLongerDistances() {
        // T2 = T1 × (D2/D1)^1.06. Doubling the distance costs more than
        // doubling the time — that 1.06 exponent is the fatigue factor.
        let predictions = RaceTimePrediction.predict(
            from: [WorkoutFixture.runSession(distanceMeters: 5_000, durationSec: 1_200)],
            sport: .run
        )
        XCTAssertEqual(predictions[10_000] ?? 0, 1_200 * pow(2, 1.06), accuracy: 0.001)
        XCTAssertGreaterThan(predictions[10_000] ?? 0, 2_400)
        XCTAssertGreaterThan(predictions[42_195] ?? 0, predictions[21_097.5] ?? 0)
    }

    func testRacePredictionPicksTheFastestBasisNotTheLongest() {
        let predictions = RaceTimePrediction.predict(
            from: [
                WorkoutFixture.runSession(distanceMeters: 10_000, durationSec: 3_600), // 6:00/km
                WorkoutFixture.runSession(distanceMeters: 5_000, durationSec: 1_200)   // 4:00/km
            ],
            sport: .run
        )
        // Basis is the 5K, so the 5K prediction is exactly that effort.
        XCTAssertEqual(predictions[5_000] ?? 0, 1_200, accuracy: 0.001)
    }

    // MARK: - WorkoutHistoryBaselines

    func testBaselinesAreEmptyWithoutMatchingSessions() {
        let baselines = WorkoutHistoryBaselines.compute(from: [], sport: .run)
        XCTAssertEqual(baselines.sampleCount, 0)
        XCTAssertNil(baselines.avgPaceSecPerKm)
        XCTAssertNil(baselines.avgHR)
        XCTAssertNil(baselines.avgAlpha1)
        XCTAssertEqual(baselines.sport, .run)
    }

    func testBaselinesIgnoreOtherSports() {
        let baselines = WorkoutHistoryBaselines.compute(
            from: [WorkoutFixture.runSession(distanceMeters: 10_000, durationSec: 3_000, sport: .bike)],
            sport: .run
        )
        XCTAssertEqual(baselines.sampleCount, 0)
    }

    func testBaselinePaceIsDistanceWeightedNotSessionAveraged() {
        // 10 km in 50 min (300 s/km) plus 2 km in 12 min (360 s/km). A plain
        // mean of the two paces is 330; distance-weighted is 310.
        let baselines = WorkoutHistoryBaselines.compute(
            from: [
                WorkoutFixture.runSession(distanceMeters: 10_000, durationSec: 3_000),
                WorkoutFixture.runSession(distanceMeters: 2_000, durationSec: 720)
            ],
            sport: .run
        )
        XCTAssertEqual(baselines.sampleCount, 2)
        XCTAssertEqual(baselines.avgPaceSecPerKm ?? 0, 310, accuracy: 0.001)
    }

    func testBaselineHeartRateIsSampleWeighted() {
        let baselines = WorkoutHistoryBaselines.compute(
            from: [
                WorkoutFixture.runSession(
                    distanceMeters: 10_000, durationSec: 3_000,
                    samples: WorkoutFixture.samples(count: 100, hr: { _ in 150 })
                ),
                WorkoutFixture.runSession(
                    distanceMeters: 2_000, durationSec: 720,
                    samples: WorkoutFixture.samples(count: 300, hr: { _ in 130 })
                )
            ],
            sport: .run
        )
        // (100×150 + 300×130) / 400 = 135, not the 140 a per-session mean
        // would give.
        XCTAssertEqual(baselines.avgHR ?? 0, 135, accuracy: 0.001)
    }

    func testBaselinesSkipZeroAndMissingReadings() {
        let mixed = (0 ..< 100).map { offset in
            WorkoutSample(
                offsetSec: offset,
                heartRate: offset < 50 ? 150 : nil,
                alpha1: offset < 50 ? 0.9 : 0
            )
        }
        let baselines = WorkoutHistoryBaselines.compute(
            from: [WorkoutFixture.runSession(distanceMeters: 10_000, durationSec: 3_000, samples: mixed)],
            sport: .run
        )
        XCTAssertEqual(baselines.avgHR ?? 0, 150, accuracy: 0.001)
        XCTAssertEqual(baselines.avgAlpha1 ?? 0, 0.9, accuracy: 0.001)
    }

    func testBaselinesKeepOnlyTheMostRecentSessionsUpToTheLimit() {
        let sessions = (0 ..< 40).map { index in
            WorkoutFixture.runSession(
                distanceMeters: 10_000,
                durationSec: 3_000,
                startedDaysIn: index
            )
        }
        XCTAssertEqual(
            WorkoutHistoryBaselines.compute(from: sessions, sport: .run, limit: 30).sampleCount,
            30
        )
        XCTAssertEqual(
            WorkoutHistoryBaselines.compute(from: sessions, sport: .run, limit: 5).sampleCount,
            5
        )
    }

    func testBaselinePaceIsNilWhenNoSessionCarriesUsableDistance() {
        var session = WorkoutFixture.runSession(distanceMeters: 0, durationSec: 3_000)
        session.workoutMetadata = WorkoutMetadata(sport: .run)
        let baselines = WorkoutHistoryBaselines.compute(from: [session], sport: .run)
        XCTAssertEqual(baselines.sampleCount, 1)
        XCTAssertNil(baselines.avgPaceSecPerKm)
    }
}
