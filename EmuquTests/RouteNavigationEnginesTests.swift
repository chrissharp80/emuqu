import CoreLocation
@testable import Emuqu
import MapKit
import XCTest

// MARK: - RouteNavigationEnginesTests
//
// Deterministic tests for the route-navigation engines:
// SavedRouteStepBuilder, TurnAlertEngine, TurnMarkerEngine,
// and ActiveRouteSession's synthetic-route engagement path. The
// engines are pure (or have only deterministic state machines), so
// they're testable without the full app environment — no archive,
// no network, no GPS hardware.
//
// Coverage:
//   • SavedRouteStepBuilder.detectTurns — pure geometry + smoothing
//   • TurnAlertEngine.evaluate — threshold state machine (3 levels +
//     arrival), monotonic guarantee
//   • TurnMarkerEngine.evaluate — split-delta math + first-tick init
//   • ActiveRouteSession.engageSyntheticRoute — sticky step advance
//     under jittered locations
//   • TurnAlertFormatter — distance rounding for spoken output
//   • route_history_baseline filter predicate — case sensitivity +
//     nil handling

final class RouteNavigationEnginesTests: XCTestCase {

    // MARK: - SavedRouteStepBuilder.detectTurns

    /// Straight line — no turns expected.
    func testDetectTurnsStraightLine() {
        let coords: [CLLocationCoordinate2D] = stride(from: 0.0, to: 0.005, by: 0.0001)
            .map { CLLocationCoordinate2D(latitude: 35.0 + $0, longitude: -89.65) }
        let turns = SavedRouteStepBuilder.detectTurns(in: coords)
        XCTAssertEqual(turns, [], "perfectly straight polyline should have no turns")
    }

    /// One sharp 90° turn at the midpoint — should detect exactly one
    /// turn at the corner index.
    func testDetectTurnsOneSharpRightTurn() {
        // 10 fixes east (~50 m), then 10 fixes north (~50 m). The
        // corner is at index 10.
        var coords: [CLLocationCoordinate2D] = []
        for i in 0...10 {
            coords.append(CLLocationCoordinate2D(
                latitude: 35.0,
                longitude: -89.65 + Double(i) * 0.0000559  // ~5m east per fix at lat 35
            ))
        }
        for i in 1...10 {
            coords.append(CLLocationCoordinate2D(
                latitude: 35.0 + Double(i) * 0.0000449,   // ~5m north per fix
                longitude: -89.65 + 10 * 0.0000559
            ))
        }
        let turns = SavedRouteStepBuilder.detectTurns(in: coords)
        XCTAssertEqual(turns.count, 1, "one 90° corner should produce exactly one turn")
        XCTAssertEqual(turns.first, 10, "turn should be detected at the corner index")
    }

    /// Two close turns within minTurnSeparationMeters — should collapse
    /// to one (GPS jitter pattern).
    func testDetectTurnsCollapsesNearbyTurns() {
        // A right-then-immediate-left jitter within 5 m, then a long
        // segment so the surviving turn isn't dropped by the min-segment
        // filter.
        var coords: [CLLocationCoordinate2D] = [
            CLLocationCoordinate2D(latitude: 35.0, longitude: -89.65),
            CLLocationCoordinate2D(latitude: 35.0, longitude: -89.64996),       // 5 m E
            CLLocationCoordinate2D(latitude: 35.000045, longitude: -89.64996),  // 5 m N
            CLLocationCoordinate2D(latitude: 35.000045, longitude: -89.64992)  // 5 m E
        ]
        for i in 1...30 {
            coords.append(CLLocationCoordinate2D(
                latitude: 35.000045,
                longitude: -89.64992 + Double(i) * 0.00006
            ))
        }
        let turns = SavedRouteStepBuilder.detectTurns(in: coords)
        XCTAssertLessThanOrEqual(turns.count, 1, "two close turns should collapse to ≤1")
    }

    // MARK: - TurnAlertEngine threshold state machine

    /// Approach from 200 m: only fires inside the FAR window (135-165 m).
    /// 200 m is OUTSIDE that window, so nothing should fire.
    func testTurnAlertOutsideFarWindowDoesNotFire() {
        let step = makeStepResult(
            currentStepIndex: 0,
            upcomingInstruction: "Turn right onto Oak",
            distance: 200,
            remaining: 1000
        )
        let r = TurnAlertEngine.evaluate(step: step, state: TurnAlertState())
        XCTAssertNil(r.payload, "200m is outside the far window (135-165m), should not fire")
    }

    /// Full progression: FAR (1) → no refire → NEAR (2) → AT-TURN (3).
    /// Each level fires once and only once.
    func testTurnAlertFiresAllThreeThresholdsInOrderMonotonic() {
        var state = TurnAlertState()
        let base = makeStepResult(
            currentStepIndex: 0,
            upcomingInstruction: "Turn right onto Oak",
            distance: 0,
            remaining: 1000
        )

        // FAR: 150m inside [135, 165]
        let r1 = TurnAlertEngine.evaluate(step: withDistance(base, 150), state: state)
        XCTAssertEqual(r1.payload?.thresholdLevel, 1, "150m fires FAR")
        state = r1.nextState

        // FAR refire attempt: 145m still inside window — should NOT fire
        let r2 = TurnAlertEngine.evaluate(step: withDistance(base, 145), state: state)
        XCTAssertNil(r2.payload, "FAR is monotonic — no refire on same step")
        state = r2.nextState

        // NEAR: 60m inside [52.5, 67.5]
        let r3 = TurnAlertEngine.evaluate(step: withDistance(base, 60), state: state)
        XCTAssertEqual(r3.payload?.thresholdLevel, 2, "60m fires NEAR")
        state = r3.nextState

        // AT-TURN: 20m ≤ 25m
        let r4 = TurnAlertEngine.evaluate(step: withDistance(base, 20), state: state)
        XCTAssertEqual(r4.payload?.thresholdLevel, 3, "20m fires AT-TURN")
        state = r4.nextState

        // AT-TURN refire attempt: same distance, no refire
        let r5 = TurnAlertEngine.evaluate(step: withDistance(base, 20), state: state)
        XCTAssertNil(r5.payload, "AT-TURN is monotonic — no refire")
    }

    /// When the user advances to a new step, threshold counter resets
    /// so the new step's FAR alert can fire.
    func testTurnAlertResetsOnStepAdvance() {
        let priorState = TurnAlertState(lastStepIndex: 0, lastThresholdLevel: 3)
        let nextStep = makeStepResult(
            currentStepIndex: 1,  // advanced
            upcomingInstruction: "Turn left onto Maple",
            distance: 150,        // FAR window
            remaining: 800
        )
        let r = TurnAlertEngine.evaluate(step: nextStep, state: priorState)
        XCTAssertEqual(r.payload?.thresholdLevel, 1,
            "step advance resets state, new FAR fires")
        XCTAssertEqual(r.nextState.lastStepIndex, 1)
    }

    /// Arrival fires once when remaining ≤ 25m.
    func testTurnAlertArrivalFiresOnce() {
        let step = makeStepResult(
            currentStepIndex: 5,
            upcomingInstruction: "Arrive at home",
            distance: 0,
            remaining: 15  // within arrival distance
        )
        var state = TurnAlertState()
        let r1 = TurnAlertEngine.evaluate(step: step, state: state)
        XCTAssertEqual(r1.payload?.isArrival, true, "remaining<25m triggers arrival")
        state = r1.nextState
        let r2 = TurnAlertEngine.evaluate(step: step, state: state)
        XCTAssertNil(r2.payload, "arrival fires once, not on every tick")
    }

    // MARK: - TurnAlertFormatter

    func testTurnAlertFormatterRoundsImperialDistance() {
        // 200 m ≈ 656 ft → rounds to 650 ft (nearest 50)
        let p = TurnAlertPayload(
            stepInstruction: "Turn right onto Oak St",
            distanceMeters: 200,
            thresholdLevel: 1,
            destinationLabel: "home",
            isArrival: false
        )
        let s = TurnAlertFormatter.render(payload: p, unitsImperial: true)
        XCTAssertTrue(s.hasPrefix("In 650 feet, "),
            "expected rounded-50ft prefix, got: \(s)")
        XCTAssertTrue(s.contains("turn right"),
            "instruction tail should be lower-cased after distance prefix")
    }

    func testTurnAlertFormatterAtTurnSpeaksInstructionAlone() {
        let p = TurnAlertPayload(
            stepInstruction: "Turn left onto Pine St",
            distanceMeters: 10,
            thresholdLevel: 3,
            destinationLabel: "home",
            isArrival: false
        )
        XCTAssertEqual(
            TurnAlertFormatter.render(payload: p, unitsImperial: true),
            "Turn left onto Pine St"
        )
    }

    func testTurnAlertFormatterArrivalUsesDestinationLabel() {
        let p = TurnAlertPayload(
            stepInstruction: "(unused)",
            distanceMeters: 0,
            thresholdLevel: 4,
            destinationLabel: "Saturday loop",
            isArrival: true
        )
        XCTAssertEqual(
            TurnAlertFormatter.render(payload: p, unitsImperial: false),
            "You've arrived at Saturday loop."
        )
    }

    // MARK: - TurnMarkerEngine

    /// First tick captures baselines and returns nil.
    /// Second tick on same step accumulates HR samples.
    /// Third tick where step advances fires payload with split deltas.
    func testTurnMarkerInitsThenFiresOnAdvance() {
        var state = TurnMarkerState()
        let s0 = makeStepResult(currentStepIndex: 0)
        let r0 = TurnMarkerEngine.evaluate(
            step: s0,
            context: makeContext(distance: 0, elapsed: 0, hr: 130, elev: 0),
            state: state
        )
        XCTAssertNil(r0.payload, "first tick is init only")
        XCTAssertEqual(r0.nextState.legStartStepIndex, 0)
        state = r0.nextState

        // Second tick, same step
        let r1 = TurnMarkerEngine.evaluate(
            step: s0,
            context: makeContext(distance: 100, elapsed: 60, hr: 140, elev: 5),
            state: state
        )
        XCTAssertNil(r1.payload, "no advance, no payload")
        state = r1.nextState

        // Third tick: step advances 0→1
        let s1 = makeStepResult(
            currentStepIndex: 1,
            currentInstruction: "Turn right onto Maple"
        )
        let r2 = TurnMarkerEngine.evaluate(
            step: s1,
            context: makeContext(distance: 250, elapsed: 130, hr: 145, elev: 12),
            state: state
        )
        XCTAssertNotNil(r2.payload, "step advance fires payload")
        XCTAssertEqual(r2.payload?.legDurationSec, 130,
            "leg duration = 130 - 0")
        XCTAssertEqual(r2.payload?.legDistanceMeters, 250,
            "leg distance = 250 - 0")
        // HR avg over (130 + 140 + 145) / 3 = 138.333... → 138
        XCTAssertEqual(r2.payload?.legAvgHR, 138,
            "avg HR over 3 samples = 138 (truncated)")
        XCTAssertEqual(r2.payload?.legElevationGainMeters, 12,
            "12m ≥ 10m threshold so surfaced")
    }

    /// Pace is nil when the leg distance is too short.
    func testTurnMarkerPaceNilForTinyLeg() {
        var state = TurnMarkerState()
        // Init
        let r0 = TurnMarkerEngine.evaluate(
            step: makeStepResult(currentStepIndex: 0),
            context: makeContext(distance: 0, elapsed: 0, hr: 130, elev: 0),
            state: state
        )
        state = r0.nextState

        // Advance with only 30 m of leg distance — under the 50m floor
        let r = TurnMarkerEngine.evaluate(
            step: makeStepResult(currentStepIndex: 1),
            context: makeContext(distance: 30, elapsed: 20, hr: 132, elev: 0),
            state: state
        )
        XCTAssertNotNil(r.payload, "tiny leg still fires payload")
        XCTAssertNil(r.payload?.legPaceSecPerKm, "pace nil when distance < 50m")
    }

    /// Elevation gain under 10m is suppressed (skip-when-normal).
    func testTurnMarkerSkipsTinyElevation() {
        var state = TurnMarkerState()
        let init0 = TurnMarkerEngine.evaluate(
            step: makeStepResult(currentStepIndex: 0),
            context: makeContext(distance: 0, elapsed: 0, hr: 130, elev: 100),
            state: state
        )
        state = init0.nextState

        let r = TurnMarkerEngine.evaluate(
            step: makeStepResult(currentStepIndex: 1),
            context: makeContext(distance: 200, elapsed: 90, hr: 135, elev: 105),
            state: state
        )
        // Only 5m of climbing this leg — should be suppressed
        XCTAssertNil(r.payload?.legElevationGainMeters,
            "5m elevation should be skipped (under 10m threshold)")
    }

    // MARK: - ActiveRouteSession synthetic engagement + step advance

    /// Engage 3 synthetic steps, query along the path, verify sticky
    /// step index advances forward only.
    func testActiveRouteSessionAdvancesStepIndexNoRegression() {
        let stepACoords = [
            CLLocationCoordinate2D(latitude: 35.000, longitude: -89.650),
            CLLocationCoordinate2D(latitude: 35.000, longitude: -89.64950)  // ~46m E
        ]
        let stepBCoords = [
            CLLocationCoordinate2D(latitude: 35.000, longitude: -89.64950),
            CLLocationCoordinate2D(latitude: 35.00045, longitude: -89.64950) // ~50m N
        ]
        let stepCCoords = [
            CLLocationCoordinate2D(latitude: 35.00045, longitude: -89.64950),
            CLLocationCoordinate2D(latitude: 35.00045, longitude: -89.64900) // ~46m E
        ]
        let steps = [
            ActiveRouteSession.InternalStep(
                instructions: "Head east on First St",
                distance: 46,
                polyline: makePolyline(stepACoords)
            ),
            ActiveRouteSession.InternalStep(
                instructions: "Turn left onto Second Ave",
                distance: 50,
                polyline: makePolyline(stepBCoords)
            ),
            ActiveRouteSession.InternalStep(
                instructions: "Arrive at home",
                distance: 46,
                polyline: makePolyline(stepCCoords)
            )
        ]

        ActiveRouteSession.shared.disengage()
        ActiveRouteSession.shared.engageSyntheticRoute(
            steps: steps,
            totalDistance: 142,
            totalDuration: 100,
            destinationLabel: "home",
            destinationCoord: stepCCoords[1]
        )

        // Position at start of step A
        let r1 = ActiveRouteSession.shared.currentStep(for: CLLocation(
            latitude: 35.000, longitude: -89.650
        ))
        XCTAssertEqual(r1?.currentStepIndex, 0, "starts at step 0")

        // Position near step B's FAR endpoint. NOTE: ActiveRouteSession's
        // polylineDistance is vertex-only (not perpendicular-to-segment),
        // so a point equidistant from two adjacent steps' shared vertex
        // ties — push past the midpoint so step B wins decisively. This
        // is a known limitation of the existing geometry, not a bug:
        // for short MapKit-step polylines (~50–200 m) vertex-only is fine
        // because the user is never far from a vertex.
        let r2 = ActiveRouteSession.shared.currentStep(for: CLLocation(
            latitude: 35.00040, longitude: -89.64950
        ))
        XCTAssertEqual(r2?.currentStepIndex, 1, "advances to step 1")
        XCTAssertTrue(r2?.upcomingInstruction.contains("Arrive") ?? false,
            "upcoming should be the arrival instruction")

        // Position at destination
        let r3 = ActiveRouteSession.shared.currentStep(for: CLLocation(
            latitude: 35.00045, longitude: -89.64900
        ))
        XCTAssertTrue(r3?.arrived ?? false,
            "within 25m of last polyline endpoint should arrive")

        // Jittered BACK to step A coords — sticky, do NOT regress
        let r4 = ActiveRouteSession.shared.currentStep(for: CLLocation(
            latitude: 35.000, longitude: -89.650
        ))
        XCTAssertGreaterThanOrEqual(r4?.currentStepIndex ?? 0, 2,
            "sticky step index never regresses under jitter")

        ActiveRouteSession.shared.disengage()
    }

    /// Snapshot is nil before engage, populated after, nil again
    /// after disengage.
    func testActiveRouteSessionSnapshotLifecycle() {
        ActiveRouteSession.shared.disengage()
        XCTAssertNil(ActiveRouteSession.shared.snapshot(),
            "no engaged route → nil snapshot")

        let coords = [
            CLLocationCoordinate2D(latitude: 35.0, longitude: -89.65),
            CLLocationCoordinate2D(latitude: 35.001, longitude: -89.65)
        ]
        let step = ActiveRouteSession.InternalStep(
            instructions: "Head north",
            distance: 111,
            polyline: makePolyline(coords)
        )
        ActiveRouteSession.shared.engageSyntheticRoute(
            steps: [step],
            totalDistance: 111,
            totalDuration: 80,
            destinationLabel: "test",
            destinationCoord: coords[1]
        )
        let snap = ActiveRouteSession.shared.snapshot()
        XCTAssertEqual(snap?.destinationLabel, "test")
        XCTAssertEqual(snap?.stepCount, 1)
        XCTAssertEqual(snap?.totalDistanceMeters, 111)

        ActiveRouteSession.shared.disengage()
        XCTAssertNil(ActiveRouteSession.shared.snapshot(),
            "post-disengage → nil snapshot")
    }

    // MARK: - route_history_baseline filter predicate
    //
    // The fact at AppFactResolver+Workout.swift filters the archive by
    // `workoutMetadata?.recognizedRouteName == routeName`. Swift String
    // equality is case-sensitive, so a renamed-or-rebuilt SavedRoute
    // won't match prior sessions. Prove it.

    func testRouteHistoryBaselineFilterIsCaseSensitive() {
        var meta1 = WorkoutMetadata(sport: .walk); meta1.recognizedRouteName = "Daily 1"
        var meta2 = WorkoutMetadata(sport: .walk); meta2.recognizedRouteName = "daily 1"
        var meta3 = WorkoutMetadata(sport: .walk); meta3.recognizedRouteName = nil
        var meta4 = WorkoutMetadata(sport: .walk); meta4.recognizedRouteName = "Daily 1"

        let pool = [meta1, meta2, meta3, meta4]
        // Replicate the predicate exactly:
        // `archive.entries.filter { $0.workoutMetadata?.recognizedRouteName == routeName }`
        let target = "Daily 1"
        let matches = pool.filter { $0.recognizedRouteName == target }
        XCTAssertEqual(matches.count, 2, "exact-case-only matches count")
        // Implication for the user: if they've renamed a route or
        // saved+resaved with different casing, prior sessions won't
        // contribute to the baseline. The fact returns 'first run on
        // this route' even when there's history under another spelling.
    }

    // MARK: - Helpers

    private func makePolyline(_ coords: [CLLocationCoordinate2D]) -> MKPolyline {
        // `baseAddress` really is nil for an empty buffer, so this is the one
        // unwrap here that was not merely theoretical.
        coords.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return MKPolyline() }
            return MKPolyline(coordinates: base, count: buf.count)
        }
    }

    private func makeStepResult(
        currentStepIndex: Int = 0,
        currentInstruction: String = "",
        upcomingInstruction: String = "",
        distance: Double = 100,
        remaining: Double = 500,
        destination: String = "test",
        arrived: Bool = false
    ) -> ActiveRouteSession.StepResult {
        ActiveRouteSession.StepResult(
            currentStepIndex: currentStepIndex,
            currentInstruction: currentInstruction,
            upcomingInstruction: upcomingInstruction,
            distanceToUpcomingStepMeters: distance,
            remainingDistanceMeters: remaining,
            destinationLabel: destination,
            arrived: arrived
        )
    }

    private func withDistance(
        _ base: ActiveRouteSession.StepResult,
        _ distance: Double
    ) -> ActiveRouteSession.StepResult {
        ActiveRouteSession.StepResult(
            currentStepIndex: base.currentStepIndex,
            currentInstruction: base.currentInstruction,
            upcomingInstruction: base.upcomingInstruction,
            distanceToUpcomingStepMeters: distance,
            remainingDistanceMeters: base.remainingDistanceMeters,
            destinationLabel: base.destinationLabel,
            arrived: base.arrived
        )
    }

    /// Build a minimal WorkoutAIContext with only the fields the
    /// turn-marker engine reads. Everything else gets safe defaults.
    private func makeContext(
        distance: Double,
        elapsed: Int,
        hr: Int?,
        elev: Double
    ) -> WorkoutAIContext {
        WorkoutAIContext(
            sport: .walk,
            nowAt: Date(),
            sessionStart: Date().addingTimeInterval(TimeInterval(-elapsed)),
            elapsedSeconds: elapsed,
            heartRate: hr,
            peakHR: hr ?? 0,
            userMaxHR: 180,
            hrDriftPercent: nil,
            alpha1: nil,
            band: .unknown,
            alpha1FitQuality: nil,
            alpha1Status: .warmup(fractionReady: 0),
            distanceMeters: distance,
            currentPaceSecPerKm: nil,
            currentSpeedMS: nil,
            cadenceStepsPerMin: nil,
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
