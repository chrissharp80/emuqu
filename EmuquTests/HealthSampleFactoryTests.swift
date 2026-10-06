@testable import Emuqu
import HealthKit
import XCTest

/// What Emuqu may write into Apple Health: samples HealthKit can hold without
/// raising an uncatchable exception, and resting heart rate only from the
/// overnight reading.
@MainActor
final class HealthSampleFactoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let bpm = HKUnit.count().unitDivided(by: .minute())

    // MARK: - Sample intervals

    func testForwardAndInstantIntervalsAreValid() {
        XCTAssertTrue(HealthSampleFactory.isValidInterval(start: start, end: start.addingTimeInterval(60)))
        XCTAssertTrue(HealthSampleFactory.isValidInterval(start: start, end: start))
    }

    /// `HKSample` raises NSInvalidArgumentException when end precedes start.
    func testBackwardsIntervalBuildsNoSample() throws {
        let type = try XCTUnwrap(HKQuantityType.quantityType(forIdentifier: .heartRate))
        let sample = HealthSampleFactory.quantitySample(
            type: type, value: 60, unit: bpm, start: start, end: start.addingTimeInterval(-1)
        )
        XCTAssertNil(sample)
        XCTAssertFalse(HealthSampleFactory.isValidInterval(start: start, end: start.addingTimeInterval(-1)))
    }

    func testNonFiniteValueOrDateBuildsNoSample() throws {
        let type = try XCTUnwrap(HKQuantityType.quantityType(forIdentifier: .heartRate))
        for value in [Double.nan, .infinity] {
            XCTAssertNil(HealthSampleFactory.quantitySample(type: type, value: value, unit: bpm, start: start, end: start))
        }
        let undated = start.addingTimeInterval(.nan)
        XCTAssertFalse(HealthSampleFactory.isValidInterval(start: undated, end: start))
    }

    func testValidSampleCarriesItsValueAndSpan() throws {
        let type = try XCTUnwrap(HKQuantityType.quantityType(forIdentifier: .heartRate))
        let end = start.addingTimeInterval(60)
        let sample = try XCTUnwrap(HealthSampleFactory.quantitySample(type: type, value: 58, unit: bpm, start: start, end: end))
        XCTAssertEqual(sample.quantity.doubleValue(for: bpm), 58)
        XCTAssertEqual(sample.startDate, start)
        XCTAssertEqual(sample.endDate, end)
    }

    // MARK: - Sleep export

    /// A night whose stage list holds a backwards interval, and whose in-bed
    /// start is after its end, writes only the intervals HealthKit can hold.
    func testSleepExportDropsBackwardsIntervals() throws {
        let sleepType = try XCTUnwrap(HKCategoryType.categoryType(forIdentifier: .sleepAnalysis))
        let stages = [
            SleepStageInterval(stage: .core, start: start, end: start.addingTimeInterval(1_800)),
            SleepStageInterval(stage: .awake, start: start.addingTimeInterval(3_600), end: start.addingTimeInterval(1_900))
        ]
        let night = sleepData(stages: stages)
        let backwards = HealthWriteAndObserve.sleepExportSamples(
            sleepData: night, sleepType: sleepType, sessionId: UUID(),
            inBedStart: start.addingTimeInterval(7_200), sleepEnd: start
        )
        XCTAssertEqual(backwards.count, 1, "only the forward stage interval")
        XCTAssertTrue(backwards.allSatisfy { $0.endDate >= $0.startDate })
        let forward = HealthWriteAndObserve.sleepExportSamples(
            sleepData: night, sleepType: sleepType, sessionId: UUID(),
            inBedStart: start, sleepEnd: start.addingTimeInterval(7_200)
        )
        XCTAssertEqual(forward.count, 2, "the in-bed span and the forward stage interval")
    }

    // MARK: - Resting heart rate

    /// Resting heart rate is the overnight reading's. A quick reading or a
    /// nap writes none, and neither does a session from Apple Health.
    func testOnlyAnOvernightReadingWritesRestingHeartRate() {
        let result = analysisResult(nocturnalMedianHR: 54)
        XCTAssertEqual(HealthWriteAndObserve.restingHeartRateToExport(session: session(.overnight), result: result), 54)
        for type in [SessionType.quick, .nap, .workout, .breathe] {
            XCTAssertNil(HealthWriteAndObserve.restingHeartRateToExport(session: session(type), result: result), type.rawValue)
        }
        XCTAssertNil(HealthWriteAndObserve.restingHeartRateToExport(
            session: session(.overnight), result: analysisResult(nocturnalMedianHR: nil)
        ))
    }

    /// One per night: the export replaces any resting-heart-rate summary of
    /// Emuqu's nearby, and nothing else.
    func testRestingHeartRateSummaryIdentity() {
        let id = UUID()
        XCTAssertTrue(HeartRateHealthQueries.isRestingHeartRateSummary(
            HealthExportIdentity.summary(sessionId: id, metric: .restingHeartRate)
        ))
        XCTAssertFalse(HeartRateHealthQueries.isRestingHeartRateSummary(
            HealthExportIdentity.summary(sessionId: id, metric: .heartRate)
        ))
        XCTAssertFalse(HeartRateHealthQueries.isRestingHeartRateSummary("not-a-session-rhr"))
        XCTAssertLessThanOrEqual(
            HeartRateHealthQueries.restingHeartRateNightSpan, 12 * 3_600,
            "consecutive nights, about a day apart, never replace each other"
        )
    }

    // MARK: - Fixtures

    private func session(_ type: SessionType) -> HRVSession {
        var session = HRVSession(
            id: UUID(), startDate: start, endDate: start.addingTimeInterval(8 * 3_600), state: .complete,
            rrSeries: nil, analysisResult: nil, artifactFlags: nil
        )
        session.sessionType = type
        return session
    }

    private func sleepData(stages: [SleepStageInterval]) -> SleepData {
        SleepData(
            date: start, inBedStart: start, sleepStart: start, sleepEnd: start.addingTimeInterval(7_200),
            totalSleepMinutes: 120, inBedMinutes: 120, deepSleepMinutes: nil, remSleepMinutes: nil,
            awakeMinutes: 0, sleepEfficiency: 100, boundarySource: .hrEstimated, segments: [],
            stageIntervals: stages, boundaryValidation: nil, hrSleepQuality: nil
        )
    }

    private func analysisResult(nocturnalMedianHR: Double?) -> HRVAnalysisResult {
        HRVAnalysisResult(
            windowStart: 0,
            windowEnd: 600_000,
            timeDomain: TimeDomainMetrics(
                meanRR: 1_000, sdnn: 54, rmssd: 45, pnn50: 20, sdsd: 43, meanHR: 60, sdHR: 3, triangularIndex: 12
            ),
            frequencyDomain: FrequencyDomainMetrics(vlf: 500, lf: 800, hf: 800, lfHfRatio: 1, totalPower: 2_100),
            nonlinear: NonlinearMetrics(
                sd1: 32, sd2: 48, sd1Sd2Ratio: 0.67, sampleEntropy: 1.5, approxEntropy: 1.2,
                dfaAlpha1: 0.95, dfaAlpha2: 0.85, dfaAlpha1R2: 0.95
            ),
            ansMetrics: ANSMetrics(
                stressIndex: 120, pnsIndex: 1.5, snsIndex: -0.5, readinessScore: 7, respirationRate: 14,
                nocturnalHRDip: 12, daytimeRestingHR: 65, nocturnalMedianHR: nocturnalMedianHR
            ),
            artifactPercentage: 3.0,
            cleanBeatCount: 590,
            analysisDate: start
        )
    }
}
