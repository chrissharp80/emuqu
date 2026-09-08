@testable import Emuqu
import XCTest

/// `WorkoutMileMarkerEngine` — the split-marker check-ins announced during a
/// workout ("Mile 3 in 8:45, pace 8:12 min/mi").
///
/// 193 lines at 2.1% coverage. The engine is explicitly documented as pure —
/// snapshot plus state in, payload out, no I/O — which makes the absence of
/// tests the only reason it was unverified.
///
/// What is worth pinning: the 60-second refusal window (a GPS jitter claiming
/// 1.6 km in 30 s must not false-fire "mile 1"), the monotonic marker index
/// (an announcement must never repeat or run backwards when GPS drifts), and
/// the skip-when-normal fields — cadence is surfaced only when it is OUTSIDE
/// the healthy band, so a normal run does not get nagged about it.
final class WorkoutMileMarkerEngineTests: XCTestCase {

    // MARK: - Firing window

    /// A GPS jitter that pretends we covered a mile in 30 s must not fire.
    func testNoMarkerFiresInsideTheFirstMinute() {
        for elapsed in [0, 30, 59] {
            let (payload, next) = WorkoutMileMarkerEngine.evaluate(
                context: makeContext(distance: 5_000, elapsed: elapsed),
                state: MileMarkerState(),
                interval: .everyDistanceUnit,
                unitsImperial: true
            )
            XCTAssertNil(payload, "elapsed \(elapsed)s should be inside the refusal window")
            XCTAssertEqual(next.lastMarkerIndex, 0, "state must not advance either")
        }
    }

    func testAMarkerFiresOnceThe60SecondWindowHasPassed() {
        let (payload, _) = WorkoutMileMarkerEngine.evaluate(
            context: makeContext(distance: 1_700, elapsed: 600),
            state: MileMarkerState(),
            interval: .everyDistanceUnit,
            unitsImperial: true
        )
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.markerIndex, 1)
        XCTAssertEqual(payload?.markerUnit, .mile)
    }

    // MARK: - Units resolution

    /// `.everyDistanceUnit` resolves against the user's actual preference.
    func testDistanceUnitResolvesToMilesOrKilometresByPreference() {
        let imperial = WorkoutMileMarkerEngine.evaluate(
            context: makeContext(distance: 1_700, elapsed: 600),
            state: MileMarkerState(), interval: .everyDistanceUnit, unitsImperial: true
        ).payload
        XCTAssertEqual(imperial?.markerUnit, .mile)

        let metric = WorkoutMileMarkerEngine.evaluate(
            context: makeContext(distance: 1_700, elapsed: 600),
            state: MileMarkerState(), interval: .everyDistanceUnit, unitsImperial: false
        ).payload
        XCTAssertEqual(metric?.markerUnit, .kilometer)
        XCTAssertEqual(metric?.markerIndex, 1, "1.7 km is the first kilometre marker")
    }

    /// A time-based interval indexes by 10-minute blocks, not distance —
    /// so it fires on a treadmill with no GPS at all.
    func testTimeIntervalIndexesByElapsedNotDistance() {
        let (payload, _) = WorkoutMileMarkerEngine.evaluate(
            context: makeContext(distance: 0, elapsed: 1_250),
            state: MileMarkerState(), interval: .everyTenMinutes, unitsImperial: true
        )
        XCTAssertEqual(payload?.markerIndex, 2, "1250 s is the second 10-minute block")
        XCTAssertEqual(payload?.markerUnit, .tenMinutes)
    }

    // MARK: - Monotonicity

    /// The marker index must never repeat. GPS drift backwards, or a second
    /// tick at the same distance, must both be silent.
    func testAMarkerNeverFiresTwiceForTheSameIndex() {
        let context = makeContext(distance: 1_700, elapsed: 600)
        let (first, state) = WorkoutMileMarkerEngine.evaluate(
            context: context, state: MileMarkerState(),
            interval: .everyDistanceUnit, unitsImperial: true
        )
        XCTAssertNotNil(first)

        let (second, _) = WorkoutMileMarkerEngine.evaluate(
            context: context, state: state,
            interval: .everyDistanceUnit, unitsImperial: true
        )
        XCTAssertNil(second, "the same marker must not be announced twice")
    }

    func testGPSDriftingBackwardsDoesNotFire() {
        let (_, state) = WorkoutMileMarkerEngine.evaluate(
            context: makeContext(distance: 3_400, elapsed: 1_200),
            state: MileMarkerState(), interval: .everyDistanceUnit, unitsImperial: true
        )
        let (payload, _) = WorkoutMileMarkerEngine.evaluate(
            context: makeContext(distance: 3_000, elapsed: 1_260),
            state: state, interval: .everyDistanceUnit, unitsImperial: true
        )
        XCTAssertNil(payload, "a backwards distance correction must stay silent")
    }

    /// Crossing several markers between ticks (a tunnel, a GPS re-acquire)
    /// announces the latest — not one payload per skipped marker.
    func testSkippingSeveralMarkersAnnouncesTheLatestOnly() {
        let (payload, next) = WorkoutMileMarkerEngine.evaluate(
            context: makeContext(distance: 8_100, elapsed: 2_400),
            state: MileMarkerState(), interval: .everyDistanceUnit, unitsImperial: true
        )
        XCTAssertEqual(payload?.markerIndex, 5, "8100 m is mile 5")
        XCTAssertEqual(next.lastMarkerIndex, 5)
    }

    // MARK: - Split deltas

    func testSplitDurationAndDistanceAreMeasuredFromTheLastMarker() {
        var state = MileMarkerState()
        (_, state) = WorkoutMileMarkerEngine.evaluate(
            context: makeContext(distance: 1_610, elapsed: 600),
            state: state, interval: .everyDistanceUnit, unitsImperial: true
        )
        let (payload, _) = WorkoutMileMarkerEngine.evaluate(
            context: makeContext(distance: 3_220, elapsed: 1_140),
            state: state, interval: .everyDistanceUnit, unitsImperial: true
        )

        XCTAssertEqual(payload?.markerIndex, 2)
        XCTAssertEqual(payload?.splitDurationSec, 540, "the SECOND mile took 9 minutes")
    }

    /// A stub split — under 100 m — has no meaningful pace, and reporting one
    /// would produce a wild number.
    func testNoPaceIsReportedForAStubSplit() {
        var state = MileMarkerState()
        (_, state) = WorkoutMileMarkerEngine.evaluate(
            context: makeContext(distance: 1_610, elapsed: 600),
            state: state, interval: .everyDistanceUnit, unitsImperial: true
        )
        // Jump the index without covering ground: a time-based re-index.
        let (payload, _) = WorkoutMileMarkerEngine.evaluate(
            context: makeContext(distance: 3_220, elapsed: 1_200),
            state: MileMarkerState(
                lastMarkerIndex: 1,
                splitStartDistanceMeters: 3_200,
                splitStartElevationMeters: 0,
                splitStartElapsedSec: 1_100
            ),
            interval: .everyDistanceUnit, unitsImperial: true
        )
        XCTAssertNil(payload?.splitPaceSecPerKm, "a 20 m split has no meaningful pace")
    }

    /// A flat split skips elevation entirely — only ≥15 m of gain is worth
    /// mentioning.
    func testFlatSplitsOmitElevation() {
        let (payload, _) = WorkoutMileMarkerEngine.evaluate(
            context: makeContext(distance: 1_700, elapsed: 600, elev: 5),
            state: MileMarkerState(), interval: .everyDistanceUnit, unitsImperial: true
        )
        XCTAssertNil(payload?.splitElevationGainMeters)
    }

    func testAClimbingSplitReportsElevation() {
        let (payload, _) = WorkoutMileMarkerEngine.evaluate(
            context: makeContext(distance: 1_700, elapsed: 600, elev: 40),
            state: MileMarkerState(), interval: .everyDistanceUnit, unitsImperial: true
        )
        XCTAssertEqual(payload?.splitElevationGainMeters ?? 0, 40, accuracy: 0.5)
    }

    // MARK: - Skip-when-normal cadence

    /// Cadence is surfaced only when OUTSIDE the healthy 165–190 band, so a
    /// normal run is not nagged about it.
    func testHealthyCadenceIsNotSurfaced() {
        for cadence in [165.0, 175.0, 190.0] {
            let (payload, _) = WorkoutMileMarkerEngine.evaluate(
                context: makeContext(distance: 1_700, elapsed: 600, cadence: cadence),
                state: MileMarkerState(), interval: .everyDistanceUnit, unitsImperial: true
            )
            XCTAssertNil(payload?.cadenceSpm, "\(cadence) spm is healthy and should be silent")
        }
    }

    func testOutOfBandCadenceIsSurfaced() {
        for cadence in [140.0, 200.0] {
            let (payload, _) = WorkoutMileMarkerEngine.evaluate(
                context: makeContext(distance: 1_700, elapsed: 600, cadence: cadence),
                state: MileMarkerState(), interval: .everyDistanceUnit, unitsImperial: true
            )
            XCTAssertNotNil(payload?.cadenceSpm, "\(cadence) spm is outside the band")
        }
    }

    // MARK: - Rendering

    private func payload(
        index: Int = 3,
        unit: MileMarkerUnit = .mile,
        durationSec: Int = 525,
        paceSecPerKm: Double? = 300,
        zone: String? = nil,
        totalMeters: Double = 4_828,
        cadence: Double? = nil,
        elevation: Double? = nil
    ) -> MileMarkerPayload {
        MileMarkerPayload(
            markerIndex: index,
            markerUnit: unit,
            splitDurationSec: durationSec,
            splitPaceSecPerKm: paceSecPerKm,
            hrZoneLabel: zone,
            totalDistanceMeters: totalMeters,
            totalElapsedSec: 1_500,
            cadenceSpm: cadence,
            splitElevationGainMeters: elevation,
            driftCue: nil
        )
    }

    func testRenderedUtteranceLeadsWithTheMarkerAndSplitTime() {
        let text = MileMarkerFormatter.render(payload: payload(), unitsImperial: true)
        XCTAssertTrue(text.hasPrefix("Mile 3 in 8:45"), "got: \(text)")
        XCTAssertTrue(text.hasSuffix("."))
    }

    /// Pace is stored per-kilometre and converted at render time — an
    /// imperial user must never be read a per-km pace.
    func testPaceIsConvertedToTheUsersUnits() {
        let metric = MileMarkerFormatter.render(payload: payload(), unitsImperial: false)
        XCTAssertTrue(metric.contains("min/km"), "got: \(metric)")
        XCTAssertTrue(metric.contains("5:00"), "300 s/km is 5:00 min/km — got: \(metric)")

        let imperial = MileMarkerFormatter.render(payload: payload(), unitsImperial: true)
        XCTAssertTrue(imperial.contains("min/mi"), "got: \(imperial)")
        XCTAssertTrue(imperial.contains("8:03"), "300 s/km is 8:03 min/mi — got: \(imperial)")
    }

    /// A time-based marker already implies duration, so total distance is
    /// omitted — otherwise every announcement says the same thing twice.
    func testTimeMarkersOmitTotalDistance() {
        let timed = MileMarkerFormatter.render(
            payload: payload(unit: .tenMinutes), unitsImperial: true
        )
        XCTAssertFalse(timed.contains("total"), "got: \(timed)")

        let distance = MileMarkerFormatter.render(payload: payload(), unitsImperial: true)
        XCTAssertTrue(distance.contains("total"), "got: \(distance)")
    }

    func testOptionalFieldsAreOmittedWhenAbsent() {
        let bare = MileMarkerFormatter.render(payload: payload(), unitsImperial: true)
        XCTAssertFalse(bare.contains("cadence"))
        XCTAssertFalse(bare.contains("climbing"))
    }

    func testOptionalFieldsAppearWhenPresent() {
        let full = MileMarkerFormatter.render(
            payload: payload(zone: "Z2 — endurance", cadence: 150, elevation: 30),
            unitsImperial: true
        )
        XCTAssertTrue(full.contains("Z2 — endurance"), "got: \(full)")
        XCTAssertTrue(full.contains("cadence 150"), "got: \(full)")
        XCTAssertTrue(full.contains("climbing"), "got: \(full)")
    }

    /// Every marker unit must render a label — a missing case would read as
    /// an empty announcement.
    func testEveryMarkerUnitRendersALabel() {
        for unit in [MileMarkerUnit.mile, .kilometer, .twoKilometers, .fiveKilometers, .tenMinutes] {
            let text = MileMarkerFormatter.render(payload: payload(unit: unit), unitsImperial: false)
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.hasPrefix(" in "), "\(unit) produced an empty label: \(text)")
        }
    }

    // MARK: - HR zone label
    //
    // The zone the AI speaks aloud. Without this, a mutation swapping the
    // denominator to session-observed peak HR survives
    // a green suite — reinstating the exact defect the field note records:
    // "Zone 5 at 100 bpm" when the peak was only 105.

    /// The denominator is the user's PHYSIOLOGICAL max, not the session peak.
    /// Ten minutes into an easy walk the peak equals the current HR, so a
    /// peak-based denominator reads 100% of max and calls every walk Z5.
    func testZoneUsesPhysiologicalMaxNotSessionPeak() throws {
        // 100 bpm against a 180 max is 56% — recovery. Against a session peak
        // that is also 100 it would be 100% — VO2max.
        let context = makeContext(distance: 2_000, elapsed: 900, hr: 100, maxHR: 180)
        let result = WorkoutMileMarkerEngine.evaluate(
            context: context, state: MileMarkerState(), interval: .everyKilometer, unitsImperial: false
        )
        let zone = try XCTUnwrap(result.payload?.hrZoneLabel)
        XCTAssertTrue(zone.hasPrefix("Z1"), "100 bpm at a 180 max is recovery, not \(zone)")
    }

    /// The band edges, so a shifted threshold is a failure rather than a
    /// slightly different word in the user's ear.
    func testZoneBandsMatchThePercentOfMaxFramework() throws {
        let cases: [(hr: Int, prefix: String)] = [
            (107, "Z1"),   // 59.4%
            (108, "Z2"),   // 60.0%
            (126, "Z3"),   // 70.0%
            (144, "Z4"),   // 80.0%
            (162, "Z5")    // 90.0%
        ]
        for testCase in cases {
            let context = makeContext(distance: 2_000, elapsed: 900, hr: testCase.hr, maxHR: 180)
            let result = WorkoutMileMarkerEngine.evaluate(
                context: context, state: MileMarkerState(), interval: .everyKilometer, unitsImperial: false
            )
            let zone = try XCTUnwrap(result.payload?.hrZoneLabel)
            XCTAssertTrue(
                zone.hasPrefix(testCase.prefix),
                "\(testCase.hr) bpm at a 180 max should be \(testCase.prefix), got \(zone)"
            )
        }
    }

    /// No heart rate means no zone claim, rather than a zone computed from a
    /// missing number.
    func testNoHeartRateYieldsNoZoneLabel() {
        let context = makeContext(distance: 2_000, elapsed: 900, hr: nil, maxHR: 180)
        let result = WorkoutMileMarkerEngine.evaluate(
            context: context, state: MileMarkerState(), interval: .everyKilometer, unitsImperial: false
        )
        XCTAssertNotNil(result.payload)
        XCTAssertNil(result.payload?.hrZoneLabel)
    }

    /// Minimal context carrying only what the mile-marker engine reads.
    /// Lifted from `RouteNavigationEnginesTests` and widened for cadence,
    /// which the engine filters on.
    private func makeContext(
        distance: Double,
        elapsed: Int,
        hr: Int? = nil,
        elev: Double = 0,
        cadence: Double? = nil,
        maxHR: Int = 180
    ) -> WorkoutAIContext {
        WorkoutAIContext(
            sport: .walk,
            nowAt: Date(),
            sessionStart: Date().addingTimeInterval(TimeInterval(-elapsed)),
            elapsedSeconds: elapsed,
            heartRate: hr,
            peakHR: hr ?? 0,
            userMaxHR: maxHR,
            hrDriftPercent: nil,
            alpha1: nil,
            band: .unknown,
            alpha1FitQuality: nil,
            alpha1Status: .warmup(fractionReady: 0),
            distanceMeters: distance,
            currentPaceSecPerKm: nil,
            currentSpeedMS: nil,
            cadenceStepsPerMin: cadence,
            powerWatts: nil,
            footPodActive: false,
            currentMETs: nil,
            recentSplitPaces: [],
            currentLatitude: nil,
            currentLongitude: nil,
            currentAltitudeMeters: nil,
            currentHeadingDegrees: nil,
            gpsAccuracyMeters: nil,
            elevationGainMeters: elev,
            currentGradePercent: nil,
            upcomingClimb: nil,
            routeTopology: nil,
            weather: nil,
            strapConnected: false,
            strapSilentSec: nil,
            currentRoadName: nil,
            currentLocality: nil,
            currentAdministrativeArea: nil,
            currentCountryCode: nil,
            currentCompactAddress: nil,
            currentNearestCrossStreet: nil,
            currentNearestIntersection: nil,
            sessionAverageHR: nil,
            reverseSplitDeltaSecPerKm: nil,
            liveHRDriftPercent: nil,
            recentHRSlopeBpm: nil,
            aerobicDecouplingPercent: nil,
            cadenceDriftSpm: nil,
            gradeAdjustedPaceSecPerKm: nil,
            recentSplitGradeAdjustedPaces: [],
            projectedMinutesUntilFade: nil,
            historicalSportAvgPaceSecPerKm: nil,
            historicalSportAvgHR: nil,
            historicalSportAvgAlpha1: nil,
            historicalSportSampleCount: 0,
            todayRecoveryScore: nil,
            todayTrainingReadiness: nil,
            todayATL: nil,
            todayCTL: nil,
            todayTSB: nil,
            projectedDaysUntilFresh: nil,
            projectedTSBTomorrowSteadyState: nil,
            recoveryHoursNeeded: nil,
            zone1Sec: 0,
            zone2Sec: 0,
            zone3Sec: 0,
            zone4Sec: 0,
            zone5Sec: 0,
            dominantZone: nil,
            predictedRaceTime5KSec: nil,
            predictedRaceTime10KSec: nil,
            predictedRaceTimeHalfSec: nil,
            predictedRaceTimeMarathonSec: nil,
            userUnits: .metric,
            targetZone: nil,
            activeThresholds: [],
            thresholdBreachSec: [:]
        )
    }
}
