@testable import Emuqu
import HealthKit
import XCTest

/// Tests for the samples written into Apple Health after a workout.
///
/// This is the code that puts your workout
/// into the Health app: heart rate, distance, and active energy. Wrong values
/// here do not just render badly — they are written into the user's permanent
/// Health record and contribute to their activity rings.
@MainActor
final class HealthKitWorkoutExportTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_622_534_400)
    private var clock: WorkoutWallClock { WorkoutWallClock(startDate: start) }

    private func sample(
        _ offsetSec: Int, hr: Int? = nil, distance: Double? = nil, mets: Double? = nil
    ) -> WorkoutSample {
        WorkoutSample(offsetSec: offsetSec, heartRate: hr, distanceMeters: distance, mets: mets)
    }

    // MARK: - Heart rate

    func testHeartRateSamplesAreEmittedPerReading() {
        let samples = [sample(0, hr: 120), sample(10, hr: 130), sample(20, hr: 140)]
        XCTAssertEqual(HealthKitWorkoutExport.heartRateSamples(from: samples, clock: clock).count, 3)
    }

    func testTicksWithoutAHeartRateAreSkipped() {
        // The strap drops out mid-workout; those ticks must not become samples.
        let samples = [sample(0, hr: 120), sample(10), sample(20, hr: 140)]
        XCTAssertEqual(HealthKitWorkoutExport.heartRateSamples(from: samples, clock: clock).count, 2)
    }

    func testHeartRateSampleCarriesTheRightValueAndTime() {
        let out = HealthKitWorkoutExport.heartRateSamples(from: [sample(60, hr: 152)], clock: clock)
        let s = try? XCTUnwrap(out.first)
        XCTAssertEqual(s?.quantity.doubleValue(for: HKUnit(from: "count/min")), 152)
        XCTAssertEqual(s?.startDate, start.addingTimeInterval(60))
    }

    func testNoSamplesProducesNothing() {
        XCTAssertTrue(HealthKitWorkoutExport.heartRateSamples(from: [], clock: clock).isEmpty)
    }

    /// Apple Watch heart rate read from Apple Health is not written back as
    /// Emuqu's: the Watch already saved it.
    func testRowsFilledFromAppleHealthAreNotWrittenBack() {
        let samples = [sample(0, hr: 120), sample(10, hr: 130), sample(20, hr: 140)]
        let out = HealthKitWorkoutExport.heartRateSamples(from: samples, clock: clock, skipping: [10])
        XCTAssertEqual(out.map(\.startDate), [start, start.addingTimeInterval(20)])
    }

    /// Heart rate goes with a workout only when Apple Health export and its
    /// heart-rate switch are both on, as the Health permission text says.
    func testWorkoutHeartRateFollowsTheExportSettings() {
        var settings = UserSettings()
        settings.enableHealthKitExport = false
        settings.exportHeartRate = true
        XCTAssertFalse(HealthKitWorkoutExport.writesHeartRate(with: settings))
        settings.enableHealthKitExport = true
        XCTAssertTrue(HealthKitWorkoutExport.writesHeartRate(with: settings))
        settings.exportHeartRate = false
        XCTAssertFalse(HealthKitWorkoutExport.writesHeartRate(with: settings))
    }

    // MARK: - Data that came from Apple Health

    /// A workout rebuilt from Apple Health's passive samples carries Health's
    /// own heart rate, distance and effort. Exporting it writes the workout
    /// and nothing else, so none of those reach Health again as Emuqu's.
    func testWorkoutRebuiltFromAppleHealthWritesNoSampleSeries() {
        let track = ImportedWorkoutTrack(
            startDate: start, endDate: start.addingTimeInterval(600), track: [],
            heartRateSamples: [(start.addingTimeInterval(5), 110), (start.addingTimeInterval(300), 128)],
            cadenceSamples: [], sport: .walk
        )
        let rebuilt = ImportedWorkoutBuilder.buildSession(from: track, source: .appleHealthSamples)
        XCTAssertNil(rebuilt.healthKitExportedAt, "the rebuilt workout itself is still exported")
        let options = HealthKitWorkoutExport.sampleOptions(for: rebuilt, bodyWeightKg: 75, writesHeartRate: true)
        XCTAssertFalse(options.writesHeartRate)
        XCTAssertFalse(options.writesDistanceAndEnergy)
    }

    /// A workout recorded with Apple Watch heart rate keeps its own distance
    /// and energy but never writes the Watch's heart rate back.
    func testAppleWatchWorkoutWritesDistanceAndEnergyButNotHeartRate() {
        let options = HealthKitWorkoutExport.sampleOptions(
            for: recordedWorkout(deviceId: CloudSessionPayload.appleWatchDeviceId), bodyWeightKg: 75, writesHeartRate: true
        )
        XCTAssertFalse(options.writesHeartRate)
        XCTAssertTrue(options.writesDistanceAndEnergy)
    }

    func testStrapWorkoutWritesEverySeriesTheSettingsAllow() {
        let session = recordedWorkout(deviceId: "polar-h10")
        let allowed = HealthKitWorkoutExport.sampleOptions(for: session, bodyWeightKg: 75, writesHeartRate: true)
        XCTAssertTrue(allowed.writesHeartRate)
        XCTAssertTrue(allowed.writesDistanceAndEnergy)
        let heartRateOff = HealthKitWorkoutExport.sampleOptions(for: session, bodyWeightKg: 75, writesHeartRate: false)
        XCTAssertFalse(heartRateOff.writesHeartRate)
    }

    private func recordedWorkout(deviceId: String) -> HRVSession {
        var session = HRVSession(
            id: UUID(), startDate: start, endDate: start.addingTimeInterval(600), state: .complete,
            rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        session.sessionType = .workout
        session.deviceProvenance = DeviceProvenance(
            deviceId: deviceId, deviceModel: "Test", firmwareVersion: nil,
            recordingMode: .streaming, appVersion: "1", osVersion: "1", capturedAt: start
        )
        session.workoutMetadata = WorkoutMetadata(sport: .run)
        return session
    }

    // MARK: - Distance

    func testDistanceIsWrittenAsPerTickDeltas() {
        // Cumulative 0, 100, 250 -> deltas 100 and 150. Writing cumulative
        // values instead would triple-count the distance in Health.
        let samples = [sample(0, distance: 0), sample(10, distance: 100), sample(20, distance: 250)]
        let out = HealthKitWorkoutExport.distanceSamples(from: samples, sport: .run, clock: clock)
        let metres = out.map { $0.quantity.doubleValue(for: .meter()) }
        XCTAssertEqual(metres, [100, 150])
    }

    func testNonAdvancingDistanceIsSkipped() {
        // GPS jitter reports the same or a lower cumulative distance. Those
        // ticks must not emit — a negative delta would subtract from the
        // user's Health total. The first reading is real travel and does.
        let samples = [sample(0, distance: 100), sample(10, distance: 100), sample(20, distance: 90)]
        let out = HealthKitWorkoutExport.distanceSamples(from: samples, sport: .run, clock: clock)
        XCTAssertEqual(out.count, 1, "only the advancing reading emits")
        XCTAssertEqual(out.first?.quantity.doubleValue(for: .meter()), 100)
    }

    func testTotalDistanceMatchesTheFinalCumulativeReading() {
        let samples = (0 ..< 20).map { sample($0 * 10, distance: Double($0) * 45) }
        let out = HealthKitWorkoutExport.distanceSamples(from: samples, sport: .run, clock: clock)
        let total = out.reduce(0.0) { $0 + $1.quantity.doubleValue(for: .meter()) }
        XCTAssertEqual(total, 19 * 45, accuracy: 0.001, "deltas must sum to the distance actually travelled")
    }

    func testRowingWritesNoDistance() {
        // An erg's metres are not walking or running distance.
        let samples = [sample(0, distance: 0), sample(10, distance: 100)]
        XCTAssertTrue(HealthKitWorkoutExport.distanceSamples(from: samples, sport: .row, clock: clock).isEmpty)
    }

    func testCyclingUsesTheCyclingDistanceType() {
        // Filing a ride under walking/running distance corrupts both metrics.
        let samples = [sample(0, distance: 0), sample(10, distance: 100)]
        let ride = HealthKitWorkoutExport.distanceSamples(from: samples, sport: .bike, clock: clock)
        let run = HealthKitWorkoutExport.distanceSamples(from: samples, sport: .run, clock: clock)
        XCTAssertEqual(ride.first?.quantityType, HKQuantityType.quantityType(forIdentifier: .distanceCycling))
        XCTAssertEqual(run.first?.quantityType, HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning))
    }

    /// A merged or recovered tick list can arrive out of order. A span from a
    /// later tick back to an earlier one would raise an uncatchable
    /// HealthKit exception, so the ticks are taken in time order.
    func testOutOfOrderTicksStillWriteForwardSpans() {
        let samples = [sample(20, distance: 250, mets: 8), sample(0, distance: 0, mets: 8), sample(10, distance: 100, mets: 8)]
        let distance = HealthKitWorkoutExport.distanceSamples(from: samples, sport: .run, clock: clock)
        let energy = HealthKitWorkoutExport.activeEnergySamples(from: samples, clock: clock, bodyWeightKg: 75)
        XCTAssertEqual(distance.map { $0.quantity.doubleValue(for: .meter()) }, [100, 150])
        XCTAssertEqual(energy.count, 3)
        XCTAssertTrue((distance + energy).allSatisfy { $0.endDate >= $0.startDate })
    }

    func testNonFiniteDistanceIsRejected() {
        let samples = [sample(0, distance: 0), sample(10, distance: .infinity)]
        XCTAssertTrue(HealthKitWorkoutExport.distanceSamples(from: samples, sport: .run, clock: clock).isEmpty)
    }

    // MARK: - Active energy

    func testEnergyIsEmittedForTicksWithMETs() {
        let samples = [sample(0, mets: 8), sample(60, mets: 8), sample(120, mets: 8)]
        let out = HealthKitWorkoutExport.activeEnergySamples(
            from: samples, clock: clock, bodyWeightKg: 75
        )
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.allSatisfy { $0.quantity.doubleValue(for: .kilocalorie()) > 0 })
    }

    func testTicksWithoutMETsAreSkipped() {
        let out = HealthKitWorkoutExport.activeEnergySamples(
            from: [sample(0), sample(60)], clock: clock, bodyWeightKg: 75
        )
        XCTAssertTrue(out.isEmpty)
    }

    func testHeavierAthleteBurnsMoreForTheSameEffort() {
        // kcal scales with body mass; if it did not, the formula is wrong.
        let samples = [sample(0, mets: 8), sample(60, mets: 8)]
        let light = HealthKitWorkoutExport.activeEnergySamples(from: samples, clock: clock, bodyWeightKg: 60)
        let heavy = HealthKitWorkoutExport.activeEnergySamples(from: samples, clock: clock, bodyWeightKg: 100)
        let lightKcal = light.reduce(0.0) { $0 + $1.quantity.doubleValue(for: .kilocalorie()) }
        let heavyKcal = heavy.reduce(0.0) { $0 + $1.quantity.doubleValue(for: .kilocalorie()) }
        XCTAssertGreaterThan(heavyKcal, lightKcal)
    }

    func testHarderEffortBurnsMore() {
        let easy = [sample(0, mets: 4), sample(60, mets: 4)]
        let hard = [sample(0, mets: 12), sample(60, mets: 12)]
        let easyKcal = HealthKitWorkoutExport.activeEnergySamples(from: easy, clock: clock, bodyWeightKg: 75)
            .reduce(0.0) { $0 + $1.quantity.doubleValue(for: .kilocalorie()) }
        let hardKcal = HealthKitWorkoutExport.activeEnergySamples(from: hard, clock: clock, bodyWeightKg: 75)
            .reduce(0.0) { $0 + $1.quantity.doubleValue(for: .kilocalorie()) }
        XCTAssertGreaterThan(hardKcal, easyKcal)
    }

    func testNonFiniteMETsAreRejected() {
        // HKQuantity raises an NSException on NaN or infinity — an uncatchable
        // crash while writing to Health.
        let samples = [sample(0, mets: .nan), sample(60, mets: .infinity)]
        XCTAssertTrue(
            HealthKitWorkoutExport.activeEnergySamples(from: samples, clock: clock, bodyWeightKg: 75).isEmpty
        )
    }

    func testNegativeMETsAreRejected() {
        let samples = [sample(0, mets: -5), sample(60, mets: -5)]
        XCTAssertTrue(
            HealthKitWorkoutExport.activeEnergySamples(from: samples, clock: clock, bodyWeightKg: 75).isEmpty
        )
    }

    // MARK: - Pauses

    /// A ten-minute pause at active second 15. `offsetSec` stops while
    /// paused, so every tick after it belongs ten minutes later on the wall
    /// clock than its offset says.
    private var pausedClock: WorkoutWallClock {
        WorkoutWallClock(startDate: start, pauseSpans: [WorkoutPauseSpan(atElapsed: 15, seconds: 600)])
    }

    func testHeartRateAfterAPauseSitsAtItsWallClockMoment() {
        let samples = [sample(10, hr: 120), sample(15, hr: 125), sample(20, hr: 140)]
        let out = HealthKitWorkoutExport.heartRateSamples(from: samples, clock: pausedClock)
        XCTAssertEqual(out.map(\.startDate), [10, 15, 620].map { start.addingTimeInterval($0) })
    }

    /// The span the pause interrupted starts where the workout resumed, so
    /// no distance is spread over the paused minutes.
    func testDistanceAfterAPauseNeverSpansThePause() {
        let samples = [sample(10, distance: 50), sample(15, distance: 75), sample(20, distance: 100)]
        let out = HealthKitWorkoutExport.distanceSamples(from: samples, sport: .run, clock: pausedClock)
        XCTAssertEqual(out.map(\.startDate), [0, 10, 615].map { start.addingTimeInterval($0) })
        XCTAssertEqual(out.map(\.endDate), [10, 15, 620].map { start.addingTimeInterval($0) })
        XCTAssertEqual(out.map { $0.quantity.doubleValue(for: .meter()) }, [50, 25, 25])
    }

    /// Energy is worked out over the active seconds, and its sample sits
    /// after the pause, not across it.
    func testEnergyAfterAPauseNeverSpansThePause() {
        let samples = [sample(10, mets: 8), sample(20, mets: 8)]
        let paused = HealthKitWorkoutExport.activeEnergySamples(from: samples, clock: pausedClock, bodyWeightKg: 75)
        let unpaused = HealthKitWorkoutExport.activeEnergySamples(from: samples, clock: clock, bodyWeightKg: 75)
        XCTAssertEqual(paused.map(\.startDate), [0, 615].map { start.addingTimeInterval($0) })
        XCTAssertEqual(paused.map(\.endDate), [10, 620].map { start.addingTimeInterval($0) })
        XCTAssertEqual(
            paused.map { $0.quantity.doubleValue(for: .kilocalorie()) },
            unpaused.map { $0.quantity.doubleValue(for: .kilocalorie()) }
        )
    }

    func testEachPauseBecomesAPauseAndAResumeEvent() {
        let twoPauses = WorkoutWallClock(startDate: start, pauseSpans: [
            WorkoutPauseSpan(atElapsed: 30, seconds: 60), WorkoutPauseSpan(atElapsed: 15, seconds: 600)
        ])
        let events = HealthKitWorkoutExport.pauseEvents(of: twoPauses, endDate: start.addingTimeInterval(3600))
        XCTAssertEqual(events.map(\.type), [.pause, .resume, .pause, .resume])
        XCTAssertEqual(events.map(\.dateInterval.start), [15, 615, 630, 690].map { start.addingTimeInterval($0) })
        XCTAssertTrue(events.allSatisfy { $0.dateInterval.duration == 0 })
    }

    /// Stopped while paused: the pause runs to the end, with no resume.
    func testAPauseStillRunningAtTheEndGetsNoResume() {
        let events = HealthKitWorkoutExport.pauseEvents(of: pausedClock, endDate: start.addingTimeInterval(400))
        XCTAssertEqual(events.map(\.type), [.pause])
        XCTAssertTrue(HealthKitWorkoutExport.pauseEvents(of: pausedClock, endDate: start.addingTimeInterval(15)).isEmpty)
    }

    func testAWorkoutWithoutPausesHasNoPauseEvents() {
        XCTAssertTrue(HealthKitWorkoutExport.pauseEvents(of: clock, endDate: start.addingTimeInterval(600)).isEmpty)
    }
}
