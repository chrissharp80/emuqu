@testable import Emuqu
import XCTest

/// Tests for SleepScienceAnalyzer — fragmentation, cycles, architecture, age norms, enhanced score
final class SleepScienceAnalyzerTests: XCTestCase {
    // MARK: - Helpers

    private let baseDate = TestDate.from(
        DateComponents(year: 2025, month: 1, day: 15, hour: 22)
    )

    /// Create a SleepStageInterval starting at the given offset (minutes from baseDate).
    private func interval(_ stage: HealthKitManager.SleepStage, startMin: Int, durationMin: Int) -> HealthKitManager.SleepStageInterval {
        let start = baseDate.addingTimeInterval(Double(startMin) * 60)
        let end = baseDate.addingTimeInterval(Double(startMin + durationMin) * 60)
        return HealthKitManager.SleepStageInterval(stage: stage, start: start, end: end)
    }

    /// Build a standard 7h sleep with typical stage distribution.
    private func makeStandardSleepData() -> SleepData {
        let intervals = [
            // Cycle 1: deep-heavy
            interval(.core, startMin: 0, durationMin: 20),
            interval(.deep, startMin: 20, durationMin: 30),
            interval(.core, startMin: 50, durationMin: 15),
            interval(.rem, startMin: 65, durationMin: 15),
            // Cycle 2
            interval(.core, startMin: 80, durationMin: 25),
            interval(.deep, startMin: 105, durationMin: 20),
            interval(.core, startMin: 125, durationMin: 10),
            interval(.rem, startMin: 135, durationMin: 20),
            // Awake briefly
            interval(.awake, startMin: 155, durationMin: 5),
            // Cycle 3: more REM
            interval(.core, startMin: 160, durationMin: 30),
            interval(.deep, startMin: 190, durationMin: 10),
            interval(.core, startMin: 200, durationMin: 15),
            interval(.rem, startMin: 215, durationMin: 25),
            // Cycle 4: REM-dominant
            interval(.core, startMin: 240, durationMin: 30),
            interval(.rem, startMin: 270, durationMin: 30),
            // Cycle 5: light + REM
            interval(.core, startMin: 300, durationMin: 40),
            interval(.rem, startMin: 340, durationMin: 20),
            interval(.awake, startMin: 360, durationMin: 5),
            interval(.core, startMin: 365, durationMin: 55)
        ]

        let sleepStart = baseDate
        let sleepEnd = baseDate.addingTimeInterval(420 * 60) // 7 hours

        return SleepData(
            date: baseDate,
            inBedStart: baseDate.addingTimeInterval(-15 * 60),
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            totalSleepMinutes: 410,
            inBedMinutes: 420,
            deepSleepMinutes: 60,
            remSleepMinutes: 110,
            awakeMinutes: 10,
            sleepEfficiency: 97.6,
            boundarySource: .healthKit,
            segments: [],
            stageIntervals: intervals,
            boundaryValidation: nil,
            hrSleepQuality: nil
        )
    }

    // MARK: - Fragmentation

    func testZeroAwakeningsFragmentation() {
        let intervals = [
            interval(.core, startMin: 0, durationMin: 120),
            interval(.deep, startMin: 120, durationMin: 60),
            interval(.rem, startMin: 180, durationMin: 60)
        ]

        let (index, count) = SleepScienceAnalyzer.computeFragmentation(
            intervals: intervals, totalSleepMinutes: 240, awakeMinutes: 0
        )

        XCTAssertEqual(count, 0, "Should count zero awakenings")
        XCTAssertEqual(index, 0, accuracy: 0.01, "Fragmentation should be 0 with no awakenings")
    }

    func testSingleAwakeningFragmentation() {
        let intervals = [
            interval(.core, startMin: 0, durationMin: 120),
            interval(.awake, startMin: 120, durationMin: 5),
            interval(.deep, startMin: 125, durationMin: 60),
            interval(.rem, startMin: 185, durationMin: 55)
        ]

        let (index, count) = SleepScienceAnalyzer.computeFragmentation(
            intervals: intervals, totalSleepMinutes: 235, awakeMinutes: 5
        )

        XCTAssertEqual(count, 1)
        XCTAssertGreaterThan(index, 0, "Should have non-zero fragmentation")
        XCTAssertLessThan(index, 20, "Single brief awakening should be low fragmentation")
    }

    func testHighFragmentation() {
        // Many wake episodes
        var intervals = [HealthKitManager.SleepStageInterval]()
        for i in 0 ..< 20 {
            intervals.append(interval(.core, startMin: i * 24, durationMin: 20))
            intervals.append(interval(.awake, startMin: i * 24 + 20, durationMin: 4))
        }

        let (index, count) = SleepScienceAnalyzer.computeFragmentation(
            intervals: intervals, totalSleepMinutes: 400, awakeMinutes: 80
        )

        XCTAssertEqual(count, 20)
        XCTAssertGreaterThan(index, 30, "20 awakenings with 80 min awake should be high fragmentation")
    }

    func testZeroTotalSleepMinutes() {
        let (index, count) = SleepScienceAnalyzer.computeFragmentation(
            intervals: [], totalSleepMinutes: 0, awakeMinutes: 0
        )
        XCTAssertEqual(index, 0)
        XCTAssertEqual(count, 0)
    }

    // MARK: - Sleep Cycle Detection

    func testDetectsCyclesFromStages() {
        // Simple 2-cycle pattern: NREM → REM → 15+ min NREM → REM
        let intervals = [
            interval(.core, startMin: 0, durationMin: 40),
            interval(.deep, startMin: 40, durationMin: 20),
            interval(.rem, startMin: 60, durationMin: 20),
            // After REM: 20 min NREM (>15 → cycle boundary)
            interval(.core, startMin: 80, durationMin: 40),
            interval(.deep, startMin: 120, durationMin: 15),
            interval(.rem, startMin: 135, durationMin: 25),
            interval(.core, startMin: 160, durationMin: 20)
        ]

        let cycles = SleepScienceAnalyzer.detectSleepCycles(intervals: intervals)

        XCTAssertGreaterThanOrEqual(cycles.count, 2, "Should detect at least 2 cycles")
        XCTAssertTrue(cycles[0].isComplete, "First cycle should have REM")
    }

    func testNoCyclesFromEmptyIntervals() {
        let cycles = SleepScienceAnalyzer.detectSleepCycles(intervals: [])
        XCTAssertEqual(cycles.count, 0)
    }

    func testNoCyclesFromOnlyAwake() {
        let intervals = [
            interval(.awake, startMin: 0, durationMin: 60),
            interval(.awake, startMin: 60, durationMin: 60)
        ]
        let cycles = SleepScienceAnalyzer.detectSleepCycles(intervals: intervals)
        XCTAssertEqual(cycles.count, 0)
    }

    func testIncompleteCycleHasNoREM() {
        // Only NREM, no REM at all
        let intervals = [
            interval(.core, startMin: 0, durationMin: 60),
            interval(.deep, startMin: 60, durationMin: 30)
        ]

        let cycles = SleepScienceAnalyzer.detectSleepCycles(intervals: intervals)

        // Should have 1 incomplete cycle
        if let cycle = cycles.first {
            XCTAssertFalse(cycle.isComplete, "Cycle without REM should be incomplete")
            XCTAssertEqual(cycle.remMinutes, 0)
        }
    }

    // MARK: - Age-Adjusted Norms

    func testAgeNormsForYoungAdult() {
        let norms = SleepScienceAnalyzer.computeAgeNorms(
            age: 25, deepPercent: 18.0, remPercent: 22.0, efficiency: 90.0
        )

        XCTAssertEqual(norms.age, 25)
        XCTAssertTrue(norms.isDeepInRange, "18% deep should be in range for age 25 (15-22%)")
        XCTAssertTrue(norms.isREMInRange, "22% REM should be in range for age 25 (20-25%)")
    }

    func testAgeNormsForOlderAdult() {
        let norms = SleepScienceAnalyzer.computeAgeNorms(
            age: 65, deepPercent: 8.0, remPercent: 18.0, efficiency: 80.0
        )

        XCTAssertEqual(norms.age, 65)
        XCTAssertTrue(norms.isDeepInRange, "8% deep should be in range for age 65 (5-13%)")
        XCTAssertTrue(norms.isREMInRange, "18% REM should be in range for age 65 (16-21%)")
    }

    func testAgeNormsDeepBelowRange() {
        let norms = SleepScienceAnalyzer.computeAgeNorms(
            age: 30, deepPercent: 5.0, remPercent: 22.0, efficiency: 85.0
        )

        XCTAssertFalse(norms.isDeepInRange, "5% deep should be below range for age 30 (13-20%)")
        XCTAssertLessThan(norms.deepDeviation, 0, "Deviation should be negative when below midpoint")
    }

    func testAgeNormsForTeenager() {
        let norms = SleepScienceAnalyzer.computeAgeNorms(
            age: 16, deepPercent: 20.0, remPercent: 23.0, efficiency: 92.0
        )

        XCTAssertEqual(norms.age, 16)
        XCTAssertTrue(norms.isDeepInRange, "20% deep in range for <20 (17-25%)")
        XCTAssertTrue(norms.isREMInRange, "23% REM in range for <20 (20-25%)")
        XCTAssertEqual(norms.expectedEfficiency, 90.0)
    }

    func testAgeNormsForElderly() {
        let norms = SleepScienceAnalyzer.computeAgeNorms(
            age: 75, deepPercent: 5.0, remPercent: 17.0, efficiency: 70.0
        )

        XCTAssertEqual(norms.age, 75)
        XCTAssertTrue(norms.expectedDeepPercent == 3.0 ... 10.0)
        XCTAssertTrue(norms.expectedREMPercent == 15.0 ... 20.0)
        XCTAssertEqual(norms.expectedEfficiency, 75.0)
    }

    // MARK: - Architecture

    func testDeepFrontLoadedArchitecture() {
        // All deep in first half, all REM in second half
        let sleepStart = baseDate
        let sleepEnd = baseDate.addingTimeInterval(8 * 3600)
        let intervals = [
            interval(.deep, startMin: 0, durationMin: 60), // First half deep
            interval(.core, startMin: 60, durationMin: 180),
            interval(.rem, startMin: 240, durationMin: 60), // Second half REM
            interval(.core, startMin: 300, durationMin: 120),
            interval(.rem, startMin: 420, durationMin: 60) // Second half REM
        ]

        let sleepData = SleepData(
            date: baseDate, inBedStart: nil,
            sleepStart: sleepStart, sleepEnd: sleepEnd,
            totalSleepMinutes: 480, inBedMinutes: 480,
            deepSleepMinutes: 60, remSleepMinutes: 120,
            awakeMinutes: 0, sleepEfficiency: 100,
            boundarySource: .healthKit, segments: [],
            stageIntervals: intervals, boundaryValidation: nil,
            hrSleepQuality: nil
        )

        let arch = SleepScienceAnalyzer.analyzeArchitecture(
            intervals: intervals, sleepData: sleepData
        )

        XCTAssertTrue(arch.deepFrontLoaded, "Deep should be front-loaded (100% in first half)")
        XCTAssertTrue(arch.remBackLoaded, "REM should be back-loaded (100% in second half)")
        XCTAssertGreaterThan(arch.architectureScore, 80, "Perfect architecture should score highly")
    }

    func testNoSleepBoundariesDefaultsArchitecture() {
        let sleepData = SleepData(
            date: baseDate, inBedStart: nil,
            sleepStart: nil, sleepEnd: nil,
            totalSleepMinutes: 420, inBedMinutes: 420,
            deepSleepMinutes: 60, remSleepMinutes: 90,
            awakeMinutes: 0, sleepEfficiency: 100,
            boundarySource: .recordingBounds, segments: [],
            stageIntervals: [], boundaryValidation: nil,
            hrSleepQuality: nil
        )

        let arch = SleepScienceAnalyzer.analyzeArchitecture(
            intervals: [], sleepData: sleepData
        )

        XCTAssertEqual(arch.architectureScore, 50, "Missing boundaries should return neutral score")
    }

    // MARK: - Enhanced Score

    func testEnhancedScoreGoodSleep() {
        let sleepData = makeStandardSleepData()
        let architecture = SleepScienceAnalyzer.SleepArchitecture(
            deepFrontLoaded: true, remBackLoaded: true,
            firstHalfDeepPercent: 70, secondHalfREMPercent: 65,
            architectureScore: 80
        )

        let score = SleepScienceAnalyzer.computeEnhancedScore(
            sleepData: sleepData,
            typicalSleepHours: 7.5,
            fragmentationIndex: 5.0,
            cycleCount: 4,
            architecture: architecture,
            ageNorms: nil
        )

        XCTAssertGreaterThan(score, 60, "Good 7h sleep should score well")
        XCTAssertLessThanOrEqual(score, 100)
    }

    func testEnhancedScorePoorSleep() {
        let sleepData = SleepData(
            date: baseDate, inBedStart: nil,
            sleepStart: baseDate, sleepEnd: baseDate.addingTimeInterval(3 * 3600),
            totalSleepMinutes: 150, inBedMinutes: 180,
            deepSleepMinutes: 10, remSleepMinutes: 20,
            awakeMinutes: 30, sleepEfficiency: 83,
            boundarySource: .healthKit, segments: [],
            stageIntervals: [], boundaryValidation: nil,
            hrSleepQuality: nil
        )

        let architecture = SleepScienceAnalyzer.SleepArchitecture(
            deepFrontLoaded: false, remBackLoaded: false,
            firstHalfDeepPercent: 40, secondHalfREMPercent: 40,
            architectureScore: 40
        )

        let score = SleepScienceAnalyzer.computeEnhancedScore(
            sleepData: sleepData,
            typicalSleepHours: 8.0,
            fragmentationIndex: 50,
            cycleCount: 1,
            architecture: architecture,
            ageNorms: nil
        )

        XCTAssertLessThan(score, 55, "Short, fragmented sleep should score poorly")
    }

    // MARK: - Full Analysis

    func testFullAnalysisWithStages() {
        let sleepData = makeStandardSleepData()

        let result = SleepScienceAnalyzer.analyze(
            sleepData: sleepData, userAge: 35, typicalSleepHours: 7.5
        )

        XCTAssertNotNil(result, "Should produce analysis for valid sleep data")
        if let analysis = result {
            XCTAssertGreaterThanOrEqual(analysis.cycleCount, 0)
            XCTAssertGreaterThan(analysis.enhancedScore, 0)
            XCTAssertLessThanOrEqual(analysis.enhancedScore, 100)
            XCTAssertNotNil(analysis.ageNorms, "Should have age norms when age is provided")
            XCTAssertEqual(analysis.ageNorms?.age, 35)
        }
    }

    func testFullAnalysisNoAge() {
        let sleepData = makeStandardSleepData()

        let result = SleepScienceAnalyzer.analyze(
            sleepData: sleepData, userAge: nil, typicalSleepHours: 7.5
        )

        XCTAssertNotNil(result)
        XCTAssertNil(result?.ageNorms, "Should be nil when no age provided")
    }

    func testFullAnalysisZeroSleepReturnsNil() {
        let emptySleep = SleepData(
            date: baseDate, inBedStart: nil,
            sleepStart: nil, sleepEnd: nil,
            totalSleepMinutes: 0, inBedMinutes: 0,
            deepSleepMinutes: nil, remSleepMinutes: nil,
            awakeMinutes: 0, sleepEfficiency: 0,
            boundarySource: .recordingBounds, segments: [],
            stageIntervals: [], boundaryValidation: nil,
            hrSleepQuality: nil
        )

        let result = SleepScienceAnalyzer.analyze(
            sleepData: emptySleep, userAge: 30, typicalSleepHours: 8.0
        )

        XCTAssertNil(result, "Zero sleep should return nil")
    }

    func testAboveRangeDeepAndREMGetsFullCredit() {
        // 28% deep and 43% REM — well above age 55 norms (8-15% deep, 17-22% REM)
        // Should NOT be penalized — more deep/REM is beneficial, not harmful
        let sleepData = SleepData(
            date: baseDate, inBedStart: nil,
            sleepStart: baseDate, sleepEnd: baseDate.addingTimeInterval(7 * 3600),
            totalSleepMinutes: 400, inBedMinutes: 420,
            deepSleepMinutes: 112, remSleepMinutes: 172, // 28% deep, 43% REM
            awakeMinutes: 20, sleepEfficiency: 95.2,
            boundarySource: .healthKit, segments: [],
            stageIntervals: [
                interval(.deep, startMin: 0, durationMin: 112),
                interval(.rem, startMin: 112, durationMin: 172),
                interval(.core, startMin: 284, durationMin: 116),
                interval(.awake, startMin: 400, durationMin: 20)
            ],
            boundaryValidation: nil,
            hrSleepQuality: nil
        )

        let norms = SleepScienceAnalyzer.computeAgeNorms(
            age: 55, deepPercent: 28.0, remPercent: 43.0, efficiency: 95.2
        )

        // Both are above range — deviation should be positive
        XCTAssertFalse(norms.isDeepInRange, "28% deep is above 8-15% range")
        XCTAssertFalse(norms.isREMInRange, "43% REM is above 17-22% range")
        XCTAssertGreaterThan(norms.deepDeviation, 0, "Deep deviation should be positive (above midpoint)")
        XCTAssertGreaterThan(norms.remDeviation, 0, "REM deviation should be positive (above midpoint)")

        // Score should give full stage credit — above range should NOT reduce score
        let architecture = SleepScienceAnalyzer.SleepArchitecture(
            deepFrontLoaded: true, remBackLoaded: true,
            firstHalfDeepPercent: 80, secondHalfREMPercent: 70,
            architectureScore: 85
        )

        let score = SleepScienceAnalyzer.computeEnhancedScore(
            sleepData: sleepData,
            typicalSleepHours: 7.0,
            fragmentationIndex: 5.0,
            cycleCount: 4,
            architecture: architecture,
            ageNorms: norms
        )

        // With full stage credit (20/20) + good everything else, score should be high
        XCTAssertGreaterThan(score, 75, "Above-range deep/REM should not be penalized — score should be high")
    }

    func testBelowRangeDeepStillPenalized() {
        // 3% deep — well below age 30 norms (13-20%)
        let norms = SleepScienceAnalyzer.computeAgeNorms(
            age: 30, deepPercent: 3.0, remPercent: 22.0, efficiency: 85.0
        )

        XCTAssertFalse(norms.isDeepInRange, "3% deep below range for age 30")
        XCTAssertLessThan(norms.deepDeviation, 0, "Below-range should have negative deviation")

        // Score with below-range deep should be lower than score with in-range deep
        let sleepDataLowDeep = SleepData(
            date: baseDate, inBedStart: nil,
            sleepStart: baseDate, sleepEnd: baseDate.addingTimeInterval(7 * 3600),
            totalSleepMinutes: 400, inBedMinutes: 420,
            deepSleepMinutes: 12, remSleepMinutes: 88, // 3% deep, 22% REM
            awakeMinutes: 20, sleepEfficiency: 95.2,
            boundarySource: .healthKit, segments: [],
            stageIntervals: [interval(.core, startMin: 0, durationMin: 400)],
            boundaryValidation: nil,
            hrSleepQuality: nil
        )

        let arch = SleepScienceAnalyzer.SleepArchitecture(
            deepFrontLoaded: true, remBackLoaded: true,
            firstHalfDeepPercent: 70, secondHalfREMPercent: 65,
            architectureScore: 80
        )

        let scoreLowDeep = SleepScienceAnalyzer.computeEnhancedScore(
            sleepData: sleepDataLowDeep,
            typicalSleepHours: 7.0,
            fragmentationIndex: 5.0,
            cycleCount: 4,
            architecture: arch,
            ageNorms: norms
        )

        let normsGoodDeep = SleepScienceAnalyzer.computeAgeNorms(
            age: 30, deepPercent: 16.0, remPercent: 22.0, efficiency: 85.0
        )

        let sleepDataGoodDeep = SleepData(
            date: baseDate, inBedStart: nil,
            sleepStart: baseDate, sleepEnd: baseDate.addingTimeInterval(7 * 3600),
            totalSleepMinutes: 400, inBedMinutes: 420,
            deepSleepMinutes: 64, remSleepMinutes: 88, // 16% deep, 22% REM
            awakeMinutes: 20, sleepEfficiency: 95.2,
            boundarySource: .healthKit, segments: [],
            stageIntervals: [interval(.core, startMin: 0, durationMin: 400)],
            boundaryValidation: nil,
            hrSleepQuality: nil
        )

        let scoreGoodDeep = SleepScienceAnalyzer.computeEnhancedScore(
            sleepData: sleepDataGoodDeep,
            typicalSleepHours: 7.0,
            fragmentationIndex: 5.0,
            cycleCount: 4,
            architecture: arch,
            ageNorms: normsGoodDeep
        )

        XCTAssertLessThan(scoreLowDeep, scoreGoodDeep, "Below-range deep should score lower than in-range")
    }

    func testAnalysisWithoutStageData() {
        // Sleep data without deep/REM breakdown (no Apple Watch)
        let sleepData = SleepData(
            date: baseDate, inBedStart: nil,
            sleepStart: baseDate, sleepEnd: baseDate.addingTimeInterval(7 * 3600),
            totalSleepMinutes: 420, inBedMinutes: 430,
            deepSleepMinutes: nil, remSleepMinutes: nil,
            awakeMinutes: 10, sleepEfficiency: 97.7,
            boundarySource: .healthKit, segments: [],
            stageIntervals: [
                interval(.core, startMin: 0, durationMin: 415),
                interval(.awake, startMin: 415, durationMin: 5)
            ],
            boundaryValidation: nil,
            hrSleepQuality: nil
        )

        let result = SleepScienceAnalyzer.analyze(
            sleepData: sleepData, userAge: 40, typicalSleepHours: 7.5
        )

        XCTAssertNotNil(result)
        if let analysis = result {
            // No stages → no cycles, neutral architecture
            XCTAssertEqual(analysis.cycleCount, 0, "No stage data → no detected cycles")
            XCTAssertNil(analysis.ageNorms, "No stages → no age norms")
            XCTAssertEqual(analysis.architecture.architectureScore, 50, "Should default to neutral")
        }
    }
}

/// Guards `SleepData.plausiblyBelongsToRecording`, which stops
/// HealthKit from grafting a whole night's sleep block onto a short pre-sleep
/// clip (the 419-min-sleep-on-a-12.8-min-recording bug that fabricated sleep,
/// mis-slotted the session to the wrong day, and tripped the archive hash).
final class SleepDataPlausibilityTests: XCTestCase {
    private func sleep(start: Date, end: Date) -> SleepData {
        let minutes = Int(end.timeIntervalSince(start) / 60)
        return SleepData(
            date: start,
            sleepStart: start,
            sleepEnd: end,
            totalSleepMinutes: minutes,
            inBedMinutes: minutes,
            awakeMinutes: 0,
            sleepEfficiency: 95,
            boundarySource: .healthKit
        )
    }

    /// The exact regression: a 12.8-min clip (21:45–21:58) with the following
    /// night's 7-hour block (21:58 → 04:58) attached. Overlap ≈ 0 → reject.
    func testRejectsFullNightOnShortClip() {
        let recStart = Date(timeIntervalSince1970: 1_785_600_000)
        let recEnd = recStart.addingTimeInterval(12.8 * 60)
        let fullNight = sleep(start: recEnd, end: recEnd.addingTimeInterval(7 * 3600))
        XCTAssertFalse(fullNight.plausiblyBelongsToRecording(start: recStart, end: recEnd))
    }

    /// A genuine overnight whose recording spans the whole night is accepted.
    func testAcceptsMatchingOvernight() {
        let recStart = Date(timeIntervalSince1970: 1_785_600_000)
        let recEnd = recStart.addingTimeInterval(8 * 3600)
        let night = sleep(start: recStart.addingTimeInterval(10 * 60), end: recEnd.addingTimeInterval(-5 * 60))
        XCTAssertTrue(night.plausiblyBelongsToRecording(start: recStart, end: recEnd))
    }

    /// Strap removed partway through the night still overlaps > 50% of the
    /// recording — must be accepted (don't reject legitimate short-strap nights).
    func testAcceptsStrapRemovedBeforeWake() {
        let recStart = Date(timeIntervalSince1970: 1_785_600_000)
        let recEnd = recStart.addingTimeInterval(5 * 3600) // strap off after 5h
        let night = sleep(start: recStart.addingTimeInterval(13 * 60), end: recStart.addingTimeInterval(6.75 * 3600))
        XCTAssertTrue(night.plausiblyBelongsToRecording(start: recStart, end: recEnd))
    }

    /// Strap LEFT RUNNING for hours past wake (recording ≫ sleep) — the app
    /// explicitly supports this (History slots by sleepEnd for exactly this
    /// case), so the real sleep block must be accepted even though it's a small
    /// fraction of the very long recording. Regression guard: a denominator of
    /// the recording duration (rather than the shorter span) would reject this.
    func testAcceptsStrapLeftRunningLongPastWake() {
        let recStart = Date(timeIntervalSince1970: 1_785_600_000)
        let recEnd = recStart.addingTimeInterval(15 * 3600) // strap on 15h
        let night = sleep(start: recStart.addingTimeInterval(30 * 60), end: recStart.addingTimeInterval(7.5 * 3600)) // 7h sleep early
        XCTAssertTrue(night.plausiblyBelongsToRecording(start: recStart, end: recEnd))
    }

    /// No usable sleep window → nothing to reject (returns true).
    func testNoSleepWindowIsPermitted() {
        let recStart = Date(timeIntervalSince1970: 1_785_600_000)
        let recEnd = recStart.addingTimeInterval(3600)
        let empty = SleepData(
            date: recStart, totalSleepMinutes: 0, inBedMinutes: 0,
            awakeMinutes: 0, sleepEfficiency: 0, boundarySource: .recordingBounds
        )
        XCTAssertTrue(empty.plausiblyBelongsToRecording(start: recStart, end: recEnd))
    }
}
