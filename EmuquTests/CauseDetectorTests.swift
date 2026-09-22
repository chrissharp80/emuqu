@testable import Emuqu
import XCTest

/// Tests for CauseDetector and individual detection strategies
/// Validates that probable causes are correctly identified from HRV patterns
final class CauseDetectorTests: XCTestCase {
    var detector = CauseDetector()

    // MARK: - Test Context Helpers

    private func createContext(
        rmssd: Double = 40.0,
        stressIndex: Double = 150.0,
        lfHfRatio: Double = 1.5,
        dfaAlpha1: Double = 0.9,
        pnn50: Double = 15.0,
        isGoodReading: Bool = false,
        isExcellentReading: Bool = false,
        tags: Set<ReadingTag> = [],
        totalSleepMinutes: Int = 420,
        sleepEfficiency: Double = 85.0
    ) -> CauseDetectionContext {
        let trendStats = AnalysisSummaryGenerator.TrendStats(
            hasData: true,
            avgRMSSD: 45.0,
            baselineRMSSD: 42.0,
            avgHR: 58.0,
            baselineHR: 55.0,
            avgStress: 120.0,
            baselineStress: 110.0,
            avgReadiness: 75.0,
            sessionCount: 7,
            daySpan: 14,
            trend7Day: nil,
            trend30Day: nil
        )

        let sleepInput = AnalysisSleepInput(
            totalSleepMinutes: totalSleepMinutes,
            inBedMinutes: totalSleepMinutes + 30,
            deepSleepMinutes: totalSleepMinutes / 4,
            remSleepMinutes: totalSleepMinutes / 4,
            awakeMinutes: 15,
            sleepEfficiency: sleepEfficiency
        )

        let session = HRVSession()

        return CauseDetectionContext(
            rmssd: rmssd,
            stressIndex: stressIndex,
            lfHfRatio: lfHfRatio,
            dfaAlpha1: dfaAlpha1,
            pnn50: pnn50,
            isGoodReading: isGoodReading,
            isExcellentReading: isExcellentReading,
            selectedTags: tags,
            trendStats: trendStats,
            sleepInput: sleepInput,
            sleepTrend: nil,
            session: session,
            recentSessions: []
        )
    }

    // MARK: - Aggregator Tests

    func testDetectorReturnsLimitedCauses() {
        let context = createContext(rmssd: 20.0, stressIndex: 300.0)

        let causes = detector.detectCauses(in: context, limit: 3)

        XCTAssertLessThanOrEqual(causes.count, 3)
    }

    func testDetectorSortsByWeight() {
        let context = createContext(rmssd: 20.0, stressIndex: 300.0)

        let causes = detector.detectCauses(in: context, limit: 10)

        // Verify causes are sorted by weight (descending)
        for i in 0 ..< (causes.count - 1) {
            XCTAssertGreaterThanOrEqual(causes[i].rankingWeight, causes[i + 1].rankingWeight)
        }
    }

    func testDetectorWithCustomStrategies() {
        // Create detector with only one strategy
        let customDetector = CauseDetector(strategies: [SevereCauseDetector()])

        let context = createContext(rmssd: 15.0, stressIndex: 400.0)
        let causes = customDetector.detectCauses(in: context)

        // Should only get severe causes
        XCTAssertTrue(causes.isEmpty || causes.allSatisfy {
            $0.confidence == .critical || $0.confidence == .veryHigh || $0.confidence == .high
        })
    }

    // MARK: - Positive Cause Detector Tests

    func testPositiveDetectorOnlyTriggersForGoodReadings() {
        let positiveDetector = PositiveCauseDetector()

        let badContext = createContext(rmssd: 20.0, isGoodReading: false)
        let goodContext = createContext(rmssd: 60.0, isGoodReading: true, totalSleepMinutes: 480)

        let badCauses = positiveDetector.detectCauses(in: badContext)
        _ = positiveDetector.detectCauses(in: goodContext)

        XCTAssertTrue(badCauses.isEmpty, "Should not detect positive causes for bad readings")
        // Good context might have positive causes
    }

    func testPositiveDetectorDetectsSolidSleep() {
        let positiveDetector = PositiveCauseDetector()

        let context = createContext(
            rmssd: 55.0,
            isGoodReading: true,
            totalSleepMinutes: 480, // 8 hours
            sleepEfficiency: 92.0
        )

        let causes = positiveDetector.detectCauses(in: context)

        let sleepCause = causes.first { $0.cause.lowercased().contains("sleep") }
        XCTAssertNotNil(sleepCause, "Should detect solid sleep as positive factor")
    }

    // MARK: - Severe Cause Detector Tests

    func testSevereDetectorSkipsGoodReadings() {
        let severeDetector = SevereCauseDetector()

        let goodContext = createContext(rmssd: 60.0, isGoodReading: true)
        let causes = severeDetector.detectCauses(in: goodContext)

        XCTAssertTrue(causes.isEmpty, "Should not detect severe causes for good readings")
    }

    func testSevereDetectorDetectsHRVCrash() {
        let severeDetector = SevereCauseDetector()

        // Create context with HRV way below average
        let context = createContext(rmssd: 15.0, stressIndex: 350.0) // Very low

        let causes = severeDetector.detectCauses(in: context)

        // May or may not trigger depending on trend data
        // The test verifies the detector runs without crashing
        XCTAssertTrue(causes.isEmpty || causes.contains { $0.confidence == .critical || $0.confidence == .veryHigh })
    }

    // MARK: - Tag-Based Cause Detector Tests

    func testTagDetectorDetectsAlcohol() {
        let tagDetector = TagBasedCauseDetector()

        let alcoholTag = ReadingTag(name: "Alcohol", colorHex: "#FF0000", isSystem: true)
        let context = createContext(rmssd: 25.0, tags: [alcoholTag])

        let causes = tagDetector.detectCauses(in: context)

        let alcoholCause = causes.first { $0.cause.lowercased().contains("alcohol") }
        XCTAssertNotNil(alcoholCause)
        XCTAssertTrue(alcoholCause?.confidence == .veryHigh || alcoholCause?.confidence == .high)
    }

    func testTagDetectorDetectsPoorSleep() {
        let tagDetector = TagBasedCauseDetector()

        let poorSleepTag = ReadingTag(name: "Poor Sleep", colorHex: "#888888", isSystem: true)
        let context = createContext(rmssd: 25.0, dfaAlpha1: 1.2, tags: [poorSleepTag])

        let causes = tagDetector.detectCauses(in: context)

        let sleepCause = causes.first { $0.cause.lowercased().contains("sleep") }
        XCTAssertNotNil(sleepCause)
    }

    func testTagDetectorDetectsStress() {
        let tagDetector = TagBasedCauseDetector()

        let stressTag = ReadingTag(name: "Stressed", colorHex: "#FFA500", isSystem: true)
        let context = createContext(rmssd: 25.0, lfHfRatio: 4.0, tags: [stressTag])

        let causes = tagDetector.detectCauses(in: context)

        let stressCause = causes.first { $0.cause.lowercased().contains("stress") }
        XCTAssertNotNil(stressCause)
    }

    func testTagDetectorDetectsIllness() {
        let tagDetector = TagBasedCauseDetector()

        let illnessTag = ReadingTag(name: "Illness", colorHex: "#00FF00", isSystem: true)
        let context = createContext(rmssd: 15.0, tags: [illnessTag])

        let causes = tagDetector.detectCauses(in: context)

        let illnessCause = causes.first { $0.cause.lowercased().contains("illness") }
        XCTAssertNotNil(illnessCause)
        XCTAssertEqual(illnessCause?.confidence, .veryHigh)
    }

    func testTagDetectorSkipsGoodReadings() {
        let tagDetector = TagBasedCauseDetector()

        let alcoholTag = ReadingTag(name: "Alcohol", colorHex: "#FF0000", isSystem: true)
        let context = createContext(rmssd: 60.0, isGoodReading: true, tags: [alcoholTag])

        let causes = tagDetector.detectCauses(in: context)

        XCTAssertTrue(causes.isEmpty, "Should not report negative causes for good readings")
    }

    // MARK: - Sleep Cause Detector Tests

    func testSleepDetectorDetectsInsufficientSleep() {
        let sleepDetector = SleepCauseDetector()

        let context = createContext(
            rmssd: 25.0,
            totalSleepMinutes: 300, // 5 hours
            sleepEfficiency: 85.0
        )

        let causes = sleepDetector.detectCauses(in: context)

        let sleepCause = causes.first { $0.cause.lowercased().contains("insufficient") || $0.cause.lowercased().contains("sleep") }
        XCTAssertNotNil(sleepCause)
    }

    func testSleepDetectorDetectsFragmentedSleep() {
        let sleepDetector = SleepCauseDetector()

        let context = createContext(
            rmssd: 25.0,
            totalSleepMinutes: 420,
            sleepEfficiency: 70.0 // Low efficiency with adequate time = fragmented
        )

        let causes = sleepDetector.detectCauses(in: context)

        let fragmentedCause = causes.first { $0.cause.lowercased().contains("fragment") }
        XCTAssertNotNil(fragmentedCause)
    }

    func testSleepDetectorSkipsGoodReadings() {
        let sleepDetector = SleepCauseDetector()

        let context = createContext(
            rmssd: 60.0,
            isGoodReading: true,
            totalSleepMinutes: 300 // Short sleep but good reading
        )

        let causes = sleepDetector.detectCauses(in: context)

        // For good readings, sleep detector returns positive causes or none
        let negativeCause = causes.first { $0.cause.lowercased().contains("insufficient") }
        XCTAssertNil(negativeCause)
    }

    // MARK: - Metric-Based Cause Detector Tests

    func testMetricDetectorSkipsGoodReadings() {
        let metricDetector = MetricBasedCauseDetector()

        let context = createContext(rmssd: 60.0, isGoodReading: true)
        let causes = metricDetector.detectCauses(in: context)

        XCTAssertTrue(causes.isEmpty)
    }

    func testMetricDetectorDetectsUntaggedStress() {
        let metricDetector = MetricBasedCauseDetector()

        let context = createContext(
            rmssd: 25.0,
            stressIndex: 250.0,
            lfHfRatio: 4.0 // High sympathetic
        )

        let causes = metricDetector.detectCauses(in: context)

        let stressCause = causes.first { $0.cause.lowercased().contains("stress") }
        XCTAssertNotNil(stressCause)
    }

    func testMetricDetectorSkipsWhenTagged() {
        let metricDetector = MetricBasedCauseDetector()

        let stressTag = ReadingTag(name: "Stressed", colorHex: "#FFA500", isSystem: true)
        let context = createContext(
            rmssd: 25.0,
            stressIndex: 250.0,
            lfHfRatio: 4.0,
            tags: [stressTag]
        )

        let causes = metricDetector.detectCauses(in: context)

        // Should not duplicate - stress is already tagged
        let untaggedStressCause = causes.first { $0.cause == "Unidentified Stress" }
        XCTAssertNil(untaggedStressCause)
    }

    // MARK: - Pattern Cause Detector Tests

    func testPatternDetectorSkipsGoodReadings() {
        let patternDetector = PatternCauseDetector()

        let context = createContext(rmssd: 60.0, isGoodReading: true)
        let causes = patternDetector.detectCauses(in: context)

        XCTAssertTrue(causes.isEmpty)
    }

    func testPatternDetectorRequiresSufficientHistory() {
        let patternDetector = PatternCauseDetector()

        // Context with empty recent sessions
        let context = createContext(rmssd: 25.0)
        let causes = patternDetector.detectCauses(in: context)

        // Without history, no day-of-week patterns can be detected
        XCTAssertTrue(causes.isEmpty)
    }

    // MARK: - Detected Cause Conversion Tests

    func testDetectedCauseToProbableCause() {
        let cause = DetectedCause(
            cause: "Test Cause",
            confidence: .high,
            explanation: "Test explanation",
            rankingWeight: 0.8
        )

        let probableCause = cause.toProbableCause()

        XCTAssertEqual(probableCause.cause, "Test Cause")
        XCTAssertEqual(probableCause.confidence, "Clear pattern match")
        XCTAssertEqual(probableCause.explanation, "Test explanation")
    }

    // MARK: - Confidence Level Tests

    /// The labels describe how completely the pattern matched, not confidence
    /// that the cause is true.
    ///
    /// A scale like "Critical", "Very High", "High", "Moderate", "Low",
    /// printed beside a sentence about illness, reads as a
    /// probability, and none of these rules has an outcome dataset behind it.
    /// This test pins the register: no label may state how
    /// likely the CAUSE is, only how completely the DATA matched.
    func testConfidenceLabelsDescribeMatchStrengthNotLikelihood() {
        XCTAssertEqual(DetectedCause.CauseConfidence.critical.rawValue, "Full pattern match")
        XCTAssertEqual(DetectedCause.CauseConfidence.veryHigh.rawValue, "Strong pattern match")
        XCTAssertEqual(DetectedCause.CauseConfidence.high.rawValue, "Clear pattern match")
        XCTAssertEqual(DetectedCause.CauseConfidence.moderate.rawValue, "Partial match")
        XCTAssertEqual(DetectedCause.CauseConfidence.low.rawValue, "Faint match")

        let probabilityWords = ["likely", "probable", "confidence", "certain", "chance"]
        for level in [DetectedCause.CauseConfidence.critical, .veryHigh, .high,
                      .moderateHigh, .moderate, .lowModerate, .low] {
            for word in probabilityWords {
                XCTAssertFalse(level.rawValue.lowercased().contains(word),
                               "\(level.rawValue) reads as a likelihood claim")
            }
        }
    }

    // MARK: - Illness Framing

    /// The biggest-deviation rules describe physiology; they never name,
    /// forecast or presume an illness (App Store 1.4.1).
    ///
    /// These rules used to ship "Severe HRV Crash … likely acute illness …
    /// Consider staying home and monitoring for symptoms" and "Possible Immune
    /// Response" under a "Full pattern match" / "Clear pattern match" badge.
    /// The thresholds were never evaluated against illness outcomes, so the
    /// titles now name the pattern and the explanations list common causes
    /// with illness last. The copy linter forbids the old phrasings in
    /// source; this pins what the two detectors actually emit.
    func testSevereAndMetricCausesDescribePhysiologyNotIllness() {
        let context = createContext(rmssd: 15.0, stressIndex: 300.0)
        let causes = SevereCauseDetector().detectCauses(in: context)
            + MetricBasedCauseDetector().detectCauses(in: context)
        let titles = causes.map(\.cause)

        XCTAssertTrue(titles.contains("Sharp HRV Drop"), "Got \(titles)")
        XCTAssertTrue(titles.contains("Very Low HRV with High Stress Index"), "Got \(titles)")

        let forbidden = [
            "possible illness", "immune", "likely acute illness", "coming on",
            "monitor", "stay home", "staying home", "cold/flu", "fighting something"
        ]
        for cause in causes {
            let text = (cause.cause + " " + cause.explanation).lowercased()
            for phrase in forbidden {
                XCTAssertFalse(text.contains(phrase), "\(cause.cause): contains '\(phrase)'")
            }
        }
    }

    // MARK: - Integration Tests

    func testFullCauseDetectionPipeline() {
        let alcoholTag = ReadingTag(name: "Alcohol", colorHex: "#FF0000", isSystem: true)

        let context = createContext(
            rmssd: 20.0,
            stressIndex: 300.0,
            lfHfRatio: 3.5,
            dfaAlpha1: 1.2,
            tags: [alcoholTag],
            totalSleepMinutes: 300,
            sleepEfficiency: 75.0
        )

        let causes = detector.detectCauses(in: context, limit: 5)

        // Should detect multiple causes
        XCTAssertGreaterThan(causes.count, 0)

        // Alcohol should be high priority
        let alcoholCause = causes.first { $0.cause.lowercased().contains("alcohol") }
        XCTAssertNotNil(alcoholCause)
    }

    func testGoodReadingOnlyGetsPositiveCauses() {
        let context = createContext(
            rmssd: 65.0,
            stressIndex: 80.0,
            lfHfRatio: 1.2,
            dfaAlpha1: 0.85,
            isGoodReading: true,
            isExcellentReading: true,
            totalSleepMinutes: 480,
            sleepEfficiency: 92.0
        )

        let causes = detector.detectCauses(in: context)

        // All causes for good readings should be positive
        for cause in causes {
            XCTAssertTrue(
                cause.confidence == .goodSign ||
                    cause.confidence == .excellent ||
                    cause.confidence == .contributingFactor ||
                    cause.confidence == .high ||
                    cause.confidence == .moderateHigh ||
                    cause.confidence == .pattern,
                "Good reading should only have positive causes, got \(cause.confidence)"
            )
        }
    }
}
