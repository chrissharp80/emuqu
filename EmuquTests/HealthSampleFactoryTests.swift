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
            inBedStart: start.addingTimeInterval(7_200), sleepEnd: start, version: 1
        )
        XCTAssertEqual(backwards.count, 1, "only the forward stage interval")
        XCTAssertTrue(backwards.allSatisfy { $0.endDate >= $0.startDate })
        let forward = HealthWriteAndObserve.sleepExportSamples(
            sleepData: night, sleepType: sleepType, sessionId: UUID(),
            inBedStart: start, sleepEnd: start.addingTimeInterval(7_200), version: 1
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
        let writes = HealthKitManager.forTests(settingsProvider: { UserSettings() }, sampleStore: store).writes
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
    /// removes what it left. A re-analysis that shortened the night writes
    /// fewer windows: the earlier ones it shares an identity with are
    /// replaced by the save, and the one past the new end must be deleted.
    func testFailedDeleteIsReportedAndTheNextExportLeavesOneSet() async throws {
        let store = InMemoryHealthSampleStore()
        let writes = HealthKitManager.forTests(settingsProvider: { UserSettings() }, sampleStore: store).writes
        let long = sessionWithBeats(minutes: 12)
        let short = sessionWithBeats(minutes: 7, id: long.id)
        let result = analysisResult(nocturnalMedianHR: nil)
        try await writes.exportHRV(session: long, result: result)
        XCTAssertEqual(store.samples.count, 3, "two full 5-minute windows and the tail")
        store.failNextDelete = true
        do {
            try await writes.exportHRV(session: short, result: result)
            XCTFail("the failed delete must be reported")
        } catch {}
        XCTAssertEqual(store.samples.count, 3, "two windows replaced, the third not deleted")
        try await writes.exportHRV(session: short, result: result)
        XCTAssertEqual(store.samples.count, 2, "the next export removes what was left")
    }

    /// Exporting a session again with the same identities never doubles it,
    /// and the replacement does not delete the samples HealthKit already
    /// replaced through their sync identifier.
    func testReExportIsReplacedThroughTheSyncIdentifier() async throws {
        let store = InMemoryHealthSampleStore()
        let writes = HealthKitManager.forTests(settingsProvider: { UserSettings() }, sampleStore: store).writes
        let session = sessionWithBeats(minutes: 12)
        let result = analysisResult(nocturnalMedianHR: nil)
        try await writes.exportHRV(session: session, result: result)
        let first = store.samples
        try await writes.exportHRV(session: session, result: result)
        XCTAssertEqual(store.samples.count, first.count)
        XCTAssertEqual(store.deletedReplacedSamples, 0, "nothing HealthKit replaced is deleted again")
        let versions = store.samples.compactMap { $0.metadata?[HKMetadataKeySyncVersion] as? Int }
        let firstVersions = first.compactMap { $0.metadata?[HKMetadataKeySyncVersion] as? Int }
        XCTAssertEqual(versions.count, first.count, "every sample carries a sync version")
        XCTAssertGreaterThan(versions.min() ?? 0, firstVersions.max() ?? .max, "the later export wins")
    }

    /// Deleting a session forever removes every metric it exported, and
    /// nothing another session exported.
    func testRemovingASessionsExportsLeavesOnlyOtherSessions() async throws {
        let store = InMemoryHealthSampleStore()
        let manager = HealthKitManager.forTests(settingsProvider: { UserSettings() }, sampleStore: store)
        let session = sessionWithBeats(minutes: 12)
        let other = sessionWithBeats(minutes: 6)
        let result = analysisResult(nocturnalMedianHR: 52)
        for exported in [session, other] {
            try await manager.writes.exportHRV(session: exported, result: result)
            let points = try XCTUnwrap(exported.rrSeries?.points)
            try await manager.heartRate.exportHeartRateSeries(from: points, sessionStart: start, sessionId: exported.id)
            try await manager.writes.exportSleepToHealthKit(sleepData: sleepData(stages: [stage(0, 7_200)]), sessionId: exported.id)
        }
        let end = try XCTUnwrap(session.endDate)
        try await manager.heartRate.exportRestingHeartRate(value: 52, at: end, sessionId: session.id)
        let othersCount = store.samples.filter { ($0.metadata?[HKMetadataKeyExternalUUID] as? String)?.hasPrefix(other.id.uuidString) == true }.count
        try await manager.writes.removeExports(sessionId: session.id, from: start, to: end)
        XCTAssertEqual(store.samples.count, othersCount)
        XCTAssertTrue(store.samples.allSatisfy {
            ($0.metadata?[HKMetadataKeyExternalUUID] as? String)?.hasPrefix(other.id.uuidString) == true
        })
    }

    /// Two exports of one session that overlap leave one set: the second
    /// reads what the first saved, not what was there before either. The
    /// second is shorter (a trimmed recording), so a second export that read
    /// the store before the first saved would leave the first's last minutes
    /// behind.
    func testOverlappingExportsOfOneSessionLeaveOneSet() async throws {
        let store = InMemoryHealthSampleStore()
        let manager = HealthKitManager.forTests(settingsProvider: { UserSettings() }, sampleStore: store)
        let session = sessionWithBeats(minutes: 10)
        let points = try XCTUnwrap(session.rrSeries?.points)
        let trimmed = try XCTUnwrap(sessionWithBeats(minutes: 6, id: session.id).rrSeries?.points)
        let (sessionStart, id) = (start, session.id)
        let first = Task { try await manager.heartRate.exportHeartRateSeries(from: points, sessionStart: sessionStart, sessionId: id) }
        let second = Task { try await manager.heartRate.exportHeartRateSeries(from: trimmed, sessionStart: sessionStart, sessionId: id) }
        try await first.value
        try await second.value
        XCTAssertEqual(store.samples.count, 6, "one sample per minute of the later export, and no tail of the first")
    }

    /// Deleting a session forever waits for its running export and then
    /// removes what that export wrote.
    func testRemovalAfterAnOverlappingExportLeavesNothing() async throws {
        let store = InMemoryHealthSampleStore()
        let writes = HealthKitManager.forTests(settingsProvider: { UserSettings() }, sampleStore: store).writes
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
        let series = try XCTUnwrap(HealthWriteAndObserve.hrvExportSamples(
            session: sessionWithBeats(minutes: 12), result: measured, sdnnType: sdnnType, version: 1
        ))
        XCTAssertEqual(series.count, 3, "two full 5-minute windows and the 2-minute tail")
        let summary = try XCTUnwrap(HealthWriteAndObserve.hrvExportSamples(
            session: session(.overnight), result: measured, sdnnType: sdnnType, version: 1
        ))
        XCTAssertEqual(summary.count, 1)
        XCTAssertEqual(summary.first?.metadata?[HKMetadataKeySyncIdentifier] as? String, summary.first?.metadata?[HKMetadataKeyExternalUUID] as? String)
        XCTAssertEqual(summary.first?.metadata?[HKMetadataKeySyncVersion] as? Int, 1)
        var estimated = measured
        estimated.estimatedMetrics = [EstimatedMetric.sdnn.rawValue]
        XCTAssertNil(HealthWriteAndObserve.hrvExportSamples(session: session(.overnight), result: estimated, sdnnType: sdnnType, version: 1))
    }

    // MARK: - Fixtures

    private func stage(_ from: TimeInterval, _ to: TimeInterval) -> SleepStageInterval {
        SleepStageInterval(
            stage: .core, start: start.addingTimeInterval(from), end: start.addingTimeInterval(to)
        )
    }

    /// An overnight session with `minutes` of beats alternating 980 / 1,020 ms.
    private func sessionWithBeats(minutes: Int, id: UUID = UUID()) -> HRVSession {
        let points = (0..<(minutes * 60)).map { RRPoint(t_ms: Int64($0) * 1_000, rr_ms: $0.isMultiple(of: 2) ? 980 : 1_020) }
        var session = session(.overnight, id: id)
        session.rrSeries = RRSeries(points: points, sessionId: session.id, startDate: start)
        return session
    }

    private func session(_ type: SessionType, id: UUID = UUID()) -> HRVSession {
        var session = HRVSession(
            id: id, startDate: start, endDate: start.addingTimeInterval(8 * 3_600), state: .complete,
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
/// apart interleave. A save replaces a stored sample with the same sync
/// identifier and a lower sync version, and is dropped against a higher or
/// equal one, as HealthKit does. A workout is saved with the samples that go
/// with it (`saveWorkout(_:with:)`), and read back with them.
@MainActor
final class InMemoryHealthSampleStore: HealthSampleStore {
    private(set) var samples: [HKSample] = []
    /// Samples a delete was asked to remove that a save had already replaced.
    private(set) var deletedReplacedSamples = 0
    /// The sample types of each delete, in the order asked.
    private(set) var deletedTypes: [HKSampleType] = []
    private var replaced: [HKSample] = []
    /// Each stored sample saved with a workout, and that workout.
    private var savedWithWorkout: [(sample: HKSample, workout: HKWorkout)] = []
    var failNextSave = false
    var failNextDelete = false
    /// The next read by time span throws this, as a Health read refused.
    var failNextRead: Error?
    /// The next save waits until `releaseHeldSave()`, as a Health call that
    /// does not answer.
    var holdNextSave = false
    private var heldSave: CheckedContinuation<Void, Never>?

    struct Failure: Error {}

    func ownSamples(of type: HKSampleType, in span: DateInterval?, timeout _: TimeInterval, label _: String) async throws -> [HKSample] {
        await Task.yield()
        if let failure = failNextRead {
            failNextRead = nil
            throw failure
        }
        return samples.filter { sample in
            sample.sampleType == type && (span.map { $0.start <= sample.startDate && sample.startDate <= $0.end } ?? true)
        }
    }

    func ownSamples(of type: HKSampleType, savedWith workout: HKWorkout, timeout _: TimeInterval, label _: String) async throws -> [HKSample] {
        await Task.yield()
        return samples.filter { sample in
            sample.sampleType == type && savedWithWorkout.contains { $0.sample === sample && $0.workout === workout }
        }
    }

    /// Saves a workout and the samples that go with it, as a builder does:
    /// each replaces a stored one by sync identifier, as `save(_:)` does.
    func saveWorkout(_ workout: HKWorkout, with series: [HKSample]) {
        saveReplacingBySync(workout)
        for sample in series {
            saveReplacingBySync(sample)
            savedWithWorkout.append((sample, workout))
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
        for sample in new { saveReplacingBySync(sample) }
    }

    private func saveReplacingBySync(_ sample: HKSample) {
        guard let id = sample.metadata?[HKMetadataKeySyncIdentifier] as? String,
              let version = sample.metadata?[HKMetadataKeySyncVersion] as? Int,
              let index = samples.firstIndex(where: { $0.metadata?[HKMetadataKeySyncIdentifier] as? String == id })
        else { return samples.append(sample) }
        guard (samples[index].metadata?[HKMetadataKeySyncVersion] as? Int ?? 0) < version else { return }
        replaced.append(samples[index])
        samples[index] = sample
    }

    func delete(_ old: [HKSample]) async throws {
        await Task.yield()
        if failNextDelete {
            failNextDelete = false
            throw Failure()
        }
        deletedReplacedSamples += old.filter { sample in replaced.contains { $0 === sample } }.count
        deletedTypes += old.first.map { [$0.sampleType] } ?? []
        samples.removeAll { sample in old.contains { $0 === sample } }
    }

    /// Lets the held save return, writing nothing.
    func releaseHeldSave() {
        heldSave?.resume()
        heldSave = nil
    }
}
