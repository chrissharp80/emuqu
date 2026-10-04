import CoreLocation
@testable import Emuqu
import Foundation
import XCTest

/// Frozen inputs shared by the snapshot suites.
///
/// Every value here is a closed-form function of its index or a literal, and
/// every date is anchored. A snapshot built from `Date()` or from live settings
/// renders differently tomorrow, and a suite that fails for reasons unrelated
/// to the change under test is one people learn to ignore.
///
/// Centralised so the snapshot suites do not each grow their own copy of the
/// same session builder.
enum SnapshotFixtures {
    /// 08:00:00 UTC on 1 June 2021.
    static let anchor = Date(timeIntervalSince1970: 1_622_534_400)

    static let sessionId =
        UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE") ?? UUID()

    /// A plausible overnight RR series: respiratory sway, a slow downward HR
    /// drift, and two ectopic beats so artifact handling has something to draw.
    static func rrSeries(beats: Int = 600) -> RRSeries {
        var t: Int64 = 0
        var points: [RRPoint] = []
        for i in 0 ..< beats {
            let phase = Double(i) / 12.0
            let drift = 60.0 * (Double(i) / Double(beats))
            var rr = 950.0 + drift + 45.0 * sin(phase)
            if i == 200 || i == 401 { rr *= 0.55 }
            let ms = Int(rr.rounded())
            points.append(RRPoint(t_ms: t, rr_ms: ms))
            t += Int64(ms)
        }
        return RRSeries(points: points, sessionId: sessionId, startDate: anchor)
    }

    static func analysisResult() -> HRVAnalysisResult {
        var result = HRVAnalysisResult(
            windowStart: 100, windowEnd: 400,
            timeDomain: TimeDomainMetrics(
                meanRR: 60_000.0 / 58.0, sdnn: 54.0, rmssd: 45.0, pnn50: 20.0,
                sdsd: 42.75, meanHR: 58.0, sdHR: 3.0, triangularIndex: 12.0
            ),
            frequencyDomain: FrequencyDomainMetrics(
                vlf: 500, lf: 800, hf: 666.67, lfHfRatio: 1.2, totalPower: 2100
            ),
            nonlinear: NonlinearMetrics(
                sd1: 32.0, sd2: 48.0, sd1Sd2Ratio: 0.67,
                sampleEntropy: 1.5, approxEntropy: 1.2,
                dfaAlpha1: 0.95, dfaAlpha2: 0.85, dfaAlpha1R2: 0.95
            ),
            ansMetrics: ANSMetrics(
                stressIndex: 120, pnsIndex: 1.5, snsIndex: -0.5,
                readinessScore: 7.0, respirationRate: 14.0,
                nocturnalHRDip: 12.0, daytimeRestingHR: 65.0, nocturnalMedianHR: 57.0
            ),
            artifactPercentage: 3.0,
            cleanBeatCount: 290,
            analysisDate: anchor
        )
        result.isConsolidated = true
        result.isOrganizedRecovery = true
        result.windowHRStability = 0.04
        return result
    }

    /// A completed overnight reading with analysis attached.
    static func overnightSession(dayOffset: Int = 0) -> HRVSession {
        let start = anchor.addingTimeInterval(Double(dayOffset) * 86_400)
        var session = HRVSession(startDate: start, sessionType: .overnight)
        session.endDate = start.addingTimeInterval(8 * 3600)
        session.state = .complete
        session.rrSeries = rrSeries()
        session.analysisResult = analysisResult()
        session.recoveryScore = 72
        return session
    }

    /// A 40-minute run with a climb, an HR ramp and a decaying alpha-1.
    static func workoutSamples(count: Int = 240) -> [WorkoutSample] {
        (0 ..< count).map { i in
            let frac = Double(i) / Double(count)
            return WorkoutSample(
                offsetSec: i * 10,
                heartRate: Int(120 + 40 * frac),
                distanceMeters: Double(i) * 45,
                paceSecPerKm: 300 - 40 * frac,
                cadenceStepsPerMin: 168 + 6 * (frac - 0.5),
                altitudeMeters: 100 + 60 * frac,
                alpha1: 1.15 - 0.6 * frac,
                mets: 8 + 4 * frac,
                powerWatts: Int(220 + 60 * frac)
            )
        }
    }

    static func workoutSession() -> HRVSession {
        var meta = WorkoutMetadata(sport: .run)
        meta.samples = workoutSamples()
        meta.distanceMeters = 10_800
        meta.elevationGainMeters = 60
        meta.elevationLossMeters = 12
        var session = HRVSession(startDate: anchor, sessionType: .workout)
        session.endDate = anchor.addingTimeInterval(2_400)
        session.state = .complete
        session.workoutMetadata = meta
        return session
    }

    /// A short GPS track: a straight run east with a gentle climb.
    static func track(points: Int = 40) -> [CLLocation] {
        (0 ..< points).map { i in
            CLLocation(
                coordinate: CLLocationCoordinate2D(
                    latitude: 51.5074, longitude: -0.1278 + Double(i) * 0.0004
                ),
                altitude: 20 + Double(i) * 1.5,
                horizontalAccuracy: 5, verticalAccuracy: 8,
                timestamp: anchor.addingTimeInterval(Double(i) * 10)
            )
        }
    }
}

// MARK: - Detail-screen inputs

extension SnapshotFixtures {
    /// An overnight sleep record with a normal architecture split.
    static func sleepData() -> SleepData {
        SleepData(
            date: anchor,
            sleepStart: anchor.addingTimeInterval(600),
            sleepEnd: anchor.addingTimeInterval(8 * 3600),
            totalSleepMinutes: 400,
            inBedMinutes: 420,
            deepSleepMinutes: 80,
            remSleepMinutes: 90,
            awakeMinutes: 20,
            sleepEfficiency: 95,
            boundarySource: .recordingBounds
        )
    }

    /// Overnight vitals, each slightly off its baseline so the deltas render
    /// rather than collapsing to "no change".
    static func recoveryVitals() -> RecoveryVitals {
        RecoveryVitals(
            respiratoryRate: 14.2,
            respiratoryRateBaseline: 13.8,
            oxygenSaturation: 96.5,
            oxygenSaturationMin: 93.0,
            wristTemperature: 0.3,
            wristTemperatureBaseline: 0.0,
            restingHeartRate: 52.0
        )
    }
}

// MARK: - Hermetic environment

extension SnapshotFixtures {
    /// An empty archive no other suite writes to, so a screen that lists
    /// sessions renders the same picture whatever the shared archive holds.
    static let emptyArchiveDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SnapshotFixtures-EmptyArchive", isDirectory: true)

    /// A collector over `emptyArchiveDirectory` instead of the app's archive.
    @MainActor
    static func collector() -> RRCollector {
        RRCollector(
            polarManager: PolarManager(), healthKit: HealthKitManager(),
            archive: SessionArchive(directory: emptyArchiveDirectory)
        )
    }
}

extension XCTestCase {
    /// Puts `SettingsManager.shared` on fresh-install defaults for this test
    /// and restores the settings it found afterwards. The settings manager has
    /// no injectable instance, so this is how a snapshot stops depending on
    /// whatever the host's settings happen to be.
    @MainActor
    func useDefaultSettings() {
        let saved = SettingsManager.shared.settings
        SettingsManager.shared.settings = UserSettings()
        addTeardownBlock { @MainActor in SettingsManager.shared.settings = saved }
    }
}
