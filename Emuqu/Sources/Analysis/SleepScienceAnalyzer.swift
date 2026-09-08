import Foundation

// `typealias Wts = <WeightsStruct>` is deliberate. These are dense linear
// combinations — `(1 - ranks.hr[i]) * Wts.hr + ranks.rmssd[i] * Wts.rmssd + …` —
// where the alias exists so one formula fits on one line and reads like the
// equation it implements. Spelling it out wraps every term and makes the
// structure harder to check against the paper.
//
// Not `W`: that would need the type-name rule switched off for the whole
// file. The rule's three-character minimum costs two characters
// here and buys back a blanket waiver.
enum SleepScienceAnalyzer {
    /// Complete sleep science analysis results
    struct SleepAnalysis {
        let fragmentationIndex: Double // 0-100, lower = better consolidated sleep
        let awakeningCount: Int // Number of wake episodes during sleep
        let sleepCycles: [SleepCycle] // Detected NREM→REM cycles
        let cycleCount: Int // Total complete cycles
        let architecture: SleepArchitecture // Deep/REM distribution analysis
        let ageNorms: AgeAdjustedNorms? // Age-specific stage targets (nil if no birthday)
        let enhancedScore: Double // 0-100 enhanced sleep score incorporating all metrics
    }

    /// A single detected NREM→REM sleep cycle
    struct SleepCycle {
        let cycleNumber: Int
        let start: Date
        let end: Date
        let nremMinutes: Int // Deep + Light minutes in this cycle
        let remMinutes: Int
        let durationMinutes: Int

        var isComplete: Bool {
            remMinutes > 0
        }
    }

    /// Sleep architecture analysis — how stages are distributed across the night
    struct SleepArchitecture {
        let deepFrontLoaded: Bool // Deep sleep concentrated in first half (healthy pattern)
        let remBackLoaded: Bool // REM concentrated in second half (healthy pattern)
        let firstHalfDeepPercent: Double // % of deep sleep in first half of night
        let secondHalfREMPercent: Double // % of REM in second half of night
        let architectureScore: Double // 0-100, how well stages follow expected distribution

        /// No stage timeline to read — a neutral 50 rather than a zero, which
        /// would score a strap-only night as if its architecture were bad.
        static let unknown = SleepArchitecture(
            deepFrontLoaded: false, remBackLoaded: false,
            firstHalfDeepPercent: 0, secondHalfREMPercent: 0,
            architectureScore: 50
        )
    }

    /// Age-adjusted stage norms based on Ohayon et al. (2004) meta-analysis
    struct AgeAdjustedNorms {
        let age: Int
        let expectedDeepPercent: ClosedRange<Double> // Expected deep sleep % range
        let expectedREMPercent: ClosedRange<Double> // Expected REM % range
        let expectedEfficiency: Double // Expected minimum efficiency
        let deepDeviation: Double // How far actual deep% deviates from midpoint (negative = below)
        let remDeviation: Double // How far actual REM% deviates from midpoint
        let isDeepInRange: Bool
        let isREMInRange: Bool
    }

    // MARK: - Main Analysis

    /// Run full sleep science analysis on sleep data.
    /// - Parameters:
    ///   - sleepData: HealthKit sleep data (can be adjusted)
    ///   - userAge: User's age in years (nil if birthday not set)
    ///   - typicalSleepHours: User's sleep target
    /// - Returns: Complete sleep analysis, or nil if insufficient data
    static func analyze(
        sleepData: SleepData,
        userAge: Int?,
        typicalSleepHours: Double
    ) -> SleepAnalysis? {
        guard sleepData.nightSleepMinutes > 0 else { return nil }
        let intervals = sleepData.stageIntervals.sorted { $0.start < $1.start }
        let hasStages = sleepData.deepSleepMinutes != nil || sleepData.remSleepMinutes != nil
        let (fragmentationIndex, awakeningCount) = computeFragmentation(intervals: intervals, totalSleepMinutes: sleepData.nightSleepMinutes, awakeMinutes: sleepData.awakeMinutes)
        let cycles = hasStages ? detectSleepCycles(intervals: intervals) : []
        let architecture: SleepArchitecture = hasStages ? analyzeArchitecture(intervals: intervals, sleepData: sleepData) : .unknown
        let ageNorms = hasStages ? ageNorms(userAge: userAge, sleepData: sleepData) : nil
        let completeCycles = cycles.filter(\.isComplete).count
        return SleepAnalysis(
            fragmentationIndex: fragmentationIndex, awakeningCount: awakeningCount,
            sleepCycles: cycles, cycleCount: completeCycles,
            architecture: architecture, ageNorms: ageNorms,
            enhancedScore: computeEnhancedScore(
                sleepData: sleepData, typicalSleepHours: typicalSleepHours,
                fragmentationIndex: fragmentationIndex, cycleCount: completeCycles,
                architecture: architecture, ageNorms: ageNorms
            )
        )
    }

    /// Age norms need both an age and a stage breakdown to compare against.
    private static func ageNorms(userAge: Int?, sleepData: SleepData) -> AgeAdjustedNorms? {
        guard let age = userAge, sleepData.nightSleepMinutes > 0 else { return nil }
        let night = Double(sleepData.nightSleepMinutes)
        return computeAgeNorms(
            age: age,
            deepPercent: Double(sleepData.deepSleepMinutes ?? 0) / night * 100,
            remPercent: Double(sleepData.remSleepMinutes ?? 0) / night * 100,
            efficiency: sleepData.sleepEfficiency
        )
    }

    // MARK: - Fragmentation Index

    /// Compute sleep fragmentation index (0-100) and awakening count.
    /// Fragmentation = how disrupted sleep is, based on wake episodes and brief arousals.
    /// Lower index = better consolidated sleep.
    ///
    /// Formula: (awakenings per hour × 10) + (wake% × 2), capped at 100
    /// Reference: Haba-Rubio et al. (2004) sleep fragmentation index
    static func computeFragmentation(
        intervals: [HealthKitManager.SleepStageInterval],
        totalSleepMinutes: Int,
        awakeMinutes: Int
    ) -> (index: Double, awakeningCount: Int) {
        guard totalSleepMinutes > 0 else { return (0, 0) }

        let awakeningCount = countAwakenings(intervals)

        let totalHours = Double(totalSleepMinutes + awakeMinutes) / 60.0
        let awakeningsPerHour = totalHours > 0 ? Double(awakeningCount) / totalHours : 0
        let wakePercent = Double(awakeMinutes) / Double(totalSleepMinutes + awakeMinutes) * 100

        // Composite index: weighted combination
        let index = min(100, awakeningsPerHour * SleepScienceConstants.fragmentationAwakeningsWeight + wakePercent * SleepScienceConstants.fragmentationWakePercentWeight)

        return (index, awakeningCount)
    }

    /// Distinct awake episodes — consecutive awake intervals are one awakening,
    /// not several.
    private static func countAwakenings(_ intervals: [HealthKitManager.SleepStageInterval]) -> Int {
        var awakeningCount = 0
        var previousWasAwake = false
        for interval in intervals {
            if interval.stage == .awake, !previousWasAwake { awakeningCount += 1 }
            previousWasAwake = interval.stage == .awake
        }
        return awakeningCount
    }

    // MARK: - Sleep Cycle Detection

    /// Detect NREM→REM sleep cycles from stage intervals.
    /// A typical sleep cycle is 80-120 minutes: NREM (deep+light) followed by REM.
    /// The first cycle tends to have more deep sleep, later cycles more REM.
    static func detectSleepCycles(
        intervals: [HealthKitManager.SleepStageInterval]
    ) -> [SleepCycle] {
        // Awake intervals are not part of any cycle.
        let sleepIntervals = intervals.filter { $0.stage != .awake }
        guard let firstInterval = sleepIntervals.first else { return [] }
        var builder = SleepCycleBuilder(cycleStart: firstInterval.start)
        for interval in sleepIntervals {
            builder.consume(interval)
        }
        guard let lastEnd = sleepIntervals.last?.end else { return builder.cycles }
        return builder.finish(at: lastEnd)
    }

    /// Walks the stage timeline accumulating NREM/REM minutes, closing a cycle
    /// once 15 minutes of NREM have followed a REM bout.
    private struct SleepCycleBuilder {
        var cycles: [SleepCycle] = []
        var cycleStart: Date
        private var nremMinutes = 0
        private var remMinutes = 0
        private var inREM = false
        /// Consecutive non-REM minutes since the last REM interval.
        private var remExitCount = 0

        init(cycleStart: Date) {
            self.cycleStart = cycleStart
        }

        mutating func consume(_ interval: HealthKitManager.SleepStageInterval) {
            let minutes = interval.durationMinutes
            guard interval.stage != .rem else {
                inREM = true
                remExitCount = 0
                remMinutes += minutes
                return
            }
            guard inREM else {
                nremMinutes += minutes
                return
            }
            remExitCount += minutes
            guard remExitCount >= 15 else {
                nremMinutes += minutes
                return
            }
            closeCycle(at: interval.start)
        }

        private mutating func closeCycle(at end: Date) {
            cycles.append(SleepCycle(
                cycleNumber: cycles.count + 1,
                start: cycleStart,
                end: end,
                nremMinutes: nremMinutes,
                remMinutes: remMinutes,
                durationMinutes: nremMinutes + remMinutes
            ))
            cycleStart = end
            // The non-REM minutes that ended this cycle open the next one.
            nremMinutes = remExitCount
            remMinutes = 0
            inREM = false
            remExitCount = 0
        }

        /// Closes the final cycle when it has meaningful content.
        mutating func finish(at lastEnd: Date) -> [SleepCycle] {
            guard nremMinutes + remMinutes >= 30 else { return cycles }
            cycles.append(SleepCycle(
                cycleNumber: cycles.count + 1,
                start: cycleStart,
                end: lastEnd,
                nremMinutes: nremMinutes,
                remMinutes: remMinutes,
                durationMinutes: nremMinutes + remMinutes
            ))
            return cycles
        }
    }

    // MARK: - Sleep Architecture

    /// Analyze how sleep stages are distributed across the night.
    /// Healthy pattern: deep sleep front-loaded (first half), REM back-loaded (second half).
    static func analyzeArchitecture(
        intervals: [HealthKitManager.SleepStageInterval],
        sleepData: SleepData
    ) -> SleepArchitecture {
        guard let sleepStart = sleepData.sleepStart, let sleepEnd = sleepData.sleepEnd else {
            return .unknown
        }
        let midpoint = sleepStart.addingTimeInterval(sleepEnd.timeIntervalSince(sleepStart) / 2)
        let halves = stageMinutesPerHalf(intervals: intervals, midpoint: midpoint)
        // Clamp to 100: the per-half interval sums are accumulated independently
        // of the aggregate deep/rem totals, so rounding or clipped intervals can
        // push the ratio slightly over 100% — the exposed field must stay a valid
        // percentage.
        let firstHalfDeepPercent = share(halves.firstDeep, of: sleepData.deepSleepMinutes)
        let secondHalfREMPercent = share(halves.secondREM, of: sleepData.remSleepMinutes)
        return SleepArchitecture(
            deepFrontLoaded: firstHalfDeepPercent >= 55,
            remBackLoaded: secondHalfREMPercent >= 55,
            firstHalfDeepPercent: firstHalfDeepPercent,
            secondHalfREMPercent: secondHalfREMPercent,
            // Deep front-loading is worth 50 points, REM back-loading 50: a
            // fully front-loaded night scores the full half.
            architectureScore: min(100, min(50, firstHalfDeepPercent) + min(50, secondHalfREMPercent))
        )
    }

    /// Clamped to 100: the per-half interval sums are accumulated independently
    /// of the aggregate totals, so rounding or clipped intervals can push the
    /// ratio slightly over 100% — the exposed field must stay a percentage.
    private static func share(_ halfMinutes: Int, of totalMinutes: Int?) -> Double {
        guard let total = totalMinutes, total > 0 else { return 0 }
        return min(100, Double(halfMinutes) / Double(total) * 100)
    }

    /// Deep and REM minutes either side of the night's midpoint. Intervals that
    /// span the midpoint are split in proportion to how much of them fell on
    /// each side.
    private static func stageMinutesPerHalf(
        intervals: [HealthKitManager.SleepStageInterval],
        midpoint: Date
    ) -> HalfNightStages {
        var halves = HalfNightStages()
        for interval in intervals {
            halves.add(interval, midpoint: midpoint)
        }
        return halves
    }

    /// Deep and REM minutes accumulated per half of the night.
    private struct HalfNightStages {
        var firstDeep = 0
        var secondDeep = 0
        var firstREM = 0
        var secondREM = 0

        mutating func add(_ interval: HealthKitManager.SleepStageInterval, midpoint: Date) {
            let minutes = interval.durationMinutes
            if interval.end <= midpoint {
                addFirst(interval.stage, minutes)
            } else if interval.start >= midpoint {
                addSecond(interval.stage, minutes)
            } else {
                // Spans the midpoint — split proportionally.
                let fraction = midpoint.timeIntervalSince(interval.start) / interval.end.timeIntervalSince(interval.start)
                let firstMin = Int(Double(minutes) * fraction)
                addFirst(interval.stage, firstMin)
                addSecond(interval.stage, minutes - firstMin)
            }
        }

        private mutating func addFirst(_ stage: HealthKitManager.SleepStage, _ minutes: Int) {
            if stage == .deep { firstDeep += minutes }
            if stage == .rem { firstREM += minutes }
        }

        private mutating func addSecond(_ stage: HealthKitManager.SleepStage, _ minutes: Int) {
            if stage == .deep { secondDeep += minutes }
            if stage == .rem { secondREM += minutes }
        }
    }

    // MARK: - Age-Adjusted Norms

    /// Compute age-adjusted sleep stage norms.
    /// Based on Ohayon et al. (2004) meta-analysis of 65 studies:
    /// - Deep sleep declines ~2% per decade after age 20
    /// - REM remains relatively stable (20-25%) until old age
    /// - Sleep efficiency declines ~3% per decade after 30
    static func computeAgeNorms(
        age: Int,
        deepPercent: Double,
        remPercent: Double,
        efficiency _: Double
    ) -> AgeAdjustedNorms {
        let expected = expectedStages(forAge: age)
        let deepMidpoint = (expected.deep.lowerBound + expected.deep.upperBound) / 2
        let remMidpoint = (expected.rem.lowerBound + expected.rem.upperBound) / 2
        return AgeAdjustedNorms(
            age: age,
            expectedDeepPercent: expected.deep,
            expectedREMPercent: expected.rem,
            expectedEfficiency: expected.efficiency,
            deepDeviation: deepPercent - deepMidpoint,
            remDeviation: remPercent - remMidpoint,
            isDeepInRange: expected.deep.contains(deepPercent),
            isREMInRange: expected.rem.contains(remPercent)
        )
    }

    /// Expected deep %, REM % and efficiency by decade, from Ohayon 2004.
    private static func expectedStages(
        forAge age: Int
    ) -> (deep: ClosedRange<Double>, rem: ClosedRange<Double>, efficiency: Double) {
        switch age {
        case ..<20: (17.0 ... 25.0, 20.0 ... 25.0, 90.0)
        case 20 ..< 30: (15.0 ... 22.0, 20.0 ... 25.0, 88.0)
        case 30 ..< 40: (13.0 ... 20.0, 19.0 ... 24.0, 85.0)
        case 40 ..< 50: (10.0 ... 18.0, 18.0 ... 23.0, 83.0)
        case 50 ..< 60: (8.0 ... 15.0, 17.0 ... 22.0, 80.0)
        case 60 ..< 70: (5.0 ... 13.0, 16.0 ... 21.0, 78.0)
        default: (3.0 ... 10.0, 15.0 ... 20.0, 75.0) // 70+
        }
    }

    // MARK: - Enhanced Sleep Score

    /// Compute an enhanced sleep score incorporating all science metrics.
    /// Builds on the basic duration+efficiency+stages formula by adding:
    /// - Fragmentation penalty (disrupted sleep = worse recovery)
    /// - Cycle bonus (achieving full cycles = better architecture)
    /// - Architecture bonus (proper stage distribution)
    /// - Age-adjusted scoring (grade against your age group, not population)
    ///
    /// Weights: Duration 25%, Efficiency 20%, Stages 20%, Fragmentation 15%,
    ///          Cycles 10%, Architecture 10%
    /// Enhanced-score section weights and targets. Not inline
    /// literals throughout the function below: the doc comment advertises
    /// the weighting, so the table IS the
    /// weighting. Sections sum to 100.
    enum EnhancedScoreWeights {
        static let durationPoints = 25.0
        static let efficiencyPoints = 20.0
        /// Stage points split evenly: deep half + REM half.
        static let stageHalfPoints = 10.0
        static let fragmentationPoints = 15.0
        static let cyclePoints = 10.0
        static let architecturePoints = 10.0
        /// Ratio cap so oversleeping / over-efficiency can't inflate a section.
        static let ratioCap = 1.1
        /// Population deep/REM percentage targets (no age norms available).
        static let populationDeepTargetPct = 20.0
        static let populationREMTargetPct = 25.0
        /// Points lost per percentage-point of below-range stage deviation.
        static let deviationPenaltySlope = 0.5
        /// Nominal sleep-cycle length (hours) for the expected-cycle count.
        static let cycleLengthHours = 1.5
        static let minimumExpectedCycles = 3
        /// #15 — duration-debt ceiling. Below this raw duration ratio
        /// (actual/target) the enhanced score is capped so strong efficiency
        /// can't hide a short night. At the threshold the cap is
        /// `durationDebtCeilingAtThreshold`, falling linearly to
        /// `durationDebtCeilingFloor` at ratio 0.
        static let durationDebtRatioThreshold = 0.85
        static let durationDebtCeilingAtThreshold = 90.0
        static let durationDebtCeilingFloor = 60.0
    }

    static func computeEnhancedScore(
        sleepData: SleepData,
        typicalSleepHours: Double,
        fragmentationIndex: Double,
        cycleCount: Int,
        architecture: SleepArchitecture,
        ageNorms: AgeAdjustedNorms?
    ) -> Double {
        typealias Wts = EnhancedScoreWeights
        let targetHours = max(typicalSleepHours, 1.0)
        let sleepHours = Double(sleepData.nightSleepMinutes) / 60.0
        // 24-hour sleep for the DURATION component: the consolidated night plus
        // any qualifying daytime nap. A nap discharges homeostatic sleep pressure,
        // so a night that was "front-loaded" by a nap and came out short is not
        // sleep debt (Nature Sci Reports s41598-021-84625-8). Nap time feeds the
        // duration score and the duration-debt ceiling ONLY; efficiency, stages,
        // fragmentation, and cycles stay computed on the night alone.
        let durationHours = Double(sleepData.totalSleepIncludingNapMinutes) / 60.0
        // Fragmentation is inverted: index 0 -> full points, 50 -> half, 100 -> 0.
        // 4-5 complete cycles is ideal for 7-8h sleep.
        let expectedCycles = max(Wts.minimumExpectedCycles, Int(sleepHours / Wts.cycleLengthHours))
        let total = min(durationHours / targetHours, Wts.ratioCap) * Wts.durationPoints
            + efficiencyRatio(sleepData: sleepData, ageNorms: ageNorms) * Wts.efficiencyPoints
            + stagesScore(sleepData: sleepData, ageNorms: ageNorms)
            + max(0, Wts.fragmentationPoints * (1.0 - fragmentationIndex / 100.0))
            + min(Double(cycleCount) / Double(expectedCycles), 1.0) * Wts.cyclePoints
            + architecture.architectureScore / 100.0 * Wts.architecturePoints
        return min(100, max(0, durationDebtCapped(total, ratio: durationHours / targetHours)))
    }

    private static func efficiencyRatio(
        sleepData: SleepData,
        ageNorms: AgeAdjustedNorms?
    ) -> Double {
        typealias Wts = EnhancedScoreWeights
        guard let norms = ageNorms else {
            return min(sleepData.sleepEfficiency / SleepConstants.goodEfficiency, Wts.ratioCap)
        }
        // Score relative to age-expected efficiency.
        return min(sleepData.sleepEfficiency / norms.expectedEfficiency, Wts.ratioCap)
    }

    /// Deep + REM adequacy. Neutral half-credit when the night carried no stage
    /// data at all, so a strap-only night is neither rewarded nor punished.
    private static func stagesScore(
        sleepData: SleepData,
        ageNorms: AgeAdjustedNorms?
    ) -> Double {
        typealias Wts = EnhancedScoreWeights
        guard let deep = sleepData.deepSleepMinutes, sleepData.nightSleepMinutes > 0 else {
            return Wts.stageHalfPoints
        }
        guard let norms = ageNorms else {
            let deepPct = Double(deep) / Double(sleepData.nightSleepMinutes) * 100
            let remPct = Double(sleepData.remSleepMinutes ?? 0) / Double(sleepData.nightSleepMinutes) * 100
            return min(Wts.stageHalfPoints, (deepPct / Wts.populationDeepTargetPct) * Wts.stageHalfPoints)
                + min(Wts.stageHalfPoints, (remPct / Wts.populationREMTargetPct) * Wts.stageHalfPoints)
        }
        return ageAdjustedStagesScore(norms)
    }

    /// Above-range deep/REM is not penalized — more SWS is universally
    /// beneficial (Dijk 2010, Tasali 2008), and REM above range is not a
    /// recovery concern. Only below-range values reduce the score.
    private static func ageAdjustedStagesScore(_ norms: AgeAdjustedNorms) -> Double {
        typealias Wts = EnhancedScoreWeights
        let deepScore = (norms.isDeepInRange || norms.deepDeviation > 0)
            ? Wts.stageHalfPoints
            : max(0, Wts.stageHalfPoints - abs(norms.deepDeviation) * Wts.deviationPenaltySlope)
        let remScore = (norms.isREMInRange || norms.remDeviation > 0)
            ? Wts.stageHalfPoints
            : max(0, Wts.stageHalfPoints - abs(norms.remDeviation) * Wts.deviationPenaltySlope)
        return deepScore + remScore
    }

    /// #15 — duration-debt ceiling. Duration is only 25% of the score, so a
    /// night well short of target (e.g. 5h vs 8h, ratio ~0.63) can still reach
    /// ~90 on strong efficiency/deep/architecture — contradicting the "recovery
    /// will be impaired" duration narrative. Below the threshold, cap the score
    /// (scaled by the shortfall) so efficiency can't paper over the debt. Only
    /// lowers scores; a well-slept night is untouched.
    private static func durationDebtCapped(_ total: Double, ratio rawDurationRatio: Double) -> Double {
        typealias Wts = EnhancedScoreWeights
        guard rawDurationRatio < Wts.durationDebtRatioThreshold else { return total }
        let ceiling = Wts.durationDebtCeilingFloor
            + (rawDurationRatio / Wts.durationDebtRatioThreshold)
            * (Wts.durationDebtCeilingAtThreshold - Wts.durationDebtCeilingFloor)
        return min(total, ceiling)
    }

    // MARK: - Adjusted Sleep Data Builder

    /// Build a SleepData from the timeline editor's state. Covers add / remove /
    /// split / merge / carve-awake / drag-boundaries — everything the
    /// slider-based flow couldn't do.
    ///
    /// User-added intervals contribute to `totalSleepMinutes` (so the recovery
    /// Sleep factor reflects the manual declaration) but are stored with
    /// `.unspecified` stage, so deep/REM sub-scores are *not* inflated by
    /// unverifiable data.
    static func buildSleepDataFromTimelineState(
        original: SleepData,
        state: SleepTimelineState
    ) -> SleepData {
        guard !state.segments.isEmpty else { return original }
        var allIntervals: [HealthKitManager.SleepStageInterval] = []
        var envelopeUnspecifiedTotal = 0
        let adjustedSegments = state.segments.map { seg in
            adjustedSegment(
                seg, original: original,
                allIntervals: &allIntervals,
                envelopeUnspecifiedTotal: &envelopeUnspecifiedTotal
            )
        }
        return rebuiltSleepData(
            original: original, state: state, segments: adjustedSegments,
            intervals: allIntervals, envelopeUnspecified: envelopeUnspecifiedTotal
        )
    }

    private static func rebuiltSleepData(
        original: SleepData,
        state: SleepTimelineState,
        segments adjustedSegments: [HealthKitManager.SleepSegment],
        intervals allIntervals: [HealthKitManager.SleepStageInterval],
        envelopeUnspecified envelopeUnspecifiedTotal: Int
    ) -> SleepData {
        let total = SleepMergingPipeline.accumulateStageMinutes(allIntervals)
        let totalSleepMinutes = total.totalSleep + envelopeUnspecifiedTotal
        let inBedMinutes = totalSleepMinutes + total.awake
        return SleepData(
            date: original.date, inBedStart: original.inBedStart,
            sleepStart: state.segments.map(\.start).min() ?? original.sleepStart,
            sleepEnd: state.segments.map(\.end).max() ?? original.sleepEnd,
            totalSleepMinutes: totalSleepMinutes, inBedMinutes: inBedMinutes,
            deepSleepMinutes: original.deepSleepMinutes != nil ? total.deep : nil,
            remSleepMinutes: original.remSleepMinutes != nil ? total.rem : nil,
            awakeMinutes: total.awake,
            sleepEfficiency: inBedMinutes > 0 ? Double(totalSleepMinutes) / Double(inBedMinutes) * 100.0 : original.sleepEfficiency,
            boundarySource: original.boundarySource, segments: adjustedSegments,
            stageIntervals: allIntervals, boundaryValidation: original.boundaryValidation,
            hrSleepQuality: original.hrSleepQuality,
            splitGapMinutes: original.splitGapMinutes, edits: state.edits
        )
    }

    /// One edited segment, clipped to its own bounds, with its intervals
    /// appended to the running timeline.
    ///
    /// Counts ALL unspecified-stage minutes toward the total, not
    /// just user-declared ones. A provenance filter
    /// (`.userAdded`/`.userAdjusted` only) silently drops
    /// iPhone/Watch/HRV-derived unspecified minutes — but the editor's summary
    /// card counts them (`StageMinutes.totalSleep`), so Done persisted a
    /// fraction of what the editor displayed. For an iPhone-only night (all
    /// intervals `.unspecified`, `.iphone` provenance) the saved total was
    /// ZERO: the user's trim of the bogus 8 PM start saved a 0-minute snapshot,
    /// which the next automatic HK refresh then trivially "improved" over — the
    /// edit never stuck. (`.userAdjusted` is also never assigned anywhere, so
    /// half that filter was dead.) Unspecified stays excluded from deep/REM
    /// sub-scores, so those are still not inflated.
    ///
    /// Interval-less envelope segments (strap-only / HR-estimated nights
    /// produce `intervals: []`, see SleepTimelineEditModel's fallback) count
    /// their envelope duration as unspecified sleep instead of zero.
    private static func adjustedSegment(
        _ seg: SleepTimelineState.Segment,
        original: SleepData,
        allIntervals: inout [HealthKitManager.SleepStageInterval],
        envelopeUnspecifiedTotal: inout Int
    ) -> HealthKitManager.SleepSegment {
        let clipped = SleepMergingPipeline.clipIntervals(seg.intervals, to: seg.start, end: seg.end)
        allIntervals.append(contentsOf: clipped)
        let stages = SleepMergingPipeline.accumulateStageMinutes(clipped)
        var segSleepMin = stages.totalSleep
        if clipped.isEmpty {
            segSleepMin = max(0, Int(seg.end.timeIntervalSince(seg.start) / 60))
            envelopeUnspecifiedTotal += segSleepMin
        }
        return HealthKitManager.SleepSegment(
            sleepStart: seg.start,
            sleepEnd: seg.end,
            totalSleepMinutes: segSleepMin,
            deepSleepMinutes: original.deepSleepMinutes != nil ? stages.deep : nil,
            remSleepMinutes: original.remSleepMinutes != nil ? stages.rem : nil,
            coreSleepMinutes: original.deepSleepMinutes != nil ? stages.core : nil,
            awakeMinutes: stages.awake
        )
    }
}
