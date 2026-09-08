@testable import Emuqu
import XCTest

/// `WorkoutAnalysisSnapshotBuilder` — the one-pass derivation that turns a
/// workout's raw sample stream into everything the post-summary and the PDF
/// display.
///
/// It was complexity-24 with **0% coverage** across 321 executable lines, and
/// it needed no surgery to test: it is already `Inputs → build()` with no I/O.
/// It was simply never exercised.
///
/// The behaviour worth pinning here is the α1 sustained-crossing detector. Its
/// warm-up and sustain windows exist because of a real user report — "my α1 LT1
/// says 121 bpm on a 120 bpm walk because of one ectopic beat" — and the
/// constants are load-bearing: the sustain must exceed the 120 s rolling α1
/// window, or a single ectopic beat's shadow reads as a genuine threshold
/// crossing.
final class WorkoutAnalysisSnapshotBuilderTests: XCTestCase {

    // MARK: - Fixtures

    private func sample(
        at offsetSec: Int,
        hr: Int? = nil,
        alpha1: Double? = nil,
        pace: Double? = nil,
        cadence: Double? = nil,
        mets: Double? = nil,
        distance: Double? = nil
    ) -> WorkoutSample {
        WorkoutSample(
            offsetSec: offsetSec,
            heartRate: hr,
            distanceMeters: distance,
            paceSecPerKm: pace,
            cadenceStepsPerMin: cadence,
            altitudeMeters: nil,
            alpha1: alpha1,
            mets: mets
        )
    }

    private func inputs(
        samples: [WorkoutSample],
        durationSec: TimeInterval = 1_800,
        distanceMeters: Double? = 5_000,
        userMaxHR: Int = 190,
        splits: [Split] = [],
        trimp: Double? = 80,
        decouplingPercent: Double? = nil,
        elevationGainMeters: Double? = nil
    ) -> WorkoutAnalysisSnapshotBuilder.Inputs {
        .init(
            sport: .run,
            durationSec: durationSec,
            distanceMeters: distanceMeters,
            elevationGainMeters: elevationGainMeters,
            elevationLossMeters: nil,
            meanHR: 150,
            userMaxHR: userMaxHR,
            bodyWeightKg: 75,
            samples: samples,
            splits: splits,
            trimp: trimp,
            decouplingPercent: decouplingPercent
        )
    }

    private func split(_ index: Int, paceSecPerKm: Double) -> Split {
        Split(
            index: index,
            distanceMeters: 1_000,
            durationSeconds: paceSecPerKm,
            averageHR: 150,
            averagePaceSecPerKm: paceSecPerKm,
            elevationGainMeters: nil
        )
    }

    // MARK: - Empty input

    /// An empty stream must produce a snapshot of absences, not zeros. A zero
    /// α1 or a zone array of all-zero would render as real measured values.
    func testEmptySamplesProduceAbsencesNotZeros() {
        let snap = WorkoutAnalysisSnapshotBuilder.build(inputs(samples: []))

        XCTAssertNil(snap.alpha1Mean)
        XCTAssertNil(snap.alpha1Min)
        XCTAssertNil(snap.alpha1Max)
        XCTAssertNil(snap.secondsBelowAT1)
        XCTAssertNil(snap.hrZoneSeconds)
        XCTAssertNil(snap.dominantHRZone)
        XCTAssertNil(snap.dominantAlpha1BandRaw)
        XCTAssertNil(snap.firstAT1CrossingOffsetSec)
    }

    // MARK: - α1 aggregation

    func testAlphaMeanMinMaxAcrossTheStream() {
        let samples = [
            sample(at: 10, alpha1: 0.90),
            sample(at: 20, alpha1: 0.70),
            sample(at: 30, alpha1: 1.10)
        ]
        let snap = WorkoutAnalysisSnapshotBuilder.build(inputs(samples: samples))

        XCTAssertEqual(snap.alpha1Mean ?? 0, 0.90, accuracy: 0.001)
        XCTAssertEqual(snap.alpha1Min ?? 0, 0.70, accuracy: 0.001)
        XCTAssertEqual(snap.alpha1Max ?? 0, 1.10, accuracy: 0.001)
    }

    /// Band boundaries: `>= 0.75` is below-AT1, `0.50 ..< 0.75` is between,
    /// below `0.50` is above-AT2. Pinned at the exact edges because an
    /// off-by-one here silently reclassifies a whole workout's intensity.
    func testBandBoundariesAreInclusiveAtTheLowerEdge() {
        let atExactly75 = WorkoutAnalysisSnapshotBuilder.build(
            inputs(samples: [sample(at: 10, alpha1: 0.75), sample(at: 20, alpha1: 0.75)])
        )
        XCTAssertEqual(atExactly75.dominantAlpha1BandRaw, "belowAeT")

        let atExactly50 = WorkoutAnalysisSnapshotBuilder.build(
            inputs(samples: [sample(at: 10, alpha1: 0.50), sample(at: 20, alpha1: 0.50)])
        )
        XCTAssertEqual(atExactly50.dominantAlpha1BandRaw, "nearAeT")

        let below50 = WorkoutAnalysisSnapshotBuilder.build(
            inputs(samples: [sample(at: 10, alpha1: 0.30), sample(at: 20, alpha1: 0.30)])
        )
        XCTAssertEqual(below50.dominantAlpha1BandRaw, "aboveVT2")
    }

    // MARK: - α1 sustained-crossing detector

    /// The bug this guards: one ectopic beat contaminates the rolling α1
    /// window, producing a transient sub-0.75 dip. A short dip must NOT be
    /// reported as a threshold crossing — that is what put an LT1 of 121 bpm
    /// on a 120 bpm walk.
    func testATransientDipDoesNotRegisterAsACrossing() {
        var samples: [WorkoutSample] = []
        for t in stride(from: 0, through: 600, by: 10) {
            // One 30 s dip well after warm-up — far shorter than the 180 s
            // sustain requirement.
            let dipping = (300 ... 330).contains(t)
            samples.append(sample(at: t, hr: 120, alpha1: dipping ? 0.60 : 0.95))
        }

        let snap = WorkoutAnalysisSnapshotBuilder.build(inputs(samples: samples))

        XCTAssertNil(snap.firstAT1CrossingOffsetSec,
                     "a 30 s dip is an ectopic shadow, not a threshold crossing")
        XCTAssertNil(snap.firstAT1CrossingHR)
    }

    /// A genuine effort: sub-0.75 sustained past the 180 s requirement.
    func testASustainedDropRegistersACrossing() {
        var samples: [WorkoutSample] = []
        for t in stride(from: 0, through: 900, by: 10) {
            let working = t >= 300
            samples.append(sample(at: t, hr: working ? 165 : 120, alpha1: working ? 0.55 : 0.95))
        }

        let snap = WorkoutAnalysisSnapshotBuilder.build(inputs(samples: samples))

        XCTAssertNotNil(snap.firstAT1CrossingOffsetSec)
        XCTAssertEqual(snap.firstAT1CrossingOffsetSec, 300,
                       "the crossing is stamped at the START of the sustained period")
        XCTAssertEqual(snap.firstAT1CrossingHR, 165)
    }

    /// The warm-up guard: the rolling α1 buffer is still filling for the first
    /// ~2 minutes and dips low spuriously. A crossing inside that window must
    /// be ignored no matter how long it lasts.
    func testCrossingsInsideTheWarmupWindowAreIgnored() {
        var samples: [WorkoutSample] = []
        // Sustained low α1 from the very first second, ending before warm-up
        // is over — a real crossing would need to persist past 120 s.
        for t in stride(from: 0, through: 110, by: 10) {
            samples.append(sample(at: t, hr: 100, alpha1: 0.40))
        }
        for t in stride(from: 120, through: 600, by: 10) {
            samples.append(sample(at: t, hr: 110, alpha1: 0.95))
        }

        let snap = WorkoutAnalysisSnapshotBuilder.build(inputs(samples: samples))
        XCTAssertNil(snap.firstAT1CrossingOffsetSec,
                     "pre-warmup dips are buffer artefacts, not efforts")
    }

    /// Recovering above 0.75 resets the sustain counter — two short dips
    /// separated by recovery must not add up to a crossing.
    func testRecoveryResetsTheSustainCounter() {
        var samples: [WorkoutSample] = []
        for t in stride(from: 0, through: 900, by: 10) {
            let dip1 = (200 ... 320).contains(t)   // 120 s
            let dip2 = (500 ... 620).contains(t)   // 120 s, after recovery
            samples.append(sample(at: t, hr: 140, alpha1: (dip1 || dip2) ? 0.60 : 0.95))
        }

        let snap = WorkoutAnalysisSnapshotBuilder.build(inputs(samples: samples))
        XCTAssertNil(snap.firstAT1CrossingOffsetSec,
                     "two sub-sustain dips must not accumulate across a recovery")
    }

    // MARK: - HR zones

    /// Zone edges as fractions of max HR: <50% uncounted, then 50/60/70/80/90.
    func testHRZoneBucketingAtTheBoundaries() {
        // maxHR 200 makes the fractions exact: 100/120/140/160/180 bpm.
        let samples = [
            sample(at: 10, hr: 100), // 0.50 → zone 1
            sample(at: 20, hr: 120), // 0.60 → zone 2
            sample(at: 30, hr: 140), // 0.70 → zone 3
            sample(at: 40, hr: 160), // 0.80 → zone 4
            sample(at: 50, hr: 180) // 0.90 → zone 5
        ]
        let snap = WorkoutAnalysisSnapshotBuilder.build(inputs(samples: samples, userMaxHR: 200))

        let zones = try? XCTUnwrap(snap.hrZoneSeconds)
        XCTAssertEqual(zones?.count, 5)
        XCTAssertTrue(zones?.allSatisfy { $0 > 0 } ?? false,
                      "each boundary sample should land in its own zone: \(zones ?? [])")
    }

    /// Below 50% of max is not a training zone and is deliberately uncounted.
    func testVeryLowHeartRateIsNotCountedInAnyZone() {
        let samples = (1 ... 20).map { sample(at: $0 * 10, hr: 80) } // 0.42 of 190
        let snap = WorkoutAnalysisSnapshotBuilder.build(inputs(samples: samples))

        XCTAssertNil(snap.hrZoneSeconds, "sub-zone-1 HR must not fabricate a zone total")
        XCTAssertNil(snap.dominantHRZone)
    }

    func testDominantZoneIsTheOneWithTheMostTime() {
        var samples: [WorkoutSample] = []
        for t in stride(from: 10, through: 600, by: 10) {
            samples.append(sample(at: t, hr: 150)) // 0.79 of 190 → zone 3
        }
        samples.append(sample(at: 610, hr: 180))

        let snap = WorkoutAnalysisSnapshotBuilder.build(inputs(samples: samples))

        XCTAssertEqual(snap.dominantHRZone, 3)
        XCTAssertGreaterThan(snap.dominantHRZonePercent ?? 0, 80)
    }

    /// A guard against divide-by-zero: a zero or negative max HR must not
    /// crash or produce infinities.
    func testZeroMaxHeartRateIsHandled() {
        let samples = (1 ... 10).map { sample(at: $0 * 10, hr: 150) }
        for maxHR in [0, -5] {
            let snap = WorkoutAnalysisSnapshotBuilder.build(
                inputs(samples: samples, userMaxHR: maxHR)
            )
            XCTAssertNotNil(snap.hrZoneSeconds, "maxHR \(maxHR) should still bucket, not crash")
        }
    }

    // MARK: - Splits

    func testFastestAndSlowestSplitsAreIdentified() {
        let splits = [split(1, paceSecPerKm: 300), split(2, paceSecPerKm: 260), split(3, paceSecPerKm: 340)]
        let snap = WorkoutAnalysisSnapshotBuilder.build(inputs(samples: [], splits: splits))

        XCTAssertEqual(snap.fastestSplitIndex, 2)
        XCTAssertEqual(snap.fastestSplitPaceSecPerKm ?? 0, 260, accuracy: 0.5)
        XCTAssertEqual(snap.slowestSplitIndex, 3)
        XCTAssertEqual(snap.slowestSplitPaceSecPerKm ?? 0, 340, accuracy: 0.5)
    }

    func testASingleSplitIsBothFastestAndSlowest() {
        let snap = WorkoutAnalysisSnapshotBuilder.build(
            inputs(samples: [], splits: [split(1, paceSecPerKm: 300)])
        )
        XCTAssertEqual(snap.fastestSplitIndex, 1)
        XCTAssertEqual(snap.slowestSplitIndex, 1)
    }

    func testNoSplitsLeavesSplitFieldsAbsent() {
        let snap = WorkoutAnalysisSnapshotBuilder.build(inputs(samples: [], splits: []))
        XCTAssertNil(snap.fastestSplitIndex)
        XCTAssertNil(snap.slowestSplitIndex)
    }

    // MARK: - Moving time

    /// Moving is an OR of three signals. The bug it fixes: a casual 3 mph walk
    /// produces almost no pace samples (GPS gates on a 2.5 m delta), which read
    /// as "32% moving" for a 100%-active walk. Cadence alone must be enough.
    func testCadenceAloneCountsAsMoving() {
        let samples = (1 ... 30).map { sample(at: $0 * 10, cadence: 95) }
        let snap = WorkoutAnalysisSnapshotBuilder.build(inputs(samples: samples))

        XCTAssertGreaterThan(snap.movingTimeSec ?? 0, 0,
                             "a cadence-only walk is still moving")
    }

    /// 50 spm is the floor — below it we assume genuinely stationary.
    func testCadenceBelowTheFloorIsNotMoving() {
        let samples = (1 ... 30).map { sample(at: $0 * 10, cadence: 20) }
        let snap = WorkoutAnalysisSnapshotBuilder.build(inputs(samples: samples))

        XCTAssertEqual(snap.movingTimeSec ?? 0, 0)
    }

    /// HR alone is not enough — a resting strap would read as movement. It
    /// counts only alongside a physiological signal (α1 or METs).
    func testHeartRateCountsAsMovingOnlyWithAPhysiologicalSignal() {
        let hrOnly = (1 ... 30).map { sample(at: $0 * 10, hr: 140) }
        XCTAssertEqual(
            WorkoutAnalysisSnapshotBuilder.build(inputs(samples: hrOnly)).movingTimeSec ?? 0, 0,
            "a bare HR reading could just be a strap sitting on a desk"
        )

        let hrWithMets = (1 ... 30).map { sample(at: $0 * 10, hr: 140, mets: 6) }
        XCTAssertGreaterThan(
            WorkoutAnalysisSnapshotBuilder.build(inputs(samples: hrWithMets)).movingTimeSec ?? 0, 0
        )
    }

    func testPaceAloneCountsAsMoving() {
        let samples = (1 ... 30).map { sample(at: $0 * 10, pace: 320) }
        XCTAssertGreaterThan(
            WorkoutAnalysisSnapshotBuilder.build(inputs(samples: samples)).movingTimeSec ?? 0, 0
        )
    }

    // MARK: - Robustness

    /// Out-of-order and duplicate offsets happen when a backup is merged from
    /// two sources. The `max(1, delta)` guard means they must not produce
    /// negative durations.
    func testOutOfOrderOffsetsDoNotProduceNegativeDurations() {
        let samples = [
            sample(at: 100, hr: 150, alpha1: 0.9),
            sample(at: 50, hr: 150, alpha1: 0.9),
            sample(at: 100, hr: 150, alpha1: 0.9),
            sample(at: 200, hr: 150, alpha1: 0.9)
        ]
        let snap = WorkoutAnalysisSnapshotBuilder.build(inputs(samples: samples))

        XCTAssertGreaterThanOrEqual(snap.secondsBelowAT1 ?? 0, 0)
        XCTAssertGreaterThanOrEqual(snap.movingTimeSec ?? 0, 0)
        for seconds in snap.hrZoneSeconds ?? [] {
            XCTAssertGreaterThanOrEqual(seconds, 0)
        }
    }

    /// A workout with no duration must not divide by zero into an infinite
    /// or NaN percentage.
    func testZeroDurationDoesNotProduceInfinities() {
        let samples = (1 ... 10).map { sample(at: $0, hr: 150, cadence: 90) }
        let snap = WorkoutAnalysisSnapshotBuilder.build(
            inputs(samples: samples, durationSec: 0)
        )

        // `movingTimePercent` is an `Int`, so an overflowing division would
        // trap rather than produce a NaN — the assertion is that it lands in a
        // sane range at all.
        if let pct = snap.movingTimePercent {
            XCTAssertGreaterThanOrEqual(pct, 0)
            XCTAssertLessThanOrEqual(pct, 100)
        }
    }

    /// A long workout — the one-pass accumulation must stay linear and
    /// produce sane totals rather than overflowing any counter.
    func testALongWorkoutAccumulatesSanely() {
        var samples: [WorkoutSample] = []
        for t in stride(from: 0, through: 4 * 3_600, by: 5) {
            samples.append(sample(at: t, hr: 145, alpha1: 0.85, cadence: 88, mets: 8))
        }

        let snap = WorkoutAnalysisSnapshotBuilder.build(
            inputs(samples: samples, durationSec: 4 * 3_600)
        )

        let alphaTotal = (snap.secondsBelowAT1 ?? 0) + (snap.secondsBetweenAT1AT2 ?? 0) + (snap.secondsAboveAT2 ?? 0)
        XCTAssertGreaterThan(alphaTotal, 0)
        XCTAssertLessThanOrEqual(alphaTotal, 4 * 3_600 + 60,
                                 "banded seconds must not exceed the workout duration")
        XCTAssertLessThanOrEqual(snap.movingTimeSec ?? 0, 4 * 3_600 + 60)
    }

    /// Samples carrying no signal at all contribute nothing but must not
    /// break the pass.
    func testAllNilSamplesProduceAnEmptySnapshot() {
        let samples = (1 ... 50).map { sample(at: $0 * 10) }
        let snap = WorkoutAnalysisSnapshotBuilder.build(inputs(samples: samples))

        XCTAssertNil(snap.alpha1Mean)
        XCTAssertNil(snap.hrZoneSeconds)
        XCTAssertEqual(snap.movingTimeSec ?? 0, 0)
    }
}
