@testable import Emuqu
import XCTest

/// Where each live heart-rate value came from, recorded as the workout runs:
/// the peak, the AI snapshot's current and peak heart rate, the heart rate at
/// Stop and the recovery measured from it. The iCloud upload keeps a value
/// only when a strap measured it (`CloudSessionPayload`).
@MainActor
final class WatchHeartRateProvenanceTests: XCTestCase {
    /// A strap's recovery is measured from the heart rate at Stop; when that
    /// was the wrist HR, its drop is measured from Apple Watch heart rate.
    func testRecoveryMeasuredFromAWristStopHeartRateIsNotStrapOnly() {
        let samples = [
            HRRSample(offsetSec: 60, hr: 130, drop: 28, peakHR: 158, provenance: .strap),
            HRRSample(offsetSec: 120, hr: 120, drop: 38, peakHR: 158, provenance: .watchSamples)
        ]

        XCTAssertEqual(samples.measuredFromWatchStop(false), samples)
        XCTAssertEqual(samples.measuredFromWatchStop(true).map(\.provenance), [.watchSamples, .watchSamples])
        XCTAssertEqual(samples.measuredFromWatchStop(true).map(\.drop), [28, 38])
    }

    /// The live peak remembers whether the wrist HR set it.
    func testPeakRemembersWhetherTheWristSetIt() {
        let heartRate = WorkoutHR()
        heartRate.raisePeak(to: 150, fromWrist: false)
        heartRate.raisePeak(to: 172, fromWrist: true)
        XCTAssertTrue(heartRate.peakHRFromWrist)
        heartRate.raisePeak(to: 160, fromWrist: false)
        XCTAssertTrue(heartRate.peakHRFromWrist, "a lower strap reading does not set the peak")
        heartRate.raisePeak(to: 175, fromWrist: false)
        XCTAssertFalse(heartRate.peakHRFromWrist)
        XCTAssertEqual(CloudSessionPayload.heartRateSource(true), "apple_watch")
        XCTAssertEqual(CloudSessionPayload.heartRateSource(false), "strap")
    }

    func testAppleWatchDeviceIdIsTheOneTheRecorderStamps() {
        XCTAssertEqual(CloudSessionPayload.appleWatchDeviceId, "apple-watch")
    }

    /// The AI snapshot records each heart rate's source beside it.
    func testAISnapshotRecordsTheHeartRateSource() {
        var snap = live(heartRate: 150, peakHR: 172)
        snap.heartRateFromWatch = false
        snap.peakHRFromWatch = true
        let fields = Dictionary(
            WorkoutSessionLifecycle.optionalSnapshotFields(snap).compactMap { key, value in value.map { (key, $0) } },
            uniquingKeysWith: { first, _ in first }
        )

        XCTAssertEqual(fields["hr_source"], "strap")
        XCTAssertEqual(fields["peak_hr_source"], "apple_watch")
        let unrecorded = WorkoutSessionLifecycle.optionalSnapshotFields(live(heartRate: 150, peakHR: 172))
        XCTAssertEqual(unrecorded.filter { $0.0 == "hr_source" }.compactMap(\.1), [], "no source is written when none was recorded")
    }

    /// The heart rate at Stop is the wrist HR when the live reading was, or
    /// with no live reading when the last sampled row's heart rate was.
    func testStopHeartRateSourceTable() {
        // (live HR, live is wrist), (last sampled row, wrist rows), expected
        let rows: [((Int?, Bool), (Int?, [Int]), Bool)] = [
            ((160, true), (9, []), true),
            ((160, false), (9, [9]), false),
            ((nil, true), (9, [9]), true),
            ((nil, false), (9, [3]), false),
            ((0, true), (nil, []), false)
        ]
        for (liveHR, lastRow, expected) in rows {
            XCTAssertEqual(
                WorkoutRecorder.stopHeartRateIsWrist(
                    live: liveHR.0, liveFromWrist: liveHR.1, lastSampledOffset: lastRow.0, wristOffsets: lastRow.1
                ),
                expected, "\(liveHR) \(lastRow)"
            )
        }
    }

    private func live(heartRate: Int, peakHR: Int) -> AssistantContext.LiveWorkoutSnapshot {
        AssistantContext.LiveWorkoutSnapshot(
            sport: "Run", snapshotAt: Date(), sessionStartAt: Date().addingTimeInterval(-840), elapsedSeconds: 840, heartRate: heartRate, peakHR: peakHR, userMaxHR: 188,
            beatCount: 2_200, distanceMeters: 2_500, stepCount: 2_350, cadenceStepsPerMin: 168, elevationGainMeters: 18,
            alpha1: nil, alpha1Band: "Unknown", alpha1Status: "warmup", alpha1FitQualityR2: nil, strapConnected: true, strapSilentSec: nil,
            gpsFixCount: 84, gpsAccuracyMeters: 5, currentPaceSecPerKm: 330, currentSpeedMS: 2.9, powerWatts: nil, currentMETs: nil,
            recentSplitPaces: [328, 331], currentLatitude: nil, currentLongitude: nil, currentAltitudeMeters: nil,
            currentHeadingDegrees: nil, currentHeadingCardinal: nil, currentGradePercent: nil, unitsPreference: "metric", targetZone: nil
        )
    }
}
