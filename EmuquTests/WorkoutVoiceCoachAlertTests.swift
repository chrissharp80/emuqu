@testable import Emuqu
import XCTest

/// How the workout coach delivers what the trigger engine fires: a
/// `.haptic` or urgent event is felt (phone and Watch), and nothing fires a
/// deliverable alert while the coach is muted or its alerts are off.
@MainActor
final class WorkoutVoiceCoachAlertTests: XCTestCase {

    // MARK: - Dispatch

    func testAHapticEventPlaysTheAlertHaptic() {
        var played: [Bool] = []
        let coach = WorkoutVoiceCoach(engine: WorkoutTriggerEngine(rules: []), alertHaptic: { played.append($0) })
        coach.dispatch(event: event(tier: .haptic, urgency: .routine))
        XCTAssertEqual(played, [false])
    }

    /// The strap drop is urgent and `.haptic`; the threshold breach is
    /// urgent and `.spoken`. Both buzz, marked urgent.
    func testAnUrgentEventPlaysTheUrgentHapticWhateverItsTier() {
        var played: [Bool] = []
        let coach = WorkoutVoiceCoach(engine: WorkoutTriggerEngine(rules: []), alertHaptic: { played.append($0) })
        coach.dispatch(event: event(tier: .haptic, urgency: .urgent))
        coach.dispatch(event: event(tier: .spoken, urgency: .urgent))
        XCTAssertEqual(played, [true, true])
    }

    /// A routine spoken line (no haptic) and a silent event (history only)
    /// play no haptic.
    func testRoutineSpokenAndSilentEventsPlayNoHaptic() {
        var played: [Bool] = []
        let coach = WorkoutVoiceCoach(engine: WorkoutTriggerEngine(rules: []), alertHaptic: { played.append($0) })
        coach.dispatch(event: event(tier: .spoken, urgency: .routine))
        coach.dispatch(event: event(tier: .silent, urgency: .routine))
        XCTAssertEqual(played, [])
    }

    // MARK: - Engine gating

    /// While alerts can't be delivered, a `.haptic` rule keeps its cooldown
    /// like a `.spoken` one; a `.silent` rule still records.
    func testOnlySilentRulesFireWhileAlertsAreOff() {
        let engine = WorkoutTriggerEngine(rules: [alertRule("h", .haptic), alertRule("s", .spoken), alertRule("q", .silent)])
        let muted = engine.evaluate(context: makeContext(), canAlert: false)
        XCTAssertEqual(muted.map(\.ruleID), ["q"])
        let heard = engine.evaluate(context: makeContext(), canAlert: true)
        XCTAssertEqual(heard.map(\.ruleID), ["h", "s"])
    }

    // MARK: - Strap drop

    /// The strap-drop line is spoken, so it names the Watch only when the
    /// Watch's wrist heart rate is arriving; without one it says only what
    /// happened and what to check.
    func testTheStrapDropLineNamesTheWatchOnlyWhileWristHeartRateIsLive() {
        XCTAssertEqual(
            strapDropMessage(wristHeartRateLive: true),
            "Strap just went quiet — switching to your Watch's heart rate."
        )
        XCTAssertEqual(strapDropMessage(wristHeartRateLive: false), "Strap just went quiet — check its fit and battery.")
    }

    /// The message the strap-drop rule gives when the strap is connected on
    /// one workout second and gone on the next.
    private func strapDropMessage(wristHeartRateLive: Bool) -> String? {
        let engine = WorkoutTriggerEngine(rules: WorkoutTriggerEngine.equipmentAndProgressRules())
        _ = engine.evaluate(context: makeContext(elapsedSeconds: 600, strapConnected: true, wristHeartRateLive: wristHeartRateLive))
        let fired = engine.evaluate(context: makeContext(elapsedSeconds: 601, strapConnected: false, wristHeartRateLive: wristHeartRateLive))
        return fired.first { $0.ruleID == "equipment.strapDown" }?.message
    }

    // MARK: - Helpers

    private func event(tier: WorkoutTriggerEngine.Tier, urgency: WorkoutTriggerEngine.Urgency) -> WorkoutTriggerEngine.Event {
        WorkoutTriggerEngine.Event(ruleID: "test", tier: tier, urgency: urgency, message: "line", firedAt: Date())
    }

    private func alertRule(_ id: String, _ tier: WorkoutTriggerEngine.Tier) -> WorkoutTriggerEngine.Rule {
        WorkoutTriggerEngine.Rule(id: id, tier: tier, cooldown: 60, condition: { _ in true }, message: { _ in id })
    }

    /// A context the always-true test rules ignore; the strap-drop test sets
    /// the second and the heart-rate sources.
    private func makeContext(
        elapsedSeconds: Int = 600,
        strapConnected: Bool = false,
        wristHeartRateLive: Bool = false
    ) -> WorkoutAIContext {
        WorkoutAIContext(
            sport: .run,
            nowAt: Date(),
            sessionStart: Date().addingTimeInterval(-600),
            elapsedSeconds: elapsedSeconds,
            heartRate: nil,
            peakHR: 0,
            userMaxHR: 180,
            hrDriftPercent: nil,
            alpha1: nil,
            band: .unknown,
            alpha1FitQuality: nil,
            alpha1Status: .warmup(fractionReady: 0),
            distanceMeters: 0,
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
            elevationGainMeters: 0,
            currentGradePercent: nil,
            upcomingClimb: nil,
            routeTopology: nil,
            weather: nil,
            strapConnected: strapConnected,
            strapSilentSec: nil,
            wristHeartRateLive: wristHeartRateLive,
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
