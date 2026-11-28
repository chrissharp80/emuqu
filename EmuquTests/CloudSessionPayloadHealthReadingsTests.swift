@testable import Emuqu
import HealthKit
import XCTest

/// No reading taken from Apple Health survives `CloudSessionPayload.uploadable`,
/// wherever in a session it sits; the scores computed from those readings do.
/// A device that already holds the session gets every stripped reading back
/// when a newer iCloud copy replaces it.
@MainActor
final class CloudSessionPayloadHealthReadingsTests: XCTestCase {
    private let earlier = Date(timeIntervalSince1970: 1_800_000_000)
    private let later = Date(timeIntervalSince1970: 1_800_028_800)

    // MARK: - Overnight session

    func testUploadableCarriesNoHealthReadingsFromAFullyPopulatedNight() throws {
        let payload = CloudSessionPayload.uploadable(makeNight())
        let analysis = try XCTUnwrap(payload.analysisResult)

        XCTAssertNil(payload.sleepSnapshot)
        XCTAssertNil(payload.vitalsSnapshot)
        XCTAssertNil(payload.sleepStartMs)
        XCTAssertNil(payload.sleepEndMs)
        XCTAssertNil(payload.sleepSegments)
        XCTAssertNil(payload.sleepUserAdjusted)
        XCTAssertNil(payload.trainingSnapshot?.vo2Max)
        XCTAssertNil(payload.trainingSnapshot?.recentWorkouts)
        XCTAssertNil(analysis.trainingContext?.vo2Max)
        XCTAssertNil(analysis.trainingContext?.recentWorkouts)
        XCTAssertNil(analysis.ansMetrics?.daytimeRestingHR)
        XCTAssertNil(analysis.analysisSegmentLabel)
        XCTAssertNil(payload.autoWindowResult)
        XCTAssertEqual(payload.scoreBreakdown?.spo2PenaltyApplied, false)
        XCTAssertEqual(payload.scoreBreakdown?.penalties, ["No sleep data (−5)"])
        XCTAssertEqual(payload.scoreBreakdown?.factors.first { $0.label == "Vitals" }?.detail, "")
        XCTAssertEqual(payload.scoreBreakdown?.factors.first { $0.label == "Sleep" }?.detail, "")
        XCTAssertNil(payload.scoreBreakdown?.factors.first { $0.label == "Sleep" }?.facts)
    }

    /// What the app computed stays, whatever it was computed from.
    func testUploadableKeepsTheScores() throws {
        let night = makeNight()
        let payload = CloudSessionPayload.uploadable(night)
        let analysis = try XCTUnwrap(payload.analysisResult)

        XCTAssertEqual(payload.recoveryScore, night.recoveryScore)
        XCTAssertEqual(payload.frozenReadiness, night.frozenReadiness)
        XCTAssertEqual(payload.scoreBreakdown?.compositeScore, 62)
        XCTAssertEqual(payload.scoreBreakdown?.factors.first { $0.label == "Vitals" }?.score, 55)
        XCTAssertEqual(analysis.trainingContext?.ctl, 50)
        XCTAssertEqual(analysis.ansMetrics?.nocturnalHRDip, 12)
        XCTAssertEqual(analysis.ansMetrics?.nocturnalMedianHR, 57)
        XCTAssertEqual(analysis.timeDomain.rmssd, night.analysisResult?.timeDomain.rmssd)
        XCTAssertEqual(analysis.overnightNadirHR, 49)
        XCTAssertEqual(payload.rrSeries?.points.count, night.rrSeries?.points.count)
    }

    func testReplacementRestoresEveryStrippedReadingOfTheNight() throws {
        let local = makeNight()
        var remote = CloudSessionPayload.uploadable(local)
        remote.notes = "edited elsewhere"

        let merged = CloudKitSessionFreshness.replacing(local, with: remote)
        let analysis = try XCTUnwrap(merged.analysisResult)

        XCTAssertEqual(merged.notes, "edited elsewhere")
        XCTAssertEqual(analysis.trainingContext?.vo2Max, 52)
        XCTAssertEqual(analysis.trainingContext?.recentWorkouts?.count, 1)
        XCTAssertEqual(analysis.ansMetrics?.daytimeRestingHR, 65)
        XCTAssertEqual(analysis.analysisSegmentLabel, "Segment 2 (6:30–9:00 AM)")
        XCTAssertEqual(merged.scoreBreakdown?.spo2PenaltyApplied, true)
        XCTAssertEqual(merged.scoreBreakdown?.penalties, local.scoreBreakdown?.penalties)
        XCTAssertEqual(merged.vitalsSnapshot, local.vitalsSnapshot)
        let sleep = merged.scoreBreakdown?.factors.first { $0.label == "Sleep" }
        XCTAssertEqual(sleep?.detail, "7.0 h asleep")
        XCTAssertEqual(sleep?.facts, local.scoreBreakdown?.factors.first { $0.label == "Sleep" }?.facts)
    }

    /// A reanalysis on another device is a different analysis: its own label
    /// and resting heart rate are not taken from this device's older one.
    func testReplacementByADifferentAnalysisKeepsOnlyTheFrozenTrainingContext() throws {
        let local = makeNight()
        var remote = CloudSessionPayload.uploadable(local)
        remote.analysisResult = remote.analysisResult.map { result in
            HRVAnalysisResult(
                windowStart: result.windowStart + 50, windowEnd: result.windowEnd + 50, timeDomain: result.timeDomain,
                frequencyDomain: result.frequencyDomain, nonlinear: result.nonlinear, ansMetrics: result.ansMetrics,
                artifactPercentage: result.artifactPercentage, cleanBeatCount: result.cleanBeatCount,
                analysisDate: later, trainingContext: result.trainingContext
            )
        }

        let merged = CloudKitSessionFreshness.replacing(local, with: remote)

        XCTAssertNil(merged.analysisResult?.analysisSegmentLabel)
        XCTAssertNil(merged.analysisResult?.ansMetrics?.daytimeRestingHR)
        XCTAssertEqual(merged.analysisResult?.trainingContext?.vo2Max, 52)
    }

    /// A composite that changed is not explained by the old SpO₂ line.
    func testSpO2LineIsNotRestoredOntoADifferentComposite() {
        let local = makeNight()
        var remote = CloudSessionPayload.uploadable(local)
        remote.scoreBreakdown = remote.scoreBreakdown.map {
            RecoveryScoreCalculator.ScoreBreakdown(
                compositeScore: 70, tier: $0.tier, factors: $0.factors, penalties: $0.penalties, spo2PenaltyApplied: false
            )
        }

        let merged = CloudKitSessionFreshness.replacing(local, with: remote)

        XCTAssertEqual(merged.scoreBreakdown?.spo2PenaltyApplied, false)
        XCTAssertEqual(merged.scoreBreakdown?.penalties, ["No sleep data (−5)"])
    }

    /// A record scored before the lines were localized names the SpO₂ line in
    /// English, wherever it sits.
    func testEnglishSpO2LineIsFoundByItsText() {
        var night = makeNight()
        night.scoreBreakdown = RecoveryScoreCalculator.ScoreBreakdown(
            compositeScore: 62, tier: 3, factors: [], penalties: ["No sleep data (-5)", "Low blood oxygen (-10)"]
        )

        let payload = CloudSessionPayload.uploadable(night)

        XCTAssertEqual(payload.scoreBreakdown?.penalties, ["No sleep data (-5)"])
        XCTAssertEqual(payload.scoreBreakdown?.spo2PenaltyApplied, false)
    }

    // MARK: - Apple Watch workout

    func testUploadableCarriesNoAppleWatchHeartRate() throws {
        let payload = CloudSessionPayload.uploadable(makeWatchWorkout())
        let workout = try XCTUnwrap(payload.workoutMetadata)

        XCTAssertEqual(workout.samples?.compactMap(\.heartRate), [])
        XCTAssertEqual(workout.splits?.compactMap(\.averageHR), [])
        XCTAssertEqual(workout.laps?.compactMap(\.averageHR), [])
        XCTAssertEqual(workout.laps?.compactMap(\.maxHR), [])
        XCTAssertNil(payload.aiContext?["hr"])
        XCTAssertNil(payload.aiContext?["peak_hr"])
        XCTAssertNil(workout.hrrSamples)
        XCTAssertEqual(payload.aiContext?["sport"], "run")
        XCTAssertEqual(workout.luciaTRIMP, 85)
        XCTAssertEqual(workout.splits?.first?.distanceMeters, 1_000)
    }

    func testReplacementRestoresTheWatchHeartRate() {
        let local = makeWatchWorkout()
        var remote = CloudSessionPayload.uploadable(local)
        remote.notes = "edited elsewhere"

        let merged = CloudKitSessionFreshness.replacing(local, with: remote)

        XCTAssertEqual(merged.workoutMetadata?.samples?.compactMap(\.heartRate), [140, 150])
        XCTAssertEqual(merged.workoutMetadata?.splits?.compactMap(\.averageHR), [145])
        XCTAssertEqual(merged.workoutMetadata?.laps?.compactMap(\.maxHR), [158])
        XCTAssertEqual(merged.workoutMetadata?.hrrSamples?.count, 1)
        XCTAssertEqual(merged.aiContext?["hr"], "150")
        XCTAssertEqual(merged.aiContext?["peak_hr"], "158")
    }

    /// A strap workout's own heart rate travels; only rows Apple Health filled
    /// are cleared.
    func testStrapWorkoutKeepsItsOwnHeartRate() {
        var workout = makeWatchWorkout()
        workout.deviceProvenance = provenance("H10-1234")
        workout.workoutMetadata?.healthKitHROffsets = [1]
        workout.aiContext = ["sport": "run", "hr": "150", "hr_source": "strap", "peak_hr": "158", "peak_hr_source": "strap"]

        let payload = CloudSessionPayload.uploadable(workout)

        XCTAssertEqual(payload.workoutMetadata?.samples?.map(\.heartRate), [140, nil])
        XCTAssertEqual(payload.workoutMetadata?.splits?.first?.averageHR, 145)
        XCTAssertEqual(payload.aiContext?["hr"], "150")
        XCTAssertEqual(payload.aiContext?["peak_hr"], "158")
    }

    // MARK: - Strap workout that fell back to the Watch

    /// A Polar workout whose strap went silent shows the Watch's wrist HR for
    /// a stretch: every value taken from it stays on the device, and every
    /// value the strap measured travels.
    func testMixedSourceWorkoutUploadsNoWatchValueAndKeepsStrapValues() throws {
        let payload = CloudSessionPayload.uploadable(makeMixedWorkout())
        let workout = try XCTUnwrap(payload.workoutMetadata)

        XCTAssertEqual(workout.samples?.map(\.heartRate), [140, nil, nil, 150])
        XCTAssertEqual(workout.healthKitHROffsets, [1, 2])
        XCTAssertNil(payload.aiContext?["peak_hr"], "the peak was the wrist HR")
        XCTAssertEqual(payload.aiContext?["hr"], "150", "the strap measured the last reading")
        XCTAssertNil(workout.analysisSnapshot?.firstAT1CrossingHR)
        XCTAssertNil(workout.analysisSnapshot?.heroNarrative)
        XCTAssertEqual(workout.analysisSnapshot?.needsRebuild, true, "each device writes the narrative from its own heart rate")
        XCTAssertEqual(workout.laps?.map(\.averageHR), [nil, 148])
        XCTAssertEqual(workout.splits?.first?.averageHR, 145, "splits average the strap's own beats")
        XCTAssertEqual(workout.hrrSamples?.map(\.provenance), [.strap])
        XCTAssertEqual(workout.luciaTRIMP, 85)
    }

    /// Each heart-rate field of a workout, for a strap-only, a mixed-source
    /// and a Watch workout: whether the upload keeps the value.
    func testHeartRateFieldsTravelOnlyWhenTheStrapMeasuredThem() throws {
        typealias Field = (name: String, read: (HRVSession) -> Bool)
        let fields: [Field] = [
            ("row 1 HR", { $0.workoutMetadata?.samples?[1].heartRate != nil }),
            ("ai hr", { $0.aiContext?["hr"] != nil }),
            ("ai peak_hr", { $0.aiContext?["peak_hr"] != nil }),
            ("crossing HR", { $0.workoutMetadata?.analysisSnapshot?.firstAT1CrossingHR != nil }),
            ("lap 1 HR", { $0.workoutMetadata?.laps?.first?.averageHR != nil }),
            ("split HR", { $0.workoutMetadata?.splits?.first?.averageHR != nil })
        ]
        let rows: [(name: String, session: HRVSession, kept: [Bool])] = [
            ("strap only", makeStrapOnlyWorkout(), [true, true, true, true, true, true]),
            ("mixed", makeMixedWorkout(), [false, true, false, false, false, true]),
            ("watch", makeWatchSourcedMixedShape(), [false, false, false, false, false, false])
        ]
        for row in rows {
            let payload = CloudSessionPayload.uploadable(row.session)
            for (field, kept) in zip(fields, row.kept) {
                XCTAssertEqual(field.read(payload), kept, "\(row.name): \(field.name)")
            }
        }
    }

    /// A workout's AI snapshot stored before the heart rate's source was
    /// recorded may hold the wrist HR the display fell back to: its heart
    /// rate stays on the device.
    func testUnmarkedHeartRateInTheAISnapshotStaysOnTheDevice() {
        var workout = makeStrapOnlyWorkout()
        workout.aiContext = ["sport": "run", "hr": "150", "peak_hr": "158"]

        let payload = CloudSessionPayload.uploadable(workout)

        XCTAssertNil(payload.aiContext?["hr"])
        XCTAssertNil(payload.aiContext?["peak_hr"])
        XCTAssertEqual(payload.aiContext?["sport"], "run")
    }

    /// A Watch workout stored before its rows were listed: every row's heart
    /// rate is the Watch's, and the copy lists them so the replacement puts
    /// this device's heart rate back.
    func testWatchWorkoutWithoutARowListUploadsNoRowHeartRate() {
        var local = makeWatchWorkout()
        local.workoutMetadata?.healthKitHROffsets = nil

        let remote = CloudSessionPayload.uploadable(local)
        let merged = CloudKitSessionFreshness.replacing(local, with: remote)

        XCTAssertEqual(remote.workoutMetadata?.samples?.compactMap(\.heartRate), [])
        XCTAssertEqual(remote.workoutMetadata?.healthKitHROffsets, [0, 1])
        XCTAssertEqual(merged.workoutMetadata?.samples?.compactMap(\.heartRate), [140, 150])
    }

    /// The replacement puts back this device's wrist values the upload left out.
    func testReplacementRestoresTheMixedWorkoutsWatchValues() {
        let local = makeMixedWorkout()
        var remote = CloudSessionPayload.uploadable(local)
        remote.notes = "edited elsewhere"

        let merged = CloudKitSessionFreshness.replacing(local, with: remote)

        XCTAssertEqual(merged.workoutMetadata?.samples?.map(\.heartRate), [140, 171, 172, 150])
        XCTAssertEqual(merged.aiContext?["peak_hr"], "172")
        XCTAssertEqual(merged.workoutMetadata?.analysisSnapshot?.firstAT1CrossingHR, 171)
        XCTAssertEqual(merged.workoutMetadata?.analysisSnapshot?.heroNarrative, "Crossed at 171 bpm")
        XCTAssertEqual(merged.workoutMetadata?.laps?.first?.averageHR, 160)
    }

    /// The health scrub's list: without the previous list's progress or the archive's index, every
    /// uploaded id is rewritten.
    func testHealthScrubIdsToRewriteTable() {
        let (workout, night, pending) = (UUID(), UUID(), UUID())
        let uploaded: Set<UUID> = [workout, night, pending]
        let all = uploaded.map(\.uuidString).sorted()
        let rows: [(previous: Set<String>?, workouts: Set<UUID>?, expected: [String])] = [
            (nil, [workout], all),
            ([pending.uuidString], nil, all),
            ([pending.uuidString], [workout], [workout, pending].map(\.uuidString).sorted()),
            ([], [workout], [workout.uuidString]),
            ([], [], [])
        ]
        for row in rows {
            XCTAssertEqual(
                CloudHealthScrubCoordinator.idsToRewrite(uploaded: uploaded, previousRemaining: row.previous, workoutIds: row.workouts),
                row.expected
            )
        }
    }

    // MARK: - Copies keep every field

    /// `withANSMetrics` rebuilds the result field by field; this fixture sets
    /// every field, so a field the copy leaves out changes the encoding.
    func testCopyWithTheSameMetricsIsIdentical() throws {
        let result = makeFullAnalysis()
        let unset = Mirror(reflecting: result).children.filter { child in
            if case Optional<Any>.none = child.value { return true }
            return false
        }
        XCTAssertEqual(unset.map(\.label), [], "Set every field so the copy below is checked for it")

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertEqual(
            try encoder.encode(result.withANSMetrics(result.ansMetrics)), try encoder.encode(result)
        )
    }

    // MARK: - Settings record

    func testStoredSettingsLoseTheProfileValuesFilledFromHealth() throws {
        var local = UserSettings()
        let profile = HealthBiometricProfile(bodyWeightKg: 70, biologicalSex: .female, dateOfBirth: earlier)
        _ = BiometricsSettingsPage.fill(&local, from: profile)
        var stored = UserSettings()
        stored.birthday = earlier
        stored.biologicalSex = .female
        stored.bodyWeightKg = 82

        let scrubbed = try decode(CloudSettingsRecord.scrubbed(encode(stored), markedBy: local))

        XCTAssertNil(scrubbed.birthday)
        XCTAssertNil(scrubbed.biologicalSex)
        XCTAssertEqual(scrubbed.bodyWeightKg, 82, "A value that differs from Health's was entered by hand")
        XCTAssertEqual(scrubbed.profileFieldsFromHealth, [.birthday, .biologicalSex])
    }

    // MARK: - Fixtures

    private func makeNight() -> HRVSession {
        var night = HRVSession(
            id: UUID(), startDate: earlier, endDate: later, state: .complete,
            rrSeries: SnapshotFixtures.rrSeries(), analysisResult: makeFullAnalysis(), artifactFlags: nil
        )
        night.recoveryScore = 6.2
        night.frozenReadiness = 6.8
        night.sleepSnapshot = SleepData(
            date: earlier, totalSleepMinutes: 420, inBedMinutes: 460, deepSleepMinutes: 90, remSleepMinutes: 80,
            awakeMinutes: 20, sleepEfficiency: 91, boundarySource: .recordingBounds
        )
        night.vitalsSnapshot = RecoveryVitals(
            respiratoryRate: 14, respiratoryRateBaseline: 14.5, oxygenSaturation: 93, oxygenSaturationMin: 90,
            wristTemperature: 0.2, wristTemperatureBaseline: 0, restingHeartRate: 52
        )
        night.sleepStartMs = 600_000
        night.sleepEndMs = 25_000_000
        night.sleepUserAdjusted = true
        night.trainingSnapshot = makeTraining()
        night.autoWindowResult = makeFullAnalysis()
        night.scoreBreakdown = RecoveryScoreCalculator.ScoreBreakdown(
            compositeScore: 62, tier: 3,
            factors: [
                .init(label: "HRV", detail: "RMSSD 45 ms", score: 75, weight: 0.6, impact: .positive),
                .init(label: "Vitals", detail: "SpO₂ 93%", score: 55, weight: 0.15, impact: .negative),
                .init(
                    label: "Sleep", detail: "7.0 h asleep", score: 70, weight: 0.25, impact: .neutral,
                    facts: ScoreFactorFacts(sleep: .init(score: 70, hours: 7, creditedHours: 7, efficiency: 91, target: 8))
                )
            ],
            penalties: ["Low blood oxygen (−10)", "No sleep data (−5)"], spo2PenaltyApplied: true
        )
        return night
    }

    private func makeFullAnalysis() -> HRVAnalysisResult {
        var result = SnapshotFixtures.analysisResult()
        result.windowStartMs = 1_000
        result.windowEndMs = 301_000
        result.windowMeanHR = 58
        result.windowSelectionReason = "No consolidated recovery detected"
        result.windowRelativePosition = 0.5
        result.isOrganizedRecovery = true
        result.windowClassification = "Organized Recovery"
        result.organizedRecoveryZones = [.init(startMs: 1_000, endMs: 301_000)]
        result.peakCapacity = PeakCapacity(
            peakRMSSD: 60, peakSDNN: 70, peakTotalPower: 2_500, windowDurationMinutes: 5,
            windowRelativePosition: 0.4, windowMeanHR: 55
        )
        result.trainingContext = makeTraining()
        result.analysisSegmentLabel = "Segment 2 (6:30–9:00 AM)"
        result.isReanalysis = false
        result.overnightNadirHR = 49
        result.overnightNadirTimeMs = 12_000_000
        result.overnightMinHR = 48
        result.overnightMaxHR = 80
        result.overnightMeanHR = 56
        result.estimatedMetrics = [EstimatedMetric.sdsd.rawValue]
        return result
    }

    private func makeTraining() -> TrainingContext {
        TrainingContext(
            atl: 40, ctl: 50, tsb: 10, yesterdayTrimp: 80, vo2Max: 52, daysSinceHardWorkout: 2,
            recentWorkouts: [WorkoutSnapshot(date: earlier, type: "Run", durationMinutes: 45, trimp: 80)]
        )
    }

    private func makeWatchWorkout() -> HRVSession {
        var session = HRVSession(
            id: UUID(), startDate: earlier, endDate: later, state: .complete,
            rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        session.sessionType = .workout
        session.deviceProvenance = provenance(CloudSessionPayload.appleWatchDeviceId)
        session.aiContext = ["sport": "run", "hr": "150", "peak_hr": "158"]
        var workout = WorkoutMetadata(sport: .run)
        workout.samples = [WorkoutSample(offsetSec: 0, heartRate: 140), WorkoutSample(offsetSec: 1, heartRate: 150)]
        workout.healthKitHROffsets = [0, 1]
        workout.splits = [Split(
            index: 1, distanceMeters: 1_000, durationSeconds: 300, averageHR: 145,
            averagePaceSecPerKm: 300, elevationGainMeters: 4, averageAlpha1: nil
        )]
        workout.laps = [Lap(
            index: 1, startOffsetSec: 0, endOffsetSec: 300, distanceMeters: 1_000,
            averageHR: 145, maxHR: 158, averagePaceSecPerKm: 300
        )]
        workout.hrrSamples = [HRRSample(offsetSec: 60, hr: 130, drop: 28, peakHR: 158, provenance: .watchSamples)]
        workout.luciaTRIMP = 85
        session.workoutMetadata = workout
        return session
    }

    /// A Polar workout with the strap silent over rows 1 and 2, where the
    /// display showed the Watch's wrist HR, which set the peak.
    private func makeMixedWorkout() -> HRVSession {
        var session = makeStrapOnlyWorkout()
        session.aiContext = ["sport": "run", "hr": "150", "hr_source": "strap", "peak_hr": "172", "peak_hr_source": "apple_watch"]
        session.workoutMetadata?.samples = [
            WorkoutSample(offsetSec: 0, heartRate: 140), WorkoutSample(offsetSec: 1, heartRate: 171),
            WorkoutSample(offsetSec: 2, heartRate: 172), WorkoutSample(offsetSec: 3, heartRate: 150)
        ]
        session.workoutMetadata?.healthKitHROffsets = [1, 2]
        session.workoutMetadata?.analysisSnapshot = WorkoutAnalysisSnapshot(
            firstAT1CrossingOffsetSec: 1, firstAT1CrossingHR: 171, heroNarrative: "Crossed at 171 bpm"
        )
        session.workoutMetadata?.hrrSamples = [
            HRRSample(offsetSec: 60, hr: 130, drop: 28, peakHR: 158, provenance: .strap),
            HRRSample(offsetSec: 120, hr: 120, drop: 38, peakHR: 158, provenance: .watchSamples)
        ]
        return session
    }

    /// A Polar workout the strap measured throughout.
    private func makeStrapOnlyWorkout() -> HRVSession {
        var session = makeWatchWorkout()
        session.deviceProvenance = provenance("H10-1234")
        session.aiContext = ["sport": "run", "hr": "150", "hr_source": "strap", "peak_hr": "158", "peak_hr_source": "strap"]
        session.workoutMetadata?.samples = [
            WorkoutSample(offsetSec: 0, heartRate: 140), WorkoutSample(offsetSec: 1, heartRate: 150),
            WorkoutSample(offsetSec: 2, heartRate: 152), WorkoutSample(offsetSec: 3, heartRate: 150)
        ]
        session.workoutMetadata?.healthKitHROffsets = nil
        session.workoutMetadata?.analysisSnapshot = WorkoutAnalysisSnapshot(
            firstAT1CrossingOffsetSec: 1, firstAT1CrossingHR: 150, heroNarrative: "Crossed at 150 bpm"
        )
        session.workoutMetadata?.laps = [
            Lap(index: 1, startOffsetSec: 0, endOffsetSec: 2, distanceMeters: 10, averageHR: 160, maxHR: 172, averagePaceSecPerKm: 300),
            Lap(index: 2, startOffsetSec: 3, endOffsetSec: 3, distanceMeters: 5, averageHR: 148, maxHR: 150, averagePaceSecPerKm: 300)
        ]
        session.workoutMetadata?.hrrSamples = [HRRSample(offsetSec: 60, hr: 130, drop: 28, peakHR: 158, provenance: .strap)]
        return session
    }

    /// The mixed workout's shape recorded with Apple Watch heart rate.
    private func makeWatchSourcedMixedShape() -> HRVSession {
        var session = makeMixedWorkout()
        session.deviceProvenance = provenance(CloudSessionPayload.appleWatchDeviceId)
        session.aiContext = ["sport": "run", "hr": "150", "hr_source": "apple_watch", "peak_hr": "172", "peak_hr_source": "apple_watch"]
        return session
    }

    private func provenance(_ deviceId: String) -> DeviceProvenance {
        DeviceProvenance(
            deviceId: deviceId, deviceModel: "Test", firmwareVersion: nil,
            recordingMode: .streaming, appVersion: "1", osVersion: "1", capturedAt: earlier
        )
    }

    private func encode(_ settings: UserSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(settings)
    }

    private func decode(_ json: Data) throws -> UserSettings {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UserSettings.self, from: json)
    }
}
