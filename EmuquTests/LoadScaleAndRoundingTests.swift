@testable import Emuqu
import XCTest

/// Quantities on different scales are never added or compared as one, and a
/// measured value shown or stored as a whole number is rounded, not
/// truncated.
///
/// Training load: power TSS, hrTSS and the METs load put 100 at one hour at
/// threshold; Banister TRIMP puts that hour near 150. Every TRIMP-scale
/// figure goes through the hrTSS rule before it meets a TSS, so an Apple
/// Health workout counts the same as the strap's recording of the same effort.
final class LoadScaleAndRoundingTests: XCTestCase {
    private let anchors = TrainingLoadSeries.HeartRateAnchors(restingHR: 50, maxHR: 185, lthr: 165)

    private func healthWorkout(avgHR: Double, load: Double? = nil, source: WorkoutMetadata.TrainingLoadSource? = nil) -> HealthKitManager.WorkoutSummary {
        HealthKitManager.WorkoutSummary(
            date: Date(), type: .running, durationMinutes: 60, caloriesBurned: nil, averageHR: avgHR, maxHR: nil,
            precomputedLoad: load, precomputedLoadSource: source?.rawValue
        )
    }

    /// An hour of beats at a steady `bpm`, the strap's recording of it.
    private func strapHour(bpm: Int) -> [RRPoint] {
        let rr = 60_000 / bpm
        return (0 ..< 3_600_000 / rr).map { RRPoint(t_ms: Int64($0 * rr), rr_ms: rr) }
    }

    // MARK: - One training-load scale

    func testAHealthWorkoutScoresTheStrapsHrTSSForTheSameSteadyHour() throws {
        for bpm in [100, 120, 150, 160] {
            let strap = try XCTUnwrap(WorkoutAnalyzer.computeHrTSS(
                rrPoints: strapHour(bpm: bpm), userMaxHR: 185, userRestingHR: 50, userLTHR: 165,
                sex: anchors.sex
            ))
            XCTAssertEqual(healthWorkout(avgHR: Double(bpm)).effectiveLoad(anchors: anchors), strap, accuracy: 0.01, "\(bpm) bpm")
        }
    }

    func testAnHourAtThresholdFromHealthIsOneHundred() {
        XCTAssertEqual(healthWorkout(avgHR: 165).effectiveLoad(anchors: anchors), 100, accuracy: 1e-6)
    }

    func testOnlyTheTRIMPScaleTiersAreConverted() {
        let cases: [(WorkoutMetadata.TrainingLoadSource, Bool)] = [
            (.power, false), (.hr, false), (.mets, false), (.banister, true), (.routeHistory, true)
        ]
        for (source, converted) in cases {
            XCTAssertEqual(source.isTRIMPScale, converted, source.rawValue)
            let expected = converted ? anchors.tss(fromTRIMP: 150) : 150
            XCTAssertEqual(healthWorkout(avgHR: 140, load: 150, source: source).effectiveLoad(anchors: anchors), expected, accuracy: 1e-9, source.rawValue)
        }
        XCTAssertLessThan(anchors.tss(fromTRIMP: 150), 110)
    }

    func testTheShownLoadOfAStoredTRIMPIsOnTheTSSScale() throws {
        var banister = WorkoutMetadata(sport: .run)
        banister.luciaTRIMP = 150
        let shown = try XCTUnwrap(banister.preferredTrainingLoad(ftp: .none, heartRate: anchors))
        XCTAssertEqual(shown.source, .banister)
        XCTAssertEqual(shown.value, anchors.tss(fromTRIMP: 150), accuracy: 1e-9)
        var strap = WorkoutMetadata(sport: .run)
        strap.hrTSS = 90
        XCTAssertEqual(try XCTUnwrap(strap.preferredTrainingLoad(ftp: .none, heartRate: anchors)).value, 90)
    }

    /// The conversion is anchored to the user's own LTHR and sex, the ones
    /// the strap's hrTSS divides by.
    func testTheAnchorsCarryTheUsersLTHRAndSex() {
        let resolved = TrainingLoadSeries.HeartRateAnchors.resolve(
            appleRestingHR: nil, settingRestingHR: 50, settingMaxHR: 185, settingLTHR: 170, settingSex: .female
        )
        XCTAssertEqual(resolved.lthr, 170)
        XCTAssertEqual(resolved.sex, .female)
        XCTAssertEqual(TrainingLoadSeries.HeartRateAnchors(restingHR: 50, maxHR: 185).lthr, 185 * 0.88, accuracy: 1e-9)
    }

    func testEverySourceIsLabelledAsOneLoad() {
        let sources: [WorkoutMetadata.TrainingLoadSource] = [.power, .hr, .mets, .banister, .routeHistory]
        XCTAssertEqual(Set(sources.map(\.displayLabel)).count, 1)
    }

    /// A cache saved before LTHR was part of the load settings reads as a
    /// settings change, so its old-scale numbers are rebuilt.
    func testACacheSavedWithoutLTHRReadsAsChangedSettings() throws {
        let current = TrainingMetricsCache.LoadSettings(UserSettings())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        json.removeValue(forKey: "lthr")
        let old = try JSONDecoder().decode(TrainingMetricsCache.LoadSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.lthr, TrainingMetricsCache.LoadSettings.unrecorded)
        XCTAssertNotEqual(old, current)
    }

    // MARK: - Thresholds on the TSS scale

    /// The "has a fitness base" boundary was 3.2 on the TRIMP scale; an hour
    /// at threshold is 100 TSS and about 152 TRIMP at the default anchors.
    func testTheFitnessBaseBoundaryIsOnTheTSSScale() {
        XCTAssertEqual(RecoveryScoreConstants.Readiness.ctlThreshold, 3.2 / 1.52, accuracy: 0.01)
        XCTAssertEqual(
            TrainingLoadSeries.HeartRateAnchors(restingHR: 60, maxHR: 180).tss(fromTRIMP: 152), 100, accuracy: 0.5,
            "the factor the thresholds are converted at"
        )
    }

    /// The Deep Dive CTL bands are the TrainingPeaks ranges in TSS per day.
    func testTheCTLBandsAreTheTrainingPeaksRanges() {
        let renderer = DeepDiveReportRenderer(generator: PDFReportGenerator(settingsProvider: { UserSettings() }))
        let words = [15.0, 30, 55, 85, 110].map(renderer.interpretCTL)
        XCTAssertEqual(Set(words).count, 5, "one band each side of 20, 40, 70 and 100")
        XCTAssertEqual(renderer.interpretCTL(65), renderer.interpretCTL(45), "65 TSS/day is consistent training, not high")
        XCTAssertEqual(renderer.interpretCTL(99), renderer.interpretCTL(71))
    }

    // MARK: - One energy figure

    /// Ten minutes at 8 METs for 70 kg is 7 METs above rest: 7 x 3.5 x 70 x 10 / 200.
    func testEveryCalorieFigureIsActiveEnergy() throws {
        let samples = (1 ... 600).map { WorkoutSample(offsetSec: $0, heartRate: nil, mets: 8) }
        let kcal = try XCTUnwrap(WorkoutEnergy.activeKilocalories(samples: samples, bodyWeightKg: 70))
        XCTAssertEqual(kcal, 7 * 3.5 * 70 * 10 / 200, accuracy: 1e-9)
        let snapshot = WorkoutAnalysisSnapshotBuilder.build(.init(
            sport: .run, durationSec: 600, distanceMeters: 2_000, elevationGainMeters: nil, elevationLossMeters: nil,
            meanHR: nil, userMaxHR: 190, bodyWeightKg: 70, samples: samples, splits: [], load: nil, decouplingPercent: nil
        ))
        XCTAssertEqual(try XCTUnwrap(snapshot.estimatedTotalCalories), kcal, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(snapshot.calorieRatePerHour), kcal * 6, accuracy: 1e-9)
    }

    // MARK: - Rounded, not truncated

    func testMeasuredValuesRoundToTheNearestWholeNumber() {
        let beats = [RRPoint(t_ms: 0, rr_ms: 406), RRPoint(t_ms: 406, rr_ms: 406)]
        XCTAssertEqual(beats.medianHeartRateBPM, 148, "60000 / 406 = 147.8 bpm")
        XCTAssertEqual(GPSAccuracyLevel.displayMetres(4.6), 5)
        XCTAssertEqual(UnitsPreference.metric.formatPace(secondsPerMeter: 0.3076), UnitsPreference.metric.formatPace(secondsPerMeter: 0.308))
    }
}
