@testable import Emuqu
import HealthKit
import XCTest

/// What came from Apple Health is marked where it lands, so the iCloud upload
/// can leave it out: profile fields filled from Health, and workout heart-rate
/// rows filled from Apple Watch wrist HR.
@MainActor
final class HealthSourcedSyncMarkerTests: XCTestCase {

    // MARK: - Profile filled from Apple Health

    func testFillingFromHealthMarksEachFilledField() {
        var settings = UserSettings()
        let profile = HealthBiometricProfile(
            bodyWeightKg: 70, biologicalSex: .female, dateOfBirth: Date(timeIntervalSince1970: 0)
        )

        let filled = BiometricsSettingsPage.fill(&settings, from: profile)

        XCTAssertEqual(filled.count, 3)
        XCTAssertEqual(settings.bodyWeightKg, 70)
        XCTAssertEqual(settings.biologicalSex, .female)
        XCTAssertEqual(settings.birthday, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(settings.profileFieldsFromHealth, [.bodyWeight, .biologicalSex, .birthday])
    }

    /// A field the user already set is not overwritten and not marked.
    func testFillingFromHealthLeavesEnteredFieldsUnmarked() {
        var settings = UserSettings()
        settings.bodyWeightKg = 80
        let profile = HealthBiometricProfile(bodyWeightKg: 70, biologicalSex: .notSet, dateOfBirth: nil)

        let filled = BiometricsSettingsPage.fill(&settings, from: profile)

        XCTAssertTrue(filled.isEmpty)
        XCTAssertEqual(settings.bodyWeightKg, 80)
        XCTAssertTrue(settings.profileFieldsFromHealth.isEmpty)
    }

    /// Editing a filled field by hand makes it the user's own: the marker goes.
    func testEditingAFilledFieldClearsItsMarker() {
        var settings = UserSettings()
        let profile = HealthBiometricProfile(bodyWeightKg: 70, biologicalSex: .male, dateOfBirth: nil)
        _ = BiometricsSettingsPage.fill(&settings, from: profile)

        settings.bodyWeightKg = 72

        XCTAssertEqual(settings.profileFieldsFromHealth, [.biologicalSex])
        XCTAssertEqual(settings.withoutHealthFilledProfile().bodyWeightKg, 72)
        XCTAssertNil(settings.withoutHealthFilledProfile().biologicalSex)
    }

    // MARK: - Workout heart rate from Apple Health

    func testBackfilledRowsAreMarkedOnAStrapWorkout() {
        let samples = [WorkoutSample(offsetSec: 0, heartRate: 120), WorkoutSample(offsetSec: 1, heartRate: 121)]

        XCTAssertEqual(WorkoutFinalizer.healthKitHROffsets(samples: samples, backfilled: [1], source: .strap), [1])
        XCTAssertNil(WorkoutFinalizer.healthKitHROffsets(samples: samples, backfilled: [], source: .strap))
    }

    /// A Watch-sourced workout's heart rate is all wrist HR.
    func testEveryRowWithHeartRateIsMarkedOnAWatchWorkout() {
        let samples = [
            WorkoutSample(offsetSec: 0, heartRate: 120),
            WorkoutSample(offsetSec: 1),
            WorkoutSample(offsetSec: 2, heartRate: 122)
        ]

        XCTAssertEqual(WorkoutFinalizer.healthKitHROffsets(samples: samples, backfilled: [], source: .watch), [0, 2])
    }

    func testUploadClearsHeartRateOnMarkedRowsOnly() {
        let session = makeWorkoutSession()

        let payload = CloudSessionPayload.uploadable(session)

        XCTAssertEqual(payload.workoutMetadata?.samples?.map(\.heartRate), [120, nil, 122])
        XCTAssertEqual(payload.workoutMetadata?.samples?[1].distanceMeters, 5)
        XCTAssertEqual(payload.workoutMetadata?.healthKitHROffsets, [1])
    }

    func testPullKeepsThisDevicesHealthHeartRate() {
        let local = makeWorkoutSession()
        var remote = CloudSessionPayload.uploadable(local)
        remote.morningFeeling = 4

        let merged = CloudKitSessionFreshness.replacing(local, with: remote)

        XCTAssertEqual(merged.morningFeeling, 4)
        XCTAssertEqual(merged.workoutMetadata?.samples?.map(\.heartRate), [120, 140, 122])
    }

    /// A copy written before rows were marked keeps its values, and takes this
    /// device's list so the next upload strips them.
    func testPullOfAnUnmarkedCopyKeepsTheLocalMarkers() {
        let local = makeWorkoutSession()
        var remote = local
        remote.workoutMetadata?.healthKitHROffsets = nil

        let merged = CloudKitSessionFreshness.replacing(local, with: remote)

        XCTAssertEqual(merged.workoutMetadata?.healthKitHROffsets, [1])
        XCTAssertEqual(CloudSessionPayload.uploadable(merged).workoutMetadata?.samples?[1].heartRate, nil)
    }

    func testMarkersSurviveTheArchiveAndOlderRecordsDecode() throws {
        var metadata = WorkoutMetadata(sport: .run)
        metadata.healthKitHROffsets = [3, 4]
        let decoded = try JSONDecoder().decode(WorkoutMetadata.self, from: try JSONEncoder().encode(metadata))
        XCTAssertEqual(decoded.healthKitHROffsets, [3, 4])

        let older = try JSONDecoder().decode(WorkoutMetadata.self, from: Data("{\"sport\":\"run\"}".utf8))
        XCTAssertNil(older.healthKitHROffsets)
    }

    // MARK: - Fixtures

    private func makeWorkoutSession() -> HRVSession {
        var session = HRVSession(
            id: UUID(), startDate: Date(timeIntervalSince1970: 1_000), endDate: Date(timeIntervalSince1970: 4_600),
            state: .complete, rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        var workout = WorkoutMetadata(sport: .run)
        workout.samples = [
            WorkoutSample(offsetSec: 0, heartRate: 120),
            WorkoutSample(offsetSec: 1, heartRate: 140, distanceMeters: 5),
            WorkoutSample(offsetSec: 2, heartRate: 122)
        ]
        workout.healthKitHROffsets = [1]
        session.workoutMetadata = workout
        return session
    }
}
