@testable import Emuqu
import HealthKit
import XCTest

/// What Emuqu may write into Apple Health: samples HealthKit can hold without
/// raising an uncatchable exception, resting heart rate only from the
/// overnight reading, and a re-export that replaces the session's earlier
/// samples without losing or doubling them.
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

    // MARK: - Replacing an earlier export

    /// A save that fails leaves the earlier export in Health, untouched.
    func testFailedSaveLeavesTheEarlierExport() async throws {
        let store = InMemoryHealthSampleStore()
        let writes = HealthKitManager(settingsProvider: { UserSettings() }, sampleStore: store).writes
        let id = UUID()
        try await writes.exportSleepToHealthKit(sleepData: sleepData(stages: [stage(0, 7_200)]), sessionId: id)
        let first = store.samples
        XCTAssertEqual(first.count, 2, "the in-bed span and one stage")
        store.failNextSave = true
        do {
            try await writes.exportSleepToHealthKit(sleepData: sleepData(stages: [stage(0, 3_600), stage(3_600, 7_200)]), sessionId: id)
            XCTFail("the failed save must be reported")
        } catch {}
        XCTAssertTrue(store.samples.elementsEqual(first, by: ===), "the earlier export is still there, alone")
    }

    /// A delete that fails is reported, and the next export of the session
    /// removes both earlier sets.
    func testFailedDeleteIsReportedAndTheNextExportLeavesOneSet() async throws {
        let store = InMemoryHealthSampleStore()
        let writes = HealthKitManager(settingsProvider: { UserSettings() }, sampleStore: store).writes
        let session = sessionWithBeats(minutes: 12)
        let result = analysisResult(nocturnalMedianHR: nil)
        try await writes.exportHRV(session: session, result: result)
        let setSize = store.samples.count
        XCTAssertGreaterThan(setSize, 1, "a windowed series")
        store.failNextDelete = true
        do {
            try await writes.exportHRV(session: session, result: result)
            XCTFail("the failed delete must be reported")
        } catch {}
        XCTAssertEqual(store.samples.count, 2 * setSize, "the new set is saved beside the one not deleted")
        try await writes.exportHRV(session: session, result: result)
        XCTAssertEqual(store.samples.count, setSize, "the next export removes both earlier sets")
    }

    /// Two exports of one session that overlap leave one set: the second
    /// reads what the first saved, not what was there before either.
    func testOverlappingExportsOfOneSessionLeaveOneSet() async throws {
        let store = InMemoryHealthSampleStore()
        let manager = HealthKitManager(settingsProvider: { UserSettings() }, sampleStore: store)
        let session = sessionWithBeats(minutes: 10)
        let points = try XCTUnwrap(session.rrSeries?.points)
        let (sessionStart, id) = (start, session.id)
        let first = Task { try await manager.exportHeartRateSeries(from: points, sessionStart: sessionStart, sessionId: id) }
        let second = Task { try await manager.exportHeartRateSeries(from: points, sessionStart: sessionStart, sessionId: id) }
        try await first.value
        try await second.value
        XCTAssertEqual(store.samples.count, 10, "one sample per minute, once")
    }

    /// Deleting a session forever waits for its running export and then
    /// removes what that export wrote.
    func testRemovalAfterAnOverlappingExportLeavesNothing() async throws {
        let store = InMemoryHealthSampleStore()
        let writes = HealthKitManager(settingsProvider: { UserSettings() }, sampleStore: store).writes
        let session = sessionWithBeats(minutes: 12)
        let result = analysisResult(nocturnalMedianHR: nil)
        let span = (start, start.addingTimeInterval(720))
        let export = Task { try await writes.exportHRV(session: session, result: result) }
        let removal = Task { try await writes.removeExportedHRV(sessionId: session.id, from: span.0, to: span.1) }
        try await export.value
        try await removal.value
        XCTAssertTrue(store.samples.isEmpty)
    }

    /// A save Health never answers fails that replacement once its timeout
    /// passes, and the next replacement under the same key still runs.
    func testAHungSaveFailsAndFreesItsKey() async throws {
        let store = InMemoryHealthSampleStore()
        let replacer = HealthSampleReplacer(store: store)
        let type = try XCTUnwrap(HKTypes.quantity(.heartRate))
        let replacement = HealthSampleReplacement(
            type: type, span: nil, timeout: 0.2, label: "hung", serialKey: "one-key", matches: { _ in true }
        )
        let sample = HKQuantitySample(
            type: type, quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 60), start: start, end: start
        )
        store.holdNextSave = true
        do {
            try await replacer.replace([sample], replacement)
            XCTFail("a save that never answers must time out")
        } catch HealthKitManager.HealthKitError.queryTimedOut(let label) {
            XCTAssertEqual(label, "hung save")
        }
        try await replacer.replace([sample], replacement)
        XCTAssertEqual(store.samples.count, 1, "the next replacement under the key ran")
        store.releaseHeldSave()
    }

    /// The series when the beats fill a window; the summary when the
    /// recording is too short; nothing (and nothing removed) for a short
    /// recording whose SDNN is an estimate.
    func testHRVExportShapes() throws {
        let sdnnType = try XCTUnwrap(HKTypes.quantity(.heartRateVariabilitySDNN))
        let measured = analysisResult(nocturnalMedianHR: nil)
        let series = try XCTUnwrap(HealthWriteAndObserve.hrvExportSamples(session: sessionWithBeats(minutes: 12), result: measured, sdnnType: sdnnType))
        XCTAssertEqual(series.count, 3, "two full 5-minute windows and the 2-minute tail")
        let summary = try XCTUnwrap(HealthWriteAndObserve.hrvExportSamples(session: session(.overnight), result: measured, sdnnType: sdnnType))
        XCTAssertEqual(summary.count, 1)
        var estimated = measured
        estimated.estimatedMetrics = [EstimatedMetric.sdnn.rawValue]
        XCTAssertNil(HealthWriteAndObserve.hrvExportSamples(session: session(.overnight), result: estimated, sdnnType: sdnnType))
    }

    // MARK: - Fixtures

    private func stage(_ from: TimeInterval, _ to: TimeInterval) -> SleepStageInterval {
        SleepStageInterval(
            stage: .core, start: start.addingTimeInterval(from), end: start.addingTimeInterval(to)
        )
    }

    /// An overnight session with `minutes` of beats alternating 980 / 1,020 ms.
    private func sessionWithBeats(minutes: Int) -> HRVSession {
        let points = (0..<(minutes * 60)).map { RRPoint(t_ms: Int64($0) * 1_000, rr_ms: $0.isMultiple(of: 2) ? 980 : 1_020) }
        var session = session(.overnight)
        session.rrSeries = RRSeries(points: points, sessionId: session.id, startDate: start)
        return session
    }

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

/// The Health store a replacement reads, saves to and deletes from, in
/// memory. Each call yields before it acts, so replacements that are not kept
/// apart interleave.
@MainActor
private final class InMemoryHealthSampleStore: HealthSampleStore {
    private(set) var samples: [HKSample] = []
    var failNextSave = false
    var failNextDelete = false
    /// The next save waits until `releaseHeldSave()`, as a Health call that
    /// does not answer.
    var holdNextSave = false
    private var heldSave: CheckedContinuation<Void, Never>?

    struct Failure: Error {}

    func ownSamples(of type: HKSampleType, in span: DateInterval?, timeout _: TimeInterval, label _: String) async throws -> [HKSample] {
        await Task.yield()
        return samples.filter { sample in
            sample.sampleType == type && (span.map { $0.start <= sample.startDate && sample.startDate <= $0.end } ?? true)
        }
    }

    func save(_ new: [HKSample]) async throws {
        await Task.yield()
        if holdNextSave {
            holdNextSave = false
            await withCheckedContinuation { heldSave = $0 }
            return
        }
        if failNextSave {
            failNextSave = false
            throw Failure()
        }
        samples += new
    }

    func delete(_ old: [HKSample]) async throws {
        await Task.yield()
        if failNextDelete {
            failNextDelete = false
            throw Failure()
        }
        samples.removeAll { sample in old.contains { $0 === sample } }
    }

    /// Lets the held save return, writing nothing.
    func releaseHeldSave() {
        heldSave?.resume()
        heldSave = nil
    }
}
