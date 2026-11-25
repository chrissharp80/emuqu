import CoreLocation
@testable import Emuqu
import XCTest

/// The hill ahead from past workouts, the heart-rate forecast on it, the
/// spoken warning, and the mid-workout questions answered without a model.
@MainActor
final class FloLiveAnswersTests: XCTestCase {
    private let foot = CLLocationCoordinate2D(latitude: 39.781, longitude: -89.652)
    /// Metres per degree of latitude, for laying tracks out north.
    private let metersPerDegree = UnitConstants.metersPerDegreeLatitude

    // MARK: - The climb ahead, from past tracks

    func testPastPassesThatAgreeFindTheClimbAndItsHeartRateRise() throws {
        let tracks = [track(daysAgo: 2, startHR: 140, topHR: 158), track(daysAgo: 5, startHR: 142, topHR: 162), track(daysAgo: 9, startHR: 138, topHR: 152)]
        let climb = try XCTUnwrap(PlaceHistory.climbAhead(in: tracks, at: location(metersBeforeFoot: 300), heading: 0))
        XCTAssertEqual(climb.passes, 3)
        XCTAssertEqual(climb.distanceMeters, 300, accuracy: 15)
        XCTAssertEqual(climb.gainMeters, 30, accuracy: 1)
        XCTAssertEqual(climb.gradePercent, 10, accuracy: 1)
        XCTAssertEqual(climb.heartRateRise, 18, "the median of 18, 20 and 14")
    }

    func testGoingTheOtherWayFindsNoClimb() {
        let tracks = [track(daysAgo: 2, startHR: 140, topHR: 158), track(daysAgo: 5, startHR: 142, topHR: 162)]
        XCTAssertNil(PlaceHistory.climbAhead(in: tracks, at: location(metersBeforeFoot: 300), heading: 180))
    }

    func testOnePassIsNotEnoughToClaimAClimb() {
        XCTAssertNil(PlaceHistory.climbAhead(in: [track(daysAgo: 2, startHR: 140, topHR: 158)], at: location(metersBeforeFoot: 300), heading: 0))
    }

    func testPassesThatWentThisWayWithoutAClimbOutvoteOneThatSawIt() {
        let tracks = [track(daysAgo: 2, startHR: 140, topHR: 158), track(daysAgo: 4, startHR: 140, topHR: 158), flatTrack(daysAgo: 5), flatTrack(daysAgo: 6), flatTrack(daysAgo: 7)]
        XCTAssertNil(PlaceHistory.climbAhead(in: tracks, at: location(metersBeforeFoot: 300), heading: 0))
    }

    func testVisitsHereGiveTheLatestAndTheMedian() throws {
        let tracks = [track(daysAgo: 2, startHR: 140, topHR: 158), track(daysAgo: 5, startHR: 150, topHR: 162), track(daysAgo: 9, startHR: 130, topHR: 152)]
        let visits = try XCTUnwrap(PlaceHistory.visits(in: tracks, at: location(metersBeforeFoot: 0), heading: 0))
        XCTAssertEqual(visits.count, 3)
        XCTAssertEqual(visits.latestHeartRate, 140)
        XCTAssertEqual(visits.medianHeartRate, 140)
    }

    func testAPastWorkoutBecomesATrackWithItsSamplesAtEachFix() throws {
        let start = Date().addingTimeInterval(-86_400)
        let built = try XCTUnwrap(PlaceHistory.track(from: session(start: start, hillHR: 166)))
        XCTAssertEqual(built.date, start)
        let onHill = try XCTUnwrap(built.points.first { $0.heartRate == 166 })
        XCTAssertNotNil(onHill.altitudeMeters)
        XCTAssertGreaterThan(onHill.distanceAlongMeters, 0)
    }

    // MARK: - The forecast

    func testTheLowestLimitTheUserSetWins() {
        let limit = ClimbHeartRateForecast.limit(
            ceilings: [.init(metric: .heartRateBPM, condition: .greaterThan, value: 165), .init(metric: .heartRateZone, condition: .greaterThan, value: 3)],
            maxHR: 190, thresholdHeartRate: 167, thresholdIsUserSet: true
        )
        XCTAssertEqual(limit, .init(bpm: 152, source: .userLimit), "the top of zone 3 is 0.80 × 190")
    }

    func testWithoutALimitTheThresholdIsUsedAndSaysWhenItIsAnEstimate() {
        let limit = ClimbHeartRateForecast.limit(ceilings: [], maxHR: 190, thresholdHeartRate: 167, thresholdIsUserSet: false)
        XCTAssertEqual(limit, .init(bpm: 167, source: .estimatedThreshold))
    }

    func testAForecastNeedsTheRiseToCrossALimitTheUserIsUnder() {
        let limit = ClimbHeartRateForecast.Limit(bpm: 160, source: .threshold)
        let climb = climbAhead(distance: 250, rise: 16)
        XCTAssertEqual(ClimbHeartRateForecast.forecast(climb: climb, heartRate: 150, limit: limit)?.predictedHeartRate, 166)
        XCTAssertNil(ClimbHeartRateForecast.forecast(climb: climb, heartRate: 140, limit: limit), "140 + 16 stays under 160")
        XCTAssertNil(ClimbHeartRateForecast.forecast(climb: climb, heartRate: 162, limit: limit), "already over: the breach alert's job")
        XCTAssertNil(ClimbHeartRateForecast.forecast(climb: climbAhead(distance: 250, rise: 3), heartRate: 158, limit: limit), "a 3-beat rise is noise")
    }

    // MARK: - The spoken cue

    func testTheCueIsSpokenBeforeTheClimbWhenTheRiseWouldCrossTheThreshold() throws {
        var ctx = context(heartRate: 150, speed: 1.4)
        ctx.historyClimbAhead = climbAhead(distance: 140, rise: 16)
        ctx.thresholdHeartRate = 160
        ctx.thresholdHeartRateIsUserSet = true
        let engine = WorkoutTriggerEngine(rules: [WorkoutTriggerEngine.climbHeartRateForecastRule()])
        let event = try XCTUnwrap(engine.evaluate(context: ctx).first)
        XCTAssertEqual(event.ruleID, "climb.heartRateForecast")
        XCTAssertEqual(event.tier, .spoken)
        XCTAssertEqual(event.message, "Hill in 150 meters, about 10 percent. It has taken your heart rate up 16 beats before, which would put you at 166, over your threshold of 160. Ease off now.")
    }

    func testTheCueWaitsUntilTheClimbIsAboutTwoMinutesAway() {
        XCTAssertFalse(WorkoutTriggerEngine.inSpeakingWindow(400, speed: 1.4), "a walker is about 5 minutes from it")
        XCTAssertTrue(WorkoutTriggerEngine.inSpeakingWindow(400, speed: 3.5))
        XCTAssertFalse(WorkoutTriggerEngine.inSpeakingWindow(30, speed: 3.5), "too late to ease off")
    }

    // MARK: - Mid-workout questions without a model

    func testLiveQuestionsMatchOnlyDuringAWorkout() {
        for question in ["How am I doing on this hill compared to last time?", "Should I ease off?", "Is it just the climb?", "What's ahead?", "Where am I?", "What's my heart rate?"] {
            XCTAssertNotNil(DeterministicIntent.matchedPattern(for: question, live: true), question)
        }
        XCTAssertNil(DeterministicIntent.matchedPattern(for: "Should I ease off?"), "no workout: the model answers")
    }

    func testHowAmIDoingMeansTheWorkoutDuringOne() {
        XCTAssertEqual(DeterministicIntent.matchedPattern(for: "how am I doing", live: true)?.pattern.id, "live_summary")
        XCTAssertEqual(DeterministicIntent.matchedPattern(for: "how am I doing")?.pattern.id, "recovery_score_today")
    }

    func testThisSpotIsComparedWithThePastPasses() throws {
        var live = snapshot(heartRate: 158, paceSecPerKm: 340)
        live.visitsHere = PlaceHistory.Visits(count: 4, medianPaceSecPerKm: 360, medianHeartRate: 164, latestDate: Date(), latestPaceSecPerKm: 355, latestHeartRate: 166)
        let answer = try XCTUnwrap(DeterministicIntent.tryMatch("how am I doing on this hill compared to the last two weeks", in: matchContext(live)))
        XCTAssertTrue(answer.contains("Over your last 4 passes here"), answer)
        XCTAssertTrue(answer.contains("faster than usual"), answer)
        XCTAssertTrue(answer.contains("Heart rate 6 beats lower."), answer)
    }

    func testEaseOffSaysTheClimbWillTakeYouOver() throws {
        var live = snapshot(heartRate: 150, paceSecPerKm: 340)
        live.historyClimbAhead = climbAhead(distance: 300, rise: 16)
        live.thresholdHeartRate = 160
        live.thresholdHeartRateIsUserSet = false
        let answer = try XCTUnwrap(DeterministicIntent.tryMatch("should I ease off", in: matchContext(live)))
        XCTAssertTrue(answer.contains("over your estimated threshold of 160"), answer)
    }

    func testEaseOffSaysYoureFineWhenNothingWillCrossTheLimit() throws {
        var live = snapshot(heartRate: 140, paceSecPerKm: 340)
        live.thresholdHeartRate = 160
        live.thresholdHeartRateIsUserSet = true
        let answer = try XCTUnwrap(DeterministicIntent.tryMatch("should I ease off", in: matchContext(live)))
        XCTAssertEqual(answer, "You're fine. Heart rate 140, 20 under your threshold of 160.")
    }

    func testItsTheClimbWhenTheGradeExplainsThePace() throws {
        var live = snapshot(heartRate: 158, paceSecPerKm: 340, grade: 6)
        live.gradeAdjustedPaceSecPerKm = 302
        let answer = try XCTUnwrap(DeterministicIntent.tryMatch("is it just the climb", in: matchContext(live)))
        XCTAssertTrue(answer.hasPrefix("It's the climb."), answer)
    }

    func testWithoutTheNumbersTheQuestionGoesToTheModel() {
        XCTAssertNil(DeterministicIntent.tryMatch("how am I doing on this hill compared to last time", in: matchContext(snapshot(heartRate: 150, paceSecPerKm: 340))))
    }

    // MARK: - The live memory, end to end

    func testTheLiveMemoryReadsHistoryOffTheMainActorAndFindsTheClimb() async throws {
        let archive = SessionArchive(directory: temporaryDirectory())
        for (daysAgo, hillHR) in [(2, 166), (5, 164), (8, 168)] {
            try archive.archive(session(start: Date().addingTimeInterval(Double(-daysAgo) * 86_400), hillHR: hillHR), skipSameNightMerge: true)
        }
        let memory = LivePlaceMemory()
        let here = location(metersBeforeFoot: 300)
        var now = Date()
        let deadline = Date().addingTimeInterval(10)
        while memory.climbAhead == nil, Date() < deadline {
            memory.update(location: here, heading: 0, sessionStart: Date(), archive: archive, now: now)
            now = now.addingTimeInterval(LivePlaceMemory.refreshInterval)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let climb = try XCTUnwrap(memory.climbAhead, "no climb found from three past runs")
        XCTAssertEqual(climb.passes, 3)
        XCTAssertNotNil(memory.visitsHere)
        memory.reset()
        XCTAssertNil(memory.climbAhead)
    }

    // MARK: - Fixtures

    private func location(metersBeforeFoot meters: Double) -> CLLocation {
        CLLocation(latitude: foot.latitude - meters / metersPerDegree, longitude: foot.longitude)
    }

    /// A pass north: 600 m flat to the foot, 300 m at 10 % (30 m up) with
    /// the heart rate rising from `startHR` to `topHR`, then 200 m flat.
    private func track(daysAgo: Int, startHR: Int, topHR: Int) -> PlaceHistory.Track {
        let points = stride(from: -600.0, through: 500, by: 10).map { along -> PlaceHistory.Point in
            let climbed = min(max(along, 0), 300)
            let heartRate = startHR + Int(Double(topHR - startHR) * climbed / 300)
            return PlaceHistory.Point(
                latitude: foot.latitude + along / metersPerDegree, longitude: foot.longitude, altitudeMeters: 150 + climbed / 10,
                distanceAlongMeters: along + 600, heartRate: heartRate, paceSecPerKm: 360
            )
        }
        return PlaceHistory.Track(date: Date().addingTimeInterval(Double(-daysAgo) * 86_400), points: points)
    }

    private func flatTrack(daysAgo: Int) -> PlaceHistory.Track {
        let points = stride(from: -600.0, through: 500, by: 10).map { along in
            PlaceHistory.Point(
                latitude: foot.latitude + along / metersPerDegree, longitude: foot.longitude, altitudeMeters: 150,
                distanceAlongMeters: along + 600, heartRate: 140, paceSecPerKm: 360
            )
        }
        return PlaceHistory.Track(date: Date().addingTimeInterval(Double(-daysAgo) * 86_400), points: points)
    }

    private func climbAhead(distance: Double, rise: Int) -> PlaceHistory.ClimbAhead {
        PlaceHistory.ClimbAhead(distanceMeters: distance, lengthMeters: 300, gainMeters: 30, passes: 3, heartRateRise: rise, peakHeartRate: 160)
    }

    /// A 30-minute run north at 3 m/s with the same 10 % climb, recorded as
    /// a workout: GPS fixes every 10 s and a sample every second.
    private func session(start: Date, hillHR: Int) -> HRVSession {
        var fixes: [CLLocation] = []
        var samples: [WorkoutSample] = []
        for second in 0...1_800 {
            let along = Double(second) * 3 - 900
            let altitude = 150 + min(max(along, 0), 300) / 10
            let onHill = along >= 0 && along <= 300
            if second.isMultiple(of: 10) {
                let coordinate = CLLocationCoordinate2D(latitude: foot.latitude + along / metersPerDegree, longitude: foot.longitude)
                fixes.append(CLLocation(coordinate: coordinate, altitude: altitude, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: start.addingTimeInterval(Double(second))))
            }
            samples.append(WorkoutSample(
                offsetSec: second, heartRate: onHill ? hillHR : 148, distanceMeters: Double(second) * 3, paceSecPerKm: 333,
                cadenceStepsPerMin: 168, altitudeMeters: altitude, alpha1: nil, mets: nil, powerWatts: nil
            ))
        }
        var session = HRVSession(startDate: start, tags: [], sessionType: .workout)
        session.endDate = start.addingTimeInterval(1_800)
        session.state = .complete
        var metadata = WorkoutMetadata(sport: .run)
        metadata.gpsPolyline = WorkoutAnalyzer.encodePolyline(track: fixes)
        metadata.gpsFixTimes = WorkoutAnalyzer.encodeFixTimes(track: fixes)
        metadata.samples = samples
        session.workoutMetadata = metadata
        return session
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloLiveAnswersTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                // swallow-ok: a test that archived nothing leaves no directory to remove.
            }
        }
        return directory
    }

    private func matchContext(_ live: AssistantContext.LiveWorkoutSnapshot) -> DeterministicIntent.MatchContext {
        DeterministicIntent.MatchContext(now: Date(), archive: SessionArchive(directory: temporaryDirectory()), userSettings: UserSettings(), liveWorkout: live)
    }

    private func snapshot(heartRate: Int, paceSecPerKm: Double, grade: Double? = nil) -> AssistantContext.LiveWorkoutSnapshot {
        AssistantContext.LiveWorkoutSnapshot(
            sport: "Run", snapshotAt: Date(), sessionStartAt: Date().addingTimeInterval(-840), elapsedSeconds: 840, heartRate: heartRate, peakHR: heartRate, userMaxHR: 188,
            beatCount: 2_200, distanceMeters: 2_500, stepCount: 2_350, cadenceStepsPerMin: 168, elevationGainMeters: 18,
            alpha1: nil, alpha1Band: "Unknown", alpha1Status: "warmup", alpha1FitQualityR2: nil, strapConnected: true, strapSilentSec: nil,
            gpsFixCount: 84, gpsAccuracyMeters: 5, currentPaceSecPerKm: paceSecPerKm, currentSpeedMS: 2.9, powerWatts: nil, currentMETs: nil,
            recentSplitPaces: [328, 331], currentLatitude: foot.latitude, currentLongitude: foot.longitude, currentAltitudeMeters: 150,
            currentHeadingDegrees: 0, currentHeadingCardinal: "N", currentGradePercent: grade, unitsPreference: "metric", targetZone: nil
        )
    }

    private func context(heartRate: Int, speed: Double) -> WorkoutAIContext {
        WorkoutAIContext(
            sport: .run, nowAt: Date(), sessionStart: Date().addingTimeInterval(-600), elapsedSeconds: 600, heartRate: heartRate, peakHR: heartRate, userMaxHR: 190,
            hrDriftPercent: nil, alpha1: nil, band: .unknown, alpha1FitQuality: nil, alpha1Status: .warmup(fractionReady: 0), distanceMeters: 1_000,
            currentPaceSecPerKm: 700, currentSpeedMS: speed, cadenceStepsPerMin: nil, powerWatts: nil, footPodActive: false, currentMETs: nil, recentSplitPaces: [],
            currentLatitude: nil, currentLongitude: nil, currentAltitudeMeters: nil, currentHeadingDegrees: 0, gpsAccuracyMeters: nil, elevationGainMeters: 0,
            currentGradePercent: nil, upcomingClimb: nil, routeTopology: nil, weather: nil, strapConnected: true, strapSilentSec: nil, wristHeartRateLive: false,
            currentRoadName: nil, currentLocality: nil, currentAdministrativeArea: nil, currentCountryCode: nil, currentCompactAddress: nil,
            currentNearestCrossStreet: nil, currentNearestIntersection: nil, sessionAverageHR: nil, reverseSplitDeltaSecPerKm: nil, liveHRDriftPercent: nil,
            recentHRSlopeBpm: nil, aerobicDecouplingPercent: nil, cadenceDriftSpm: nil, gradeAdjustedPaceSecPerKm: nil, recentSplitGradeAdjustedPaces: [],
            projectedMinutesUntilFade: nil, historicalSportAvgPaceSecPerKm: nil, historicalSportAvgHR: nil, historicalSportAvgAlpha1: nil, historicalSportSampleCount: 0,
            todayRecoveryScore: nil, todayTrainingReadiness: nil, todayATL: nil, todayCTL: nil, todayTSB: nil, projectedDaysUntilFresh: nil,
            projectedTSBTomorrowSteadyState: nil, recoveryHoursNeeded: nil, zone1Sec: 0, zone2Sec: 0, zone3Sec: 0, zone4Sec: 0, zone5Sec: 0, dominantZone: nil,
            predictedRaceTime5KSec: nil, predictedRaceTime10KSec: nil, predictedRaceTimeHalfSec: nil, predictedRaceTimeMarathonSec: nil, userUnits: .metric,
            targetZone: nil, activeThresholds: [], thresholdBreachSec: [:]
        )
    }
}
